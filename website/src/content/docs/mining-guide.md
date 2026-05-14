---
title: Mining Guide
slug: mining-guide
---

# Anvil256 — Mining Guide

## How Anvil256 Mining Works — Mathematical Summary

Anvil256 uses **Keccak-Cascade PoW with Temporal Miner Binding**. The puzzle
for each epoch $n$ incorporates two values that are undetermined until specific
on-chain events occur:

**1. $\epsilon[n]$ (epoch entropy):**

$$
\epsilon[n] \;=\; H\!\bigl(\texttt{blockhash}(\texttt{lastMineBlock}[n{-}1]) \,\|\, D[n]\bigr)
$$

$\texttt{blockhash}(\texttt{lastMineBlock}[n{-}1])$ is produced by the sequencer
when epoch $n{-}1$ closes — a future event at any earlier time. By collision
resistance of $H$, no precomputed nonce is valid with probability better than
$D[n]/2^{256}$ (see SECURITY.md Theorem 4.1).

**2. $\gamma(m)$ (miner epoch counter):**

$$
\gamma(m) \;=\; \texttt{minerEpochCount}[m]
$$

Strictly monotonic, non-transferable, permanently tied to address $m$.
A new address has $\gamma = 0$ and receives a distinct but equally hard challenge.

**Full puzzle validity condition:**

$$
\kappa(m,\nu,n) \;=\; H\!\Bigl(H\!\bigl(H(m\,\|\,\gamma(m)\,\|\,g)\,\|\,n\,\|\,\nu\bigr)\;\Big\|\;\epsilon[n]\Bigr) \;<\; D[n]
$$

The CLI fetches both $\gamma(m)$ and $\epsilon[n]$ from the contract at the
start of each epoch before dispatching a kernel job.

---

## Hardware

Expected hashrate and mines-per-day estimates assume:
- Global hashrate $\mathcal{H}_{\text{global}} = 100\;\text{GH/s}$
- Target epoch time $\mathbb{E}[T_{\text{epoch}}] = 120\;\text{s}$
- Expected mines per day for hashrate $\mathcal{H}$:

$$
\mu \;=\; \frac{86{,}400}{120} \times \frac{\mathcal{H}}{\mathcal{H}_{\text{global}}}
\;=\; 720 \times \frac{\mathcal{H}}{\mathcal{H}_{\text{global}}}
$$

| Tier | GPU | $\mathcal{H}$ | $\mathcal{H}/\mathcal{H}_{\text{global}}$ | $\mu$ (mines/day) |
|------|-----|--------------|------------------------------------------|-------------------|
| Entry | RTX 3060 | 560 MH/s | 0.56% | $720 \times 0.0056 \approx 0.4$ |
| Mid | RTX 4060 Ti | 1.6 GH/s | 1.6% | $720 \times 0.016 \approx 1.1$ |
| High | RTX 4090 | 4.4 GH/s | 4.4% | $720 \times 0.044 \approx 3.2$ |
| Datacenter | H100 | 9.6 GH/s | 9.6% | $720 \times 0.096 \approx 6.9$ |
| AMD | RX 7900 XTX | 2.6 GH/s | 2.6% | $720 \times 0.026 \approx 1.9$ |
| CPU (24-core) | Ryzen 9 7950X | 35 MH/s | 0.035% | $720 \times 0.00035 \approx 0.25$ |

> **No GPU?** The CPU fallback (`miner-cpu`) runs on any Linux/Windows/macOS machine.
> Hashrate is ~20–80 MH/s depending on core count. Profitable only at very low global
> hashrate (early network) or as a learning/test setup.

**Why Cascade is ~20% slower than single-pass Keccak.** The kernel computes
two Keccak passes per nonce:

$$
\text{pass 1:}\; \text{mid} = H(\iota \,\|\, \nu), \qquad
\text{pass 2:}\; \text{result} = H(\text{mid} \,\|\, \epsilon[n])
$$

Pass 2 requires $\epsilon[n]$ held in GPU constant memory. This is not
avoidable: pass 2 is the anti-precompute layer (Theorem 4.1, SECURITY.md).
The 20% overhead is the mathematical price of structural precomputation immunity.

---

## Software Requirements

