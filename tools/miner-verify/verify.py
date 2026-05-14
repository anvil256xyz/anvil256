#!/usr/bin/env python3
"""
Standalone third-party verifier for any Anvil256 Cascade PoW tuple.

This is the reference implementation: no GPU, no CLI, just pycryptodome
doing exactly what the on-chain contract does. Use this to independently
confirm that a `Mined` event you saw on chain is internally consistent,
or to verify your CLI miner's output.

The Cascade hash is (Anvil256.sol::_cascadeHash):

    mid    = keccak256( abi.encode(bytes32 inner,   uint256 nonce  ) )
    result = keccak256( abi.encode(bytes32 mid,     bytes32 entropy) )

Valid iff uint256(result) < currentDifficulty.

To reconstruct `inner` and `entropy` yourself from on-chain state:

    inner   = anvil.getInner(miner)
    entropy = anvil.epochEntropy()

(Both are public view functions on the contract; see
contracts/src/interfaces/IAnvil256.sol.)

Usage:
    python verify.py \\
        --inner      0x95c3eff41215fcee37e84deb6a3be65a901a24156b99e01ba47a9736957f4af4 \\
        --entropy    0x11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff \\
        --nonce      12345678901234567890 \\
        --difficulty 0x0000000000000DA74D8E71E0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
"""
from __future__ import annotations
import argparse
import sys

try:
    from Crypto.Hash import keccak
except ImportError:
    print("Need: pip install pycryptodome", file=sys.stderr)
    sys.exit(1)


def parse_bytes32(s: str) -> bytes:
    s = s.removeprefix("0x")
    if len(s) != 64:
        raise SystemExit(f"expected 64-hex bytes32, got {len(s)} chars")
    return bytes.fromhex(s)


def parse_uint(s: str) -> int:
    return int(s, 16) if s.startswith("0x") else int(s)


def keccak256(data: bytes) -> bytes:
    h = keccak.new(digest_bits=256)
    h.update(data)
    return h.digest()


def cascade_hash(inner: bytes, entropy: bytes, nonce: int) -> bytes:
    """Anvil256.sol::_cascadeHash, byte-for-byte."""
    mid = keccak256(inner + nonce.to_bytes(32, "big"))
    return keccak256(mid + entropy)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--inner",      required=True, help="32-byte ι (hex)")
    ap.add_argument("--entropy",    required=True, help="32-byte ε[n] (hex)")
    ap.add_argument("--nonce",      required=True, help="uint256 nonce (dec or 0x-hex)")
    ap.add_argument("--difficulty", required=True, help="uint256 difficulty (dec or 0x-hex)")
    args = ap.parse_args()

    inner      = parse_bytes32(args.inner)
    entropy    = parse_bytes32(args.entropy)
    nonce      = parse_uint(args.nonce)
    difficulty = parse_uint(args.difficulty)

    h     = cascade_hash(inner, entropy, nonce)
    h_int = int.from_bytes(h, "big")

    print(f"inner       : 0x{inner.hex()}")
    print(f"entropy     : 0x{entropy.hex()}")
    print(f"nonce       : {nonce} (0x{nonce:064x})")
    print(f"cascade     : 0x{h.hex()}")
    print(f"difficulty  : 0x{difficulty:064x}")
    print()
    if h_int < difficulty:
        print("RESULT      : VALID (cascade < difficulty)")
        return 0
    else:
        print("RESULT      : INVALID (cascade >= difficulty)")
        return 1


if __name__ == "__main__":
    sys.exit(main())
