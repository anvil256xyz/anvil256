---
title: Protocol Milestones
slug: roadmap
---

# Anvil256 — Protocol Milestones

> Milestones are ordered by logical dependency, not calendar time.
> Each milestone has a well-defined completion criterion: a mathematical
> property that either holds or does not. Informal descriptions are never
> substituted for formal verification criteria.

---

## M0 — Formal Specification

**Completion criterion:** All core protocol constructions are stated as
closed-form expressions with explicit domain, range, and invariants, with
proofs or derivations for every non-trivial claim.

| Deliverable | Formal Property | Verification |
|-------------|----------------|-------------|
| Keccak-Cascade + gamma binding | Preimage resistance; wallet-rotation cost is at least $k \times \$0.10$ | MATH.md §1 |
| NCT concentration factor | Sybil cost equals $k \times \$0.10$ for a $k$-address attack | MATH.md §2.4 |
| PI controller Lyapunov certificate | $\Delta V \leq -K_p e^2 \leq 0$ with equality only at $(e,I) = (0,0)$ | MATH.md §3.3 |
| Supply identity | Miner-only baseline approaches 21,000,000 ANVL; actual supply includes seed + POL reserve mints inside `MAX_SUPPLY` | MATH.md §6 |
| Oracle fee formula | `fee_wei = 10^25 / p` for an 8-decimal ETH/USD feed | MATH.md §5.1 |
| Q60.18 overflow bounds | Intermediate products are bounded within `int256` for $\lvert u\rvert \leq U_{\max}$ | MATH.md §4 |

Status: **complete.**

---

## M1 — Contract Correctness

**Completion criterion:** The deployed bytecode satisfies all protocol
invariants I1–I13 under adversarial input. Formally: for all reachable
states $S$ and all valid calldata $c$:

$$
\forall\,i \in \{1,\ldots,13\} : I_i\!\bigl(\text{post}(S, c)\bigr) = \top
$$

### M1.1 — Unit Correctness

Each contract component produces outputs matching its formal specification.

| Contract | Formal Correctness Condition |
|----------|----------------------------|
| `CascadePoW.sol` | `mine(ν)` accepts iff the Cascade hash is below `currentDifficulty` (I12) |
| `PIController.sol` | Output matches §3.2 of MATH.md: $u_{\text{pi}} = \mathbf{sat}(-(K_p e + K_i I), \pm 0.5)$ for all $(e,I,C_u)$ in domain |
| `MinerWindow.sol` | $C_u = \lvert\{m : freq[m] > 0\}\rvert$ at all times after first mine (I11) |
| `FixedPointMath.sol` | $\lvert\exp_4(u) - \exp(u)\rvert < 4.3 \times 10^{-4}$ for $\lvert u\rvert \leq 0.5$; `log2Floor` exact |
| `FeeOracle.sol` | Returns `fee_wei = 10^25 / p`; reverts on conditions O1-O4 |

### M1.2 — Invariant Coverage

Fuzz tests over the full reachable state space demonstrate:

$$
\texttt{totalSupply} \leq \texttt{MAX\_SUPPLY} \quad \text{after } n \text{ arbitrary mine calls}
$$

$$
\texttt{currentEpoch}[n+1] \geq \texttt{currentEpoch}[n] \quad \forall\,n
$$

$$
\Delta F_{recipient}+\Delta F_{stuck}+\Delta F_{LP}=\texttt{currentFeeWei}()\quad\text{(I7, per mine)}
$$

### M1.3 — Gas Budget

`mine()` gas $\leq 68{,}000$ on Base L2 under worst-case storage access
pattern (cold slots on first call of a new address). Formally:

$$
\text{gas}(\texttt{mine}()) \;\leq\; 68{,}000 \quad \text{for all reachable pre-states}
$$

This bound must not regress across versions.

### M1.4 — External Audit

At least one independent security firm completes a review of the final
pre-deployment bytecode. Audit report published in full. The reviewed
bytecode must match the cosign-signed release hash.

---

## M2 — Kernel Correctness

**Completion criterion:** The CUDA/OpenCL kernel produces `found` outputs
where $\kappa(m,\nu,n) < D[n]$, verified by independent on-chain `mine()`
acceptance, for 10,000 independent test cases. Formally:

$$
\Pr\!\bigl[\texttt{mine}(\nu_{\text{kernel}}) \text{ accepted}\bigr] \;=\; 1
\quad \text{over } 10{,}000 \text{ test cases}
$$

### M2.1 — Single-Device Correctness

Kernel output on one GPU matches CPU reference implementation for identical
$(ι, \epsilon[n], D[n])$ inputs. Formally, for all test inputs:

$$
\kappa_{\text{GPU}}(m,\nu,n) \;=\; \kappa_{\text{CPU}}(m,\nu,n)
$$

Verified by CI on every commit.

### M2.2 — Multi-Arch Correctness

Fat binary verified across `sm_75`, `sm_80`, `sm_86`, `sm_89`, `sm_90`.
OpenCL fallback produces identical results on AMD and Intel targets:

$$
\kappa_{\text{CUDA}}(\cdot) \;=\; \kappa_{\text{OpenCL}}(\cdot) \quad \forall \text{ inputs}
$$

### M2.3 — Determinism Under Replay

Given identical $(ι, \epsilon[n], D[n])$ and identical search range, two
independent kernel runs on the same hardware return the same $\nu^*$:

$$
\nu^*_{\text{run 1}} = \nu^*_{\text{run 2}} \quad \text{(no non-determinism from scheduling)}
$$

### M2.4 — Reproducible Build

Docker-based build produces byte-identical binaries across two independent
build environments:

