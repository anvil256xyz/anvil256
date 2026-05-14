---
title: Architecture
slug: architecture
---

# Anvil256 — Architecture

Three components. Zero servers. No coordinator.

```
┌──────────────────────┐    ┌───────────────────────────┐    ┌──────────────────────────────┐
│  Static website      │    │  CLI (Rust)               │    │  Anvil256.sol                │
│  Astro Starlight     │    │  γ-counter read           │    │  Base L2                     │
│  IPFS + Cloudflare   │    │  epoch_entropy fetch      │    │  immutable ERC-20 + PoW      │
│  no backend          │    │  nonce search dispatch    │    │  PI + NCT controller         │
│                      │    │  tx construction + submit │    │  Cascade verifier            │
└──────────▲───────────┘    └────────────▲──────────────┘    └──────────────▲───────────────┘
           │                             │                                   │
           │   browser, viem read-only   │   operator RPC (HTTPS, EIP-1559) │   same RPC
           └─────────────────────────────┴───────────────────────────────────┘
                                 no Anvil256 infrastructure in the loop
```

---

## On-Chain / Off-Chain Split

### What Lives On-Chain

| Component | State | Formal Invariant |
|-----------|-------|-----------------|
| ERC-20 | `balanceOf`, `totalSupply`, `transfer` | `totalSupply <= 21,000,000e18` (I1) |
| Mining state | `epoch`, `difficulty` $D[n]$, `currentReward()`, `integralErrorWad` $I[n]$, `lastMineBlock`, `epochEntropy` $\epsilon[n]$, period start timestamp | $D[n] \geq 1$ (I5); $|I[n]| \leq 4.0 \times \text{WAD}$ (I10) |
| Miner identity | `gamma(m) = minerEpochCount[m]` — monotonic per-address counter | $\gamma$ strictly non-decreasing (I13) |
| NCT window | `minerWindow[256]` packed circular buffer, `windowHead`, `uniqueCount` $C_u$, `windowFreq[m]` | $C_u \in [1,256]$ (I11) |
| Cascade verifier | `mine(ν)` recomputes $\tau,\iota,\kappa$ on-chain; asserts $\kappa < D[n]$ | I12 |
| Distribution | Valid `mine()`: mint $R(n)$ to `msg.sender`, mint up to $0.1R(n)$ to POL reserve, increment $\gamma(m)$, update NCT window | $S_{seed}+\sum(R_{paid}+M_{LP,paid})\leq S_{max}$ |
| Fee | Split `currentFeeWei()`: 50% to `feeRecipient`, 50% to `lpReserveEthWei`; failed dev transfer parks in `stuckFeesWei` | I7: `dev + stuck + lpReserve = fee` exactly |
| Adjustment | Every $2{,}016$ epochs: `PIController.step(...)` updates $(D[n+1], I[n+1])$ before entropy is written | — |
| Entropy | `epochEntropy = H(entropySource || currentDifficulty)`; falls back to prevrandao/timestamp if blockhash window expired | — |
| Halving | $R(n) = R_0 \gg \lfloor n/210{,}000\rfloor$, clamped to 0 at epoch $\geq 13{,}440{,}000$ | — |

### What Lives Off-Chain

| Component | Description | Mathematical Role |
|-----------|-------------|-----------------|
| $\gamma$ read | CLI reads $\texttt{minerEpochCount}[m]$ before each job dispatch — one `eth_call` per epoch | $\gamma(m)$ required to compute $\tau(m,n) = H(m \,\|\, \gamma \,\|\, g)$ |
| $\epsilon[n]$ fetch | CLI reads `epochEntropy` from contract — mandatory round-trip, cannot be skipped | $\epsilon[n]$ is the outer-pass input; withholding it makes nonce computation impossible (Theorem 4.1, SECURITY.md). `EntropyFallback` event indicates prevrandao-only path was used (PATCH-1). |
| Nonce search | CUDA/OpenCL kernel iterates: find $\nu$ s.t. $\kappa(m,\nu,n) < D[n]$ | Brute-force search over $\nu \in \{0,\ldots,2^{32}-1\}$; expected iterations $= 2^{256}/D[n]$ |
| Tx construction | CLI reads `currentFeeWei()`, attaches as `msg.value`, signs EIP-1559 tx | Ensures I7 is satisfiable |
| Stats site | Browser reads on-chain state via viem — no server, no cache | — |

---

## Cascade PoW — Off-Chain Computation

The mining kernel receives a pre-computed job from the CLI:

```
JOB <inner_hex64> <epoch_entropy_hex64> <difficulty_hex64> <job_id>
```

where `inner_hex64` $= \iota(m,n) = H(\tau(m,n) \,\|\, n)$ is precomputed by the CLI
(requiring both $\gamma(m)$ from chain and the current epoch $n$).

