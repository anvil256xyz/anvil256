//! Configuration layering: defaults < .env file < CLI flags < environment.

use std::path::PathBuf;

use clap::Parser;
use ethers::types::Address;
use url::Url;

use crate::error::{CliError, CliResult};

/// Command-line interface (parsed by clap).
#[derive(Parser, Debug, Clone)]
#[command(name = "anvil256-cli", version, about = "Anvil256 reference mining client")]
pub struct Cli {
    /// Path to .env file to load (default: ./.env if present).
    #[arg(long, env = "ANVIL256_ENV_FILE")]
    pub env_file: Option<PathBuf>,

    /// RPC endpoint URL. Overrides BASE_RPC_URL.
    #[arg(long, env = "BASE_RPC_URL")]
    pub rpc_url: Option<String>,

    /// Hex-encoded 32-byte private key (with or without 0x).
    #[arg(long, env = "PRIVATE_KEY")]
    pub private_key: Option<String>,

    /// Anvil256 contract address.
    #[arg(long, env = "ANVIL256_ADDRESS")]
    pub contract: Option<Address>,

    /// Hard cap on the *gas* component of a mine() tx, in USD.
    #[arg(long, env = "MAX_GAS_USD", default_value_t = 0.05)]
    pub max_gas_usd: f64,

    /// Hard cap on the *protocol fee* component of a mine() tx, in USD.
    /// The contract computes the fee from a Chainlink ETH/USD feed and
    /// expects msg.value >= currentFeeWei(). The fee is nominally $0.10 but
    /// scales with the oracle price. Abort the round if the oracle reports a
    /// fee above this cap.
    #[arg(long, env = "MAX_FEE_USD", default_value_t = 0.15)]
    pub max_fee_usd: f64,

    /// Path to the kernel binary.
    /// If not set, the CLI probes ./bin/miner (CUDA) then ./bin/miner-cpu
    /// (CPU fallback built with `make cpu`) and uses the first one that exists.
    #[arg(long, env = "MINER_BIN")]
    pub miner_bin: Option<PathBuf>,

    /// Print effective config and exit.
    #[arg(long, default_value_t = false)]
    pub print_config: bool,
}

/// Effective runtime configuration after merging all sources.
///
/// `Debug` is implemented manually so that `--print-config` never leaks the
/// private key. The raw value remains accessible via `Config::private_key`
/// for the signer middleware in `chain::build`.
#[derive(Clone)]
pub struct Config {
    pub rpc_url:           Url,
    pub private_key:       String,
    pub contract:          Address,
    pub max_gas_usd:       f64,
    pub max_fee_usd:       f64,
    pub priority_fee_gwei: f64,
    pub eth_price_usd:     f64,
    pub miner_bin:         PathBuf,
    pub miner_devices:     Vec<u32>,
    pub miner_npt:         u32,
    pub miner_block:       u32,
    pub miner_target_ms:   u32,
    pub max_search_secs:   u64,
    pub keep_mining:       bool,
    pub log_format:        String,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Redact the private key. The fingerprint is just the last 4 hex
        // characters of the hex-stripped key, which is enough for the
        // operator to confirm "yes, the CLI loaded the key I expected"
        // without exposing the secret in logs or stdout.
        let pk_stripped = self.private_key.strip_prefix("0x").unwrap_or(&self.private_key);
        let fingerprint = pk_stripped
            .get(pk_stripped.len().saturating_sub(4)..)
            .unwrap_or("????");

        f.debug_struct("Config")
            .field("rpc_url",           &self.rpc_url)
            .field("private_key",       &format_args!("[redacted, ...{fingerprint}]"))
            .field("contract",          &self.contract)
            .field("max_gas_usd",       &self.max_gas_usd)
            .field("max_fee_usd",       &self.max_fee_usd)
            .field("priority_fee_gwei", &self.priority_fee_gwei)
            .field("eth_price_usd",     &self.eth_price_usd)
            .field("miner_bin",         &self.miner_bin)
            .field("miner_devices",     &self.miner_devices)
            .field("miner_npt",         &self.miner_npt)
            .field("miner_block",       &self.miner_block)
            .field("miner_target_ms",   &self.miner_target_ms)
            .field("max_search_secs",   &self.max_search_secs)
            .field("keep_mining",       &self.keep_mining)
            .field("log_format",        &self.log_format)
            .finish()
    }
}

