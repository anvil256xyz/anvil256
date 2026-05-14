# Anvil256 — Repository Structure

Authoritative tree of the monorepo. Every file has a one-line purpose and
points to its owning sub-component.

```
anvil256/
├── README.md                          project overview + quick start
├── LICENSE                            MIT
├── STRUCTURE.md                       this file
├── .gitignore
│
├── .github/
│   ├── slither.config.json            Slither tuning (gas, false-positive filters)
│   └── workflows/
│       ├── ci-contracts.yml           forge build + test + slither
│       ├── ci-rust.yml                cargo test + fmt + clippy on cli/
│       ├── ci-website.yml             pnpm build + website checks
│       └── release.yml                future signed binary release pipeline
│
├── contracts/                         Foundry project
│   ├── foundry.toml                   (added during forge init)
│   ├── remappings.txt                 (added during forge init)
│   ├── src/
│   │   ├── Anvil256.sol               main ERC-20 + PoW + fees + POL accounting
│   │   ├── interfaces/
│   │   │   ├── IAnvil256.sol          events, errors, view selectors
│   │   │   └── AggregatorV3Interface.sol Chainlink interface (inlined)
│   │   └── libs/
│   │       ├── Anvil256Factory.sol    deterministic deployment helper
│   │       ├── LiquidityBootstrap.sol Uniswap v3 seed, deploy, and drip logic
│   │       ├── MinerWindow.sol        recent-miner ring buffer for NCT
│   │       ├── PIController.sol       discrete-time PI feedback controller
│   │       ├── FeeOracle.sol          µUSD -> wei conversion
│   │       └── FixedPointMath.sol     Q60.18 helpers: expWad, log2Floor, satAdd/Sub
│   ├── test/
│   │   ├── Anvil256.t.sol             end-to-end + fuzz + invariant suite
│   │   └── PIController.t.sol         controller unit tests
│   └── script/
│       └── Deploy.s.sol               Foundry deployment script
│
├── cli/                               Rust orchestrator
│   ├── Cargo.toml
│   ├── .env.example                   operator-facing configuration template
│   └── src/
│       ├── main.rs                    signal handling + round loop
│       ├── config.rs                  .env + CLI flag layering
│       ├── chain.rs                   abigen! typed bindings + snapshot()
│       ├── tx.rs                      mine-tx construction + gas cap + fee attachment
│       ├── miner_proc.rs              subprocess supervisor (JSON protocol)
│       ├── telemetry.rs               tracing setup
│       ├── error.rs                   retryable / fatal taxonomy
│       └── abi/anvil256.json          contract ABI consumed by the CLI
│
├── kernel/                            Native nonce-search subprocess
│   ├── README.md
│   ├── Makefile                       builds bin/miner (CUDA primary, OpenCL fallback)
│   ├── miner.cu                       CUDA kernel
│   ├── miner_cpu.cpp                  portable CPU fallback miner
│   ├── include/
│   │   └── protocol.h                 JSON protocol shared between CLI and kernel
│   └── tests/
│       └── verify.py                  pycryptodome reference for correctness
│
├── website/                           Astro Starlight + Tailwind + viem
│   ├── package.json
│   ├── tsconfig.json
│   ├── astro.config.mjs
│   ├── tailwind.config.mjs
│   ├── public/logo.png                static logo + favicon source
│   └── src/
│       ├── styles/global.css
│       ├── lib/viem-client.ts         client-side RPC reader (read-only)
│       ├── pages/                     homepage, live stats, source-build page
│       └── content/docs/              tokenomics, math, security, ops docs
│
├── website/src/content/docs/          canonical public documentation
│   ├── tokenomics.md                  supply curve, halving, fee, POL reserve
│   ├── architecture.md                contract, CLI, kernel, website design
│   ├── whitepaper.md                  formal protocol description
│   ├── security.md                    threat model + invariants
│   ├── math.md                        PI controller + Q60.18 + oracle math
│   ├── mining-guide.md                operator handbook
│   ├── build.md                       source-build instructions
│   ├── deployment.md                  deployment checklist + addresses
│   └── roadmap.md                     phased delivery plan
│
├── scripts/
│   ├── check-supply-math.py           verifies the 21 M geometric sum
│   ├── compute-difficulty.py          initial D for a given target hashrate
│   ├── simulate-difficulty.py         PI controller step-response simulator
│   └── reproducible-build.sh          docker-pinned build entrypoint
│
└── tools/
    └── miner-verify/
        └── verify.py                  standalone Keccak-256 reference
```

## File-count summary

| Module    | Source files | Purpose                                |
|-----------|--------------|-----------------------------------------|
| contracts | 9+          | Solidity contract + libraries + tests   |
| cli       | 8+          | Rust orchestrator + config + ABI        |
| kernel    | 5+          | CUDA/CPU miners + protocol + verifier   |
| website   | 8+          | Astro Starlight site + canonical docs   |
| docs      | 9           | Served from `website/src/content/docs`  |
| scripts   | 4           | Verification, simulation, build         |
| tools     | 1           | Reference verifier                      |
| .github   | 5           | CI + release pipeline                   |
| **Total** | **tracked in tree** |                                |

## Canonical configuration sources

* On-chain constants live in `contracts/src/Anvil256.sol` as
  `constant` / `immutable` fields. Change them in one place, run
  `python scripts/check-supply-math.py`, and the supply math
  re-derives itself.
* Controller gains live in `contracts/src/libs/PIController.sol`.
* Oracle parameters (`microUsd = 100_000`, `maxStaleness = 24 h`)
  live in `contracts/src/Anvil256.sol`'s `currentFeeWei()` view.
* Operator-facing knobs live in `cli/.env.example` (gas cap, RPC,
  device list, etc.).
