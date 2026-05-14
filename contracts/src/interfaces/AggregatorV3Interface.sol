// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Chainlink AggregatorV3 interface — inlined to avoid
///         pulling the entire chainlink/contracts dependency. The official
///         interface (with EnumerableMap, etc.) is identical for the read
///         path we actually use.
///         sourced from Chainlink contracts
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        );
}