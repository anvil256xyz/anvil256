---
title: Tokenomics
slug: tokenomics
---

# Anvil256 — Tokenomics

> **ANVL** is a fixed-supply proof-of-work token on Base L2 with explicit
> protocol-owned liquidity (POL) accounting. The hard cap is
> $21{,}000{,}000$ ANVL. The launch has **no dev premine**, **no presale**,
> **no VC tranche**, **no admin mint**, and **no withdraw function** for the
> official Uniswap v3 LP NFTs.
>
> It is not accurate to say that every emitted token goes to miners. The current
> contract mints a small genesis LP seed and then mints a 10% liquidity reserve
> alongside each miner reward. The honest identity is:
>
> $$
> \mathrm{dev\ premine}=0,\qquad
> \mathrm{genesis\ LP\ seed}=1\ \mathrm{ANVL},\qquad
> \mathrm{LP\ emission}=0.1R(n)
> $$

---

## 1. Contract Constants

| Symbol | Value | Meaning |
|--------|-------|---------|
| $S_{\max}$ | $21{,}000{,}000$ ANVL | hard cap enforced by `_update` |
| $R_0$ | $50$ ANVL | initial miner reward |
| $H$ | $210{,}000$ epochs | halving interval |
| $K$ | $64$ | maximum halving intervals |
| $F$ | $\$0.10$ | per-mine protocol fee |
| $q_{dev}$ | $50\%$ | dev split of $F$ |
| $q_{LP}$ | $50\%$ | ETH liquidity split of $F$ |
| $\lambda$ | $10\%$ | LP token reserve minted per miner reward |
| $S_{seed}$ | $1$ ANVL | genesis seed LP token amount |
| $E_{seed}$ | $0.001$ ETH | genesis seed LP ETH amount |
| $B$ | $50\%$ | main LP deployment trigger |

---

## 2. Reward and Minting Function

The miner reward at epoch $n$ is:

$$
R(n)=
\begin{cases}
R_0 \gg \lfloor n/H \rfloor, & \lfloor n/H \rfloor < K \\
0, & \lfloor n/H \rfloor \ge K
\end{cases}
$$

For a normal mine before the supply cap boundary:

$$
M_{miner}(n)=R(n)
$$

$$
M_{LP}(n)=\lambda R(n)=0.1R(n)
$$

$$
M_{total}(n)=R(n)+0.1R(n)=1.1R(n)
$$

At epoch 0:

$$
R(0)=50,\qquad M_{LP}(0)=5,\qquad M_{total}(0)=55\ \mathrm{ANVL}
$$

The cap is still absolute:

$$
totalSupply \le S_{\max}
$$

If a mine would exceed $S_{\max}$, the contract truncates the miner reward first
and then truncates the LP reserve mint if needed.

---

## 3. Supply Identity With LP Reserve

The idealized geometric identity for miner-only rewards is:

$$
\sum_{k=0}^{63} H R_0 2^{-k}
\;=\; 2 H R_0 \cdot (1 - 2^{-64}) \;\approx\; 21{,}000{,}000\ \mathrm{ANVL}
$$

**Integer truncation note.** The on-chain implementation uses integer
right-shift (`INITIAL_REWARD >> halvings`). Due to floor truncation at each
halving, the actual total mintable via the miner schedule is approximately
$20{,}999{,}991$ ANVL — ${\sim}9$ ANVL below `MAX_SUPPLY`. `MAX_SUPPLY` is a
hard ceiling; the ${\sim}9$ ANVL shortfall simply never gets minted. This is
intentional and has no economic significance.

But the deployed contract also mints a 10% LP reserve alongside each miner
reward. Therefore the practical cap is reached earlier than the pure
miner-only schedule. Ignoring final right-shift dust and cap truncation,
cumulative mint pressure is:

$$
S_{pressure}\approx S_{seed}+1.1\sum_{k=0}^{63}H R_0 2^{-k}
$$

$$
S_{pressure}\approx 1 + 1.1\times 21{,}000{,}000
=23{,}100{,}001\ \mathrm{ANVL}
$$

Because the actual cap is $21{,}000{,}000$, the schedule terminates by cap
before the theoretical miner-only terminus. This is intentional: the LP reserve
is inside the same hard cap, not inflation outside it.

Approximate full-cap mine count during the first reward band:

$$
N_{cap}^{(band0)}=\left\lceil\frac{21{,}000{,}000-1}{55}\right\rceil
=381{,}819\ \mathrm{mines}
$$

This is a deliberately invalid single-band counterfactual: it assumes $R(n)=50$
forever. Because $381{,}819>210{,}000$,
the first halving occurs before cap, so the exact termination requires summing
the piecewise halving schedule with the $1.1$ multiplier and cap truncation.

---

## 4. Fee Split Formula

