---
title: Anvil256 Whitepaper
slug: whitepaper
---

# Anvil256 Whitepaper

> **Anvil256** is a proof-of-work token combining
> **Keccak-Cascade PoW** with temporal miner binding,
> **Nakamoto-Coefficient-Throttle** difficulty, pure **epoch-native** halving,
> protocol-owned liquidity, and a **$0.10** native-ETH protocol fee — deployed on Base L2.
>
> If $\kappa(m,\nu,n) < D[n]$, the miner receives $R(n)$ ANVL and the
> protocol-owned liquidity reserve receives up to $0.1R(n)$ ANVL inside the
> hard cap:
>
> $$
> S_{seed}+\sum_n\bigl(R(n)+0.1R(n)\bigr) \leq 21{,}000{,}000
> $$
>
> Admin keys: $\varnothing$.

*v0.3 — 2026* &nbsp;·&nbsp; Base L2 &nbsp;·&nbsp; ERC-20 &nbsp;·&nbsp; immutable bytecode

---

## Abstract

Anvil256 (ticker **ANVL**) is an ERC-20 token with a 21,000,000 ANVL hard cap,
proof-of-work miner rewards, and explicit protocol-owned liquidity reserves. It introduces
four constructions absent from any prior production PoW token in combination.

**1. Keccak-Cascade PoW with Temporal Miner Binding.**
A three-layer hash construction. For epoch $n$, miner $m$, and nonce $\nu$:

$$
\kappa(m,\nu,n) \;=\; H\!\Bigl(H\!\bigl(H(m \,\|\, \gamma(m) \,\|\, g) \,\|\, n \,\|\, \nu\bigr) \;\big\|\; H(b_{n-1} \,\|\, D[n])\Bigr)
$$

where $\gamma(m) \in \mathbb{N}$ is a strictly monotonic, non-transferable on-chain
counter — the miner's accumulated identity. A nonce is valid iff $\kappa < D[n]$.
The outer layer binds each puzzle to $\epsilon[n] = H(b_{n-1} \,\|\, D[n])$,
a value determined only when epoch $n{-}1$ closes, making precomputation
structurally impossible.

**2. Nakamoto Coefficient Throttle (NCT).**
A second difficulty control signal derived from concentration in the 256-epoch
miner window. With $C_u$ distinct addresses and $k$ filled slots (steady state
$k = 256$):

$$
u_{\text{nct}}[n] \;=\; \min\!\Bigl(0.1\,\bigl(\tfrac{k}{C_u} - 1\bigr),\;0.3\Bigr) \;\geq\; 0
$$

This signal is always $\geq 0$ and is added to the PI timing signal in
log-difficulty space. Centralisation raises $D$; the unique Nash equilibrium
of minimal difficulty requires $C_u = k = 256$ (full distribution).

**3. Discrete-Time PI Controller on $\ln D$.**
With Lyapunov function $V(e,I) = e^2/2 + (K_i/K_p)\,I^2/2$, one-step decrement
$\Delta V \leq -K_p\,e^2$, and LaSalle invariance implying global asymptotic
stability of the origin $(e,I) = (0,0)$. Difficulty update:

$$
D[n+1] \;=\; \mathbf{sat}\!\bigl(D[n]\cdot\exp(u[n]),\;D[n]/4,\;4D[n]\bigr)
$$

where $u[n] = \mathbf{sat}(u_{\text{pi}} + u_{\text{nct}},\,\pm 0.5)$ and
$\exp$ is computed as a 4th-order Maclaurin polynomial with truncation error
$< 2.84 \times 10^{-4}$.

**4. Pure Epoch-Native Emission.**
All supply parameters are expressed in epochs (confirmed `mine()` calls):

$$
R(n) \;=\; R_0 \gg \lfloor n/H \rfloor, \quad
M(n)=R(n)+0.1R(n), \quad
S_{total}\leq 21{,}000{,}000\;\text{ANVL}
$$

No calendar dates. No block times. Wall-clock duration is an observable,
not a protocol input.

---

## 1. Design Goals

**No Dev Premine.**
There is no team mint, VC allocation, presale, or admin mint. The constructor
mints a 1 ANVL genesis seed to the contract for the official ANVL/WETH LP, and
every valid mine mints a 10% POL token reserve alongside the miner reward. The
claim is no dev premine, not "every token goes directly to miners."

