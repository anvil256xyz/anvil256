//! Subprocess supervisor for the GPU kernel.
//!
//! Speaks the JSON protocol documented in `kernel/include/protocol.h`.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

use crate::error::{CliError, CliResult};

/// Maximum time we will wait for the kernel to honour an `EXIT` request
/// before SIGKILL-ing it. Bounded so a hung kernel cannot block the CLI
/// from exiting cleanly on Ctrl+C.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

/* ====================== events from kernel ====================== */

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum MinerEvent {
    Ready {
        devices: Vec<DeviceInfo>,
    },
    Progress {
        job:        u64,
        device:     String,
        hashes:     u64,
        hashrate:   f64,
        elapsed_ms: u64,
    },
    Found {
        job:        u64,
        device:     String,
        nonce:      String, // u256 decimal
        hash:       String, // 0x-hex
        hashes:     u64,
        hashrate:   f64,
        elapsed_ms: u64,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Deserialize)]
pub struct DeviceInfo {
    pub index: u32,
    pub name:  String,
    pub cu:    u32,
    pub wg:    u32,
    #[serde(default)]
    pub grid:  u32,
    #[serde(default)]
    pub npt:   u32,
}

/* ====================== commands to kernel ====================== */

#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum MinerCmd {
    /// Dispatch one Cascade PoW search. Carries the two on-chain-derived
    /// 32-byte values the kernel needs: the inner hash ι(m,n) and the epoch
    /// entropy ε[n]. The kernel computes
    ///     κ = H(H(ι ‖ nonce_be32) ‖ ε)
    /// and emits FOUND when κ < difficulty (all big-endian).
    Job {
        inner:         [u8; 32],
        epoch_entropy: [u8; 32],
        difficulty:    [u8; 32],
        job:           u64,
    },
    Stop,
    Exit,
}

impl MinerCmd {
    /// Serialize to the whitespace-delimited format the kernel parses.
    /// Matches `kernel/include/protocol.h` exactly.
    fn to_line(&self) -> String {
        match self {
            MinerCmd::Job { inner, epoch_entropy, difficulty, job } => format!(
                "JOB {} {} {} {}\n",
                hex::encode(inner),
                hex::encode(epoch_entropy),
                hex::encode(difficulty),
                job
            ),
            MinerCmd::Stop => "STOP\n".to_string(),
            MinerCmd::Exit => "EXIT\n".to_string(),
        }
    }
}

/* ====================== supervisor ====================== */

pub struct Miner {
    child:  Child,
    stdin:  BufWriter<ChildStdin>,
    stdout: Lines<BufReader<ChildStdout>>,
}

impl Miner {
    pub async fn spawn(bin: &Path) -> CliResult<Self> {
        let mut cmd = Command::new(bin);
        cmd.stdin(Stdio::piped())
           .stdout(Stdio::piped())
           .stderr(Stdio::inherit())
           .kill_on_drop(true);

        let mut child = cmd
            .spawn()
            .map_err(CliError::MinerSpawn)?;

        let stdin  = child.stdin.take().ok_or(CliError::MinerBrokenPipe)?;
        let stdout = child.stdout.take().ok_or(CliError::MinerEof)?;

        Ok(Self {
            child,
            stdin:  BufWriter::new(stdin),
            stdout: BufReader::new(stdout).lines(),
        })
    }

    pub async fn send(&mut self, cmd: MinerCmd) -> CliResult<()> {
        let line = cmd.to_line();
        self.stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::BrokenPipe {
                    CliError::MinerBrokenPipe
                } else {
                    CliError::Io(e)
                }
            })?;
        self.stdin.flush().await.map_err(CliError::Io)?;
        Ok(())
    }

    pub async fn next_event(&mut self) -> CliResult<MinerEvent> {
        loop {
            let line = self.stdout
                .next_line()
                .await
                .map_err(CliError::Io)?
                .ok_or(CliError::MinerEof)?;

            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            return serde_json::from_str::<MinerEvent>(trimmed)
                .map_err(|e| CliError::MinerParse(format!("{e}: {trimmed}")));
        }
    }

    pub async fn shutdown(mut self) -> CliResult<()> {
        let _ = self.send(MinerCmd::Exit).await;
        // Bounded grace period: if the kernel ignores EXIT we SIGKILL it
        // ourselves rather than blocking the CLI's own exit forever.
        match timeout(SHUTDOWN_GRACE, self.child.wait()).await {
            Ok(_)  => {}
            Err(_) => { let _ = self.child.start_kill(); }
        }
        Ok(())
    }
}
