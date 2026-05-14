//! On-chain glue: typed bindings + state snapshots.

use std::sync::Arc;

use ethers::core::types::U256;
use ethers::prelude::*;

use crate::config::Config;
use crate::error::{CliError, CliResult};

abigen!(
    Anvil256,
    "src/abi/anvil256.json"
);

pub type SignerProvider = SignerMiddleware<Provider<Http>, LocalWallet>;
pub type AnvilContract  = Anvil256<SignerProvider>;

/// Atomic snapshot of every on-chain value needed to dispatch one kernel job.
#[derive(Debug, Clone)]
pub struct ChainState {
    pub epoch:         u64,
    pub difficulty:    [u8; 32],
    pub reward:        U256,
    pub inner:         [u8; 32],
    pub epoch_entropy: [u8; 32],
    pub fee_wei:       U256,
    pub gamma:         u64,
}

/// Build a signer-bound contract handle from the config.
pub async fn build(cfg: &Config) -> CliResult<Arc<AnvilContract>> {
    let provider = Provider::<Http>::try_from(cfg.rpc_url.as_str())
        .map_err(|e| CliError::Rpc(format!("provider: {e}")))?;
    let chain_id = provider
        .get_chainid()
        .await
        .map_err(|e| CliError::Rpc(format!("chain_id: {e}")))?
        .as_u64();
    let wallet: LocalWallet = cfg
        .private_key
        .parse::<LocalWallet>()
        .map_err(|_| CliError::InvalidPrivateKey)?
        .with_chain_id(chain_id);

    let signer = SignerMiddleware::new(provider, wallet);
    Ok(Arc::new(Anvil256::new(cfg.contract, Arc::new(signer))))
}

fn map_call_err(e: ContractError<SignerProvider>) -> CliError {
    let msg = format!("{e}");
    if msg.contains("StaleOracle")
        || msg.contains("InvalidOracle")
        || msg.contains("OracleClockSkew")
        || msg.contains("OracleDecimalsTooLarge")
    {
        CliError::FeeOracleStale(msg)
    } else {
        CliError::Rpc(msg)
    }
}

/// Read every on-chain value the miner needs for one round.
///
/// Sequential calls avoid the E0716 lifetime issue that arises when
/// ContractCall builders (which borrow `c`) are held across try_join! await
/// points. The extra latency is negligible (~7 × 1 ms on a local RPC).
pub async fn snapshot(c: &AnvilContract, miner: Address) -> CliResult<ChainState> {
    let epoch         = c.current_epoch().call().await.map_err(map_call_err)?;
    let difficulty    = c.current_difficulty().call().await.map_err(map_call_err)?;
    let reward        = c.current_reward().call().await.map_err(map_call_err)?;
    let fee_wei       = c.current_fee_wei().call().await.map_err(map_call_err)?;
    let inner         = c.get_inner(miner).call().await.map_err(map_call_err)?;
    let epoch_entropy = c.epoch_entropy().call().await.map_err(map_call_err)?;
    let gamma         = c.miner_epoch_count(miner).call().await.map_err(map_call_err)?;

    let mut d = [0u8; 32];
    difficulty.to_big_endian(&mut d);

    Ok(ChainState {
        epoch:         epoch.as_u64(),
        difficulty:    d,
        reward,
        inner,
        epoch_entropy,
        fee_wei,
        gamma,
    })
}