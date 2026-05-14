---
title: Deployment
slug: deployment
---
# Anvil256 — Deployment

> Mainnet deployment values are immutable contract parameters or addresses
> emitted by the CREATE2 deployment script. The contract has no admin upgrade,
> no admin mint, and no post-deployment mechanism to change these fields.

---

## Mainnet (Base)

| Field | Value |
|-------|-------|
| Network | Base mainnet (`8453`) |
| Contract address | [`0x8C3199578834914AC08Eb628475D4Cfd26e011c2`](https://basescan.org/address/0x8C3199578834914AC08Eb628475D4Cfd26e011c2) |
| Factory address | [`0x41B50910F7d3AA5FddB769ae25B1abee0aaE476b`](https://basescan.org/address/0x41B50910F7d3AA5FddB769ae25B1abee0aaE476b) |
| Official ANVL/WETH pool | [`0x6fB1ED50F803e830C0F2Ca56d16e4F1F7E21eAFC`](https://basescan.org/address/0x6fB1ED50F803e830C0F2Ca56d16e4F1F7E21eAFC) |
| Deployment block | See Basescan deployment transaction |
| Deployment tx | See Basescan contract creation transaction |
| Deployer | See Basescan contract creation transaction |
| Basescan verified source | [`Anvil256`](https://basescan.org/address/0x8C3199578834914AC08Eb628475D4Cfd26e011c2#code) |
| Initial difficulty | `611068181523490305623205538956088469597103209577106379562116356380562` |
| Genesis epoch | 0 |
| Genesis LP seed | 1 ANVL + 0.001 ETH, official full-range LP |
| Genesis timestamp | `1778790599` |
| Initial reward | 50 ANVL |
| LP token reserve | 10% of each miner reward, inside `MAX_SUPPLY` |
| Halving interval | 210,000 epochs |
| Target epoch time | 120 s (controller setpoint) |
| Difficulty period | 2,016 epochs |
| `feeRecipient` | [`0xF5BC63C3aaed17c617Cfd6403753210C2cebfD68`](https://basescan.org/address/0xF5BC63C3aaed17c617Cfd6403753210C2cebfD68) |
| ETH/USD feed | [`0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70`](https://basescan.org/address/0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70) |
| Uniswap v3 factory | [`0x33128a8fC17869897dcE68Ed026d694621f6FDfD`](https://basescan.org/address/0x33128a8fC17869897dcE68Ed026d694621f6FDfD) |
| Position manager | [`0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1`](https://basescan.org/address/0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1) |
| WETH | [`0x4200000000000000000000000000000000000006`](https://basescan.org/address/0x4200000000000000000000000000000000000006) |
| Initial sqrt price X96 | `2505414487287301086054410895` |
| `genesisBlockhash` | Read from `genesisBlockHash()`; bound into all Cascade puzzles at construction |

**Deployment verification checklist:**
- `totalSupply() == 1e18` after pool initialization, from the genesis LP seed
- `feeRecipient != deployer`
- `currentEpoch == 0`
- `currentReward() == 50e18`
- `liquidityPool() != address(0)` and `seedPositionId() != 0`
- Contract source is verified on Basescan
- Website live stats reads `0x8C3199578834914AC08Eb628475D4Cfd26e011c2` on Base mainnet

---

## Testnet (Base Sepolia)

| Field | Value |
|-------|-------|
| Contract address | TBD |
| Faucet | https://www.alchemy.com/faucets/base-sepolia |

---

## Binary Release Index

| Version | sha256 (linux-x86_64) | Notes |
|---------|----------------------|-------|
| v0.1.0 | TBD | First mainnet-eligible release; γ binding included |
