---
title: Security Model
slug: security
---

# Anvil256 — Security Model

---

## 1. Assets

| Asset | Location | Formal Protection |
|-------|----------|------------------|
| Unminted ANVL supply | Intrinsic to `Anvil256.sol` | Minted on valid $\kappa < D$ only; `totalSupply ≤ MAX_SUPPLY` (I1) |
| Minted ANVL | ERC-20 balances | Standard ERC-20 transfer semantics |
| Protocol fee ETH | `feeRecipient` (immutable) | `address immutable feeRecipient`; no setter (I2) |
| POL reserve ETH | `lpReserveEthWei` | 50% of each protocol fee until deployed/dripped to official LP |
| POL reserve ANVL | `lpReserveTokenWei` / official LP NFT | 10% of each miner reward, minted inside `MAX_SUPPLY` |
| Stuck-fee ETH | `stuckFeesWei` | Sweepable by anyone, permissionless |
| Operator private keys | Operator's machine only | Never transmitted; not in scope |
| Difficulty state | `currentDifficulty`, `integralErrorWad` | $D \geq 1$ (I5); $|I| \leq I_{\max} = 4.0$ (I10) |
| Miner temporal identity | `minerEpochCount[m]` = $\gamma(m)$ | Monotonic, non-transferable (I13) |
| NCT window state | `minerWindow`, `uniqueCount`, `windowFreq` | $C_u \in [1,256]$ (I11); updated before external calls (§4.4) |
| Epoch entropy | `epochEntropy`, `lastMineBlock` | Set after difficulty adjustment; commits to post-adjustment $D[n+1]$ |

---

## 2. Adversary Classes

| Class | Formal Capability |
|-------|------------------|
| External miner | Run any client; submit any `(nonce, address)` pair as `mine()` input |
| Precompute attacker | Compute candidate $\kappa$ values before $\epsilon[n]$ is known |
| Wallet rotation attacker | Generate fresh addresses; attempt to reduce $\sigma(k)$ below $k \times \texttt{fee}$ |
| NCT Sybil attacker | Operate $k$ addresses to suppress $C[n]$ while controlling $>W/k$ hashrate |
| MEV searcher | Observe mempool; reorder or front-run `mine()` transactions |
| Malicious RPC | Censor or misrepresent `eth_call` / `eth_getTransactionReceipt` responses |
| Compromised Chainlink oracle | Return malformed `latestRoundData()` |
| Fee recipient compromise | Drain future fee accumulations |
| Post-deployment deployer | **No privileges** — contract is fully immutable post-constructor |

---

## 3. Protocol Invariants

**Definition 3.1 (Protocol Invariant).** A predicate $I$ over the contract
state is a *protocol invariant* iff it holds in all reachable states — i.e.,
for all sequences of valid calldata starting from the deployment state.

| ID | Invariant | Formal Statement |
|----|-----------|-----------------|
| I1 | Supply cap | `totalSupply(S) <= MAX_SUPPLY = 21,000,000e18` for all reachable states |
| I2 | Fee recipient immutability | `feeRecipient` is immutable; no setter exists |
| I3 | Deployer separation | Constructor enforces `feeRecipient != msg.sender` and `feeRecipient != address(0)` |
| I4 | Oracle non-null | Constructor enforces `_ethUsdFeed != address(0)` |
| I5 | Difficulty floor | $D[n] \geq 1$ for all $n$ |
| I6 | Epoch monotonicity | `currentEpoch[n+1] = currentEpoch[n] + 1` after each valid `mine()` |
| I7 | Fee correctness | After `mine()`: `feeRecipient delta + stuckFeesWei delta + lpReserveEthWei delta = currentFeeWei()` exactly |
| I8 | Refund correctness | `msg.sender` refunded $\max(\texttt{msg.value} - \texttt{currentFeeWei}(), 0)$ |
| I9 | Halving terminus | $R(n) = 0$ for $n \geq 13{,}440{,}000$; `mine()` reverts `MiningEnded()` unless `MAX_SUPPLY` is reached earlier |
| I10 | Anti-windup | `integralErrorWad` remains inside `[-I_MAX * WAD, +I_MAX * WAD]` |
| I11 | Window integrity | $C_u \in [1, 256]$ after first mine; $C_u = \lvert\{m : freq[m] > 0\}\rvert$ exactly |
| I12 | Cascade correctness | `mine(ν)` verifies $\kappa(m,\nu,n) < D[n]$ before any state mutation |
| I13 | $\gamma$-monotonicity | `minerEpochCount[m]` is strictly non-decreasing; never decremented or transferred |