| Component | Requirement |
|-----------|-------------|
| OS | Linux kernel ≥ 5.10 (Ubuntu 22.04+ recommended), Windows 10/11, macOS 14+ |
| CUDA (GPU path) | CUDA Toolkit 11.8 or 12.x, driver ≥ 520 |
| CPU path | Any x86-64 or ARM64, C++17 compiler, pthreads |
| Rust (CLI build) | rustc ≥ 1.75 (stable), cargo |
| Solidity (contracts) | Foundry (`forge`, `cast`) |
| Wallet | ETH on Base L2 (≈$1 covers ≈9 mines at $0.108/mine) |
| RPC | Base L2 endpoint (Alchemy, Infura, or self-hosted) |

---

## Mining Economics — Exact Fee and Reserve Split

Each successful `mine()` requires the oracle-priced protocol fee:

$$
fee_{wei}=\frac{100{,}000\times 10^{20}}{p_{chainlink}}
$$

At ETH $=\$2{,}500$, $fee_{wei}=4\times10^{13}$ wei, i.e. $\$0.10$.
The fee is split inside the contract:

$$
fee = \$0.05_{dev}+\$0.05_{LP}
$$

The miner receives only the miner reward:

$$
M_{miner}(n)=R(n)
$$

The liquidity reserve receives an additional token mint:

$$
M_{LP}(n)=0.1R(n)
$$

At epoch 0:

$$
R(0)=50,\qquad M_{LP}(0)=5,\qquad M_{total}(0)=55\ \mathrm{ANVL}
$$

Miner break-even before gas and electricity is therefore:

$$
P_{BE}(0)=\frac{\$0.10}{50}=\$0.002/\mathrm{ANVL}
$$

This is not a profit guarantee. It is only the fee break-even price.

---

## Option A — Build from Source (Recommended)

Prebuilt tar releases are **not available yet**. Build locally from source so
you can inspect the code, reproduce the binaries, and trust your own toolchain.

### 1. Clone

```bash
git clone https://github.com/anvil256xyz/anvil256.git
cd anvil256
```

### 2. Build the kernel

For NVIDIA GPU mining, use the default CUDA target:

```bash
cd kernel
make
cd ..
```

Equivalent explicit GPU command:

```bash
cd kernel
make cuda ARCHS="89"    # change ARCHS for your GPU generation
cd ..
```

For CPU-only mining:

```bash
cd kernel
make cpu
cd ..
```

Expected outputs:

```bash
ls -lh cli/bin/
# miner       # CUDA GPU kernel, if built
# miner-cpu   # CPU fallback kernel, if built
```

### 3. Build the CLI

Install Rust first if `cargo` is not available:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
```

```bash
cd cli
cargo build --release --locked
```

The binary is written to:

```bash
./target/release/anvil256-cli
```

Keep running commands from `cli/`; the CLI expects kernel binaries under
`cli/bin/` by default.

### 4. Configure

```bash
cp .env.example .env
nano .env        # or: vim .env / code .env
```

Minimum required fields in `.env`:

```bash
# Base L2 RPC endpoint (get a free key from https://www.alchemy.com)
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_API_KEY

# Your mining wallet private key — NEVER share or commit this
PRIVATE_KEY=0xYOUR_PRIVATE_KEY_HERE

# Deployed Anvil256 contract address
ANVIL256_ADDRESS=0xYOUR_CONTRACT_ADDRESS_HERE
```

Full optional tuning reference:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_GAS_USD` | 0.05 | Abort round if L2 gas cost exceeds this USD cap |
| `MAX_FEE_USD` | 0.15 | Abort round if protocol fee exceeds this USD cap |
| `PRIORITY_FEE_GWEI` | 0.001 | EIP-1559 miner tip (negligible on Base) |
| `ETH_PRICE_USD` | 2500.0 | Fallback ETH price for gas estimation (overridden by oracle) |
| `MINER_BIN` | auto | Path to kernel binary (auto-detects GPU→CPU fallback) |
| `MINER_DEVICES` | all | Comma-separated GPU device indices, e.g. `0,1,2` |
| `MINER_NPT` | 128 | Nonces per thread per kernel launch |
| `MINER_TARGET_BATCH_MS` | 250 | Target ms per kernel batch |
| `MINER_PROGRESS_MS` | 750 | How often the kernel emits progress logs (CPU miner) |
| `MINER_THREADS` | nproc | Worker threads (CPU miner only) |
| `MAX_SEARCH_SECS` | 300 | Abandon search after this many seconds (retries next epoch) |
| `KEEP_MINING` | true | Set to `false` to mine exactly one epoch then exit |
| `LOG_FORMAT` | text | Set to `json` for structured logging (Datadog, Loki, etc.) |

