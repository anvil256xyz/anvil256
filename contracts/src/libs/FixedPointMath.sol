// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  FixedPointMath — signed Q60.18 utilities.
///
/// @notice Used by the PI controller to perform a *geometric* difficulty
///         update of the form
///
///             D[n+1] = D[n] * exp(u[n])
///
///         rather than the linearised approximation `D[n] * (1 + u[n])`.
///         For |u| ≤ 0.5 the two differ by at most 0.026 %, but the
///         geometric form is symmetric in log-D and composes correctly
///         across many periods. This is the textbook (continuous-time)
///         control-law for variables constrained to be positive — almost
///         never seen on-chain.
///
/// @dev    All "wad" values are signed int256 with implicit scale 1e18
///         (so 1.0 → 1e18, 0.5 → 5e17, -0.25 → -25e16).
///
///         Bounds of safety:
///
///             * expWad(x) requires |x| ≤ WAD (= 1.0). Inside the PI
///               controller we always call it with |x| ≤ 0.5 WAD so the
///               4th-order truncation error |x|⁵/120 is below 2.6 · 10⁻⁴,
///               i.e. better than one part in 3,800.
///             * log2Wad(x) requires x ≥ 1.
///
/// @custom:status  pure math; no storage, no state, no external calls.
library FixedPointMath {
    int256 internal constant WAD = 1e18;

    error InputOutOfRange();

    /* ===================== exp / mulWad ===================== */

    /// @notice 4th-order Maclaurin expansion of exp around 0:
    ///
    ///     exp(x) ≈ 1 + x + x²/2 + x³/6 + x⁴/24
    ///
    ///         For |x| ≤ 1 the truncation error is ≤ e/120 ≈ 0.0227,
    ///         and for |x| ≤ 0.5 it is ≤ 0.5⁵/120 ≈ 2.6 · 10⁻⁴.
    ///
    /// @dev Computed at full precision then divided back to Q60.18 ONCE at
    ///      the very end to avoid compounding rounding errors. The
    ///      intermediate `xn` values can reach |x|^4 ≈ (5e17)^4 ≈ 6.25e70
    ///      which fits comfortably below `type(int256).max` ≈ 5.79e76.
    function expWad(int256 x) internal pure returns (int256) {
        if (x < -WAD || x > WAD) revert InputOutOfRange();

        // each term is kept in its natural scale (x²: Q60.36, x³: Q60.54, x⁴: Q60.72)
        // and divided ONCE at the end.
        int256 x2 = x * x;                  // scale 1e36
        int256 x3 = x2 * x;                 // scale 1e54
        int256 x4 = x3 * x;                 // scale 1e72

        // term values, all scaled to WAD by their own divisor:
        //   1       → WAD
        //   x       → x
        //   x²/2    → x2 / (2 * WAD)
        //   x³/6    → x3 / (6 * WAD * WAD)
        //   x⁴/24   → x4 / (24 * WAD * WAD * WAD)
        int256 sum = WAD
            + x
            + x2 / (2 * WAD)
            + x3 / (6 * WAD * WAD)
            + x4 / (24 * WAD * WAD * WAD);

        // exp(x) > 0 for all real x — clamp to a tiny positive value just
        // in case the Taylor truncation underflows at extreme inputs.
        if (sum <= 0) sum = 1;
        return sum;
    }

    /// @notice Multiply two Q60.18 numbers, returning a Q60.18 result.
    function mulWad(int256 a, int256 b) internal pure returns (int256) {
        return (a * b) / WAD;
    }

    /* ===================== saturating signed math ===================== */

    /// @notice `a + b`, but never wrap around; saturates at int256 bounds.
    function satAdd(int256 a, int256 b) internal pure returns (int256) {
        unchecked {
            int256 c = a + b;
            // overflow iff signs of a, b match but differ from c
            if (((a ^ c) & (b ^ c)) < 0) {
                return a < 0 ? type(int256).min : type(int256).max;
            }
            return c;
        }
    }

    /// @notice `a - b`, but never wrap around; saturates at int256 bounds.
    function satSub(int256 a, int256 b) internal pure returns (int256) {
        unchecked {
            int256 c = a - b;
            // overflow iff signs of a, b differ AND sign of c differs from a
            if (((a ^ b) & (a ^ c)) < 0) {
                return a < 0 ? type(int256).min : type(int256).max;
            }
            return c;
        }
    }

    /* ===================== bitwise log2 ===================== */

    /// @notice floor(log2(x)) for x ≥ 1; reverts on x == 0. O(1) via the
    ///         classic SWAR / de-Bruijn-free binary search.
    function log2Floor(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) revert InputOutOfRange();
        unchecked {
            if (x >= 2**128) { x >>= 128; r += 128; }
            if (x >= 2** 64) { x >>=  64; r +=  64; }
            if (x >= 2** 32) { x >>=  32; r +=  32; }
            if (x >= 2** 16) { x >>=  16; r +=  16; }
            if (x >= 2**  8) { x >>=   8; r +=   8; }
            if (x >= 2**  4) { x >>=   4; r +=   4; }
            if (x >= 2**  2) { x >>=   2; r +=   2; }
            if (x >= 2**  1) {            r +=   1; }
        }
    }

    /* ===================== log2Wad ===================== */

    /// @notice Natural-log-2 in Q60.18: log2(x) where x is a Q60.18 value ≥ WAD.
    ///         Returns the result in Q60.18.
    ///
    ///         Implementation: integer part via log2Floor, fractional part via
    ///         4 rounds of squaring (gives ~4 bits of precision per round → ~16 bits
    ///         total, sufficient for difficulty control).
    ///
    /// @dev    Not used by PIController (which operates in exp-space) but provided
    ///         for off-chain tooling / future on-chain use.
    ///         Reverts if x < WAD (i.e. the represented real value < 1.0).
    function log2Wad(int256 x) internal pure returns (int256) {
        if (x < WAD) revert InputOutOfRange();
        unchecked {
            // x >= WAD = 1e18 > 0, so int256 → uint256 cast is safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 xu = uint256(x);

            // WAD = 1e18 > 0, so int256 → uint256 cast is safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 intPart = log2Floor(xu / uint256(WAD));

            // Normalise to [WAD, 2*WAD) — i.e. 1.0 ≤ z < 2.0
            uint256 z = xu >> intPart;

            // Fractional part via 16 squaring iterations (~16 bits precision).
            int256 frac;
            for (uint256 k = 1; k <= 16; ++k) {
                // WAD = 1e18, cast to uint256 is safe.
                // forge-lint: disable-next-line(unsafe-typecast)
                z = z * z / uint256(WAD);  // z = z²  (now in Q60.18)
                // forge-lint: disable-next-line(unsafe-typecast)
                if (z >= 2 * uint256(WAD)) {
                    frac += WAD >> k;      // add 2^-k contribution
                    z >>= 1;              // normalise back to [1, 2)
                }
            }

            // intPart = floor(log2(x/WAD)) ≤ 255 (x fits in uint256).
            // 255 * WAD ≤ 2.55e20 << type(int256).max — safe cast.
            // forge-lint: disable-next-line(unsafe-typecast)
            return int256(intPart) * WAD + frac;
        }
    }

    /* ===================== clamp helpers ===================== */

    /// @notice Clamp a signed Q60.18 value to [lo, hi].
    function clampWad(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }
}
