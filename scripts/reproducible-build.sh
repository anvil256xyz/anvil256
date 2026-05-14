#!/usr/bin/env bash
# =====================================================================
# Reproducible build harness for Anvil256.
#
# Runs inside ghcr.io/anvil256/builder:<tag> which pins:
#   - rustc + cargo (locked Cargo.lock)
#   - nvcc (CUDA toolkit)
#   - g++, make
#
# Inputs:
#   $TAG          required, e.g. v0.1.0
#   $OUT_DIR      defaults to ./dist
#
# Output:
#   $OUT_DIR/anvil256-cli              (release binary)
#   $OUT_DIR/anvil256-miner            (CUDA kernel)
#   $OUT_DIR/sha256sums.txt
# =====================================================================
set -euo pipefail

: "${TAG:?TAG env var is required, e.g. v0.1.0}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"

mkdir -p "$OUT_DIR"

echo "==> reproducible build for tag $TAG"
echo "    root    : $ROOT"
echo "    out_dir : $OUT_DIR"

# ----------- CLI -----------
echo "==> building CLI (Rust)"
( cd "$ROOT/cli" && cargo build --release --locked )
cp "$ROOT/cli/target/release/anvil256-cli" "$OUT_DIR/"

# ----------- kernel -----------
echo "==> building kernel (CUDA)"
( cd "$ROOT/kernel" && make clean && make cuda ARCHS="${ARCHS:-75 80 86 89 90}" )
cp "$ROOT/kernel/miner" "$OUT_DIR/anvil256-miner"

# ----------- attestation -----------
echo "==> producing sha256sums.txt"
( cd "$OUT_DIR" && sha256sum anvil256-cli anvil256-miner > sha256sums.txt )

echo
echo "==> done"
cat "$OUT_DIR/sha256sums.txt"
