#!/usr/bin/env python3
"""
simulate-difficulty.py — discrete-time PI controller step-response simulator
for Anvil256 difficulty adjustment.

Reproduces the on-chain math in `contracts/src/libs/PIController.sol` byte
for byte (modulo floating-point rounding) and prints the response of the
controller to several stress scenarios:

  1. Steady state (no perturbation)
  2. 2x faster network than target (sustained)
  3. 2x slower network than target (sustained)
  4. 4x flash spike then steady state
  5. Random walk on hashrate

Usage:
    python simulate-difficulty.py
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass


# ----- constants mirroring PIController.sol -----
WAD            = 10**18
KP             = 5 * 10**17       # 0.5
KI             = 5 * 10**16       # 0.05
I_MAX          = 4 * WAD          # 4.0
U_MAX          = 5 * 10**17       # 0.5
MAX_UP_FACTOR  = 4
MAX_DOWN_DIV   = 4

TARGET_WINDOW  = 2016 * 120       # 241_920 s
INITIAL_D      = 10**30           # arbitrary middle of range


def exp_wad(x: int) -> int:
    """4th-order Maclaurin Taylor expansion of exp, Q60.18 in/out.

    Mirrors FixedPointMath.expWad. For |x| <= 1.0 the truncation error is
    bounded by e/120 ~ 0.0227; for |x| <= 0.5 (the saturation bound) it is
    < 2.6e-4.
    """
    if x < -WAD or x > WAD:
        raise ValueError("expWad: input out of range")
    x2 = x * x
    x3 = x2 * x
    x4 = x3 * x
    s = (
        WAD
        + x
        + x2 // (2 * WAD)
        + x3 // (6 * WAD * WAD)
        + x4 // (24 * WAD * WAD * WAD)
    )
    return max(s, 1)


def pi_step(oldD: int, actual_window: int, target_window: int, oldI: int):
    """One call to PIController.step (Solidity)."""
    if target_window == 0:
        return oldD, oldI, 0
    if actual_window == 0:
        actual_window = 1

    # error
    e = (actual_window - target_window) * WAD // target_window

    # integrator with anti-windup
    i = oldI + e
    if i > I_MAX:
        i = I_MAX
    if i < -I_MAX:
        i = -I_MAX

    # control
    u_raw = -((KP * e) // WAD + (KI * i) // WAD)
    if u_raw > U_MAX:
        u_raw = U_MAX
    if u_raw < -U_MAX:
        u_raw = -U_MAX

    # multiplicative update
    exp_fac = exp_wad(u_raw)
    step1   = (oldD * exp_fac) // WAD
    if step1 < 1:
        step1 = 1

    # outer clamp
    upperD = oldD * MAX_UP_FACTOR
    lowerD = oldD // MAX_DOWN_DIV
    if step1 > upperD: step1 = upperD
    if step1 < lowerD: step1 = lowerD

    return step1, i, u_raw


# -------- scenarios --------
@dataclass
class Scenario:
    name:                    str
    description:             str
    actual_window_fn:        callable           # (period_idx, current_D, initial_D) -> seconds
    n_periods:               int = 24


def scenario_steady() -> Scenario:
    return Scenario(
        name="steady",
        description="Network exactly at target hashrate",
        actual_window_fn=lambda k, d, d0: TARGET_WINDOW,
    )


def scenario_2x_fast() -> Scenario:
    """Hashrate is sustained at 2x the initial network level. Time to find a
    nonce is proportional to (D / H), so actual window = T * (d/d0) / 2.
    Steady state: d = 2 * d0 (period exactly = T again).
    """
    def f(k, d, d0):
        return max(1, (TARGET_WINDOW * d) // (2 * d0))
    return Scenario(
        name="2x_fast",
        description="Sustained 2x hashrate (network too fast)",
        actual_window_fn=f,
    )


def scenario_2x_slow() -> Scenario:
    """Hashrate is sustained at half the initial level. Steady state:
    d = d0 / 2 (period exactly = T again).
    """
    def f(k, d, d0):
        return max(1, (TARGET_WINDOW * d * 2) // d0)
    return Scenario(
        name="2x_slow",
        description="Sustained 0.5x hashrate (network too slow)",
        actual_window_fn=f,
    )


def scenario_flash_4x() -> Scenario:
    """4x flash hashrate spike at period 5, otherwise hashrate is at the
    nominal level (so actual = T * (d/d0))."""
    def f(k, d, d0):
        if k == 5:
            return max(1, (TARGET_WINDOW * d) // (4 * d0))
        return max(1, (TARGET_WINDOW * d) // d0)
    return Scenario(
        name="flash_4x",
        description="One-period 4x hashrate spike, otherwise nominal",
        actual_window_fn=f,
    )


def scenario_random_walk(seed: int = 0xA1) -> Scenario:
    """Hashrate executes a multiplicative random walk (sigma ~ 0.1 / period).
    actual = T * (d/d0) / h.
    """
    rng = random.Random(seed)
    hashrate_mul = [1.0]
    for _ in range(50):
        hashrate_mul.append(hashrate_mul[-1] * rng.uniform(0.9, 1.1))

    def f(k, d, d0):
        h = hashrate_mul[min(k, len(hashrate_mul) - 1)]
        return max(1, int((TARGET_WINDOW * (d / d0)) / h))

    return Scenario(
        name="random_walk",
        description="Multiplicative random walk on hashrate (sigma ~ 0.1)",
        actual_window_fn=f,
        n_periods=30,
    )


# -------- runner --------
def run_scenario(s: Scenario, d0: int = INITIAL_D) -> None:
    print(f"\n{'='*78}\nscenario: {s.name}   ({s.description})\n{'='*78}")
    print(f"  {'period':>6} {'actual_s':>9} {'err':>8} {'integ':>8} "
          f"{'u':>8} {'D':>16} {'D/D0':>8}")

    d = d0
    i = 0
    saturated = False
    converged_at = None

    for k in range(s.n_periods):
        actual = s.actual_window_fn(k, d, d0)
        new_d, new_i, u = pi_step(d, actual, TARGET_WINDOW, i)

        err_pct  = (actual - TARGET_WINDOW) / TARGET_WINDOW
        d_ratio  = new_d / d0
        i_real   = new_i / WAD
        u_real   = u / WAD

        if abs(new_i) >= I_MAX:
            saturated = True
        if converged_at is None and abs(err_pct) < 0.05:
            converged_at = k

        print(f"  {k:>6} {actual:>9} {err_pct:>+8.3%} {i_real:>+8.4f} "
              f"{u_real:>+8.4f} {new_d:>16d} {d_ratio:>8.4f}")
        d, i = new_d, new_i

    print(f"\n  converged_within_5pct: {converged_at if converged_at is not None else 'never'}")
    print(f"  integrator_saturated : {saturated}")
    print(f"  final_D / initial_D  : {d / d0:.4f}")


def main() -> None:
    print("Anvil256 difficulty controller simulator")
    print(f"  WAD            = {WAD}")
    print(f"  Kp, Ki         = {KP / WAD:.2f}, {KI / WAD:.2f}")
    print(f"  I_MAX, U_MAX   = {I_MAX / WAD:.1f}, {U_MAX / WAD:.1f}")
    print(f"  outer clamp    = +/-{MAX_UP_FACTOR}x")
    print(f"  target window  = {TARGET_WINDOW} s ({TARGET_WINDOW/3600:.1f} h)")

    run_scenario(scenario_steady())
    run_scenario(scenario_2x_fast())
    run_scenario(scenario_2x_slow())
    run_scenario(scenario_flash_4x())
    run_scenario(scenario_random_walk())


if __name__ == "__main__":
    main()
