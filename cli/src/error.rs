//! Error taxonomy.
//!
//! Errors are split into two camps via `is_retryable()`:
//!
//! * **Fatal**     – cannot recover by retrying the same operation (bad
//!                   config, invalid private key, contract address points at
//!                   a non-contract account, …).
//! * **Retryable** – transient network / state-of-the-world issues (RPC
//!                   timeout, epoch changed mid-search, gas spike, fee
//!                   oracle stale). Caller should sleep + try again.

use std::io;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum CliError {
    #[error("config: {0}")]
    Config(String),

    #[error("invalid private key")]
    InvalidPrivateKey,

    #[error("invalid RPC url: {0}")]
    InvalidRpc(String),

    #[error("miner subprocess spawn failed: {0}")]
    MinerSpawn(#[source] io::Error),

    #[error("miner subprocess closed stdout (EOF)")]
    MinerEof,

    #[error("miner subprocess stdin broken (EPIPE)")]
    MinerBrokenPipe,

    #[error("could not parse miner event: {0}")]
    MinerParse(String),

    #[error("rpc: {0}")]
    Rpc(String),

    #[error("transaction reverted: {0}")]
    TxReverted(String),

    #[error("gas budget exceeded: estimated ${est:.4}, cap ${cap:.4}")]
    GasCapExceeded { est: f64, cap: f64 },

    #[error("protocol fee budget exceeded: current ${est:.4}, cap ${cap:.4}")]
    FeeCapExceeded { est: f64, cap: f64 },

    #[error("protocol fee oracle stale or unreachable: {0}")]
    FeeOracleStale(String),

    #[error("epoch changed mid-search (old={old}, new={new})")]
    EpochChanged { old: u64, new: u64 },

    #[error("search timed out after {0}s")]
    SearchTimeout(u64),

    #[error(transparent)]
    Io(#[from] io::Error),

    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl CliError {
    /// True iff the caller should sleep and retry instead of aborting.
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            CliError::Rpc(_)
                | CliError::FeeOracleStale(_)
                | CliError::EpochChanged { .. }
                | CliError::SearchTimeout(_)
                | CliError::GasCapExceeded { .. }
                | CliError::FeeCapExceeded { .. }
                | CliError::MinerBrokenPipe
                | CliError::MinerEof
                | CliError::MinerParse(_)
        )
    }

    /// True iff the error indicates the GPU kernel subprocess is no longer
    /// healthy and the supervisor should re-spawn it before the next round.
    pub fn is_miner_failure(&self) -> bool {
        matches!(
            self,
            CliError::MinerBrokenPipe
                | CliError::MinerEof
                | CliError::MinerParse(_)
        )
    }
}

pub type CliResult<T> = Result<T, CliError>;
