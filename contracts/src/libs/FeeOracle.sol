// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title  FeeOracle — converts a USD-denominated fee to wei using a
///         Chainlink-compatible ETH/USD price feed.
///
/// @notice Math: let p be the oracle answer (integer with `d` decimals) and
///         f the desired fee in micro-USD (1e-6 USD units). Then
///
///             fee_wei = f * 1e18 * 10^d / (p * 1e6)
///                     = (f * 10^(12 + d)) / p
///
///         For Chainlink ETH/USD on Base (8 decimals, e.g. p = 250_000_000_000
///         for $2,500) and f = 100_000 µUSD ($0.10):
///
///             fee_wei = 100_000 * 1e20 / 250_000_000_000
///                     = 1e25 / 2.5e11
///                     = 4e13 wei
///                     = 0.00004 ETH
///                     = $0.10 at ETH = $2,500 ✓
///
/// @dev    The oracle answer is sanity-checked for positivity and recency
///         (must be at most `maxStaleness` seconds old). Reverts otherwise —
///         miners then simply retry later when the feed updates.
library FeeOracle {
    error StaleOracle(uint256 updatedAt, uint256 maxStaleness);
    error InvalidOracle(int256 answer);

    /// @notice The oracle reported a timestamp ahead of the current block.
    ///         Indicates either oracle misconfiguration or an L2 reorg /
    ///         clock-skew condition; treated identically to a stale feed.
    error OracleClockSkew(uint256 updatedAt, uint256 blockTimestamp);

    /// @notice Reverts if the feed's `decimals()` is implausibly large
    ///         (would overflow `10 ** (12 + dec)`). Every real Chainlink
    ///         feed satisfies `dec ≤ 18`; we conservatively cap at 24.
    error OracleDecimalsTooLarge(uint8 decimals);

    /// @notice Conservative cap on Chainlink aggregator decimals.
    ///         Rationale: `microUsd * 10**(12 + dec)` must fit in uint256.
    ///         uint256 max ≈ 1.16e77.  microUsd ≤ 1e12 (reasonable ceiling).
    ///         Overflow threshold: 1e12 * 10**(12+dec) > 1.16e77
    ///             → dec > 53.  We cap at 24 as a conservative sanity guard
    ///         (every real Chainlink feed uses ≤ 18 decimals).  This is NOT
    ///         the theoretical overflow boundary (~53); it is an early-reject
    ///         for clearly-misconfigured feeds.
    uint8 internal constant MAX_ORACLE_DECIMALS = 24;

    /// @notice Convert µUSD to wei using the given oracle.
    /// @param feed          Chainlink ETH/USD aggregator (8 decimals on Base mainnet)
    /// @param microUsd      desired fee in 1e-6 USD units (e.g. 100_000 = $0.10)
    /// @param maxStaleness  reject answers older than this many seconds
    function microUsdToWei(
        AggregatorV3Interface feed,
        uint256 microUsd,
        uint256 maxStaleness
    ) internal view returns (uint256 wei_) {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound)
            = feed.latestRoundData();

        if (answer <= 0) revert InvalidOracle(answer);

        // Standard Chainlink stale-round guard: if answeredInRound < roundId
        // the aggregator returned a cached answer from a previous round,
        // meaning the feed has not yet propagated a fresh answer for this round.
        if (answeredInRound < roundId) revert StaleOracle(updatedAt, maxStaleness);

        // Defensive: an oracle answer dated in the future indicates either a
        // misconfigured aggregator or a chain reorg / clock-skew condition.
        if (updatedAt > block.timestamp) {
            revert OracleClockSkew(updatedAt, block.timestamp);
        }
        uint256 ageSeconds = block.timestamp - updatedAt;
        if (ageSeconds > maxStaleness) {
            revert StaleOracle(updatedAt, maxStaleness);
        }

        uint8 dec = feed.decimals();
        if (dec > MAX_ORACLE_DECIMALS) revert OracleDecimalsTooLarge(dec);

        // Safe: answer > 0 is asserted above (InvalidOracle check), so the
        // int256 → uint256 cast cannot represent a negative value here.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 p = uint256(answer);

        // fee_wei = (f * 10^(12 + dec)) / p
        uint256 num = microUsd * (10 ** (12 + uint256(dec)));
        wei_ = num / p;
    }
}
