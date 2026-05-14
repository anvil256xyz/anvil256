# kernel/

This directory holds the **GPU compute kernels** for Anvil256.

| File                       | Purpose                                          |
|----------------------------|--------------------------------------------------|
| `miner.cu`                 | CUDA path (NVIDIA) — primary build target        |
| `miner_cpu.cpp`            | Portable CPU fallback                            |
| `include/protocol.h`       | Stable JSON protocol (kernel ↔ Rust orchestrator) |
| `Makefile`                 | nvcc + g++ build rules                            |
| `tests/verify.py`          | Cross-check kernel output against pycryptodome   |

## Quick build

```bash
# NVIDIA (default arch sm_89 = RTX 4060 Ti / 4080 / 4090)
make cuda

# Multi-arch fat binary (Turing / Ampere / Ada / Hopper / Blackwell)
make cuda ARCHS="75 80 86 89 90 100 120"

# RTX 5060 / 5070 / 5080 / 5090, CUDA 12.8+ recommended
make cuda ARCHS="120"

# CPU fallback
make cpu
```

## Standalone test (no Rust orchestrator)

The `JOB` line carries three 32-byte hex values — inner (ι), epoch
entropy (ε), and difficulty — followed by a job id. This matches the
on-chain Cascade verifier in `Anvil256.sol::_cascadeHash`.

```bash
./miner <<< $'JOB 95c3eff41215fcee37e84deb6a3be65a901a24156b99e01ba47a9736957f4af4 11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff 000000000000000DA74D8E71E0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF 1\nEXIT\n'
```

Or one-shot (no stdin loop):

```bash
./miner --once \
    0x95c3eff41215fcee37e84deb6a3be65a901a24156b99e01ba47a9736957f4af4 \
    0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff \
    0x000000000000000DA74D8E71E0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
```

Expected output: one `{"type":"ready",...}` then one `{"type":"found",...}` then exit.

## Tuning

See [`website/src/content/docs/mining-guide.md`](../website/src/content/docs/mining-guide.md)
and the `MINER_*` env vars in [`cli/.env.example`](../cli/.env.example).

Multi-GPU is enabled by default across all visible CUDA devices. Restrict it
with `MINER_DEVICES=0,1`. Each selected GPU gets an isolated `2^56` nonce
window for the current job, preventing cross-device duplicate nonce scans in
normal operation.

The default values are tuned for an RTX 4060 Ti at 2.0 GH/s:
- `MINER_BLOCK=128`
- `MINER_NPT=128` (auto-adjusts)
- `MINER_TARGET_BATCH_MS=250`
- Grid auto-sized to `SM_count * 64 = 34 * 64 = 2176` blocks.

## Verifying kernel correctness

```bash
pip install pycryptodome
python tests/verify.py
```

This script runs the miner against random (inner, entropy, difficulty)
triples, captures each `found` event, and recomputes the two-pass Cascade
hash in Python using `Crypto.Hash.keccak`:

    mid    = keccak256( abi.encode(inner, nonce) )
    result = keccak256( abi.encode(mid,   entropy) )

Any mismatch is a kernel correctness bug.