### 5. Run

```bash
./target/release/anvil256-cli
```

Normal startup output:

```
INFO Anvil256 CLI starting  rpc=https://… contract=0x…
INFO signer ready            miner_addr=0xa0ee…
INFO kernel binary selected  bin="./bin/miner"
INFO waiting for kernel ready event
INFO kernel device           index=0 name="NVIDIA GeForce RTX 4060 Ti" cu=34 wg=128 grid=272 npt=128
INFO chain snapshot          epoch=0 gamma=0 reward_wei=50000000000000000000 fee_wei=43454266557161 difficulty_hex="0x000000…"
INFO mining                  device=RTX 4060 Ti hashes=200000000 hashrate_ghs=1.600 elapsed_ms=125
INFO FOUND                   device=RTX 4060 Ti nonce=8539386912708195224 hash=0x000000… hashrate_ghs=1.601 elapsed_ms=1234
INFO submitting mine()       fee_wei=43454266557161 gas_limit=198741 gas_cost_usd=0.0086
INFO mine() confirmed        tx_hash=0xbef7…
INFO chain snapshot          epoch=1 gamma=1 …
```

---

## Kernel Build Reference

The CLI auto-detects the kernel binary at runtime:
- First tries `./bin/miner` (CUDA)
- Falls back to `./bin/miner-cpu` (CPU)
- Fails with a clear error if neither exists

### GPU kernel (CUDA)

Requires CUDA Toolkit 11.8+ and `nvcc` in your `PATH`.

```bash
cd kernel

# Check nvcc is available
nvcc --version

# Build for your GPU architecture:
#   sm_75 = Turing  (RTX 20xx)
#   sm_80 = Ampere  (A100, RTX 30xx)
#   sm_86 = Ampere  (RTX 3060–3090)
#   sm_89 = Ada     (RTX 40xx)
#   sm_90 = Hopper  (H100)

# Single arch (fastest compile, smallest binary):
make cuda ARCHS="89"

# Multi-arch fat binary (distributable, works on multiple GPU gens):
make cuda ARCHS="75 80 86 89 90"

# Output:
ls -lh ../cli/bin/miner
```

### CPU kernel (no GPU required)

```bash
cd kernel    # if not already there

# Requires: g++ with C++17 support
g++ --version   # must be ≥ 7.0

make cpu

# Output:
ls -lh ../cli/bin/miner-cpu
```

### Build both GPU + CPU

```bash
cd kernel
make all ARCHS="86 89"

ls -lh ../cli/bin/
# miner       ← CUDA
# miner-cpu   ← CPU fallback
```

### Makefile reference

```
make              — same as `make cuda` (default)
make cuda         — NVIDIA GPU kernel → cli/bin/miner
make cpu          — CPU fallback kernel → cli/bin/miner-cpu
make opencl       — OpenCL kernel → cli/bin/miner-opencl (AMD/Intel)
make all          — cuda + cpu
make clean        — remove all built binaries from cli/bin/
make help         — print this reference

# Variables:
make cuda ARCHS="75 80 86 89 90"    — multi-arch fat binary
make cuda NVCC=/usr/local/cuda/bin/nvcc    — explicit nvcc path
make cpu  CXX=clang++               — use clang instead of g++
```

### Run the built CLI

```bash
cd cli
cp .env.example .env
nano .env
cargo build --release --locked
./target/release/anvil256-cli
```

Or if you want to use the compiled binary in-place:

```bash
# From repo root:
cd cli
ANVIL256_ADDRESS=0x… \
BASE_RPC_URL=https://… \
PRIVATE_KEY=0x… \
  ./target/release/anvil256-cli
```

## Option B — Prebuilt Tar Releases

Prebuilt tarballs are intentionally not documented as the primary path yet.
Until signed release artifacts are published, users should build locally from
source using Option A.

