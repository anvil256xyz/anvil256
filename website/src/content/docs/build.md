---
title: Build from Source
slug: build
---
# Anvil256 — Build from Source

## Prerequisites

| Component | Tool | Min version |
|-----------|------|-------------|
| Contracts | Foundry (`forge` + `cast`) | 0.2.x |
| CLI | Rust toolchain | 1.78 |
| Kernel (NVIDIA) | CUDA toolkit (`nvcc`) | 12.3 |
| Kernel (AMD/Intel) | OpenCL SDK (`opencl-headers`) | 3.0 |
| Website | Node.js + pnpm | 20.x |

---

## Reproducible Build (Recommended)

```bash
docker run --rm -v $PWD:/src ghcr.io/anvil256/builder:latest
ls dist/       # binaries + sha256sums.txt
```

The Docker image pins exact compiler versions. The output `sha256sums.txt`
must match the official release. Verify:

```bash
sha256sum -c dist/sha256sums.txt
```

---

## Native Build

### Contracts

```bash
cd contracts/
forge install          # OpenZeppelin, forge-std
forge build            # compiles Anvil256.sol + all sub-contracts
forge test -vvv        # full test suite + fuzz runs
```

Key contracts and their role:

| Contract | Role |
|----------|------|
| `Anvil256.sol` | Core: mine(), ERC-20, halving, fee, epoch counter |
| `CascadePoW.sol` | τ + inner + outer Cascade verification |
| `PIController.sol` | PI + NCT combined difficulty update |
| `MinerWindow.sol` | 256-slot circular buffer + `uniqueCount` + `windowFreq` |
| `FixedPointMath.sol` | Q60.18, 4th-order Maclaurin exp, O(1) log₂ |
| `FeeOracle.sol` | Chainlink ETH/USD → fee_wei |

### CLI

```bash
cd cli/
cargo build --release    # produces target/release/anvil256-cli
cargo test --release
```

The CLI is responsible for:
- Reading `γ(miner) = minerEpochCount[address]` from the contract
- Reading `epochEntropy` from the contract
- Computing `τ = H(miner ∥ γ ∥ genesis)` and `inner = H(τ ∥ epoch)`
- Dispatching the kernel job with the derived `inner` value (not the raw address)
- Watching for epoch transitions and re-dispatching immediately

### Kernel — CUDA (NVIDIA)

```bash
cd kernel/
make cuda                    # produces ./miner
make cuda ARCHS="75 80 86 89 90"  # fat binary for multiple SM architectures
```

### Kernel — OpenCL (AMD / Intel / fallback)

```bash
cd kernel/
make opencl              # produces ./miner-opencl
```

### Website

```bash
cd website/
pnpm install
pnpm dev       # local preview at http://localhost:4321
pnpm build     # produces dist/
```

---

## Cross-Compilation

| Target | Method |
|--------|--------|
| `linux-x86_64-gnu` | native or `cross` Docker |
| `linux-aarch64-gnu` | `cross build --target aarch64-unknown-linux-gnu` |
| `darwin-arm64` | on macOS: `cargo build --target aarch64-apple-darwin` |
| `windows-x64-msvc` | `cargo build --target x86_64-pc-windows-msvc` |

CUDA kernel cross-compilation is not supported. Build natively on the target platform.

---

## Test Coverage Targets

| Suite | Target | Critical property verified |
|-------|--------|---------------------------|
| `CascadePoW.t.sol` | 100% branch | Two-pass correctness; γ-binding rejection |
| `PIController.t.sol` | 100% branch | Steady-state convergence; NCT; anti-windup |
| `MinerWindow.t.sol` | 100% branch | Circular buffer invariants; uniqueCount accuracy |
| `FixedPointMath.t.sol` | 100% branch | exp4 error bound; log2Floor exactness |
| Fuzz | ≥ 10,000 runs | Supply cap; epoch monotonicity; fee accounting |
| Integration (CLI) | End-to-end | γ fetch → kernel → submit → receipt → γ increment |