// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Anvil256} from "../Anvil256.sol";

/// @title  Anvil256Factory
/// @notice Permissionless CREATE2 factory that deploys Anvil256 and atomically
///         initializes its official ANVL/WETH seed liquidity.
///
/// @dev    ROOT CAUSE BEING FIXED
///         ───────────────────────
///         During the Anvil256 constructor, `LiquidityBootstrap.genesis()` calls
///         `NonfungiblePositionManager.mint()`, which in turn calls
///         `token.balanceOf(pool)` on the ANVL token (= `address(this)` inside
///         the constructor).  At that point EXTCODESIZE(address(this)) == 0
///         because the constructor has not returned yet, so the EVM treats
///         `address(this)` as a non-contract and reverts.
///
///         STRATEGY — split construction from Uniswap genesis
///         ──────────────────────────────────────────────────
///         CREATE2 gives a deterministic address, but it does not make bytecode
///         visible during the constructor. The correct fix is therefore not a
///         pre-approval trick; it is a two-step atomic deployment where Uniswap
///         genesis runs only after the Anvil256 constructor has returned.
///
///         The CREATE2 factory solves this by separating deployment into two
///         atomic steps inside a SINGLE transaction:
///
///           Step A. Deploy Anvil256 with msg.value = 0. In Anvil256 this is the
///                   factory path: genesis is marked pending and sqrtPriceX96 is
///                   committed in storage. Bytecode is now live at address(anvl).
///
///           Step B. Immediately call anvl.initializePool{value: msg.value}(...).
///                   At this point EXTCODESIZE(address(anvl)) > 0, so Uniswap can
///                   call balanceOf() on the token during mint callbacks.
///
///         Both steps happen atomically inside `deploy()`. If initializePool()
///         reverts, the whole transaction reverts; no half-initialized token is
///         deployed by this factory path.
///
///         PERMISSIONLESS
///         ──────────────
///         `deploy()` is callable by anyone who supplies the correct ETH value
///         (>= SEED_ETH_WEI).  The salt is derived from the constructor arguments
///         so two identical configurations produce the same address — duplicate
///         deploy attempts revert (CREATE2 collision).  There is no owner, no
///         admin key, no upgrade path.
///
contract Anvil256Factory {

    /* ══════════════════════════════════════════════════════════════
       EVENTS
    ══════════════════════════════════════════════════════════════ */

    /// @notice Emitted once per successful deployment.
    /// @param anvl      The deployed Anvil256 token contract.
    /// @param pool      The Uniswap v3 ANVL/WETH pool created during genesis.
    /// @param deployer  msg.sender who called deploy().
    event Deployed(
        address indexed anvl,
        address indexed pool,
        address indexed deployer
    );

    /* ══════════════════════════════════════════════════════════════
       ERRORS
    ══════════════════════════════════════════════════════════════ */

    error InitializePoolFailed();
    error ZeroAddress();

    /* ══════════════════════════════════════════════════════════════
       DEPLOY
    ══════════════════════════════════════════════════════════════ */

    /// @notice Deploy Anvil256 via CREATE2 and immediately initialize its
    ///         Uniswap liquidity pool — all within a single atomic transaction.
    ///
    /// @dev    The salt is keccak256(abi.encode(config)), so each unique
    ///         configuration maps to a unique deterministic address.
    ///         Redeploying with the same arguments reverts (CREATE2 collision).
    ///
    /// @param initialDifficulty   Initial PoW difficulty (> 0).
    /// @param feeRecipient        Address that receives the dev-fee split.
    ///                            Must differ from msg.sender and != address(0).
    /// @param ethUsdFeed          Chainlink ETH/USD aggregator address.
    /// @param uniswapFactory      Uniswap v3 factory.
    /// @param positionManager     Uniswap v3 NonfungiblePositionManager.
    /// @param weth                WETH9 address.
    /// @param sqrtPriceX96        Initial sqrt(token1/token0) price × 2^96,
    ///                            using Uniswap v3 token ordering.
    ///
    /// @return anvl  The newly deployed Anvil256 contract.
    function deploy(
        uint256 initialDifficulty,
        address feeRecipient,
        address ethUsdFeed,
        address uniswapFactory,
        address positionManager,
        address weth,
        uint160 sqrtPriceX96
    ) external payable returns (Anvil256 anvl) {
        // Validate non-zero addresses here so the error message is clear even
        // before constructor validation runs.
        if (feeRecipient   == address(0)) revert ZeroAddress();
        if (ethUsdFeed     == address(0)) revert ZeroAddress();
        if (uniswapFactory == address(0)) revert ZeroAddress();
        if (positionManager == address(0)) revert ZeroAddress();
        if (weth           == address(0)) revert ZeroAddress();

        // Derive a deterministic salt from the configuration so that identical
        // deployments land at the same address and duplicates revert cheaply.
        bytes32 salt = keccak256(abi.encode(
            initialDifficulty,
            feeRecipient,
            ethUsdFeed,
            uniswapFactory,
            positionManager,
            weth,
            sqrtPriceX96
        ));

        // ── STEP A ───────────────────────────────────────────────────────────
        // Deploy Anvil256 with genesis deferred. The contract bytecode is now
        // live at its deterministic address, so subsequent calls back into it
        // (e.g. balanceOf from Uniswap) will succeed.
        //
        // We pass msg.value = 0 here; in Anvil256 this selects the factory path.
        // ETH for the seed position is forwarded in Step B via initializePool().
        anvl = new Anvil256{salt: salt}(
            initialDifficulty,
            feeRecipient,
            ethUsdFeed,
            uniswapFactory,
            positionManager,
            weth,
            sqrtPriceX96
            // msg.value == 0 selects the deferred-genesis constructor path.
        );

        // ── STEP B ───────────────────────────────────────────────────────────
        // Now that the bytecode exists, call initializePool.  This mints the
        // seed ANVL, wraps ETH → WETH, and calls positionManager.mint().
        // Uniswap's callback to balanceOf(anvl) now succeeds.
        //
        // Forward all ETH sent to this function — Anvil256.initializePool()
        // will revert if msg.value < SEED_ETH_WEI and refund any excess back
        // to this contract, which we relay back to msg.sender.
        anvl.initializePool{value: msg.value}(sqrtPriceX96);

        // Relay any seed refund forwarded back from Anvil256.
        uint256 refund = address(this).balance;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            // Non-critical — if the caller can't receive ETH the deploy still
            // succeeds.  The excess ETH stays in this contract (harmless, as
            // this factory holds no protocol state).
            if (!ok) {/* ignore */}
        }

        emit Deployed(address(anvl), anvl.liquidityPool(), msg.sender);
    }

    /* ══════════════════════════════════════════════════════════════
       ADDRESS PREDICTION (pure, no state)
    ══════════════════════════════════════════════════════════════ */

    /// @notice Compute the CREATE2 address Anvil256 will land at, without
    ///         deploying anything.  Useful for pre-approvals, UI previews,
    ///         and integration tests.
    ///
    /// @dev    address = keccak256(0xff ++ factory ++ salt ++ initcodeHash)[12:]
    ///
    /// @param initialDifficulty  Same value passed to deploy().
    /// @param feeRecipient       Same value passed to deploy().
    /// @param ethUsdFeed         Same value passed to deploy().
    /// @param uniswapFactory     Same value passed to deploy().
    /// @param positionManager    Same value passed to deploy().
    /// @param weth               Same value passed to deploy().
    /// @param sqrtPriceX96       Same value passed to deploy().
    ///
    /// @return predicted  The deterministic address of the Anvil256 contract.
    function predictAddress(
        uint256 initialDifficulty,
        address feeRecipient,
        address ethUsdFeed,
        address uniswapFactory,
        address positionManager,
        address weth,
        uint160 sqrtPriceX96
    ) external view returns (address predicted) {
        bytes32 salt = keccak256(abi.encode(
            initialDifficulty,
            feeRecipient,
            ethUsdFeed,
            uniswapFactory,
            positionManager,
            weth,
            sqrtPriceX96
        ));

        bytes32 initcodeHash = keccak256(
            abi.encodePacked(
                type(Anvil256).creationCode,
                abi.encode(
                    initialDifficulty,
                    feeRecipient,
                    ethUsdFeed,
                    uniswapFactory,
                    positionManager,
                    weth,
                    sqrtPriceX96
                )
            )
        );

        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            initcodeHash
        )))));
    }

    /// @dev Allow factory to receive ETH refunds forwarded back from Anvil256.
    receive() external payable {}
}