When official tarballs exist, this section will include:

- release URL;
- `sha256sums.txt` verification;
- cosign/Sigstore verification;
- exact extracted file layout.

---

## Reproducible build (CI/attestation)

The repo ships `scripts/reproducible-build.sh` which pins compiler versions
and produces `sha256sums.txt` matching the official release:

```bash
# Requires Docker and the builder image
TAG=v0.1.0 bash scripts/reproducible-build.sh

# Outputs to ./dist/:
#   anvil256-cli
#   anvil256-miner
#   sha256sums.txt
```

---

## Epoch Lifecycle — Mathematical Steps

```
Step 1: CLI reads   γ(m) = minerEpochCount[m]           (eth_call)
Step 2: CLI reads   ε[n] = epochEntropy[n]               (eth_call)

Step 3: CLI computes:
        τ(m,n)  = H(m ∥ γ(m) ∥ genesisBlockhash)
        ι(m,n)  = H(τ(m,n) ∥ n)

Step 4: CLI dispatches JOB(ι, ε[n], D[n]) → kernel

Step 5: Kernel iterates ν = 0, 1, 2, …:
        mid    = H(ι ∥ ν_be32)
        result = H(mid ∥ ε[n])
        if result < D[n]: FOUND(ν)

        Expected iterations: E[iter] = 2^256 / D[n]

Step 6: CLI submits mine(ν) with msg.value = currentFeeWei()

Step 7: On-chain:
        contract verifies κ(m, ν, n) < D[n]
        mints R(n) = R₀ >> ⌊n/H⌋ ANVL to msg.sender
        mints 0.1R(n) ANVL to the POL reserve, subject to MAX_SUPPLY
        splits fee: 50% dev recipient, 50% lpReserveEthWei
        γ(m)++ (I13)
        ε[n+1] ← H(blockhash(block) ∥ D[n+1])

Step 8: Repeat from Step 1 with new γ(m) and new ε[n+1]
```

---

## Useful `cast` Commands (on-chain inspection)

All commands use `cast` from the Foundry toolchain.
Replace `$CONTRACT` and `$RPC` with your values.

```bash
CONTRACT=0x8ea35B3e757d36dDeD989844aa49B56bb9C48bC9
RPC=https://mainnet.base.org

# Current epoch number
cast call $CONTRACT "currentEpoch()(uint256)" --rpc-url $RPC

# Current reward (in wei; divide by 1e18 for ANVL)
cast call $CONTRACT "currentReward()(uint256)" --rpc-url $RPC

# Current difficulty (uint256)
cast call $CONTRACT "currentDifficulty()(uint256)" --rpc-url $RPC

# Current protocol fee in wei (~$0.10 in ETH)
cast call $CONTRACT "currentFeeWei()(uint256)" --rpc-url $RPC

# Your ANVL token balance
cast call $CONTRACT \
  "balanceOf(address)(uint256)" 0xYOUR_ADDRESS \
  --rpc-url $RPC

# Total ANVL minted so far
cast call $CONTRACT "totalSupply()(uint256)" --rpc-url $RPC

# Your gamma (mine count for this address)
cast call $CONTRACT \
  "minerEpochCount(address)(uint64)" 0xYOUR_ADDRESS \
  --rpc-url $RPC

# Check if ETH fees got stuck (should be 0 normally)
cast call $CONTRACT "stuckFeesWei()(uint256)" --rpc-url $RPC

# Sweep any stuck fees (permissionless, sends to feeRecipient)
cast send $CONTRACT "sweepStuckFees()" \
  --private-key 0xYOUR_KEY --rpc-url $RPC

# Claim a pending refund (if mine() over-pay was queued)
cast send $CONTRACT "claimRefund()" \
  --private-key 0xYOUR_KEY --rpc-url $RPC
```

---

## Maximising Yield

**Low-latency RPC.** The per-epoch $\gamma$ and $\epsilon[n]$ fetches are
mandatory round-trips. If RPC latency is $\ell$ ms, then $\ell$ ms of
hashrate is lost per epoch transition. At $\mathcal{H} = 1.6\;\text{GH/s}$
and $\ell = 100\;\text{ms}$:

$$
\text{Lost nonces} = 1.6 \times 10^9 \times 0.1 = 1.6 \times 10^8
$$

