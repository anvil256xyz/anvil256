#!/usr/bin/env python3
"""
Compute an initial difficulty target for Anvil256 deployment.

Given an assumed global hashrate G (hashes/sec) and target epoch time T (s),
we want the expected number of hashes per epoch to equal G*T. Therefore:

    initialDifficulty = floor(2^256 / (G * T))

The contract accepts any valid uint256, but we recommend deploying with the
output of this script using your own honest estimate of G at launch.
"""
from __future__ import annotations
import argparse


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hashrate-ghs", type=float, default=100.0,
                    help="Assumed global hashrate at launch in GH/s (default: 100)")
    ap.add_argument("--epoch-secs", type=int, default=120,
                    help="Target seconds per epoch (default: 120)")
    args = ap.parse_args()

    G = args.hashrate_ghs * 1e9
    T = args.epoch_secs
    target = (1 << 256) // int(G * T)

    print(f"assumed global hashrate : {args.hashrate_ghs} GH/s")
    print(f"target epoch time       : {T} s")
    print(f"expected hashes / epoch : {G * T:.3e}")
    print()
    print(f"initial difficulty (dec): {target}")
    print(f"initial difficulty (hex): 0x{target:064x}")
    print()
    print("Pass to the deployer as DEPLOY_INITIAL_DIFFICULTY environment var:")
    print(f"  DEPLOY_INITIAL_DIFFICULTY={target} forge script ...")


if __name__ == "__main__":
    main()