**Structural Anti-Precomputation.**
$\nexists$ PPT adversary that computes a valid nonce for epoch $n$ before
$\texttt{blockhash}(\texttt{lastMineBlock}[n-1])$ is produced, except with
negligible probability. Formal proof in MATH.md §1.5.

**Anti-Wallet-Rotation.**
Cost of maintaining $k$ independent miner identities for one window cycle:
$\sigma(k) = k \times \$0.10$. Cost of genuine mining with $k$ rigs:
$k \times \$0.10$. These are equal, so Sybil is economically dominated.

**Decentralisation as Nash Equilibrium.**
The unique minimiser of the difficulty signal is $C_u = 256$ (full distribution).
This is not a policy — it is a provable property of the controller equations.

**Epoch Purity.**
The next halving occurs at epoch $H = 210{,}000$. No block time.
No calendar. $\square$

**Immutability.**
$\nexists$ admin key, $\nexists$ upgrade proxy. The deployed bytecode is
the permanent, unalterable protocol.

---

## 2. Keccak-Cascade PoW

### 2.1 Wallet-Rotation Attack — Formal Analysis

**Definition 2.1 (Naive PoW).** Challenge: $c_{\text{naive}}(m,n,\nu) = H(m \,\|\, n \,\|\, \nu)$.
A nonce $\nu^*$ is valid iff $c_{\text{naive}} < D[n]$.

**Problem.** For any $m' \notin \{m\}$, $c_{\text{naive}}(m', n, \cdot)$
is independent of $c_{\text{naive}}(m, n, \cdot)$. Generating $m'$ costs
$O(1)$ elliptic-curve operations. Therefore:

$$
\text{Cost}_{\text{sybil}}(k) \;=\; 0 \quad \forall\;k \leq W
$$

The NCT concentration signal is then trivially spoofable: a single physical
operator can appear as $k$ independent miners by using $k$ fresh addresses,
paying zero additional protocol cost.

### 2.2 Temporal Miner Binding — Construction

**Definition 2.2 ($\gamma$-Counter).** For address $m$:
$$
\gamma(m) \;:=\; |\{j < n : \texttt{mine}_j.\texttt{sender} = m\}|
$$
Implemented as `uint64 minerEpochCount[m]`, pre-increment value at each call.
Properties: strictly non-decreasing, non-transferable, permanent.

**Definition 2.3 (Full Cascade).** For epoch $n$, caller $m$, nonce $\nu$:

$$
\epsilon[n] \;=\; H\!\bigl(\texttt{blockhash}(\texttt{lastMineBlock}[n{-}1]) \,\|\, D[n]\bigr)
$$

$$
\tau(m,n) \;=\; H\!\bigl(m \,\|\, \gamma(m) \,\|\, \texttt{genesisBlockhash}\bigr)
$$

$$
\iota(m,n) \;=\; H\!\bigl(\tau(m,n) \,\|\, n\bigr)
$$

$$
\kappa(m,\nu,n) \;=\; H\!\Bigl(H\!\bigl(\iota(m,n) \,\|\, \nu_{\text{be32}}\bigr) \;\Big\|\; \epsilon[n]\Bigr)
$$

Valid iff $\kappa(m,\nu^*,n) < D[n]$.

### 2.3 Security Properties — Summary Table

| Property | Standard PoW | Cascade PoW |
|----------|-------------|-------------|
| Precomputation | $\Pr[\text{success}] = D/2^{256}$ (same as online) | Same (structural impossibility via $\epsilon[n]$) |
| Wallet rotation cost | $\sigma(k) = 0$ | $\sigma(k) \geq k \times \$0.10$ |
| Rainbow table (known miners) | Feasible for fixed $\gamma$ | Infeasible: $\epsilon[n]$ rotates every epoch; $\gamma$ personalises |
| Cross-miner nonce theft | $\tau$ not included — feasible | $\tau$ includes $m$; $m \neq m' \Rightarrow \tau \neq \tau'$ |
| Replay across epochs | Blocked by epoch counter | Blocked by $\epsilon[n]$ change (independent per epoch) |
| ASIC optimisation | Full precompute feasible | Outer pass requires live $\epsilon[n]$: mandatory per-epoch network fetch |

### 2.4 Gas Cost