Negligible vs. $2^{256}/D[n]$ expected iterations, but grows at high
global hashrates. Self-host a Base node for sub-10ms latency.

**Distinct address per physical rig.** Multiple machines on the same address
race the same challenge — they do not add hashrates. Effective hashrate for
$k$ machines on the same address remains $\max(\mathcal{H}_1, \ldots, \mathcal{H}_k)$,
not $\sum \mathcal{H}_i$. Use separate wallets for independent rigs.

This also lowers the NCT concentration signal: each distinct address lowers
$C = 256/C_u$, which reduces $u_{\text{nct}}$ and thus lowers difficulty
for the entire network.

**Tune `MINER_TARGET_BATCH_MS`.** At $\mathcal{H} = 1.6\;\text{GH/s}$,
a 250 ms batch processes $4 \times 10^8$ nonces. Smaller batches improve
epoch-transition reaction time; larger batches improve GPU utilisation.
Tradeoff: reaction latency $\approx \texttt{MINER\_TARGET\_BATCH\_MS}\;\text{ms}$.

**Priority fee.** Base L2 at `0.001 gwei` tip lands in the next block
$>99\%$ of the time. Increasing this provides diminishing returns because
epoch slots go to the first valid nonce, not the highest fee.

---

## Cost Model

### Per Mine (RTX 4060 Ti, Epoch 0)

| Component | Formula | Typical |
|-----------|---------|---------|
| L2 gas | $66{,}500 \times 0.05\;\text{gwei} \times 10^{-9} \times p_\$$ | $\approx\$0.008$ |
| Protocol fee | $10^{25} / p_{\text{chainlink}}$ at ETH $= \$2{,}500$ | $\$0.10$ |
| **Total per mine** | | **$\approx\$0.108$** |
| GPU power per day | $160\;\text{W} \times 24\;\text{h} \times \$0.12/\text{kWh}$ | $\$0.46$ |

### Break-Even Analysis

Daily revenue at $p_{\text{ANVL}} = \$0.50$, $\mu = 11.5\;\text{mines/day}$:

$$
\text{Rev} = 11.5 \times 50 \times \$0.50 = \$287.50
$$

Daily cost:

$$
\text{Cost} = 11.5 \times \$0.108 + \$0.46 = \$1.24 + \$0.46 = \$1.70
$$

Hardware payback at RTX 4060 Ti $\approx \$450$:

$$
t_{\text{BE}} = \frac{\$450}{\$287.50 - \$1.70} \approx 1.57\;\text{days}
$$

**Price floor.** A rig breaks even when revenue $\geq$ cost:

$$
p_{\text{ANVL}} \;\geq\; \frac{\mu \times \$0.108 + P\;\text{power cost}}{\mu \times R_0}
\;\approx\; \frac{\$1.70}{11.5 \times 50} \;\approx\; \$0.003/\text{ANVL}
$$

Below this floor, hashrate exits, the PI controller reduces $D[n]$,
$\mathbb{E}[T_{\text{epoch}}]$ decreases, $\mu$ increases — a self-stabilising
closed-loop property.

These figures are examples, not forecasts. They assume a market price, global
hashrate, gas price, and power cost; the protocol guarantees none of them.

---

## Troubleshooting

### `no miner binary found`

```
fatal error: no miner binary found: tried ./bin/miner (CUDA) and ./bin/miner-cpu (CPU).
Build with `make cuda` or `make cpu`.
```

**Fix:** Build the kernel first:

```bash
cd kernel
make cpu          # CPU-only (no GPU needed)
# or
make cuda ARCHS="89"   # for RTX 40xx
```

### `ANVIL256_ADDRESS not set`

```
fatal error: config: ANVIL256_ADDRESS not set
```

**Fix:** Add it to `.env` or export it:

```bash
export ANVIL256_ADDRESS=0x…
```

### `FeeOracleStale` — retrying

```
WARN retryable error: protocol fee oracle stale or unreachable: …; sleeping 2s
```

The Chainlink ETH/USD feed has not updated within 1 hour. This is rare on Base.
The CLI retries automatically every 2 seconds — no action needed.

### `GasCapExceeded`

```
WARN retryable error: gas budget exceeded: estimated $0.06, cap $0.05; sleeping 2s
```