---

## 4. Threat Analysis and Mitigations

### 4.1 Cryptographic Assumptions

**Model.** $H = \texttt{keccak256}$ is modelled as a random oracle
$\mathcal{H} : \{0,1\}^* \to \{0,1\}^{256}$ with uniform output distribution.

| Threat | Security Bound |
|--------|---------------|
| Preimage attack on $H$ | $\Pr[\mathcal{A}(y) = x : H(x) = y] \leq 2^{-256}$ (preimage resistance) |
| Collision attack on $H$ | Birthday bound: $\geq 2^{128}$ queries needed for collision with probability $\geq 1/2$ |
| Length-extension attack | Not applicable: Keccak uses sponge construction, not Merkle–Damgård |

### 4.2 Cascade Precomputation — Formal Theorem

**Theorem 4.1.** Under the random oracle model, for any PPT adversary $\mathcal{A}$
and any epoch $n$, the probability that $\mathcal{A}$ produces a valid nonce
$\nu^*$ strictly before $\texttt{blockhash}(\texttt{lastMineBlock}[n-1])$ is
produced by the sequencer is:

$$
\Pr\!\bigl[\kappa(m,\nu^*,n) < D[n]\bigr] \;=\; \frac{D[n]}{2^{256}}
$$

i.e., no better than an online random guess.

*Proof.* $\epsilon[n] = H(\texttt{entropySource} \,\|\, D[n])$ where $\texttt{entropySource}$ is derived from
$b_{n-1}^* = \texttt{blockhash}(\texttt{lastMineBlock}[n-1])$, $\texttt{prevrandao}$, and $\texttt{block.timestamp}$
(PATCH-1: if the 256-block window has expired, $\texttt{prevrandao}$ and $\texttt{timestamp}$ are used alone,
emitting `EntropyFallback`). In all paths, $b_{n-1}^*$
is produced at an unknown future time. In the random oracle model, $\epsilon[n]$ is
uniformly distributed over $\{0,1\}^{256}$, independent of all values computable
before $b_{n-1}^*$ is known.

For any function $f$ computable by $\mathcal{A}$ before time $t^*$:

$$
\Pr_{\epsilon \sim \mathcal{U}(\{0,1\}^{256})}\!\bigl[H(H(\iota \,\|\, f(\iota)) \,\|\, \epsilon) < D\bigr]
\;=\; \frac{D}{2^{256}}
$$

since $H(\cdot \,\|\, \epsilon)$ with uniform $\epsilon$ produces a uniform output
independent of its first argument. No precomputed set $\{H(\iota \,\|\, \nu) : \nu \in \mathcal{V}\}$
reduces this probability. $\square$

**Corollary 4.2.** ASIC precomputation of rainbow tables over all possible
$(\iota, \nu)$ pairs provides no advantage, because the outer pass
$H(\cdot \,\|\, \epsilon[n])$ requires $\epsilon[n]$ — a mandatory per-epoch
network fetch.

### 4.3 Wallet Rotation Attack — Complete Analysis

