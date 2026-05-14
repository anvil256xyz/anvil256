//! Anvil256 reference mining client.
//!
//! High-level flow:
//!
//!   1. Load config (.env + CLI flags).
//!   2. Connect to RPC, sanity-check the contract.
//!   3. Spawn the GPU kernel as a subprocess; wait for its `ready` event.
//!   4. Loop:
//!        a. Snapshot on-chain state (epoch, difficulty, fee, γ, ι, ε).
//!        b. Send a JOB(ι, ε, D, job_id) to the kernel.
//!        c. Read events until `found`, then build + submit a mine() tx.
//!        d. On retryable errors, sleep + retry.
//!        e. On Ctrl+C, send EXIT to the kernel and quit.

mod chain;
mod config;
mod error;
mod miner_proc;
mod telemetry;
mod tx;

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use ethers::types::U256;
use tokio::signal;
use tokio::time::{sleep, timeout};
use tracing::{error, info, warn};

use crate::chain::{AnvilContract, ChainState};
use crate::config::{Cli, Config};
use crate::error::{CliError, CliResult};
use crate::miner_proc::{Miner, MinerCmd, MinerEvent};

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let cfg = Config::load(&cli).context("loading config")?;
    telemetry::init(&cfg.log_format);

    if cli.print_config {
        println!("{cfg:#?}");
        return Ok(());
    }

    info!(
        rpc = %cfg.rpc_url,
        contract = ?cfg.contract,
        "Anvil256 CLI starting"
    );

    let contract = chain::build(&cfg).await.context("rpc connect")?;
    let miner_addr = contract.client().address();
    info!(?miner_addr, "signer ready");
    info!(bin = ?cfg.miner_bin, "kernel binary selected");

    // Wrap the miner handle in an `Option` so we can `take()` it on failure
    // and replace it with a freshly-spawned subprocess without tripping the
    // borrow checker on `&mut miner` inside `run_round`.
    let mut miner_slot: Option<Miner> = Some(
        spawn_and_init(&cfg.miner_bin)
            .await
            .with_context(|| format!("spawning kernel at {:?}", cfg.miner_bin))?,
    );

    let shutdown_task = tokio::spawn(signal_shutdown());

    let mut job_id: u64 = 0;
    loop {
        if SHUTDOWN.load(Ordering::Relaxed) {
            break;
        }
        job_id += 1;
        let miner = miner_slot
            .as_mut()
            .expect("miner slot must be populated at top of loop");
        match run_round(&cfg, &contract, miner, job_id, miner_addr).await {
            Ok(()) => {
                if !cfg.keep_mining {
                    break;
                }
            }
            Err(e) if e.is_miner_failure() => {
                warn!("kernel subprocess failure ({e}); respawning");
                // Drop the broken handle so the OS reclaims pipes / pid
                if let Some(old) = miner_slot.take() {
                    let _ = old.shutdown().await;
                }
                sleep(Duration::from_secs(1)).await;
                match spawn_and_init(&cfg.miner_bin).await {
                    Ok(fresh) => {
                        miner_slot = Some(fresh);
                    }
                    Err(respawn_err) => {
                        error!("kernel respawn failed: {respawn_err}");
                        break;
                    }
                }
            }
            Err(e) if e.is_retryable() => {
                warn!("retryable error: {e}; sleeping 2s");
                sleep(Duration::from_secs(2)).await;
            }
            Err(e) => {
                error!("fatal error: {e}");
                break;
            }
        }
    }

    info!("shutting down kernel");
    if let Some(m) = miner_slot.take() {
        let _ = m.shutdown().await;
    }
    // Abort the SIGINT-waiter so it does not block process exit when we are
    // shutting down for a non-signal reason (one-shot mining done, fatal
    // error, etc.). Without this, `tokio::signal::ctrl_c().await` never
    // resolves and `shutdown_task.await` would hang the process forever.
    shutdown_task.abort();
    let _ = shutdown_task.await;
    Ok(())
}

/// Spawn the kernel binary, wait for the initial `ready` event, and log the
/// bound devices. Returns a live `Miner` handle ready to receive a `JOB`.
async fn spawn_and_init(bin: &std::path::Path) -> anyhow::Result<Miner> {
    let mut miner = Miner::spawn(bin)
        .await
        .with_context(|| format!("spawning kernel at {:?}", bin))?;
    info!("waiting for kernel ready event");
    match miner.next_event().await? {
        MinerEvent::Ready { devices } => {
            for d in &devices {
                info!(
                    index = d.index,
                    name = %d.name,
                    cu = d.cu,
                    wg = d.wg,
                    grid = d.grid,
                    npt = d.npt,
                    "kernel device"
                );
            }
        }
        MinerEvent::Error { message } => {
            anyhow::bail!("kernel failed to initialize: {message}");
        }
        other => anyhow::bail!("expected ready event, got: {other:?}"),
    }
    Ok(miner)
}