Base L2 base fee spiked. Either wait for it to drop, or raise `MAX_GAS_USD` in `.env`:

```bash
MAX_GAS_USD=0.10
```

### `EpochChanged` — nonce raced

```
WARN retryable error: epoch changed mid-search (old=5, new=6); sleeping 2s
```

Another miner won the epoch while your kernel was searching. Normal — the CLI
immediately starts the next epoch. No ANVL or ETH was lost.

### `kernel emitted no events; declaring it dead`

The GPU kernel process stopped emitting output for 30 seconds. The CLI kills
and respawns it automatically. Check GPU temperature and VRAM usage:

```bash
nvidia-smi
```

### Mine confirms but ANVL balance is 0

Check you are querying the **correct contract address**:

```bash
cast call $CONTRACT "totalSupply()(uint256)" --rpc-url $RPC
cast call $CONTRACT "balanceOf(address)(uint256)" 0xYOUR_ADDRESS --rpc-url $RPC
```

If `totalSupply` is non-zero but your balance is 0, the `$CONTRACT` variable
may be pointing at an old deployment. Check the CLI startup log:

```
INFO Anvil256 CLI starting  contract=0x…   ← this is the address being used
```

---

## FAQ

**Q: What is $\gamma$ and why does it matter?**

$\gamma(m) = \texttt{minerEpochCount}[m]$ is your wallet's on-chain mine
counter. It enters the Cascade puzzle as:

$$
\tau(m,n) = H(m \,\|\, \gamma(m) \,\|\, g)
$$

A new wallet has $\gamma = 0$, giving a distinct $\tau$ from established
wallets ($\gamma > 0$) — but no cheaper puzzle. Difficulty $D[n]$ is uniform
across all callers.

**Q: Does switching to a new wallet help?**

No. A fresh address has $\gamma = 0$ and receives a fresh challenge.
Difficulty is unchanged. The new address must pay $\$0.10$ to register
in the NCT window. There is no mining advantage from rotation
(see SECURITY.md §4.3, Theorem 4.3).

**Q: Can two machines mine with the same wallet?**

Yes, but they race the same challenge with the same $\gamma(m)$.
Their hashrates do not add — they compete. The probability of the
first machine finding a valid nonce is $\mathcal{H}_1 / (\mathcal{H}_1 + \mathcal{H}_2)$.
Use separate wallets for independent physical rigs.

**Q: What is an "epoch"?**

One successful `mine()` call anywhere on the network. The protocol does
not use block numbers, time, or any external clock. Epoch count is the
only unit of protocol timekeeping. The PI controller's setpoint of 120 s
is a target for the observed epoch duration, not a protocol-enforced value.

**Q: Why is Cascade ~20% slower than single-pass Keccak?**

Two Keccak evaluations per nonce. Pass 2 uses $\epsilon[n]$ in constant
memory — unavoidable by Theorem 4.1. The ~20% overhead cannot be
eliminated without removing the anti-precompute property.

**Q: Does the CLI send telemetry?**

No. The CLI contacts only your configured `BASE_RPC_URL`. No telemetry,
no update checks, no third-party endpoints.

**Q: What if Base L2 is unavailable?**

Mining halts gracefully. The CLI retries with exponential backoff.
No ANVL is at risk: $\texttt{currentEpoch}$ only advances on successful
`mine()` calls. The controller state $D[n]$ is unchanged until the next
period boundary.

**Q: GPU not detected — only CPU cores showing?**

The kernel binary was built with `make cpu`, not `make cuda`. Rebuild:

```bash
cd kernel && make cuda ARCHS="YOUR_SM_VERSION"
```

Or explicitly set `MINER_BIN=./bin/miner` in `.env` to force the CUDA binary.

**Q: How do I run multiple GPUs?**

By default all detected GPUs are used. To use specific ones:

```bash
MINER_DEVICES=0,1,2   # use GPU 0, 1, and 2 only
```

Each device runs an independent search starting at a different nonce base
(`device_index × 2^56`), so they cover non-overlapping nonce space.

**Q: What happens at halving?**

At epoch 210,000 the reward drops from 50 ANVL to 25 ANVL automatically
on-chain. No miner action needed. The CLI reads `currentReward()` each
epoch and logs the correct value.