$$
\text{sha256}(\text{binary}_{\text{build 1}}) \;=\; \text{sha256}(\text{binary}_{\text{build 2}})
$$

---

## M3 — CLI Correctness

**Completion criterion:** The CLI correctly implements the full epoch lifecycle,
verified against a local Foundry fork of the deployed contract. The lifecycle
is the sequence:

$$
\gamma\text{-fetch} \;\to\; \epsilon\text{-fetch} \;\to\; \iota\text{-compute} \;\to\; \text{dispatch} \;\to\; \nu\text{-recv} \;\to\; \text{fee-attach} \;\to\; \text{submit} \;\to\; \text{epoch-transition}
$$

### M3.1 — $\gamma$ and Entropy Fetch Order

$\texttt{minerEpochCount}[m]$ and $\epsilon[n]$ are read in the correct
causal order before each job dispatch. Verification:

$$
\text{nonce computed with stale }\gamma \;\Rightarrow\; \texttt{mine}() \text{ reverts (Cascade verification failure)}
$$

### M3.2 — Epoch Transition Handling

When a `Mined` event from any miner advances the epoch while the kernel runs:

$$
\text{CLI sends STOP} \;\to\; \text{fetches new }\gamma,\epsilon[n+1] \;\to\; \text{recomputes }\iota \;\to\; \text{dispatches fresh job}
$$

within one RPC round-trip time. The stale job's nonces are cryptographically
invalid for the new epoch (different $\epsilon[n+1]$).

### M3.3 — Fee Guard

`MAX_FEE_USD` enforcement prevents submission when:

$$
\frac{\texttt{currentFeeWei}()}{10^{18}} \times p_\$ \;>\; \texttt{MAX\_FEE\_USD}
$$

Verified under mocked oracle returning extreme values ($p \to 0$ and $p \to \infty$).

### M3.4 — Integration Test

End-to-end test against `anvil` (local Foundry node) demonstrates:
- CLI mines epochs 0, 1, 2 sequentially
- $\gamma(m)$ advances as $0 \to 1 \to 2 \to 3$ (I13)
- NCT window records miner address three times: $C_u \in \{1\}$ throughout
- Supply: $\texttt{totalSupply} = 3 \times R_0 = 150\;\text{ANVL}$ after epoch 2

---

## M4 — Testnet Validation

**Completion criterion:** The deployed contract on Base Sepolia satisfies
the following quantitative properties over a public test period:

| Property | Formal Criterion | Pass Condition |
|----------|-----------------|----------------|
| PI controller convergence | $\left|\overline{T}_{\text{epoch}} - 120\;\text{s}\right|$ over 10 periods | $< 12\;\text{s}$ (10% error) |
| NCT signal accuracy | $\|C_u - \|\text{observed distinct signers}\|\|$ | $\leq 1$ at all times |
| Halving | $R(210{,}000)$ | $= 25\;\text{ANVL exactly}$ ($= R_0 \gg 1$) |
| Cascade anti-precompute | Submit $\nu$ computed before epoch $n$ opens | `mine()` reverts |
| $\gamma$-binding | Submit $\nu$ computed for address $m$ from address $m' \neq m$ | `mine()` reverts |
| Fee accounting | $\sum_{j=1}^{n}\texttt{fee}_j = \Delta\texttt{feeRecipient.balance} + \texttt{stuckFeesWei} + \texttt{lpReserveEthWei} + \texttt{LP ETH deployed}$ | Holds exactly |

---

## M5 — Mainnet Deployment

**Completion criterion:** Contract deployed to Base mainnet satisfying:

1. Deployment transaction verifiable on Basescan with identical bytecode
   to the audited source: $\text{sha256}(\text{deployed bytecode}) = \text{sha256}(\text{audited bytecode})$.

2. Deployer address has no privileges post-constructor:
   $\nexists\,f \in \texttt{Anvil256.sol}$ such that $f$ is callable only by
   deployer after the constructor returns.

3. $\texttt{feeRecipient} \neq \texttt{deployer}$ and $\neq \texttt{address}(0)$ (I3).

4. `v1.0.0` CLI binary cosign-signed and logged to Sigstore Rekor with
   matching `sha256sums.txt`.

5. No dev premine: constructor/initializer supply is limited to the official
   genesis LP seed, $S_{seed}=1\;\mathrm{ANVL}$, held by the Anvil256 contract
   and deposited into the official ANVL/WETH LP.

---

## Invariants That Are Never In Scope

The following predicates are on-chain invariants of the immutable contract.
No milestone will ever modify them, as no mechanism to do so exists:

$$
\nexists\;\texttt{admin\_key} \;:\; \exists\,f\;\text{gated by privileged address}
$$

$$
\nexists\;\texttt{upgrade\_proxy} \;:\; \texttt{Anvil256.sol}\;\text{uses delegatecall or proxy pattern}
$$

$$
\nexists\;\texttt{governance\_token} \;:\; \text{voting or parameter-setting mechanism exists}
$$

$$
\texttt{devPremine}(S_0)=0,\quad \texttt{genesisLPSeed}(S_0)=1\;\mathrm{ANVL}
$$

$$
\texttt{feeRecipient} \neq \texttt{deployer} \;:\; \text{enforced on-chain, constructor revert}
$$

$$
\nexists\;\text{admin mint};\; \texttt{mine}()\;\text{mints}\;R(n)\;\text{to miners and}\;0.1R(n)\;\text{to POL}
$$

$$
\nexists\;\text{token migration} \;:\; \text{no V2 contract or swap mechanism deployed}
$$

These are not governance decisions or social contracts. They are provable
properties of the deployed bytecode. No future milestone — and no actor —
can override them.
