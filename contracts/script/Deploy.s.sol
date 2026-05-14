// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Anvil256}         from "../src/Anvil256.sol";

/// @title Deploy.s.sol — one-shot deployment script for Anvil256
///
/// @notice Required environment variables:
///
///     DEPLOY_INITIAL_DIFFICULTY    uint256, see scripts/compute-difficulty.py
///     DEPLOY_FEE_RECIPIENT         address, must differ from the deployer
///     DEPLOY_ETH_USD_FEED          address, Chainlink-compatible ETH/USD aggregator
///
///         Base mainnet ETH/USD feed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
///         Base Sepolia ETH/USD feed: 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1
///
/// @notice Suggested invocation:
///
///     DEPLOY_INITIAL_DIFFICULTY=$(python scripts/compute-difficulty.py --hashrate-ghs 100 | awk '/initial difficulty .dec./ {print $5}') \
///     DEPLOY_FEE_RECIPIENT=0xYourLiquidityWallet \
///     DEPLOY_ETH_USD_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70 \
///     forge script contracts/script/Deploy.s.sol \
///         --rpc-url $BASE_RPC_URL \
///         --private-key $DEPLOYER_KEY \
///         --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
contract Deploy is Script {
    /// @notice Default used only when env var is absent (testnet helper).
    uint256 internal constant DEFAULT_INITIAL_DIFFICULTY =
        0x00000000001774ccac3d3816cca98a969e8b5d0ba353997f09e63f456ce0844b;

    function run() external returns (Anvil256 deployed) {
        uint256 initialDifficulty =
            vm.envOr("DEPLOY_INITIAL_DIFFICULTY", DEFAULT_INITIAL_DIFFICULTY);

        address feeRecipient =
            vm.envAddress("DEPLOY_FEE_RECIPIENT");

        address ethUsdFeed =
            vm.envAddress("DEPLOY_ETH_USD_FEED");

        vm.startBroadcast();
        deployed = new Anvil256(initialDifficulty, feeRecipient, ethUsdFeed);
        vm.stopBroadcast();

        console2.log("Anvil256 deployed at :", address(deployed));
        console2.log("initial difficulty   :", initialDifficulty);
        console2.log("fee recipient        :", feeRecipient);
        console2.log("eth/usd feed         :", ethUsdFeed);
        console2.log("chain id             :", block.chainid);
        console2.log("genesis timestamp    :", block.timestamp);
    }
}