/// Maximum gap between two kernel events. The kernel emits `progress` once
/// per launch batch (~250 ms target), so 30 s of complete silence means it
/// has hung, GPU-reset, or the parent of a runtime fault has eaten our
/// stderr. Treat as a subprocess failure so the supervisor can respawn it.
const KERNEL_HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(30);

async fn run_round(
    cfg: &Config,
    contract: &AnvilContract,
    miner: &mut Miner,
    job_id: u64,
    miner_addr: ethers::types::Address,
) -> CliResult<()> {
    let snap = chain::snapshot(contract, miner_addr).await?;
    log_state(&snap);

    let started_at = Instant::now();
    let mut last_event = Instant::now();
    let budget = Duration::from_secs(cfg.max_search_secs);

    miner
        .send(MinerCmd::Job {
            inner:         snap.inner,
            epoch_entropy: snap.epoch_entropy,
            difficulty:    snap.difficulty,
            job:           job_id,
        })
        .await?;

    loop {
        if SHUTDOWN.load(Ordering::Relaxed) {
            return Ok(());
        }
        let elapsed = started_at.elapsed();
        if elapsed >= budget {
            let _ = miner.send(MinerCmd::Stop).await;
            return Err(CliError::SearchTimeout(cfg.max_search_secs));
        }

        // Wait up to `min(remaining budget, kernel heartbeat timeout)` for
        // the next kernel event. Without an explicit timeout a stuck kernel
        // would freeze `run_round` indefinitely (next_event blocks on
        // stdout) — neither the SearchTimeout watchdog nor SHUTDOWN ever
        // fire if no line ever arrives.
        let since_last  = last_event.elapsed();
        let until_heart = KERNEL_HEARTBEAT_TIMEOUT.saturating_sub(since_last);
        let until_end   = budget - elapsed;
        let wait        = until_heart.min(until_end);

        let evt = match timeout(wait, miner.next_event()).await {
            Ok(r) => r?,
            Err(_) => {
                if last_event.elapsed() >= KERNEL_HEARTBEAT_TIMEOUT {
                    // Kernel silent for ≥ HEARTBEAT — classify as a
                    // subprocess failure so main() respawns it.
                    warn!(
                        secs = KERNEL_HEARTBEAT_TIMEOUT.as_secs(),
                        "kernel emitted no events; declaring it dead"
                    );
                    return Err(CliError::MinerEof);
                }
                // Otherwise the per-iteration timeout fired only because
                // we reached the overall search budget; loop back and the
                // `elapsed >= budget` check above will return SearchTimeout.
                continue;
            }
        };
        last_event = Instant::now();

        match evt {
            MinerEvent::Progress { job, device, hashrate, elapsed_ms, hashes } => {
                if job != job_id {
                    warn!(event_job = job, expected_job = job_id, "ignoring stale progress event");
                    continue;
                }
                info!(
                    %device,
                    hashes,
                    hashrate_ghs = hashrate / 1e9,
                    elapsed_ms,
                    "mining"
                );
            }
            MinerEvent::Found { job, device, nonce, hash, hashrate, elapsed_ms } => {
                if job != job_id {
                    warn!(event_job = job, expected_job = job_id, "ignoring stale found event");
                    continue;
                }
                info!(%device, %nonce, %hash, hashrate_ghs = hashrate/1e9, elapsed_ms, "FOUND");
                let nonce_u256: U256 = U256::from_dec_str(&nonce)
                    .map_err(|e| CliError::MinerParse(format!("nonce: {e}")))?;

                let latest = chain::snapshot(contract, miner_addr).await?;
                if latest.epoch != snap.epoch {
                    return Err(CliError::EpochChanged {
                        old: snap.epoch,
                        new: latest.epoch,
                    });
                }

                let plan = tx::plan_mine(contract, cfg, nonce_u256).await?;
                tx::submit_mine(contract, &plan, nonce_u256).await?;
                return Ok(());
            }
            MinerEvent::Error { message } => {
                return Err(CliError::MinerParse(format!("kernel: {message}")));
            }
            MinerEvent::Ready { .. } => {
                // extra ready — ignore
            }
        }
    }
}

fn log_state(s: &ChainState) {
    info!(
        epoch          = s.epoch,
        gamma          = s.gamma,
        reward_wei     = %s.reward,
        fee_wei        = %s.fee_wei,
        difficulty_hex = format!("0x{}", hex::encode(s.difficulty)),
        inner_hex      = format!("0x{}", hex::encode(s.inner)),
        entropy_hex    = format!("0x{}", hex::encode(s.epoch_entropy)),
        "chain snapshot"
    );
}

async fn signal_shutdown() {
    if signal::ctrl_c().await.is_ok() {
        info!("SIGINT received");
        SHUTDOWN.store(true, Ordering::Relaxed);
    }
}
