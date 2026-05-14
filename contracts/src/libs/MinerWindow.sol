// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  MinerWindow — 256-slot circular buffer tracking distinct active miners.
///
/// @notice Implements the Nakamoto Coefficient Throttle (NCT) data structure
///         described in WHITEPAPER.md §3 and MATH.md §2.
///
///         The window holds the last 256 winning miner addresses. After each
///         mine() the oldest entry is evicted and the new miner is inserted.
///         `uniqueCount` (C_u) is maintained incrementally:
///
///             C = k / C_u, where k = filled slots <= 256
///             s_nct = -min(0.1 * (C - 1), 0.3)   (raw NCT signal)
///
///         The raw NCT signal is always <= 0. PIController subtracts it, making
///         the applied concentration penalty non-negative in log-difficulty space.
///
///         Invariants (MATH.md I11):
///             · C_u ∈ [1, 256] after first mine
///             · C_u = |{m : windowFreq[m] > 0}| exactly at all times
///             · windowFreq[m] ∈ [0, 256] for all m
///             · ∑_m windowFreq[m] == min(currentEpoch, 256)
///
/// @dev    All functions are `pure` or `view`-free (pure) on the storage struct.
///         The caller (Anvil256) owns storage and passes it by reference.
library MinerWindow {

    /* ─────────────────────────── types ─────────────────────────── */

    /// @notice Complete window state, stored in Anvil256.
    struct State {
        /// @dev 256 slots: win[i] = address of the miner who won slot i.
        ///      Slot index = epoch % 256.  Packed as two parallel arrays to
        ///      keep each slot in a single 32-byte word (address = 20 bytes).
        address[256] win;
        /// @dev Per-address frequency in the current window. Never > 256.
        ///      Uses uint16 to pack 2 per slot (saves ~half the SSTORE cost
        ///      versus uint256); safe since max freq = 256 < 2^16.
        mapping(address => uint16) freq;
        /// @dev Count of distinct addresses with freq > 0. C_u in the docs.
        uint16 uniqueCount;
        /// @dev Number of non-empty slots in `win`. Monotonically increases
        ///      from 0 to 256 over the first 256 recorded epochs, then stays
        ///      at 256 once the window has filled and is cycling. Used by
        ///      `nctSignal` so a partially-filled window does not produce
        ///      a spurious concentration penalty (matches invariant I11:
        ///      ∑_m freq[m] == min(currentEpoch, 256)).
        uint16 filledSlots;
    }

    /* ─────────────────────────── WAD ─────────────────────────── */

    int256 internal constant WAD = 1e18;

    /// @dev Minimum filled slots before NCT penalty activates.
    ///      During bootstrap a single miner dominates by necessity, not attack.
    ///      32 slots = 1/8 of the window; suppresses premature difficulty spikes.
    uint256 internal constant NCT_BOOTSTRAP_SLOTS = 32;

    /* ─────────────────────────── core update ─────────────────────────── */

    /// @notice Record a new winning miner at slot `epoch % 256`.
    ///
    /// @param s        window state (storage reference)
    /// @param epoch    the epoch that just completed (before increment)
    /// @param newMiner the address that won this epoch
    function record(State storage s, uint256 epoch, address newMiner) internal {
        // Guard: address(0) is used as the sentinel "empty slot" value.
        // A zero-address miner would corrupt uniqueCount and the eviction logic.
        require(newMiner != address(0), "MinerWindow: zero miner");

        uint256 slot = epoch & 0xFF;          // epoch % 256
        address evicted = s.win[slot];

        // ── evict old occupant ──
        if (evicted != address(0)) {
            uint16 f = s.freq[evicted];
            if (f > 0) {
                unchecked { s.freq[evicted] = f - 1; }
                if (f == 1) {
                    // last occurrence evicted → address leaves the window
                    unchecked { s.uniqueCount -= 1; }
                }
            }
        } else {
            // Slot was previously empty — the window grows by one filled slot.
            // Cap at 256: filledSlots must never exceed the physical array size.
            if (s.filledSlots < 256) {
                unchecked { s.filledSlots += 1; }
            }
        }

        // ── insert new occupant ──
        s.win[slot] = newMiner;
        uint16 nf = s.freq[newMiner];
        if (nf == 0) {
            // first occurrence → new unique address
            unchecked { s.uniqueCount += 1; }
        }
        // freq[miner] <= 256, well within uint16 range.
        unchecked { s.freq[newMiner] = nf + 1; }
    }

    /* ─────────────────────────── NCT signal ─────────────────────────── */

    /// @notice Compute the raw NCT difficulty signal from the current window.
    ///
    ///         s_nct = -min(0.1 * (C - 1), 0.3)   (Q60.18, always <= 0)
    ///
    ///         where C = filledSlots / C_u. In steady state filledSlots = 256;
    ///         during bootstrap, the denominator is still the observed unique
    ///         count but the penalty is suppressed until NCT_BOOTSTRAP_SLOTS.
    ///
    /// @param s        window state (storage reference, read-only here)
    /// @return signal  NCT signal in Q60.18 (negative or zero)
    function nctSignal(State storage s) internal view returns (int256 signal) {
        uint256 cu = s.uniqueCount;
        if (cu == 0) return 0;           // no mines yet → no penalty

        // K = number of filled slots in the window so far.
        uint256 k = s.filledSlots;
        if (k == 0) return 0;            // defensive — cu>0 implies k>0

        // Suppress NCT penalty during bootstrap window.
        // With fewer than NCT_BOOTSTRAP_SLOTS recorded epochs the window
        // does not have enough data to distinguish bootstrap from attack.
        // Return zero signal so difficulty is driven purely by PI timing.
        if (k < NCT_BOOTSTRAP_SLOTS) return 0;

        // C_wad = (K * WAD) / C_u    (Q60.18)
        // Concentration factor: C=1 is fully distributed, C=K means one miner.
        // Safety: k <= 256, WAD = 1e18 → k*WAD <= 2.56e20 < 2^68 — fits uint256.
        //         Casting to int256 is safe: 2.56e20 << type(int256).max ≈ 5.79e76.
        //         cu is uint16 (1..256), cast to int256 is always safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 cWad = int256(k * uint256(WAD)) / int256(uint256(cu));

        // s_nct = -min(0.1 * (C - 1), 0.3)   (Q60.18, always <= 0)
        int256 inner = (cWad - WAD) / 10;          // 0.1·(C-1)
        int256 cap   = 3 * WAD / 10;               // 0.3
        if (inner > cap) inner = cap;
        if (inner < 0)   inner = 0;                // C < 1 impossible but guard
        signal = -inner;
    }
}