**Kernel computation.** For each $\nu$ in the search space:

$$
\text{mid} \;=\; H(\iota \,\|\, \nu_{\text{be32}}), \qquad
\text{result} \;=\; H(\text{mid} \,\|\, \epsilon[n])
$$

If $\text{result} < D[n]$: `FOUND`. Expected iterations before first success:

$$
\mathbb{E}[\text{iterations}] \;=\; \frac{2^{256}}{D[n]}
$$

$\epsilon[n]$ is held in GPU constant memory for the duration of the epoch —
no per-batch network call needed. The mandatory network round-trips (for $\gamma$
and $\epsilon[n]$) occur once per epoch transition, not once per batch.

**Security note.** The kernel never receives the raw miner address $m$ or
the private key — only the derived $\iota$ value. Compromise of the kernel
process exposes only $\iota$ (a one-way derivative of $m$, $\gamma$, $g$),
not the signer key.

---

## CLI ↔ Kernel Protocol

```
host → kernel (line-oriented, plain text):
    JOB <inner_hex64> <epoch_entropy_hex64> <difficulty_hex64> <job_id>
    STOP
    EXIT

kernel → host (JSON, one object per line):
    {"type":"ready",    "devices":[...]}
    {"type":"progress", "job":J, "device":"…", "hashes":H, "hashrate":R, "elapsed_ms":T}
    {"type":"found",    "job":J, "nonce":"<decimal>", "hash":"0x…"}
    {"type":"error",    "message":"…"}
```

The CLI precomputes $\iota$ (requiring $\gamma$ from chain and miner address)
before dispatching the job. The kernel never sees the raw miner address —
it only operates on the derived $\iota$ value, ensuring:

$$
\iota \;=\; H(H(m \,\|\, \gamma(m) \,\|\, g) \,\|\, n)
$$

is a one-way commitment to the miner's identity, verifiable on-chain without
exposing $m$ to the kernel process.

---

## On-Chain State Machine

```
                ┌─────────────────────┐
                │  epoch n, D[n]      │ ◄──── mine(ν) called
                └──────────┬──────────┘
                           │
                  κ(m,ν,n) < D[n]?
                  ┌────────┴────────┐
                 no                yes
                  │                 │
             revert            ┌────▼───────────────────────────────────┐
                               │  γ(m)++                                │
                               │  win[h] ← m;  h ← (h+1) mod 256       │
                               │  uniqueCount ← updated C_u             │
                               │  mint R(n) to msg.sender               │
                                │  mint 0.1R(n) to POL reserve if cap allows │
                                │  split currentFeeWei(): dev + LP reserve │
                               │                                         │
                               │  if (currentEpoch % 2016 == 0):        │
                               │    e[n] ← timing error                 │
                               │    I[n] ← sat(I[n−1]+e, ±I_MAX)       │
                               │    u_nct ← |nctSignal()|  (≥ 0)       │
                               │    u    ← sat(u_pi + u_nct, ±0.5)     │
                               │    D[n+1] ← sat(D[n]·exp4(u), D/4,4D) │
                               │                                         │
                               │  ε[n+1] ← H(entropySource ∥ D_cur) │
                               │  entropySource=H(blockhash ∥ prevrandao ∥ ts)       │
                               │  (PATCH-1 fallback: H(prevrandao ∥ ts) if bh=0)    │
                               │  (D_cur = D[n+1] at boundary, else D[n])│
                               └─────────────────────────────────────────┘
                                                │
                                           epoch n+1 begins
```


---

## Operator Trust Model

**Formal trust assumptions.** The protocol requires no trust in any party
except the operator's own infrastructure:

| Trust Required | Rationale |
|---------------|-----------|
| Own machine | Kernel runs locally; key signs locally; no remote attestation |
| Own RPC endpoint | Malicious RPC can censor but cannot steal: CLI verifies `eth_getTransactionReceipt` |
| Chainlink oracle | Compromise $\Rightarrow$ fee spike only; client-side `MAX_FEE_USD` guard |

**Formal trust exclusions.** These parties have zero protocol-level authority:

| Party | Why No Trust Needed |
|-------|---------------------|
| Anvil256 maintainers | Contract is immutable and verified; $\nexists$ admin key |
| Pool operators | No pool protocol exists or is necessary |
| Centralised gateways | None in the architecture |
| Other miners | No coordination primitive; each `mine()` is fully independent |
| Post-deployment deployer | Constructor ensures $\texttt{feeRecipient} \neq \texttt{deployer}$ (I3); $\nexists$ privileged function post-deploy |

**The operator's private key is the unique secret in the system.** All other
values — $\gamma(m)$, $\epsilon[n]$, $D[n]$, $\iota(m,n)$ — are either
public on-chain state or deterministic functions thereof.