Total `mine()` gas: **$\approx 66{,}500$**. At Base L2 basefee $= 0.05$ gwei:

$$
\text{gas cost} = 66{,}500 \times 5 \times 10^{-11}\;\text{ETH} \approx \$0.008
$$

Full per-opcode breakdown in MATH.md §1.6.

---

## 3. Nakamoto Coefficient Throttle

### 3.1 Motivation — Insufficiency of Timing-Only Controllers

In all prior production PoW systems, the difficulty controller is driven
purely by timing: $D[n+1] = D[n] \cdot T / T_{\text{actual}}$. This signal
is invariant to who mines — one actor with 99% of hashrate produces the same
timing signal as 1,000 evenly-distributed actors at identical aggregate rate.

**Definition 3.1 (Concentration Factor).** Let $C_u$ be the number of
distinct addresses in the 256-slot miner window. The concentration factor is:

$$
C \;=\; \frac{256}{C_u} \;\in\; [1,\,256]
$$

$C = 1 \Leftrightarrow$ maximal distribution ($C_u = 256$).
$C = 256 \Leftrightarrow$ complete centralisation ($C_u = 1$).

### 3.2 NCT Signal — Derivation and Equilibrium Analysis

$$
u_{\text{nct}}[n] \;=\; \min\!\bigl(0.1\,(C[n]-1),\;0.3\bigr) \;\geq\; 0
$$

This is always $\geq 0$: the NCT only ever pushes difficulty upward.
It cannot lower difficulty below what the timing PI alone would set.
(Internally, `MinerWindow.nctSignal()` returns the negated value; `PIController`
subtracts it, yielding the same result as adding the positive magnitude above.
See MATH.md §2.3 for the full sign derivation.)

**Equilibrium table:**

| $C_u$ | $C$ | $u_{\text{nct}}$ | Difficulty multiplier per period |
|--------|-----|-----------------|----------------------------------|
| 256 | 1.0 | $0$ | $\exp(0) = 1.000$ (PI governs) |
| 128 | 2.0 | $+0.1$ | $\times\exp(0.1) \approx 1.105$ |
| 32 | 8.0 | $+0.3$ | $\times\exp(0.3) \approx 1.350$ |
| 16 | 16.0 | $+0.3$ (capped) | $\times 1.350$ |
| 1 | 256.0 | $+0.3$ (capped) | $\times 1.350$ compounding per period |

**Nash Equilibrium.** The unique strategy profile that minimises difficulty
(and thus maximises expected reward per unit of hashrate) is $C_u = 256$.
Any deviation toward concentration increases $u_{\text{nct}} > 0$, raising $D$
for all miners. This is not enforced externally — it is the mathematical
structure of the update equation.

### 3.3 Combined Update

Define the NCT penalty magnitude $u_{\text{nct}}[n] := \min(0.1\,(C[n]-1),\;0.3) \geq 0$
(see MATH.md §2.3 for the sign convention and its derivation from the
`MinerWindow.nctSignal()` return value).

$$
u[n] \;=\; \mathbf{sat}\!\bigl(u_{\text{pi}}[n] + u_{\text{nct}}[n],\;-0.5,\;+0.5\bigr)
$$

$$
D[n+1] \;=\; \mathbf{sat}\!\bigl(D[n]\cdot\exp(u[n]),\;D[n]/4,\;4D[n]\bigr)
$$

**NCT always raises or holds difficulty.** Because $u_{\text{nct}} \geq 0$,
adding it to $u_{\text{pi}}$ can only increase $u[n]$ (before the outer clamp),
which increases $D[n+1]$. Centralisation is penalised; decentralisation ($C_u = 256$,
$u_{\text{nct}} = 0$) removes the penalty entirely.

Additivity in $u$-space corresponds to multiplicativity in $D$-space, which
is the correct composition law for independent signals on a multiplicative
quantity. Formal proof in MATH.md §3.4.

---

## 4. Timing PI Controller

### 4.1 Equations

With target $T = 2{,}016 \times 120\;\text{s} = 241{,}920\;\text{s}$:

$$
e[n] \;=\; \frac{T_{\text{actual}}[n] - T}{T}, \qquad
I[n] \;=\; \mathbf{sat}(I[n{-}1]+e[n],\;\pm 4.0)
$$

