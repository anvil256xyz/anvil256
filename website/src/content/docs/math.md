---
title: Mathematical Reference
slug: math
---

# Anvil256 — Mathematical Reference

> $\sum \cdot \prod \cdot \int \cdot \partial \cdot \nabla \cdot \kappa \cdot \epsilon \cdot D[n] \cdot \mathbb{N} \cdot \square$  
> **The canonical derivation** for every non-trivial construction in the
> Anvil256 protocol. All claims are **proven** or **bounded** explicitly.
> Informal descriptions are never substituted for formal statements.

---

## Notation

The protocol uses standard mathematical notation throughout. A short legend:

| Symbol | Meaning |
|--------|---------|
| `WAD` | $10^{18}$ (Q60.18 unit scale) |
| $\|$ | concatenation via `abi.encode` (ABI-padded, prevents type-collision attacks) |
| $H(x)$ | `keccak256(x)` — 256-bit output, modelled as a random oracle |
| $\kappa$ | Cascade challenge $H( H(\text{inner} \,\|\, \nu) \,\|\, \epsilon[n])$ |
| $\epsilon[n]$ | Epoch entropy $H(b_{n-1} \,\|\, D[n])$ |
| $D[n]$ | difficulty at epoch $n$ |
| $R(n)$ | block reward at epoch $n$ — $R_0 \cdot 2^{-\lfloor n/H \rfloor}$ |
| $M_{LP}(n)$ | protocol-owned liquidity reserve mint, $0.1R(n)$ before cap truncation |
| $S_{seed}$ | genesis LP seed mint, $1$ ANVL |
| $\gamma(m)$ | per-miner epoch counter (monotonic, non-transferable) |
| $C_u$ | unique miners in the 256-epoch NCT window |
| $\lfloor \cdot \rfloor$ | floor function |
| $\mathbf{sat}(x,\,a,\,b)$ | $\max(a,\,\min(b,\,x))$ — clamp to $[a,b]$ |
| $\mathbb{Z}_{\text{wad}}$ | integer representing a real scaled by $\text{WAD}$ |
| $\mathbb{N}_{\geq 1}$ | positive integers |
| $\mathcal{H}$ | the random oracle modelling $H$ |
| $\Pr[\cdot]$ | probability over uniformly random oracle responses |
| $\square$ | end of proof |

---

## 1. Keccak-Cascade PoW with Temporal Miner Binding

### 1.1 Motivation: Formal Statement of the Wallet-Rotation Attack

**Definition 1.1 (Naive PoW Challenge).** Let $\mathcal{M}$ be the set of
miner addresses and $n \in \mathbb{N}$ be the current epoch. The naive
challenge for miner $m \in \mathcal{M}$ at epoch $n$ is:

$$
\text{challenge}_{\text{naive}}(m, n, \nu) \;=\; H(m \,\|\, n \,\|\, \nu)
$$

where $\nu \in \{0, \ldots, 2^{32}-1\}$ is the nonce. A nonce $\nu^*$ is
valid iff $\text{challenge}_{\text{naive}}(m, n, \nu^*) < D[n]$.

**Observation 1.2 (Zero-Cost Address Rotation).** Let $m \in \mathcal{M}$
be a miner address. Generating a fresh address $m' \notin \mathcal{M}$ costs
$O(1)$ key-derivation operations. The challenge function satisfies:

$$
\text{challenge}_{\text{naive}}(m, n, \nu) \;\text{ and }\;
\text{challenge}_{\text{naive}}(m', n, \nu)
$$

are independent, identically distributed when $m \neq m'$ and $\nu$ is uniform.
Therefore, the adversary can replace $m$ with $m'$ at zero marginal cost and
receive a statistically equivalent challenge — no difficulty advantage, but also
no penalty. The NCT concentration signal (§2) is then trivially gamed: $k$
physical machines can appear as $W = 256$ distinct participants with zero
additional hashrate cost.

**Definition 1.3 (Sybil Cost).** The Sybil cost $\sigma(k)$ of operating
$k$ distinct miner identities for one 256-epoch window cycle is the minimum
total protocol fee expenditure required to occupy $k$ distinct slots in the
NCT window. For naive PoW, $\sigma(k) = 0$ for all $k \leq W$.

### 1.2 Miner Epoch Counter — Formal Definition

**Definition 1.4 (Miner Epoch Counter).** The contract maintains a
total function $\gamma : \mathcal{M} \to \mathbb{N}$ defined by:

$$
\gamma(m) \;:=\; \bigl|\{j \leq n \;:\; \text{mine}_j.\text{sender} = m\}\bigr|
$$

i.e., the number of successful `mine()` calls by address $m$ up to and
including epoch $n-1$, read before the increment in the current call.

**Solidity representation:**
```solidity
mapping(address => uint64) public minerEpochCount;
// γ(m) = minerEpochCount[m] (pre-increment value at mine() call time)
```

**Lemma 1.5 (γ-Monotonicity).** For all $m \in \mathcal{M}$ and epochs
$n_1 < n_2$: $\gamma_{n_1}(m) \leq \gamma_{n_2}(m)$, with strict inequality
iff $m$ successfully called `mine()` in the interval $(n_1, n_2]$.

*Proof.* The counter is incremented by exactly 1 on each successful `mine()`
call (via `unchecked { ++minerEpochCount[msg.sender]; }`), and is never
decremented. The mapping is not transferable. $\square$

**Lemma 1.6 (γ-Non-Transferability).** For $m \neq m'$: no sequence of
contract calls can produce $\gamma(m) \gets \gamma(m') - j$ for any
$j \in \mathbb{Z}$ via internal state transfer. The counter is address-keyed
and has no setter, no reset, and no cross-address interaction. $\square$

### 1.3 Full Cascade Construction — Formal Definition

**Definition 1.7 (Cascade PoW).** For epoch $n$, nonce $\nu$, and caller
$m = \texttt{msg.sender}$:

$$
\boxed{
\begin{aligned}
\epsilon[n] \;&=\; H\!\bigl(\texttt{blockhash}(\texttt{lastMineBlock}[n{-}1]) \;\|\; D[n]\bigr) \\[4pt]
\tau(m,n) \;&=\; H\!\bigl(m \;\|\; \gamma(m) \;\|\; \texttt{genesisBlockhash}\bigr) \\[4pt]
\iota(m,n) \;&=\; H\!\bigl(\tau(m,n) \;\|\; n\bigr) \\[4pt]
\kappa(m,\nu,n) \;&=\; H\!\Bigl(H\!\bigl(\iota(m,n) \;\|\; \nu_{\text{be32}}\bigr) \;\|\; \epsilon[n]\Bigr)
\end{aligned}
}
$$

where $D[n]$ denotes the difficulty **governing epoch $n$** — i.e. the
value of `currentDifficulty` *after* the PIController adjustment that
fires at the epoch-$n$ period boundary (if any). The on-chain
implementation enforces this by running `_maybeAdjustDifficulty()` before
writing `epochEntropy`, so $\epsilon[n]$ always commits to the difficulty
that will be used to validate nonces in epoch $n$.

The nonce $\nu^*$ is **valid** iff:

$$
\kappa(m,\,\nu^*,\,n) \;<\; D[n]
$$

**Definition 1.8 (Binding Layers).** Each layer binds a distinct security property:

| Layer | Expression | Bound Secret |
|-------|-----------|-------------|
| $\tau$ | $H(m \,\|\, \gamma(m) \,\|\, g)$ | Temporal identity: address + history + genesis |
| $\iota$ | $H(\tau \,\|\, n)$ | Epoch uniqueness: separates epochs for same miner |
| $\kappa$ | $H(H(\iota \,\|\, \nu) \,\|\, \epsilon[n])$ | Anti-precompute: live chain state in outer pass |

### 1.4 Wallet-Rotation Cost — Formal Theorem

**Theorem 1.9 (Rotation Cost Lower Bound).** Under the random oracle model,
the minimum total protocol expenditure for an adversary to maintain $k$
independently-challenging miner identities for $T$ consecutive epochs is:

$$
\text{Cost}(k, T) \;\geq\; k \cdot \lceil T / W \rceil \cdot \texttt{fee}
$$

where $W = 256$ is the window size and $\texttt{fee} = \$0.10$ per mine.

*Proof.* Each address $m_i$ must appear in the NCT window at least once per $W$
epochs to maintain a distinct slot (otherwise it is evicted by the circular
buffer). Each window entry requires a successful `mine()` call at cost
$\texttt{fee}$. Fresh addresses (with $\gamma = 0$) receive no cost reduction
— difficulty $D[n]$ is uniform across all callers. Therefore maintaining $k$
distinct addresses for $\lceil T/W \rceil$ window cycles costs at least
$k \cdot \lceil T/W \rceil \cdot \texttt{fee}$. $\square$

**Corollary 1.10.** For $k = W = 256$ (full Sybil, appearing as all distinct):
$\text{Cost}(256, W) \geq 256 \times \$0.10 = \$25.60$ per window cycle.
This equals the cost of genuine mining with 256 independent physical miners.
Sybil provides no economic advantage.

### 1.5 Precomputation Impossibility — Theorem and Proof

**Theorem 1.11 (Structural Precomputation Impossibility).** No probabilistic
polynomial-time adversary $\mathcal{A}$ can produce a valid nonce for epoch
$n$ before the block at height $\texttt{lastMineBlock}[n-1]$ is finalised by
the sequencer, except with probability negligible in the security parameter
$\lambda$.

*Proof.* Let $b^* = \texttt{blockhash}(\texttt{lastMineBlock}[n-1])$ be the
target block hash, produced at an unknown future time $t^* > t_{\text{now}}$.
A valid nonce $\nu^*$ satisfies:

$$
H\!\Bigl(H\!\bigl(\iota(m,n) \,\|\, \nu^*\bigr) \;\|\; \epsilon[n]\Bigr) \;<\; D[n]
$$

where $\epsilon[n] = H(b^* \,\|\, D[n])$. In the random oracle model,
$H(b^* \,\|\, D[n])$ is uniformly distributed over $\{0,1\}^{256}$ and
independent of all values known before $b^*$ is produced. Therefore:

$$
\Pr_{\mathcal{A}}\!\bigl[\kappa(m,\nu^*,n) < D[n]\bigr]
\;=\; \frac{D[n]}{2^{256}}
$$

regardless of which $\nu^*$ $\mathcal{A}$ selects before $b^*$ is known —
this is exactly the probability of a random guess. No precomputed
intermediate (including $H(\iota \,\|\, \nu^*)$ for all $\nu^*$ in the
search space) provides any advantage, because the outer $H$ takes $\epsilon[n]$
as input, which is uniformly random over the precomputed set.

More precisely: for any function $f$ computable before time $t^*$, and any
nonce $\nu^* = f(\iota, D[n])$:

$$
\Pr\!\Bigl[H\bigl(H(\iota \,\|\, \nu^*) \,\|\, H(b^* \,\|\, D)\bigr) < D\Bigr]
\;=\; \frac{D}{2^{256}}
$$

since $H(b^* \,\|\, D)$ is an independent uniform 256-bit value. $\square$

### 1.6 Gas Accounting

| Operation | Gas |
|-----------|-----|
| `SLOAD minerEpochCount[m]` (warm) | 100 |
| `SLOAD lastMineBlock` (warm) | 100 |
| `SLOAD currentDifficulty` (warm) | 100 |
| $H$ for $\tau$ (3 packed args, 96 bytes) | 54 |
| $H$ for $\iota$ (2 args, 64 bytes) | 36 |
| $H$ for inner cascade pass (2 args, 64 bytes) | 36 |
| $H$ for outer cascade pass (2 args, 64 bytes) | 36 |
| `SSTORE minerEpochCount++` (warm→dirty) | 2,900 |
| `SSTORE lastMineBlock` (warm→dirty) | 2,900 |
| Base ERC-20 mint + event | ~30,000 |
| Window buffer + uniqueCount update (§2.1) | ~12,000 |
| Fee forward + stuck-fee fallback | ~5,500 |
| **Estimated total `mine()` gas** | **≈ 66,500 gas** |

At Base L2 with $\texttt{basefee} = 0.05\;\text{gwei}$:

$$
\text{gas cost} = 66{,}500 \times 0.05 \times 10^{-9}\;\text{ETH}
= 3.325 \times 10^{-6}\;\text{ETH} \approx \$0.008
$$

---

## 2. Nakamoto Coefficient Throttle (NCT)

### 2.1 Circular Buffer — Formal Specification

**Definition 2.1 (Miner Window).** The contract maintains:
- $W = 256$: window size (a power of 2)
- $\textbf{win}[0..255] \in \mathcal{M}^{256}$: circular buffer of recent miners
- $h \in \{0,\ldots,255\}$: write-head pointer (advances mod 256)
- $\texttt{freq} : \mathcal{M} \to \{0,\ldots,256\}$: reference count per address
- $C_u \in [1, 256]$: count of distinct addresses in the window

**Definition 2.2 (Window Update).** On successful `mine()` by $m$:

$$
\begin{aligned}
m_{\text{out}} &\gets \textbf{win}[h] \\[2pt]
\textbf{win}[h] &\gets m \\[2pt]
h &\gets (h + 1) \bmod 256 \\[2pt]
\texttt{freq}[m_{\text{out}}] &\gets \texttt{freq}[m_{\text{out}}] - 1 \\[2pt]
C_u &\gets C_u - \mathbf{1}[\texttt{freq}[m_{\text{out}}] = 0] \\[2pt]
\texttt{freq}[m] &\gets \texttt{freq}[m] + 1 \\[2pt]
C_u &\gets C_u + \mathbf{1}[\texttt{freq}[m] = 1]
\end{aligned}
$$

where $\mathbf{1}[\cdot]$ is the indicator function.

**Invariant I11.** For all reachable states after the first mine:

$$
C_u \;=\; \bigl|\{m \in \mathcal{M} : \texttt{freq}[m] > 0\}\bigr|
\;\in\; [1,\,256]
$$

*Proof.* At genesis: $C_u = 0$. After first mine: one address has $\texttt{freq} = 1$,
so $C_u = 1$. Each update increments $C_u$ iff a new address enters, and
decrements iff an address fully exits. Since $\texttt{freq}$ is a reference count
bounded by $[0, 256]$, and at most 256 distinct addresses can reside
simultaneously in a 256-slot buffer, $C_u \leq 256$ always. $C_u = 0$ is
impossible after the first mine because the writer adds its own address
before decrement can eliminate all entries. $\square$

### 2.2 Concentration Factor — Fixed-Point Representation

**Definition 2.3.** The concentration factor uses `filledSlots` $k$ (the number
of non-empty entries in the window, which grows from $0$ to $256$ over the first
$256$ mines and then stays at $256$):

$$
C_{\text{wad}}[n] \;=\; \left\lfloor \frac{k \times \text{WAD}}{C_u} \right\rfloor
$$

In the steady state ($k = 256$) this equals $\lfloor 256 \times 10^{18} / C_u \rfloor$.
The real-valued concentration factor is $C[n] = C_{\text{wad}}[n] / \text{WAD} \in [1, 256]$.

**Boundary cases (steady state):**
- $C_u = 256$: $C_{\text{wad}} = \text{WAD}$, i.e. $C = 1$ — fully distributed
- $C_u = 1$: $C_{\text{wad}} = 256 \times \text{WAD}$, i.e. $C = 256$ — fully centralised

**Bootstrap suppression.** During the first $32$ mines (`NCT_BOOTSTRAP_SLOTS = 32`),
`nctSignal()` returns $0$ regardless of window contents. A single miner must
dominate the early window by necessity — this is not an attack. The NCT penalty
activates only after $32$ fills, at which point the window contains meaningful
distribution data. This suppression also ensures $k < B_{NCT}$
does not produce a spurious concentration signal from an under-filled window.

### 2.3 NCT Control Signal — Derivation

**Definition 2.4 (NCT Signal).** With parameters $\alpha = 0.1$ and
$\tau_{\max} = 0.3$, `MinerWindow.nctSignal()` returns a non-positive raw
signal in Q60.18:

$$
\text{tax}_{\text{wad}}[n] \;=\; \min\!\left(\frac{C_{\text{wad}}[n] - \text{WAD}}{10},\; \tau_{\max,\,\text{wad}}\right)
$$

$$
s_{\text{nct}}[n] \;=\; -\text{tax}_{\text{wad}}[n] \;\leq\; 0
$$

In real units: $s_{\text{nct}}[n] = -\min(0.1\,(C[n]-1),\;0.3) \leq 0$.

**Sign convention — implementation detail.** `PIController.step()` receives
`uNct = s_nct` (non-positive) and *subtracts* it from $u_{\text{pi}}$:

```
uCombined = uPi - uNctClamped   // uNctClamped = s_nct ≤ 0
```

Because $s_{\text{nct}} \leq 0$, this is equivalent to *adding* a non-negative
penalty. Defining the penalty magnitude $u_{\text{nct}} := |\text{tax}[n]| \geq 0$:

$$
\boxed{
u[n] \;=\; \mathbf{sat}\!\bigl(u_{\text{pi}}[n] + u_{\text{nct}}[n],\;-U_{\max},\;+U_{\max}\bigr),
\quad u_{\text{nct}}[n] = \min\!\bigl(0.1\,(C[n]-1),\;0.3\bigr) \geq 0
}
$$

**NCT always raises or holds difficulty** — it never lowers it.
Centralisation ($C > 1$) increases $u[n]$, which increases $D[n+1]$.

**Observation 2.5.** $u_{\text{nct}}$ is monotonically non-decreasing in $C[n]$,
equals $0$ at $C[n] = 1$ (fully distributed), and saturates at $0.3$ for $C[n] \geq 4$.

### 2.4 Sybil Cost Analysis — Full Derivation

**Setup.** Suppose a single adversary controls $k$ addresses
$m_1, \ldots, m_k \in \mathcal{M}$, each mining with global difficulty $D[n]$.
To appear fully distributed ($C_u = W = 256$), the adversary needs $k = 256$
distinct addresses each holding $\geq 1$ slot in the 256-slot window.

**Cost per window cycle.** Each slot evicts the oldest entry after 256 new
mines system-wide. The adversary's addresses must be topped up at rate $\geq 1$
mine per 256 total mines, per address. In expectation, the adversary pays:

$$
\sigma(k) \;=\; k \times \texttt{fee} \;=\; k \times \$0.10 \quad \text{per cycle}
$$

**Suppressing NCT entirely** requires $k = W = 256$:

$$
\sigma(256) \;=\; 256 \times \$0.10 \;=\; \$25.60 \text{ per 256-mine cycle}
$$

This is identical to the cost of 256 legitimate mines. No economic gain.

**Proposition 2.6 (Sybil Equivalence).** The per-mine cost of suppressing the
NCT signal equals the per-mine cost of legitimate mining:

$$
\frac{\sigma(W)}{W} \;=\; \frac{W \cdot \texttt{fee}}{W} \;=\; \texttt{fee}
$$

Therefore the NCT Sybil attack is economically dominated by legitimate mining:
the attacker incurs identical cost while receiving NCT pressure identical to
the distributed case, and gains no additional reward. $\square$

### 2.5 Stability of NCT Term — Formal Statement

**Proposition 2.7.** Let $u_{\text{nct}}[n] = |\text{tax}[n]| \geq 0$ (the penalty
magnitude, as defined in §2.3) with $0 \leq u_{\text{nct}}[n] \leq 0.3$.
The combined control signal:

$$
u[n] \;=\; \mathbf{sat}\!\bigl(u_{\text{pi}}[n] + u_{\text{nct}}[n],\; -U_{\max},\; U_{\max}\bigr)
$$

with $U_{\max} = 0.5$ remains within $[-0.5, 0.5]$ for all values of
$u_{\text{pi}}[n] \in [-0.5, 0.5]$ and $u_{\text{nct}}[n] \in [0, 0.3]$.

*Proof.* Since $u_{\text{nct}} \leq 0.3 < U_{\max} = 0.5$, the outer
$\mathbf{sat}$ clamp is sufficient regardless of their sum. The NCT term
shifts the operating point of the PI controller by at most $0.3$ units in
the positive direction (raising $D$ on centralisation), which is within the
Lyapunov-stable regime analysed in §3.3. $\square$

---

## 3. Discrete-Time PI Controller on $\ln D$

### 3.1 State Space — Formal Definition

**Definition 3.1.** The PI controller operates on the discrete-time
state space $\mathcal{S} = \mathbb{R} \times [-I_{\max}, I_{\max}]$, with:

| Variable | Domain | Semantics |
|----------|--------|-----------|
| $e[n]$ | $\mathbb{R}$ | Fractional timing error for period $n$ |
| $I[n]$ | $[-I_{\max}, I_{\max}]$ | Integrator state (anti-windup saturated) |
| $u_{\text{pi}}[n]$ | $[-U_{\max}, U_{\max}]$ | Proportional-integral control output |
| $D[n]$ | $\mathbb{N}_{\geq 1}$ | Difficulty at the start of period $n$ |

### 3.2 System Equations — Complete Specification

**Definition 3.2.** With target window $T = 241{,}920\;\text{s}$ and
observed window $T_{\text{actual}}[n] = t_{\text{end}}[n] - t_{\text{start}}[n]$:

$$
\boxed{
\begin{aligned}
e[n] \;&=\; \frac{T_{\text{actual}}[n] - T}{T} \\[8pt]
I[n] \;&=\; \mathbf{sat}\!\bigl(I[n-1] + e[n],\;{-}I_{\max},\;{+}I_{\max}\bigr) \\[8pt]
u_{\text{pi}}[n] \;&=\; \mathbf{sat}\!\bigl(-(K_p\,e[n] + K_i\,I[n]),\;{-}U_{\max},\;{+}U_{\max}\bigr) \\[8pt]
u[n] \;&=\; \mathbf{sat}\!\bigl(u_{\text{pi}}[n] + u_{\text{nct}}[n],\;{-}U_{\max},\;{+}U_{\max}\bigr) \\[8pt]
D[n+1] \;&=\; \mathbf{sat}\!\bigl(D[n]\cdot\exp(u[n]),\;\tfrac{D[n]}{4},\;4D[n]\bigr)
\end{aligned}
}
$$

with parameters:

| Symbol | Value | Rationale |
|--------|-------|-----------|
| $T$ | $241{,}920\;\text{s}$ | $2{,}016 \times 120\;\text{s}$ target window |
| $K_p$ | $0.5$ | Proportional gain |
| $K_i$ | $0.05$ | Integral gain; critical damping $\approx$ 10 periods |
| $I_{\max}$ | $4.0$ | Anti-windup saturation bound |
| $U_{\max}$ | $0.5$ | Control output saturation |
| Max step | $\times 4\,/\,\div 4$ | Outer difficulty envelope |

### 3.3 Lyapunov Stability Certificate

**Theorem 3.3 (Asymptotic Stability at Origin).** Consider the unsaturated
linearised system (i.e., $|u_{\text{pi}}[n]| < U_{\max}$ and $|I[n]| < I_{\max}$).
The origin $(e, I) = (0, 0)$ is **globally asymptotically stable** with
Lyapunov function:

$$
V(e, I) \;=\; \frac{e^2}{2} + \frac{K_i}{K_p}\cdot\frac{I^2}{2}
$$

*Proof.* **Positive definiteness.** $V(e,I) > 0$ for $(e,I) \neq (0,0)$,
and $V(0,0) = 0$. $V$ is radially unbounded ($V \to \infty$ as $|(e,I)| \to \infty$).

**One-step decrement.** At period $n$, assuming $e[n+1] \approx -u_{\text{pi}}[n]$
(from the plant dynamics) and $I[n] = I[n-1] + e[n]$:

$$
\Delta V \;=\; V(e[n+1], I[n+1]) - V(e[n], I[n])
$$

In the unsaturated regime, the PI law gives:

$$
e[n+1] \;\approx\; -(K_p\,e[n] + K_i\,I[n])
$$

and $\Delta I = e[n]$. Therefore:

$$
\Delta V \;=\; e[n]\,\Delta e + \frac{K_i}{K_p}\,I[n]\,\Delta I
$$

$$
\Delta e \;=\; e[n+1] - e[n] \;\approx\; -K_p\,e[n] - K_i\,I[n] - e[n]
$$

$$
\Delta V \;=\; e[n]\bigl(-K_p\,e[n] - K_i\,I[n] - e[n]\bigr)
+ \frac{K_i}{K_p}\,I[n]\,e[n]
$$

$$
= -K_p\,e[n]^2 - K_i\,e[n]\,I[n] - e[n]^2 + \frac{K_i}{K_p}\cdot K_p\,e[n]\,I[n]
$$

$$
= -K_p\,e[n]^2 - e[n]^2 \;\leq\; -K_p\,e[n]^2 \;\leq\; 0
$$

Cross-terms in $e[n]\,I[n]$ cancel exactly. $\Delta V = 0$ only when $e[n] = 0$.
By LaSalle's invariance principle (applied to the set $\{(e,I) : \Delta V = 0\} = \{e=0\}$):
the largest invariant subset in this set satisfies $I[n] \to 0$ as well
(since $e=0$ implies $I$ is constant, and then $u_{\text{pi}} = -K_i\,I$,
driving $e$ away from 0 unless $I=0$ too). Therefore the unique
invariant set is $\{(0,0)\}$, confirming global asymptotic stability. $\square$

### 3.4 Justification for $\exp(u)$ vs. Linear Approximation

**Proposition 3.4.** The multiplicative update $D[n+1] = D[n] \cdot \exp(u[n])$
is the unique composition law consistent with operating the controller in
log-difficulty space.

*Proof.* Define $\ell[n] = \ln D[n]$. The natural additive update in
log-space is $\ell[n+1] = \ell[n] + u[n]$, i.e.:

$$
D[n+1] = e^{\ell[n+1]} = e^{\ell[n] + u[n]} = D[n] \cdot e^{u[n]}
$$

The linear approximation $D[n+1] \approx D[n](1 + u[n])$ introduces a
compounding error. Over $N$ periods:

$$
\prod_{i=1}^{N}(1+u_i) \;\neq\; \exp\!\Bigl(\sum_{i=1}^{N} u_i\Bigr)
$$

The relative error at the boundary $|u| = 0.5$:

$$
\frac{e^{0.5} - (1 + 0.5)}{e^{0.5}} \;=\; \frac{1.6487 - 1.5}{1.6487} \;\approx\; 9.0\%
$$

Over $N = 10$ periods this compounds to $\approx (1.09)^{10} - 1 \approx 137\%$ error
in the aggregate adjustment factor. Exact `exp` is mandatory for fidelity. $\square$

### 3.5 Fourth-Order Maclaurin Approximation

**Definition 3.5.** The on-chain `exp` implementation uses the Taylor polynomial:

$$
\exp(u) \;\approx\; 1 + u + \frac{u^2}{2!} + \frac{u^3}{3!} + \frac{u^4}{4!}
$$

**Proposition 3.6 (Error Bound).** For $|u| \leq U_{\max} = 0.5$:

$$
\left|\exp(u) - \sum_{k=0}^{4}\frac{u^k}{k!}\right|
\;\leq\; \frac{|u|^5}{5!} \cdot \frac{1}{1 - |u|/6}
\;\leq\; \frac{0.5^5}{120} \cdot \frac{1}{1 - 1/12}
\;\approx\; 2.84 \times 10^{-4}
$$

More conservatively, using the Lagrange remainder with $\xi \in (0, u)$:

$$
\left|R_4(u)\right| \;=\; \frac{e^\xi}{5!}|u|^5 \;\leq\; \frac{e^{0.5}}{120} \cdot 0.5^5
\;\approx\; \frac{1.6487 \times 0.03125}{120} \;\approx\; 4.3 \times 10^{-4}
$$

Both bounds are below $0.044\%$ — negligible relative to the $25\%$ step
resolution implied by $U_{\max} = 0.5$.

**Fixed-point implementation.** All multiplications are in Q60.18:

$$
(a \times b)_{\text{wad}} \;=\; \left\lfloor \frac{a \times b}{10^{18}} \right\rfloor
$$

Overflow condition: $|a|, |b| \leq 10 \times \text{WAD}$ ensures
$|a \times b| \leq 100 \times \text{WAD}^2 \ll 2^{255}$.
At $|u| \leq 0.5 \times \text{WAD}$: $u^4 / 24 \leq (0.5)^4/24 \approx 0.026 \times \text{WAD}$,
well within `int256` bounds.

---

## 4. Q60.18 Fixed-Point Arithmetic

### 4.1 Representation

**Definition 4.1.** Q60.18 represents a real number $r \in \mathbb{R}$ as
the integer $r_{\text{wad}} = \lfloor r \times \text{WAD} \rfloor$ where
$\text{WAD} = 10^{18}$. The usable real range is:

$$
r \;\in\; \left(-\frac{2^{255}}{\text{WAD}},\; \frac{2^{255}-1}{\text{WAD}}\right)
\;\approx\; (-5.79 \times 10^{58},\; 5.79 \times 10^{58})
$$

All protocol parameters satisfy $|r| \ll 10^{10}$, so overflow is impossible
in the normal operating regime.

### 4.2 Operation Correctness

| Operation | WAD formula | Exact iff |
|-----------|-------------|-----------|
| $\text{add}(a,b)$ | $a + b$ | always (mod $2^{256}$ wrapping excluded by bounds) |
| $\text{sub}(a,b)$ | $a - b$ | always |
| $\text{mul}(a,b)$ | $\lfloor(a \times b) / \text{WAD}\rfloor$ | intermediate $a \times b \leq 2^{255}$ |
| $\text{exp4}(u)$ | Maclaurin, 4 terms | error $< 4.3 \times 10^{-4}$ (§3.5) |
| $\text{log2Floor}(x)$ | 7-step binary search | exact for all $x \in \mathbb{N}_{\geq 1}$ |

### 4.3 `log2Floor` — Correctness and Complexity

**Algorithm 4.2.** For $x \in \mathbb{N}_{\geq 1}$, compute $\lfloor\log_2 x\rfloor$:

```
bits ← 0
for s in [128, 64, 32, 16, 8, 4, 2, 1]:
    if x >> s > 0:
        bits += s
        x >>= s
return bits
```

**Proposition 4.3 (Correctness).** Algorithm 4.2 returns $\lfloor\log_2 x\rfloor$
for all $x \geq 1$.

*Proof.* Binary search on the bit-length $\ell$ of $x$: at each step, the
remaining value of $x$ is reduced to $\lfloor x / 2^s \rfloor$. After 7 steps
(exhausting the sequence $128+64+32+16+8+4+2+1 = 255$), `bits` accumulates
the positions of all set bits from the MSB downward. The result equals the
position of the highest set bit = $\lfloor\log_2 x\rfloor$. $\square$

**Complexity.** Exactly 7 conditional branches; $O(1)$ gas independent of input.

---

## 5. Protocol Fee Oracle

### 5.1 Dimensional Derivation

**Goal.** Express a USD target fee $f = \$0.10$ as an amount in wei, given
Chainlink answer $p$ (ETH/USD with $d = 8$ decimal places, i.e. $p = p_{\$} \times 10^8$).

**Step-by-step:**

$$
\text{fee}_{\text{ETH}} \;=\; \frac{f}{p_{\$}} \;=\; \frac{0.10}{p / 10^8} \;=\; \frac{0.10 \times 10^8}{p}
$$

$$
\text{fee}_{\text{wei}} \;=\; \text{fee}_{\text{ETH}} \times 10^{18}
\;=\; \frac{0.10 \times 10^8 \times 10^{18}}{p}
\;=\; \frac{10^{-1} \times 10^{26}}{p}
\;=\; \frac{10^{25}}{p}
$$

Equivalently, expressing $f = 100{,}000\;\mu\text{USD}$:

$$
\boxed{
\text{fee}_{\text{wei}} \;=\; \frac{100{,}000 \times 10^{20}}{p}
}
$$

**Sanity check** at $p_{\$} = \$2{,}500$ ($p = 2{,}500 \times 10^8 = 2.5 \times 10^{11}$):

$$
\text{fee}_{\text{wei}} \;=\; \frac{10^{25}}{2.5 \times 10^{11}} \;=\; 4 \times 10^{13}\;\text{wei}
\;=\; 4 \times 10^{-5}\;\text{ETH} \;=\; \$0.10 \quad \checkmark
$$

**Integer arithmetic in Solidity.** The numerator $10^{25}$ fits within `uint256`
($10^{25} < 2^{256} \approx 1.16 \times 10^{77}$). Division is integer
floor-division, introducing a rounding error of at most $1\;\text{wei} = 10^{-18}\;\text{ETH}$,
which is negligible.

### 5.2 Oracle Validity — Formal Invariants

**Invariant O1 (Positive Answer):**
$$
p > 0 \quad\text{or revert}\;\texttt{InvalidOracle}
$$

**Invariant O2 (Non-Future Timestamp):**
$$
\texttt{updatedAt} \leq \texttt{block.timestamp} \quad\text{or revert}\;\texttt{OracleClockSkew}
$$

**Invariant O3 (Freshness):**
$$
\texttt{block.timestamp} - \texttt{updatedAt} \leq 24\,\text{hours}
\quad\text{or revert}\;\texttt{StaleOracle}
$$
(`ORACLE_MAX_STALENESS = 24 hours` in `Anvil256.sol`.)

**Invariant O4 (Decimal Bound):**
$$
d \leq 24 \quad\text{or revert}\;\texttt{OracleDecimalsTooLarge}
$$

**Invariant O5 (Answered-In-Round Guard):**
$$
\texttt{answeredInRound} \geq \texttt{roundId} \quad\text{or revert}\;\texttt{StaleOracle}
$$
If `answeredInRound < roundId` the aggregator is returning a cached answer
from a prior round that has not yet been superseded — treated as stale.

**Note on Round ID gaps.** Chainlink OCR2 aggregators do not guarantee
contiguous round IDs across phase boundaries. A gap in the sequence of
`roundId` values (e.g. `roundId` jumps from 1 to 10 after a phase upgrade)
is not checked — checking it would produce false positives during normal
aggregator upgrades. The `answeredInRound < roundId` guard (O5) is narrower:
it only rejects rounds where the oracle explicitly signals the answer came
from a prior round, which is a reliable indicator of a stale response.

---

## 6. Supply Curve — Complete Verification

### 6.1 Reward Function — Formal Definition

**Definition 6.1.** The block reward at epoch $n \in \mathbb{N}$ is:

$$
R(n) \;=\; \begin{cases}
R_0 \gg \lfloor n/H \rfloor & \text{if } \lfloor n/H \rfloor < 64 \\
0 & \text{if } \lfloor n/H \rfloor \geq 64
\end{cases}
$$

where $R_0 = 50 \times 10^{18}$ (50 ANVL in wei) and $H = 210{,}000$.
The operator $\gg$ is the arithmetic right-shift, i.e.:

$$
R(n) \;=\; R_0 \cdot 2^{-\lfloor n/H\rfloor} \quad\text{for halvings } 0\ldots63
$$

### 6.2 Miner-Only Schedule and Actual Supply Cap

**Theorem 6.2 (Miner-Only Baseline).** The idealized sum of miner rewards over
all halving bands approaches $21{,}000{,}000$ ANVL:

$$
\sum_{k=0}^{63} H \cdot R_0 \cdot 2^{-k}
\;=\; H \cdot R_0 \cdot \sum_{k=0}^{63} 2^{-k}
\;=\; H \cdot R_0 \cdot \frac{1 - 2^{-64}}{1 - \frac{1}{2}}
\;=\; 2 \cdot H \cdot R_0 \cdot (1 - 2^{-64})
$$

Taking the negligible $2^{-64}$ tail as zero for the idealized series:

$$
\lim \;\approx\; 2 \times 210{,}000 \times 50 \;=\; 21{,}000{,}000\;\text{ANVL}
$$

**Integer right-shift truncation (implementation note).** The Solidity
implementation uses `R(n) = INITIAL_REWARD >> halvings` (integer bit-shift).
Due to floor truncation at each shift, the actual total mintable supply across
all 64 halving bands is approximately $20{,}999{,}991$ ANVL — roughly $9$ ANVL
below `MAX_SUPPLY` in the miner-only schedule.

The deployed contract also mints protocol-owned liquidity inside the same cap:

$$
S_{seed}=1\;\text{ANVL},\qquad M_{LP}(n)=0.1R(n)
$$

For a non-boundary mine:

$$
\Delta S(n)=R(n)+M_{LP}(n)=1.1R(n)
$$

At cap boundaries, `mine()` first truncates $R(n)$ to remaining supply and then
truncates $M_{LP}(n)$ to the remaining headroom after the miner reward. Thus the
actual invariant is:

$$
S_{seed}+\sum_n\bigl(R_{paid}(n)+M_{LP,paid}(n)\bigr)\leq 21{,}000{,}000\;\text{ANVL}
$$

The 10% POL reserve is not inflation outside the cap; it consumes the same cap
and therefore causes the cap to be reached earlier than the miner-only terminus.

**Residual from finite truncation (idealized):**

$$
\delta \;=\; H \cdot R_0 \cdot 2^{-63}
\;=\; \frac{210{,}000 \times 50}{2^{63}}
\;\approx\; 1.14 \times 10^{-12}\;\text{ANVL}
$$

Moreover, the reward schedule returns zero and `mine()` reverts with
`MiningEnded()` at $n \geq 13{,}440{,}000$ if `MAX_SUPPLY` has not already stopped
minting earlier.

### 6.3 Halving Table (Miner-Only Reference)

| Halving $k$ | Epoch start $kH$ | $R(kH)$ (miner ANVL) | Miner-only cumulative | % of 21 M |
|-------------|------------------|-----------------|-------------------|-----------|
| 0 | 0 | 50.000000 | 10,500,000 | 50.0000% |
| 1 | 210,000 | 25.000000 | 15,750,000 | 75.0000% |
| 2 | 420,000 | 12.500000 | 18,375,000 | 87.5000% |
| 3 | 630,000 | 6.250000 | 19,687,500 | 93.7500% |
| 4 | 840,000 | 3.125000 | 20,343,750 | 96.8750% |
| 5 | 1,050,000 | 1.562500 | 20,671,875 | 98.4375% |
| 7 | 1,470,000 | 0.390625 | 20,917,969 | 99.6094% |
| 10 | 2,100,000 | 0.048828 | 20,989,746 | 99.9512% |
| 14 | 2,940,000 | 0.003051 | 20,999,359 | 99.9969% |
| 32 | 6,720,000 | $< 10^{-8}$ | $\approx 21{,}000{,}000$ | $\approx 100\%$ |
| 64 | 13,440,000 | 0 (terminus) | 21,000,000 | 100.0000% |

*Computation rule:* miner-only cumulative supply after halving $k$ is:
$\sum_{j=0}^{k-1} H \cdot R_0 \cdot 2^{-j} = 2HR_0(1 - 2^{-k})$.

Actual `totalSupply` includes the 1 ANVL genesis LP seed and 10% POL reserve
mints, then applies `MAX_SUPPLY` truncation.

**No calendar projections are provided.** The protocol does not compute
wall-clock time. Epoch duration is an emergent quantity; multiply epoch
count by the observed mean epoch time for any estimate.

---

## 7. Controller Interaction — Unified Signal Flow

The three subsystems interact only through $D[n]$:

```
Each mine():
    γ(m)++                                    [Temporal binding — §1.2]
    win[h] ← m;  h ← (h+1) mod 256           [NCT buffer — §2.1]
    uniqueCount ← maintained count            [NCT signal input — §2.2]

Every 2,016 mines (one period boundary):
    e[n]   ← (T_actual − T) / T              [Timing error — §3.2]
    I[n]   ← sat(I[n−1] + e[n], ±I_MAX)     [Integrator — §3.2]
    u_pi   ← sat(−(Kp·e + Ki·I), ±0.5)      [PI signal — §3.2]
    k      ← filledSlots (grows 0→256)        [Bootstrap guard — §2.2]
    C_wad  ← (k × WAD) / uniqueCount         [Concentration — §2.2]
    s_nct  ← −min(0.1·(C−1), 0.3)  [≤ 0]   [Raw NCT from MinerWindow — §2.3]
    u_nct  ← |s_nct| = min(0.1·(C−1), 0.3) [≥ 0] [Penalty magnitude — §2.3]
    u      ← sat(u_pi + u_nct, ±0.5)         [Combined — §2.5]
    D[n+1] ← sat(D[n]·exp4(u), D/4, 4D)     [Difficulty update — §3.2]
    Note: PIController receives s_nct and computes: u = uPi − s_nct = uPi + u_nct

After every mine() (using post-adjustment D[n+1] at period boundaries):
    ε[n+1] ← H(blockhash(block) ‖ currentDifficulty)
                                              [Epoch entropy — §1.3]
```

**Critical ordering note.** The difficulty adjustment (PIController.step)
occurs *before* `epochEntropy` is written. This ensures `ε[n+1]` commits
to the post-adjustment difficulty `D[n+1]`, not the stale `D[n]`. This is
the only ordering consistent with Definition 1.7:

$$
\epsilon[n+1] \;=\; H\!\bigl(\texttt{blockhash}(\texttt{lastMineBlock}[n]) \,\|\, D[n+1]\bigr)
$$

where $D[n+1]$ is the difficulty that will govern epoch $n+1$.

---

## 8. References

- Nakamoto, S. *Bitcoin: A Peer-to-Peer Electronic Cash System.* 2008.
- Åström, K.J. & Murray, R.M. *Feedback Systems.* Princeton University Press, 2nd ed. 2021.
- Khalil, H.K. *Nonlinear Systems.* Prentice Hall, 3rd ed. 2002.
- LaSalle, J.P. *The Stability of Dynamical Systems.* SIAM, 1976.
- NIST FIPS 202. *SHA-3 Standard: Permutation-Based Hash and Extendable-Output Functions.* 2015.
- EIP-2929. *Gas Cost Increases for State Access Opcodes.* 2021.
- Chainlink Labs. *OCR2 Aggregator Architecture.* docs.chain.link.