impl Config {
    pub fn load(cli: &Cli) -> CliResult<Self> {
        if let Some(p) = &cli.env_file {
            dotenvy::from_path(p)
                .map_err(|e| CliError::Config(format!("env_file {:?}: {e}", p)))?;
        } else {
            let _ = dotenvy::dotenv();
        }

        let rpc_raw = cli
            .rpc_url
            .clone()
            .or_else(|| std::env::var("BASE_RPC_URL").ok())
            .ok_or_else(|| CliError::Config("BASE_RPC_URL not set".into()))?;
        let rpc_url = Url::parse(&rpc_raw)
            .map_err(|e| CliError::InvalidRpc(format!("{rpc_raw}: {e}")))?;

        let private_key = cli
            .private_key
            .clone()
            .or_else(|| std::env::var("PRIVATE_KEY").ok())
            .ok_or_else(|| CliError::Config("PRIVATE_KEY not set".into()))?;
        Self::validate_pk(&private_key)?;

        let contract = match cli.contract {
            Some(a) => a,
            None => std::env::var("ANVIL256_ADDRESS")
                .map_err(|_| CliError::Config("ANVIL256_ADDRESS not set".into()))?
                .parse()
                .map_err(|e| CliError::Config(format!("ANVIL256_ADDRESS parse: {e}")))?,
        };

        let priority_fee_gwei = env_f64("PRIORITY_FEE_GWEI", 0.001)?;
        let eth_price_usd     = env_f64("ETH_PRICE_USD",    2500.0)?;
        let miner_npt         = env_u32("MINER_NPT",        128)?;
        let miner_block       = env_u32("MINER_BLOCK",      128)?;
        let miner_target_ms   = env_u32("MINER_TARGET_BATCH_MS", 250)?;
        let max_search_secs   = env_u64("MAX_SEARCH_SECS",  300)?;
        let keep_mining       = env_bool("KEEP_MINING",     true)?;
        let log_format        = std::env::var("LOG_FORMAT")
            .unwrap_or_else(|_| "text".into());

        let miner_devices = std::env::var("MINER_DEVICES")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .map(|s| {
                s.split(',')
                    .map(|p| p.trim().parse::<u32>())
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()
            .map_err(|e| CliError::Config(format!("MINER_DEVICES parse: {e}")))?
            .unwrap_or_default();

        // Resolve miner binary: explicit flag/env → CUDA → CPU fallback.
        let miner_bin = match cli.miner_bin.clone() {
            Some(p) => {
                if !p.exists() {
                    return Err(CliError::Config(format!(
                        "MINER_BIN {:?} does not exist", p
                    )));
                }
                p
            }
            None => {
                let cuda = PathBuf::from("./bin/miner");
                let cpu  = PathBuf::from("./bin/miner-cpu");
                if cuda.exists() {
                    cuda
                } else if cpu.exists() {
                    cpu
                } else {
                    return Err(CliError::Config(
                        "no miner binary found: tried ./bin/miner (CUDA) and                          ./bin/miner-cpu (CPU). Build with `make cuda` or `make cpu`."
                            .into(),
                    ));
                }
            }
        };

        Ok(Self {
            rpc_url,
            private_key,
            contract,
            max_gas_usd: cli.max_gas_usd,
            max_fee_usd: cli.max_fee_usd,
            priority_fee_gwei,
            eth_price_usd,
            miner_bin,
            miner_devices,
            miner_npt,
            miner_block,
            miner_target_ms,
            max_search_secs,
            keep_mining,
            log_format,
        })
    }

    fn validate_pk(s: &str) -> CliResult<()> {
        let hex = s.strip_prefix("0x").unwrap_or(s);
        if hex.len() != 64 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(CliError::InvalidPrivateKey);
        }
        Ok(())
    }
}

fn env_f64(key: &str, default: f64) -> CliResult<f64> {
    match std::env::var(key) {
        Ok(s) => s.parse().map_err(|e| CliError::Config(format!("{key} parse: {e}"))),
        Err(_) => Ok(default),
    }
}
fn env_u32(key: &str, default: u32) -> CliResult<u32> {
    match std::env::var(key) {
        Ok(s) => s.parse().map_err(|e| CliError::Config(format!("{key} parse: {e}"))),
        Err(_) => Ok(default),
    }
}
fn env_u64(key: &str, default: u64) -> CliResult<u64> {
    match std::env::var(key) {
        Ok(s) => s.parse().map_err(|e| CliError::Config(format!("{key} parse: {e}"))),
        Err(_) => Ok(default),
    }
}
fn env_bool(key: &str, default: bool) -> CliResult<bool> {
    match std::env::var(key) {
        Ok(s) => match s.trim().to_ascii_lowercase().as_str() {
            "1" | "true"  | "yes" | "y" | "on"  => Ok(true),
            "0" | "false" | "no"  | "n" | "off" => Ok(false),
            other => Err(CliError::Config(format!("{key} invalid bool: {other}"))),
        },
        Err(_) => Ok(default),
    }
}