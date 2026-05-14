---
title: Deployment
slug: deployment
---
# Anvil256 — Deployment

> This document is populated only after mainnet deployment. All values
> marked TBD are filled at deployment time and never modified thereafter.
> The contract is immutable; there is no mechanism to update these fields
> post-deployment.

---

## Mainnet (Base)

| Field | Value |
|-------|-------|
| Contract address | TBD |
| Deployment block | TBD |
| Deployment tx | TBD |
| Deployer | TBD |
| Basescan verified source | TBD |
| Initial difficulty | TBD |
| Genesis epoch | 0 |
| Genesis LP seed | 1 ANVL + 0.001 ETH, official full-range LP |
| Initial reward | 50 ANVL |
| LP token reserve | 10% of each miner reward, inside `MAX_SUPPLY` |
| Halving interval | 210,000 epochs |
| Target epoch time | 120 s (controller setpoint) |
| Difficulty period | 2,016 epochs |
| `feeRecipient` | TBD (≠ deployer, ≠ address(0)) |
| `genesisBlockhash` | TBD (bound into all Cascade puzzles at construction) |

**Deployment verification checklist:**
- `totalSupply() == 1e18` after pool initialization, from the genesis LP seed
- `feeRecipient != deployer`
- `currentEpoch == 0`
- `currentReward() == 50e18`
- `liquidityPool() != address(0)` and `seedPositionId() != 0`
- Contract source matches audited commit hash
- Bytecode hash matches cosign-signed release

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
