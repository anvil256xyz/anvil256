// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math}           from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMath} from "./FixedPointMath.sol";

/// @title  PIController — discrete-time PI controller for Anvil256 difficulty,
///         now with additive Nakamoto Coefficient Throttle (NCT) signal.
///
/// @notice Discrete-time update law (MATH.md §3–4):
///
///             e[n]    = (actual_window[n] − T) / T
///             I[n]    = clamp(I[n−1] + e[n], −I_MAX, +I_MAX)
///             u_pi    = clamp(−(Kp·e[n] + Ki·I[n]), −U_MAX, +U_MAX)
///             u       = clamp(u_pi + u_nct, −U_MAX, +U_MAX)
///             D[n+1]  = clamp(D[n]·exp(u), D[n]/4, D[n]·4)
///
///         MinerWindow.nctSignal() returns a non-positive raw value s_nct <= 0.
///         This library subtracts it, so the applied penalty is |s_nct| >= 0:
///
///             u = clamp(u_pi - s_nct, -U_MAX, +U_MAX)
///
///         Concentration can therefore raise or hold difficulty, never lower it.
///
///         Additive composition in u-space is multiplicative composition in
///         D-space (the correct law for a positive quantity). The two signals
///         are structurally independent: u_pi targets epoch timing, u_nct
///         penalises concentration. They compose exactly (MATH.md §3.4).
///
/// @dev    All functions are `pure`; the caller (Anvil256) owns state.
///
/// @dev    Supply note: PIController has no supply authority. Anvil256._rewardAt
///         uses integer right shifts for the miner reward, while Anvil256.mine()
///         separately mints the 10% POL reserve inside MAX_SUPPLY. This library
///         only maps timing/concentration observations to D[n+1].
library PIController {
    /* ─────────────────────────── fixed-point ─────────────────────────── */

    int256 internal constant WAD = 1e18;

    /* ─────────────────────────── gains ─────────────────────────── */

    /// @notice Kp = 0.5 (Q60.18).
    int256 internal constant KP = 5e17;

    /// @notice Ki = 0.05 (Q60.18). Slow integral; eliminates steady-state
    ///         error within ~10 periods.
    int256 internal constant KI = 5e16;

    /// @notice ±I_MAX = ±4.0 (Q60.18). Anti-windup saturation.
    int256 internal constant I_MAX = 4 * WAD;

    /// @notice ±U_MAX = ±0.5 (Q60.18). Guarantees exp(u) ∈ [0.606, 1.649]
    ///         before the outer 4×/¼ clamp. Also applied to the combined
    ///         (u_pi + u_nct) signal.
    int256 internal constant U_MAX = 5e17;

    /// @notice Outer difficulty clamp: 4× up, ¼ down. Bitcoin-style envelope.
    uint256 internal constant MAX_UP_FACTOR = 4;
    uint256 internal constant MAX_DOWN_DIV  = 4;

    /* ─────────────────────────── entry point ─────────────────────────── */

    /// @notice Compute the next (difficulty, integral, combinedSignal) given:
    ///         - current PI state
    ///         - the just-finished period's actual elapsed seconds
    ///         - the NCT signal for this period (from MinerWindow.nctSignal())
    ///
    /// @param oldD         current difficulty (uint256)
    /// @param actualWindow actual elapsed seconds in the just-finished period
    /// @param targetWindow target seconds per period (e.g. 241_920)
    /// @param oldI         previous integrator state, Q60.18 signed
    /// @param uNct         NCT signal from MinerWindow, Q60.18 signed (≤ 0)
    /// @return newD        clamped difficulty for the next period
    /// @return newI        updated integrator state
    /// @return u           applied combined signal, Q60.18 (for logs)
    function step(
        uint256 oldD,
        uint256 actualWindow,
        uint256 targetWindow,
        int256  oldI,
        int256  uNct
    ) internal pure returns (uint256 newD, int256 newI, int256 u) {
        if (targetWindow == 0) return (oldD, oldI, 0);
        if (actualWindow == 0) actualWindow = 1;  // guard divide-by-zero

        // Cached uint256 view of WAD to avoid repeated unsafe-typecast warnings.
        // WAD = 1e18 > 0, so int256 → uint256 is always safe here.
        uint256 WAD_U = uint256(WAD); // forge-lint: disable-line(unsafe-typecast)

        // ── timing error e = (actual - target) / target, Q60.18 ──
        // actualWindow and targetWindow are block.timestamp differences;
        // both fit comfortably in uint128, so int256 cast is always safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 e =
            // forge-lint: disable-next-line(unsafe-typecast)
            (int256(actualWindow) - int256(targetWindow)) * WAD /
            // forge-lint: disable-next-line(unsafe-typecast)
            int256(targetWindow);

        // ── integrator with anti-windup ──
        int256 i = oldI + e;
        if (i >  I_MAX) i =  I_MAX;
        if (i < -I_MAX) i = -I_MAX;

        // ── PI timing signal ──
        int256 uPi = -((KP * e) / WAD + (KI * i) / WAD);
        if (uPi >  U_MAX) uPi =  U_MAX;
        if (uPi < -U_MAX) uPi = -U_MAX;

        // ── combine with NCT signal (additive in log-D space) ──
        // u_nct ≤ 0 from MinerWindow: a negative NCT signal means mining is
        // centralised and we want to RAISE difficulty (push D up). Since
        // D[n+1] = D[n]*exp(u), a larger u means larger D. We therefore
        // SUBTRACT u_nct (which is ≤ 0) so that centralisation makes u more
        // positive, increasing D. Clamping u_nct > 0 to 0 ensures NCT never
        // decreases D (i.e. never rewards decentralisation with lower D).
        int256 uNctClamped = uNct;
        if (uNctClamped > 0)      uNctClamped = 0;   // NCT can only raise D
        if (uNctClamped < -U_MAX) uNctClamped = -U_MAX;

        // Subtract: uCombined = uPi - uNctClamped
        // uNctClamped ≤ 0, so -uNctClamped ≥ 0 → combined ≥ uPi (D increases or holds).
        int256 uCombined = uPi - uNctClamped;
        if (uCombined >  U_MAX) uCombined =  U_MAX;
        if (uCombined < -U_MAX) uCombined = -U_MAX;

        // ── multiplicative update: newD = D * exp(uCombined) ──
        // expWad returns int256 > 0 (clamped to 1 if truncation yields ≤ 0).
        // Casting to uint256 is safe because the value is positive.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 expFac = uint256(FixedPointMath.expWad(uCombined)); // Q60.18, > 0

        // For contractions (expFac <= WAD) the result is bounded above by
        // oldD so Math.mulDiv never overflows. For expansions (expFac > WAD)
        // it is possible that oldD * expFac / WAD exceeds type(uint256).max,
        // in which case Math.mulDiv would revert with panic 0x11. We saturate
        // to type(uint256).max here — the outer 4x clamp below will then
        // bring step1 down to the correct upper bound.
        uint256 step1;
        if (expFac <= WAD_U) {
            step1 = Math.mulDiv(oldD, expFac, WAD_U);
        } else {
            // The largest oldD for which (oldD * expFac) / WAD still fits in
            // uint256 is type(uint256).max * WAD / expFac, computed in 512-bit
            // precision by Math.mulDiv (safe because expFac >= WAD here).
            uint256 maxOldD = Math.mulDiv(type(uint256).max, WAD_U, expFac);
            step1 = oldD > maxOldD
                ? type(uint256).max
                : Math.mulDiv(oldD, expFac, WAD_U);
        }
        if (step1 == 0) step1 = 1;                                  // keep chain alive

        // ── outer multiplicative clamp (4× up, ¼ down) ──
        uint256 upperD = (oldD > type(uint256).max / MAX_UP_FACTOR)
            ? type(uint256).max
            : oldD * MAX_UP_FACTOR;
        uint256 lowerD = oldD / MAX_DOWN_DIV;
        if (lowerD == 0) lowerD = 1;
        if (step1 > upperD) step1 = upperD;
        if (step1 < lowerD) step1 = lowerD;

        newD = step1;
        newI = i;
        u    = uCombined;
    }
}
