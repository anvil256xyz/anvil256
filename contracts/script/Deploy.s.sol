// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2}    from "forge-std/Script.sol";
import {Anvil256}            from "../src/Anvil256.sol";
import {Anvil256Factory}     from "../src/libs/Anvil256Factory.sol";
import {LiquidityBootstrap}  from "../src/libs/LiquidityBootstrap.sol";

/// @title  Deploy.s.sol — CREATE2 deployment script for Anvil256
///
/// @notice Required environment variables:
///
///     DEPLOY_INITIAL_DIFFICULTY    uint256, see scripts/compute-difficulty.py
///     DEPLOY_FEE_RECIPIENT         address, must differ from the deployer
///
/// @notice Optional environment variables:
///
///     DEPLOY_ETH_USD_FEED          address, defaults to Base mainnet Chainlink ETH/USD
///     DEPLOY_UNISWAP_FACTORY       address, defaults to Base mainnet UniswapV3Factory
///     DEPLOY_POSITION_MANAGER      address, defaults to Base mainnet NonfungiblePositionManager
///     DEPLOY_WETH                  address, defaults to Base mainnet WETH
///     DEPLOY_SQRT_PRICE_X96        uint160, defaults to 0.001 WETH/ANVL seed price
///     DEPLOY_SEED_ETH_WEI          uint256, defaults to LiquidityBootstrap.SEED_ETH_WEI (0.001 ETH)
///     DEPLOY_FACTORY_ADDRESS       address, existing Anvil256Factory to reuse
///                                  (optional — if absent, a new factory is deployed first)
///
/// @notice How the CREATE2 fix works
///
///     The original single-step deploy failed because during the Anvil256
///     constructor, Uniswap's positionManager.mint() calls back into
///     token.balanceOf(pool) on the Anvil256 contract itself.  At that point
///     EXTCODESIZE(address(this)) == 0 (constructor has not returned), so
///     the EVM treats it as a non-contract and reverts.
///
///     This script deploys an Anvil256Factory first (or reuses one supplied
///     via DEPLOY_FACTORY_ADDRESS), then calls factory.deploy() which:
///
///       1. Deploys Anvil256 via CREATE2 with skipGenesis (msg.value == 0
///          in the constructor) — bytecode is now live.
///       2. Immediately calls anvil.initializePool() in the same transaction.
///          EXTCODESIZE > 0, so Uniswap callbacks succeed.
///
///     The predicted address is printed before broadcast so you can verify it.
///
/// @notice Suggested invocation:
///
///     DEPLOY_INITIAL_DIFFICULTY=$(python scripts/compute-difficulty.py \
///         --hashrate-ghs 100 | awk '/initial difficulty .dec./ {print $5}') \
///     DEPLOY_FEE_RECIPIENT=0xYourLiquidityWallet \
///     DEPLOY_ETH_USD_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70 \
///     forge script contracts/script/Deploy.s.sol \
///         --rpc-url $BASE_RPC_URL \
///         --private-key $DEPLOYER_KEY \
///         --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY \
///         --via-ir
contract Deploy is Script {
    /* ─────────────────────────────────────────────────────────────────────
       DEFAULTS
    ───────────────────────────────────────────────────────────────────── */

    uint256 internal constant DEFAULT_INITIAL_DIFFICULTY =
        0x00000000001774ccac3d3816cca98a969e8b5d0ba353997f09e63f456ce0844b;

    address internal constant BASE_ETH_USD_FEED =
        0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    address internal constant BASE_UNISWAP_V3_FACTORY =
        0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    address internal constant BASE_NONFUNGIBLE_POSITION_MANAGER =
        0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    address internal constant BASE_WETH =
        0x4200000000000000000000000000000000000006;

    /// @notice sqrt(0.001) × 2^96 — 0.001 WETH per ANVL seed price.
    uint160 internal constant DEFAULT_SQRT_PRICE_X96 =
        2_505_414_487_287_301_086_054_410_895;

    /* ─────────────────────────────────────────────────────────────────────
       RUN
    ───────────────────────────────────────────────────────────────────── */

    function run() external returns (Anvil256 deployed) {
        // ── Read configuration ─────────────────────────────────────────
        uint256 initialDifficulty =
            vm.envOr("DEPLOY_INITIAL_DIFFICULTY", DEFAULT_INITIAL_DIFFICULTY);

        address feeRecipient =
            vm.envAddress("DEPLOY_FEE_RECIPIENT");

        address ethUsdFeed =
            vm.envOr("DEPLOY_ETH_USD_FEED", BASE_ETH_USD_FEED);

        address uniswapFactory =
            vm.envOr("DEPLOY_UNISWAP_FACTORY", BASE_UNISWAP_V3_FACTORY);

        address positionManager =
            vm.envOr("DEPLOY_POSITION_MANAGER", BASE_NONFUNGIBLE_POSITION_MANAGER);

        address wethAddr =
            vm.envOr("DEPLOY_WETH", BASE_WETH);

        uint160 sqrtPriceX96 =
            uint160(vm.envOr("DEPLOY_SQRT_PRICE_X96", uint256(DEFAULT_SQRT_PRICE_X96)));

        uint256 seedEthWei =
            vm.envOr("DEPLOY_SEED_ETH_WEI", LiquidityBootstrap.SEED_ETH_WEI);

        // Optional: reuse an existing factory (saves ~300k gas on repeat
        // deployments to the same chain, e.g. testnet iterations).
        address existingFactory =
            vm.envOr("DEPLOY_FACTORY_ADDRESS", address(0));

        // ── Predict address (no state change) ─────────────────────────
        // We call predictAddress on a temporary factory instance off-chain
        // so we can print the address before broadcasting.
        // Note: vm.computeCreate2Address is equivalent but requires knowing
        // the factory address first — we show both approaches.
        console2.log("=== Anvil256 CREATE2 Deployment ===");
        console2.log("initial difficulty   :", initialDifficulty);
        console2.log("fee recipient        :", feeRecipient);
        console2.log("eth/usd feed         :", ethUsdFeed);
        console2.log("uniswap factory      :", uniswapFactory);
        console2.log("position manager     :", positionManager);
        console2.log("weth                 :", wethAddr);
        console2.log("sqrt price x96       :", sqrtPriceX96);
        console2.log("seed eth wei         :", seedEthWei);
        console2.log("existing factory     :", existingFactory);
        console2.log("chain id             :", block.chainid);

        // ── Broadcast ─────────────────────────────────────────────────
        vm.startBroadcast();

        // Step 1 — Deploy (or reuse) the factory.
        Anvil256Factory factory;
        if (existingFactory != address(0)) {
            factory = Anvil256Factory(payable(existingFactory));
            console2.log("reusing factory      :", address(factory));
        } else {
            factory = new Anvil256Factory();
            console2.log("factory deployed at  :", address(factory));
        }

        // Step 2 — Predict the Anvil256 address before deploying.
        address predicted = factory.predictAddress(
            initialDifficulty,
            feeRecipient,
            ethUsdFeed,
            uniswapFactory,
            positionManager,
            wethAddr,
            sqrtPriceX96
        );
        console2.log("predicted Anvil256   :", predicted);

        // Step 3 — Deploy Anvil256 via factory.
        //   • Factory internally: CREATE2-deploys Anvil256 (skipGenesis),
        //     then calls initializePool() with the seed ETH — all atomic.
        //   • msg.value is forwarded through the factory to initializePool().
        deployed = factory.deploy{value: seedEthWei}(
            initialDifficulty,
            feeRecipient,
            ethUsdFeed,
            uniswapFactory,
            positionManager,
            wethAddr,
            sqrtPriceX96
        );

        vm.stopBroadcast();

        // ── Verify address matches prediction ─────────────────────────
        require(
            address(deployed) == predicted,
            "Deploy: CREATE2 address mismatch check factory initcode hash"
        );

        // ── Summary ───────────────────────────────────────────────────
        console2.log("=== Deployment successful ===");
        console2.log("Anvil256 deployed at :", address(deployed));
        console2.log("liquidity pool       :", deployed.liquidityPool());
        console2.log("genesis timestamp    :", block.timestamp);
    }
}