Let $p$ be the Chainlink ETH/USD answer with 8 decimals:

$$
p=p_{USD}\times 10^8
$$

The required native ETH fee is:

$$
fee_{wei}=\frac{100{,}000\times 10^{20}}{p}
$$

At ETH $=\$2{,}500$:

$$
p=2500\times 10^8=2.5\times 10^{11}
$$

$$
fee_{wei}=\frac{10^{25}}{2.5\times 10^{11}}=4\times 10^{13}\ \mathrm{wei}
$$

The split is:

$$
devFee=\frac{1}{2}fee=\$0.05
$$

$$
lpFee=\frac{1}{2}fee=\$0.05
$$

`devFee` is transferred to the immutable `feeRecipient`. `lpFee` remains in the
contract as `lpReserveEthWei` until protocol liquidity is deployed or dripped.

---

## 5. Liquidity Bootstrap Mathematics

### 5.1 Genesis Seed

At deployment the constructor creates/reuses the ANVL/WETH Uniswap v3 pool and
mints a tiny full-range seed position:

$$
E_{seed}=0.001\ \mathrm{ETH},\qquad S_{seed}=1\ \mathrm{ANVL}
$$

The seed ratio is:

$$
P_{seed}=\frac{0.001}{1}=0.001\ \mathrm{ETH/ANVL}
$$

If ETH $=\$2{,}500$:

$$
P_{seed,USD}=0.001\times 2500=\$2.50/\mathrm{ANVL}
$$

This seed is deliberately small — 10× smaller than earlier design drafts.
It anchors an initial pool but should not be interpreted as a fair market price guarantee.

### 5.2 Main LP Trigger

Main protocol liquidity is not deposited every mine. It accumulates first:

$$
LP_{ETH}(N)=0.05N\ \mathrm{USD\ equivalent}
$$

$$
LP_{ANVL}(N)=\sum_{n=0}^{N-1}0.1R(n)
$$

Main deployment becomes permissionless when:

$$
totalSupply \ge 0.5S_{\max}=10{,}500{,}000\ \mathrm{ANVL}
$$

During the initial reward band, approximate trigger mine count is:

$$
N_{50\%}\approx \left\lceil\frac{10{,}500{,}000-1}{55}\right\rceil
=190{,}909\ \mathrm{mines}
$$

At that point, approximate accumulated reserves are:

$$
LP_{ETH}\approx 190{,}909\times \$0.05=\$9{,}545.45
$$

$$
LP_{ANVL}\approx 190{,}909\times 5=954{,}545\ \mathrm{ANVL}
$$

The implied reserve ratio is:

$$
P_{reserve}\approx \frac{9545.45}{954545}=\$0.01/\mathrm{ANVL}
$$

This is a reserve accounting ratio, not a market-price promise.

### 5.3 Post-Trigger Drip

After `deployLiquidityReserves()` succeeds, future mines continue to accrue:

$$
\Delta LP_{ETH}=\$0.05,\qquad \Delta LP_{ANVL}=0.1R(n)
$$

Anyone can call `dripLiquidityReserves()` to add the newly accumulated reserve
into the same official full-range LP position.

---

## 6. Official LP Lock Semantics

The official Uniswap v3 LP NFTs are minted to the Anvil256 contract itself:

$$
recipient=address(Anvil256)
$$

The token contract exposes no function for:

- `decreaseLiquidity`
- `collect`
- NFT transfer
- ETH withdrawal
- ANVL reserve withdrawal
- owner rescue

Therefore the official LP is locked in the token contract by absence of an exit
path. This is not the same as sending an NFT to a burn address, but it is a
stronger operational statement than a time lock controlled by an admin.

---

## 7. Miner Break-Even

Ignoring hardware electricity and L2 gas, the fee break-even price is:

$$
P_{BE}(n)=\frac{\$0.10}{R(n)}
$$

At epoch 0:

$$
P_{BE}(0)=\frac{0.10}{50}=\$0.002/\mathrm{ANVL}
$$

Including Base gas $g_{USD}$ and power cost per successful mine $e_{USD}$:

$$
P_{BE}(n)=\frac{0.10+g_{USD}+e_{USD}}{R(n)}
$$

No profitability is guaranteed. Mining is profitable only if market value of the
miner reward exceeds the protocol fee, gas, and hardware cost.

---

## 8. What Is Not Claimed

The protocol does **not** claim:

- that every ANVL goes directly to miners;
- that the seed LP price is fair market value;
- that mining is always profitable;
- that Chainlink cannot halt mining through stale data;
- that official LP fees can be collected;
- that the 50% trigger automatically executes without a caller.

The precise claim is narrower and stronger:

$$
admin=\varnothing,\quad devPremine=0,\quad totalSupply\le 21{,}000{,}000,
\quad officialLPWithdraw=\varnothing
$$
