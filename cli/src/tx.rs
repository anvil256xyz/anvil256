//! Mine-tx construction and submission.
//!
//! Responsibilities:
//!
//! 1. Read the on-chain protocol fee (Chainlink-derived) and attach it as
//!    `msg.value` to the `mine(nonce)` call.
//! 2. Estimate gas, compute EIP-1559 fees, and abort if the *gas* cost (not
//!    counting the protocol fee) exceeds the operator's budget in USD.
//! 3. Broadcast and wait for the receipt; on revert, surface the on-chain
//!    error in the log.

use ethers::core::types::{Eip1559TransactionRequest, TxHash, U256};
use ethers::middleware::Middleware;
use ethers::types::NameOrAddress;
use tracing::{info, warn};

use crate::chain::AnvilContract;
use crate::config::Config;
use crate::error::{CliError, CliResult};

#[derive(Debug, Clone)]
pub struct GasPlan {
    pub gas_limit:           U256,
    pub max_fee_per_gas:     U256,
    pub max_priority_per_gas:U256,
    pub fee_wei:             U256,
    pub gas_cost_wei:        U256,
    pub gas_cost_usd:        f64,
}

/// Build a tx plan + run the local gas cap check. Does NOT broadcast.
pub async fn plan_mine(
    c: &AnvilContract,
    cfg: &Config,
    nonce: U256,
) -> CliResult<GasPlan> {
    // 1. Protocol fee — must be attached as msg.value. Classify any of the
    //    typed errors raised by FeeOracle.sol
    //      (StaleOracle / InvalidOracle / OracleClockSkew / OracleDecimalsTooLarge)
    //    as `FeeOracleStale` so the supervisor retries instead of aborting.
    let fee_wei: U256 = c
        .current_fee_wei()
        .call()
        .await
        .map_err(|e| {
            let m = format!("{e}");
            if m.contains("StaleOracle")
                || m.contains("InvalidOracle")
                || m.contains("OracleClockSkew")
                || m.contains("OracleDecimalsTooLarge")
            {
                CliError::FeeOracleStale(m)
            } else {
                CliError::Rpc(m)
            }
        })?;

    // 1b. Protocol fee budget check (USD). The on-chain fee is recomputed
    //     every block from a Chainlink ETH/USD feed, so a downward spike
    //     in the feed pushes fee_wei up sharply. Reject the round when the
    //     fee exceeds the operator's cap; the supervisor will back off and
    //     retry on the next round, by which time the feed has typically
    //     recovered.
    let fee_usd = wei_to_usd(fee_wei, cfg.eth_price_usd);
    if fee_usd > cfg.max_fee_usd {
        return Err(CliError::FeeCapExceeded {
            est: fee_usd,
            cap: cfg.max_fee_usd,
        });
    }

    // 2. EIP-1559 fees.
    //
    //    All arithmetic on `U256` is done with saturating ops: the bare `*`
    //    / `+` operators panic on overflow, and a pathological RPC response
    //    (e.g. a malicious node that reports a huge `base_fee_per_gas`)
    //    would otherwise crash the entire CLI before the local gas-cap
    //    check has a chance to reject it. Saturated values flow into
    //    `wei_to_usd`, which returns `f64::INFINITY` past 2¹²⁸, so the
    //    GasCapExceeded check fires correctly.
    let client = c.client();
    let block  = client
        .get_block(ethers::core::types::BlockNumber::Latest)
        .await
        .map_err(|e| CliError::Rpc(format!("get_block: {e}")))?
        .ok_or_else(|| CliError::Rpc("no latest block".into()))?;
    let base_fee = block
        .base_fee_per_gas
        .ok_or_else(|| CliError::Rpc("no base fee (pre-1559 chain?)".into()))?;
    let priority_gwei = cfg.priority_fee_gwei.max(0.0);
    let priority      = U256::from((priority_gwei * 1e9) as u64);
    let max_fee       = base_fee
        .saturating_mul(U256::from(3u64))
        .saturating_add(priority);

    // 3. Gas estimate (passes msg.value so the simulated call actually
    //    succeeds, otherwise estimate_gas would revert with InsufficientFee).
    let mine_call = c.mine(nonce).value(fee_wei);
    let est_gas   = mine_call
        .estimate_gas()
        .await
        .map_err(|e| CliError::Rpc(format!("estimate_gas: {e}")))?;
    // 1.5× safety buffer; saturating so a pathologically large estimate
    // can't overflow U256.
    let gas_limit    = est_gas
        .saturating_mul(U256::from(3u64))
        / U256::from(2u64);
    let gas_cost_wei = max_fee.saturating_mul(gas_limit);
    let gas_cost_usd = wei_to_usd(gas_cost_wei, cfg.eth_price_usd);

    if gas_cost_usd > cfg.max_gas_usd {
        return Err(CliError::GasCapExceeded {
            est: gas_cost_usd,
            cap: cfg.max_gas_usd,
        });
    }

    Ok(GasPlan {
        gas_limit,
        max_fee_per_gas: max_fee,
        max_priority_per_gas: priority,
        fee_wei,
        gas_cost_wei,
        gas_cost_usd,
    })
}

/// Broadcast the mine() transaction and wait for the receipt.
pub async fn submit_mine(
    c: &AnvilContract,
    plan: &GasPlan,
    nonce: U256,
) -> CliResult<TxHash> {
    info!(
        fee_wei = %plan.fee_wei,
        gas_limit = %plan.gas_limit,
        gas_cost_usd = plan.gas_cost_usd,
        "submitting mine() transaction"
    );

    let call = c
        .mine(nonce)
        .value(plan.fee_wei)
        .gas(plan.gas_limit);

    let tx: Eip1559TransactionRequest = {
        let mut t: Eip1559TransactionRequest = call.tx.clone().into();
        t = t
            .max_fee_per_gas(plan.max_fee_per_gas)
            .max_priority_fee_per_gas(plan.max_priority_per_gas);
        if t.to.is_none() {
            if let Some(NameOrAddress::Address(addr)) = call.tx.to() {
                t = t.to(*addr);
            }
        }
        t
    };

    let client  = c.client();
    let pending = client
        .send_transaction(tx, None)
        .await
        .map_err(|e| CliError::Rpc(format!("send_tx: {e}")))?;
    let tx_hash = pending.tx_hash();

    let receipt = pending
        .await
        .map_err(|e| CliError::Rpc(format!("await receipt: {e}")))?
        .ok_or_else(|| CliError::Rpc("receipt missing".into()))?;

    if receipt.status != Some(1u64.into()) {
        warn!(?receipt, "mine() reverted");
        return Err(CliError::TxReverted(format!("{tx_hash:?}")));
    }

    info!(?tx_hash, "mine() confirmed");
    Ok(tx_hash)
}

/// Convert wei (U256) → USD (f64), saturating at f64::INFINITY for values
/// that don't fit in u128. `U256::as_u128()` panics on values > 2^128 - 1,
/// which would crash the CLI on a pathological RPC response — guard
/// explicitly so the worst case is a (correctly!) failing gas cap check.
fn wei_to_usd(wei: U256, eth_price_usd: f64) -> f64 {
    if wei.bits() > 128 {
        return f64::INFINITY;
    }
    let eth: f64 = (wei.as_u128() as f64) / 1e18;
    eth * eth_price_usd
}