$$
u_{\text{pi}}[n] \;=\; \mathbf{sat}\!\bigl(-(0.5\,e[n]+0.05\,I[n]),\;\pm 0.5\bigr)
$$

### 4.2 Stability Certificate (Summary)

Lyapunov function: $V(e,I) = e^2/2 + 0.1\,I^2/2$.
One-step decrement: $\Delta V \leq -0.5\,e[n]^2 \leq 0$.
LaSalle invariance: largest invariant set in $\{e=0\}$ is $\{(0,0)\}$.
Conclusion: **globally asymptotically stable origin** in unsaturated regime.
Full proof in MATH.md §3.3.

---

## 5. Epoch-Native Emission

### 5.1 Reward Function

$$
R(n) \;=\; \begin{cases}
50 \gg \lfloor n/210{,}000\rfloor & \text{(ANVL, right-shift)} \\
0 & \text{for } \lfloor n/210{,}000\rfloor \geq 64
\end{cases}
$$

### 5.2 Miner-Only Schedule — Idealized Derivation

The closed-form miner-only schedule is the Bitcoin-style baseline:

$$
\sum_{k=0}^{63} 210{,}000 \cdot 50 \cdot 2^{-k}
\;=\; 210{,}000 \cdot 50 \cdot \frac{1-2^{-64}}{1-\tfrac{1}{2}}
\;\approx\; \boxed{21{,}000{,}000\;\text{ANVL}}
$$

The deployed contract adds two hard-cap-inclusive components: a 1 ANVL genesis
LP seed and a 10% POL token reserve minted beside each miner reward:

$$
\Delta S(n)=R(n)+0.1R(n)=1.1R(n),\qquad S(0)=1\;\text{ANVL after genesis}
$$

Therefore the practical minting process reaches the 21,000,000 ANVL cap earlier
than the pure miner-only terminus. The reserve is not inflation outside the cap;
it is constrained by the same `MAX_SUPPLY` check.

### 5.3 Halving Schedule

| Halving $k$ | Epoch $kH$ | $R$ (miner ANVL) | Miner-only cumulative | % of 21 M |
|-------------|-----------|------------|------------|-----------|
| 0 | 0 | 50 | 10,500,000 | 50.000% |
| 1 | 210,000 | 25 | 15,750,000 | 75.000% |
| 2 | 420,000 | 12.5 | 18,375,000 | 87.500% |
| 3 | 630,000 | 6.25 | 19,687,500 | 93.750% |
| 4 | 840,000 | 3.125 | 20,343,750 | 96.875% |
| 5 | 1,050,000 | 1.5625 | 20,671,875 | 98.438% |
| 7 | 1,470,000 | 0.390625 | 20,917,969 | 99.609% |
| 10 | 2,100,000 | 0.048828 | 20,989,746 | 99.951% |
| 32+ | 6,720,000+ | $< 10^{-8}$ | $\approx 21{,}000{,}000$ | $\approx 100\%$ |
| 64 | 13,440,000 | 0 | 21,000,000 | 100.000% |

The table is a miner-only schedule reference. Actual `totalSupply` also includes
the genesis LP seed and POL reserve mints, and is truncated by the hard cap.

---

## 6. Protocol Fee

$$
\text{fee}_{\text{wei}} \;=\; \frac{100{,}000 \times 10^{20}}{p_{\text{chainlink}}}
$$

At ETH $= \$2{,}500$: $\text{fee}_{\text{wei}} = 4\times 10^{13}$ wei $= \$0.10$.
Full dimensional derivation in MATH.md §5.

The fee is split deterministically:

$$
\$0.10 = \$0.05_{dev}+\$0.05_{LP}
$$

The dev split is transferred to the immutable `feeRecipient`. The LP split is
accumulated as `lpReserveEthWei` and paired with the LP token reserve:

$$
\Delta LP_{ETH}=\$0.05,\qquad \Delta LP_{ANVL}=0.1R(n)
$$

Before the 50% supply trigger, reserves accumulate. At and after the trigger:

$$
totalSupply \ge 0.5\times 21{,}000{,}000 = 10{,}500{,}000\ \mathrm{ANVL}
$$

any caller may run `deployLiquidityReserves()`. Later reserves can be added via
`dripLiquidityReserves()`. Official Uniswap v3 LP NFTs are held by the token
contract and no withdrawal path exists.