| Attack | Formal Mitigation |
|--------|-----------------|
| Fresh address $\Rightarrow$ fresh cheap challenge | $\tau(m',n) = H(m' \,\|\, 0 \,\|\, g)$. Distinct from all $m$ with $\gamma > 0$, but difficulty $D[n]$ is identical. No cost reduction. |
| $k$ fresh addresses $\Rightarrow$ suppress NCT | Each address must mine at $\$0.10$ to register in window. Cost: $\sigma(k) = k \times \$0.10$ (Theorem 1.9, MATH.md). Equals genuine mining cost. |
| Accumulate $\gamma$ on one address then rotate | $\gamma$ is non-transferable (I13). Accumulated history stays with original address. |
| Replay high-$\gamma$ address's $\tau$ from another address | $\tau$ includes $\texttt{msg.sender}$ directly. $m \neq m' \Rightarrow \tau(m,n) \neq \tau(m',n)$ (collision resistance of $H$). |

**Theorem 4.3 (Rotation Equivalence).** For all $k \geq 1$ and window cycles:

$$
\sigma(k) \;=\; k \times \texttt{fee}
$$

The Sybil cost per apparent independent miner equals the legitimate mining cost.
No adversary benefits from wallet rotation. $\square$

### 4.4 NCT Attacks

| Attack | Mitigation |
|--------|-----------|
| Sybil: fake distribution with $k$ wallets | $\sigma(k) = k \times \$0.10$ (Corollary 1.10). No advantage. |
| Window stuffing: saturate buffer to reset $C_u$ | Same $\$0.10/\text{slot}$ cost floor; no free writes. |
| Reverse Sybil: concentrate to harm competitors | NCT penalty $u_{\text{nct}}\in[0,0.3]$ raises difficulty for everyone, including the concentrator. |
| Manipulate $C_u$ via reentrancy | `nonReentrant` modifier; $C_u$ and `windowFreq` updated atomically before any external calls. |

**Concentration equilibrium.** The NCT update function:

$$
D[n+1] = D[n] \cdot \exp\!\Bigl(u_{\text{pi}}[n]+\min\!\bigl(0.1(C[n]-1),\,0.3\bigr)\Bigr)
$$

achieves its minimum over strategies $C_u \in [1,256]$ at $C_u = 256$
(since $u_{\text{nct}}$ is minimised, i.e., zero). This is the unique Nash equilibrium.

### 4.5 Replay and Cross-Miner Attacks

| Attack | Formal Exclusion |
|--------|-----------------|
| Resubmit nonce in next epoch | $\epsilon[n+1] \neq \epsilon[n]$ with probability $1 - D/2^{256}$ (random oracle independence) |
| Steal nonce solved by miner $m$ and submit as $m'$ | $\tau(m',n) \neq \tau(m,n)$ for $m \neq m'$ $\Rightarrow$ $\iota(m',n) \neq \iota(m,n)$ $\Rightarrow$ valid nonce for $m$ is invalid for $m'$ |
| Replay across deployments | $\texttt{genesisBlockhash}$ differs across deployments; $\tau$ is genesis-bound |
| Replay across chain forks | Contract address differs; $\tau$ is address-included |

**Proposition 4.4.** For $m \neq m'$, $\Pr[\kappa(m,\nu,n) = \kappa(m',\nu,n)] \leq 2^{-256}$
(collision resistance of $H$, applied at the $\tau$-layer). $\square$

### 4.6 Oracle Attack Surface

The fee formula $\texttt{fee\_wei} = 10^{25} / p$ depends on the Chainlink
ETH/USD feed. Attack surface and mitigations:

| Scenario | On-Chain Response | Off-Chain Response |
|----------|-----------------|-------------------|
| Stale price ($|t - \texttt{updatedAt}| > 24\;\text{hours}$) | Revert `StaleOracle` | — |
| `answeredInRound < roundId` | Revert `StaleOracle` (O5) | — |
| $p \leq 0$ | Revert `InvalidOracle` | — |
| $\texttt{updatedAt} > \texttt{block.timestamp}$ | Revert `OracleClockSkew` | — |
| Inflated $p$ (oracle compromise) | $\texttt{fee\_wei} = 10^{25}/p \to 0$: mine cheapens, not blocks | Client-side `MAX_FEE_USD` aborts if $\texttt{fee\_wei}/p_\$ > \text{cap}$ |
| Deflated $p$ (oracle compromise) | $\texttt{fee\_wei}$ inflates: mine becomes expensive | Client-side `MAX_FEE_USD` aborts submission |
| Round ID sequence gap (phase boundary) | Not checked — gap check produces false positives | — |

**Risk.** Oracle compromise can cause temporary fee spikes or drops. It cannot
cause loss of minted ANVL, cannot modify $D[n]$, and cannot violate I1–I13.

### 4.7 Difficulty Controller — Stability Under Adversarial Input

The controller operates on $\ln D$. Its stability properties under adversarial
hashrate perturbations:

| Perturbation | Bound | Mechanism |
|-------------|-------|-----------|
| Hashrate flash spike $\times 100$ | $D$ can at most $\times 4$ per period | Outer $\mathbf{sat}(D[n]\cdot\exp(u),\,D/4,\,4D)$ envelope |
| Sustained hashrate increase | PI integrator accumulates error; converges | Lyapunov stable (MATH.md §3.3) |
| Integrator windup | $|I| \leq I_{\max} = 4.0$ always | Anti-windup saturation (I10) |
| NCT overflow | $C_{\text{wad}} \leq 256 \times \text{WAD}$; $\text{tax} \leq 0.3\,\text{WAD}$ | $C_u \geq 1$ (I11) bounds $C$ above |
| Difficulty collapse to zero | $D \geq 1$ always | Floor enforced in `PIController.step` (I5) |

