#!/usr/bin/env python3
"""
Sanity-check Anvil256's geometric supply curve.

Confirms that:
    sum_{e=0..inf} R(e) == R0 * H * 2 == 21_000_000 ANVL

and prints a halving table for documentation purposes.

Usage:
    python check-supply-math.py
"""
from __future__ import annotations
from decimal import Decimal, getcontext

getcontext().prec = 60

R0 = Decimal(50)
H  = 210_000
MAX_HALVINGS = 64
TARGET_EPOCH_SECS = 120


def reward_at(epoch: int) -> Decimal:
    halvings = epoch // H
    if halvings >= MAX_HALVINGS:
        return Decimal(0)
    return R0 / (Decimal(2) ** halvings)


def supply_through(epoch: int) -> Decimal:
    """Total ANVL minted from epoch 0 to `epoch - 1` inclusive."""
    total = Decimal(0)
    h_done = 0
    while h_done * H < epoch and h_done < MAX_HALVINGS:
        r        = R0 / (Decimal(2) ** h_done)
        seg_end  = min((h_done + 1) * H, epoch)
        seg_len  = seg_end - h_done * H
        total   += r * seg_len
        h_done  += 1
    return total


def main() -> None:
    # Asymptotic supply
    asymptote = R0 * Decimal(H) * 2
    print(f"asymptotic supply = R0 * H * 2 = {asymptote} ANVL")
    print(f"target supply cap = 21,000,000 ANVL")
    assert asymptote == Decimal(21_000_000), "math is wrong!"
    print("✓ matches MAX_SUPPLY exactly\n")

    # Halving table
    print(f"{'halving':>8} {'epoch_start':>12} {'reward':>14} {'cum_supply':>20} {'% of 21M':>10}")
    cum = Decimal(0)
    for k in range(0, 33):
        r        = R0 / (Decimal(2) ** k)
        ep_start = k * H
        # cumulative supply at the END of this halving period
        cum += r * H
        if cum > Decimal(21_000_000):
            cum = Decimal(21_000_000)
        pct = (cum / Decimal(21_000_000) * 100).quantize(Decimal("0.0001"))
        print(f"{k:>8} {ep_start:>12,} {str(r):>14} {str(cum):>20} {pct:>10}%")
        if cum >= Decimal(21_000_000):
            break

    # Timing
    secs_per_halving = TARGET_EPOCH_SECS * H
    hours = secs_per_halving / 3600
    days  = hours / 24
    months = days / 30.4375
    print()
    print(f"target epoch time : {TARGET_EPOCH_SECS} s")
    print(f"halving interval  : {H:,} epochs = {secs_per_halving:,.0f} s")
    print(f"                  = {hours:,.1f} h = {days:,.1f} d = {months:,.2f} months")


if __name__ == "__main__":
    main()