---

## 7. Security Summary

| Threat | Formal Mitigation |
|--------|-------------------|
| Keccak preimage | $\Pr[\text{success}] \leq 2^{-128}$ (birthday bound, NIST FIPS 202) |
| Cascade precomputation | $\epsilon[n]$ uniformly random before epoch $n{-}1$ closes (Theorem 1.11, MATH.md) |
| Wallet rotation / Sybil | $\sigma(k) \geq k \times \$0.10$ (Theorem 1.9, MATH.md) |
| Rainbow table over miners | $\epsilon[n]$ rotates per epoch; $\gamma$ personalises per address |
| NCT Sybil (fake diversity) | Costs $\$0.10/\text{mine}$ — equal to legitimate mining (Corollary 1.10) |
| Nonce replay across epochs | $\epsilon[n]$ is independent per epoch; reuse invalid |
| Cross-miner nonce theft | $\tau$ includes $\texttt{msg.sender}$; different caller $\Rightarrow$ different challenge |
| Oracle manipulation | Reverts O1–O4; client-side `MAX_FEE_USD` cap (MATH.md §5.2) |
| Difficulty collapse | $D \geq 1$ floor; $\times 4/\div 4$ envelope |
| Integrator windup | $\|I\|_\infty \leq I_{\max} = 4.0$ anti-windup saturation |
| Selfish mining | N/A: Base L2 deterministic sequencer finality |

---

## 8. Comparison with Prior PoW Tokens

| | Bitcoin | 0xBitcoin | Catecoin | **Anvil256** |
|---|---|---|---|---|
| Hash function | SHA-256 | Keccak-256 | Various | **Cascade Keccak** |
| Precomputation | Yes | Yes | Yes | **No (Theorem 1.11)** |
| Rotation cost $\sigma(k)$ | 0 | 0 | 0 | **$\geq k\times\$0.10$** |
| Difficulty algorithm | Ratio | Ratio | LWMA | **PI + NCT (Lyapunov)** |
| Decentralisation signal | None | None | None | **On-chain NCT** |
| Halving unit | Blocks | Blocks | Blocks | **Pure epochs** |
| Fee mechanism | None | Gas only | Gas only | **$0.10 native ETH split 50/50 (Chainlink)** |

---

## 9. Glossary

| Term | Formal Definition |
|------|------------------|
| Epoch | One successful `mine()` — atomic unit of all protocol timekeeping |
| Period | $2{,}016$ epochs — difficulty controller update interval |
| Halving | Every $H = 210{,}000$ epochs; $R \gets R \gg 1$ |
| $\epsilon[n]$ | $H(\texttt{blockhash}(\texttt{lastMineBlock}[n-1]) \,\|\, D[n])$ |
| $\gamma(m)$ | $\texttt{minerEpochCount}[m]$ — strictly monotonic, non-transferable |
| $\tau(m,n)$ | $H(m \,\|\, \gamma(m) \,\|\, g)$ — temporal identity hash |
| Cascade | Three-layer Keccak: $\tau$-layer, $\iota$-layer, $\kappa$-layer |
| NCT | Nakamoto Coefficient Throttle — $u_{\text{nct}} = \min(0.1(C-1),\,0.3) \geq 0$ |
| $C$ | $256/C_u$ — concentration factor; $C=1$ distributed, $C=256$ centralised |
| WAD | $10^{18}$ — Q60.18 fixed-point scale |

---

## 10. References

- Nakamoto, S. *Bitcoin: A Peer-to-Peer Electronic Cash System.* 2008.
- Wood, G. *Ethereum: A Secure Decentralised Generalised Transaction Ledger.* 2014.
- Åström, K.J. & Murray, R.M. *Feedback Systems.* Princeton University Press, 2nd ed. 2021.
- Khalil, H.K. *Nonlinear Systems.* Prentice Hall, 3rd ed. 2002.
- LaSalle, J.P. *The Stability of Dynamical Systems.* SIAM, 1976.
- NIST FIPS 202. *SHA-3 Standard.* 2015.
- Chainlink Labs. *Data Feed Heartbeats and Deviation Thresholds.* docs.chain.link.
- MATH.md, TOKENOMICS.md, ARCHITECTURE.md, SECURITY.md.