### 4.8 Fee Mechanics — Accounting Invariant

**Invariant I7 (Fee Accounting).** After every successful `mine()`:

$$
\Delta F_{recipient}+\Delta F_{stuck}+\Delta F_{LP}
\;=\; \texttt{currentFeeWei}()
$$

where `devFee` is 50% of the protocol fee and is forwarded to `feeRecipient`
(or parked in `stuckFeesWei` on failure), and `lpFee` is 50% and accumulates
in `lpReserveEthWei`.

*Proof sketch.* The `mine()` function:
1. Reads $f = \texttt{currentFeeWei}()$
2. Asserts $\texttt{msg.value} \geq f$; refunds excess $(\texttt{msg.value} - f)$ to `msg.sender`
3. Splits: $f_{\text{LP}} = f \times 5{,}000 / 10{,}000 = f/2$; $f_{\text{dev}} = f - f_{\text{LP}} = f/2$
4. Accumulates $f_{\text{LP}}$ into `lpReserveEthWei` (always succeeds, no external call)
5. Attempts `feeRecipient.call{value: f_dev}("")`:
   - On success: `feeRecipient.balance += f_dev`. $\Delta\texttt{stuckFeesWei} = 0$.
   - On failure: `stuckFeesWei += f_dev`. $\Delta\texttt{feeRecipient.balance} = 0$.

In all branches: $\Delta\texttt{feeRecipient.balance} + \Delta\texttt{stuckFeesWei} = f_{\text{dev}}$
and $\Delta\texttt{lpReserveEthWei} = f_{\text{LP}}$, so their sum equals $f$.
`stuckFeesWei` is sweepable permissionlessly to protect against DoS on `feeRecipient`. $\square$

**Note.** The `stuckFeesWei` mechanism applies only to `devFee`. The LP share
goes directly to `lpReserveEthWei` via in-contract accounting and is never
subject to a reverting external call.

### 4.9 MEV and Sequencer Reordering

Each `mine()` is statistically independent. The valid nonce for miner $m$
is invalid for $m' \neq m$ (Proposition 4.4). Therefore:

- **Front-running is unprofitable**: a front-runner cannot use miner $m$'s
  nonce; they must solve the puzzle for their own address.
- **Reordering only transfers the slot**: if two valid `mine()` calls from
  $m_1$ and $m_2$ compete, reordering awards the epoch to one of them — no
  additional value is extractable.
- **No arbitrage exists**: unlike DEX swaps, `mine()` contains no price-sensitive
  state to exploit.

Formal: $\nexists$ MEV strategy with positive expected value beyond the mining
reward itself, which requires solving the Cascade PoW.

### 4.10 Supply Chain — Build Integrity

| Layer | Guarantee | Mechanism |
|-------|-----------|-----------|
| Source code | Public, reviewed | GitHub; audit report published |
| Binary | Reproducible build | Docker image pins compiler versions; `sha256sums.txt` matches across builds |
| Release signing | Cosign + Sigstore Rekor | `cosign verify-blob` with GitHub OIDC identity |
| Contract | Bytecode verified | Basescan source verification; bytecode hash matches signed release |

---

## 5. Out of Scope

- Sequencer-level censorship on Base validators.
- Chainlink's internal oracle security model and aggregator architecture.
- Operator wallet hygiene and private key storage.
- Power or infrastructure failures on the operator's machine.
- Consensus-layer forks of Base

---

## 6. Invariants That Are Never In Scope for Modification

The following properties are on-chain invariants of the immutable contract.
No future action can modify them:

$$
\nexists\;\text{admin\_key},\quad
\nexists\;\text{upgrade\_proxy},\quad
\nexists\;\text{governance\_token}
$$

$$
\texttt{devPremine}=0,\quad \texttt{genesisLPSeed}=1\;\mathrm{ANVL},\quad
\texttt{feeRecipient} \neq \texttt{deployer}\;\text{(on-chain, constructor)}
$$

$$
\nexists\;\text{admin mint},\quad
\nexists\;\text{token migration mechanism}
$$

---

## 7. Responsible Disclosure

Vulnerability reports: `security@anvil256.xyz` (PGP key published on website).
Coordinated disclosure window: 90 days from acknowledgement.
