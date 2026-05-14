// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IAnvil256 — public interface for the Anvil256 ERC-20 PoW token.
/// @notice 21M-cap ERC-20 with Keccak-Cascade proof-of-work and protocol-owned
///         Uniswap v3 liquidity. No admin, no proxy, no dev premine, no presale.
///         See docs/WHITEPAPER.md for the specification and docs/MATH.md for
///         the difficulty controller derivation.
///
/// @dev    Cascade PoW construction (matches MATH.md §1.3):
///
///             entropySource = H(blockhash(lastMineBlock[n-1]) ‖ prevrandao ‖ timestamp)
///             (fallback: entropySource = H(prevrandao ‖ timestamp) if bh window expired)
///             ε[n]         = H(entropySource ‖ D[n])
///             τ(m,n)       = H(m ‖ γ(m) ‖ genesisBlockHash)
///             ι(m,n)       = H(τ(m,n) ‖ n)
///             κ(m,ν,n)     = H(H(ι(m,n) ‖ ν) ‖ ε[n])
///
///         Valid iff κ(m,ν,n) < D[n]. Economic emission per successful mine:
///
///             miner receives R(n)
///             POL reserve receives floor(0.1R(n)), subject to MAX_SUPPLY
///             fee splits into devFee + lpReserveEthWei
///
///         All POL mints are inside the same 21M cap.
interface IAnvil256 {
    /* ===================== events ===================== */

    /// @notice Emitted on every successful mine.
    /// @param  miner       the message sender that submitted the PoW
    /// @param  epoch       the epoch index that was just resolved
    /// @param  nonce       the winning nonce
    /// @param  hash        outer Cascade hash: H(H(ι ‖ nonce) ‖ ε[n])
    /// @param  reward      ANVL minted to `miner`
    /// @param  feeWei      total protocol fee paid by the miner before splitting
    event Mined(
        address indexed miner,
        uint256 indexed epoch,
        uint256         nonce,
        bytes32         hash,
        uint256         reward,
        uint256         feeWei
    );

    /// @notice Emitted when mine() reserves fee ETH and freshly minted ANVL for LP.
    event LiquidityReserved(uint256 ethWei, uint256 tokenAmount);

    /// @notice Emitted every ADJUSTMENT_PERIOD epochs when difficulty rebases.
    /// @param  period               period index (monotonic)
    /// @param  oldDifficulty        difficulty before the rebase
    /// @param  newDifficulty        difficulty after the rebase
    /// @param  actualWindowSeconds  seconds elapsed in the just-finished period
    /// @param  targetWindowSeconds  target seconds per period (constant)
    /// @param  integralWad          integrator state after this step (Q60.18 signed)
    /// @param  controlSignalWad     applied control signal u (Q60.18 signed)
    event DifficultyAdjusted(
        uint256 indexed period,
        uint256 oldDifficulty,
        uint256 newDifficulty,
        uint256 actualWindowSeconds,
        uint256 targetWindowSeconds,
        int256  integralWad,
        int256  controlSignalWad
    );

    /// @notice Emitted when epoch entropy is refreshed at the start of a new epoch.
    /// @param  epoch        the new epoch index
    /// @param  entropy      ε[epoch] = H(blockhash(lastMineBlock) ‖ D)
    event EpochEntropySet(uint256 indexed epoch, bytes32 entropy);

    /// @notice Emitted on fee transfer failure. The mine still succeeds and
    ///         the fee accumulates in the contract for later sweeping (see
    ///         `sweepStuckFees`). This decouples the PoW from a possibly-broken
    ///         recipient (e.g. a contract that reverts).
    event FeeStuck(uint256 amountWei, address indexed recipient);

    /// @notice Emitted when stuck fees are successfully swept to feeRecipient.
    event FeesSwept(uint256 amountWei, address indexed recipient);

    /// @notice Emitted when stuck fees cannot be swept and are re-queued.
    event FeesReQueued(uint256 amountWei, address indexed recipient);

    /// @notice Emitted when a `mine()` over-pay refund cannot be delivered
    ///         synchronously (e.g. msg.sender is a contract whose receive()
    ///         reverts). The amount is added to `pendingRefundsWei[payer]`
    ///         and can later be retrieved via `claimRefund()`.
    event RefundQueued(address indexed payer, uint256 amount);

    /// @notice Emitted when a queued refund is paid out via `claimRefund()`.
    event RefundClaimed(address indexed payer, uint256 amount);

    /* ===================== errors ===================== */

    error InvalidNonce();
    error SupplyCapReached();
    error InvalidInitialDifficulty();
    error InvalidFeeRecipient();
    error FeeRecipientEqualsDeployer();
    error InvalidOracle();
    error InvalidUniswapFactory();
    error InvalidPositionManager();
    error InvalidWETH();
    error InvalidSqrtPrice();
    error InsufficientSeedETH();
    error InsufficientFee(uint256 paid, uint256 required);
    error MiningEnded();
    error SeedRefundFailed();
    error NoPendingRefund();
    error DirectETHNotAccepted();
    error ClaimFailed();

    // ── CREATE2 genesis errors ──────────────────────────────────────────

    /// @notice mine() was called before initializePool() completed genesis.
    ///         Deploy via Anvil256Factory which calls initializePool() atomically.
    error PoolNotInitialized();

    /// @notice initializePool() was called on a contract that already has a pool
    ///         (either direct-deploy path or factory already ran initializePool()).
    error PoolAlreadyInitialized();

    /// @notice The sqrtPriceX96 passed to initializePool() does not match the
    ///         value stored during construction.  Prevents griefing by a third
    ///         party who calls initializePool() with a manipulated price before
    ///         the factory does.
    error SqrtPriceMismatch();

    /* ===================== state views ===================== */

    function currentEpoch()       external view returns (uint256);
    function currentDifficulty()  external view returns (uint256);
    function currentReward()      external view returns (uint256);
    function periodStartTime()    external view returns (uint256);
    function periodIndex()        external view returns (uint256);
    function integralErrorWad()   external view returns (int256);

    /// @notice The protocol fee in wei at the current oracle price.
    function currentFeeWei() external view returns (uint256);

    /// @notice The immutable address that receives the dev split of the protocol fee.
    ///         Set at construction; can never change.
    function feeRecipient() external view returns (address);

    /// @notice Immutable Uniswap v3 factory used to create/reuse the ANVL/WETH pool.
    function uniswapFactory() external view returns (address);

    /// @notice Immutable Uniswap v3 NonfungiblePositionManager used for LP NFTs.
    function uniswapPositionManager() external view returns (address);

    /// @notice Immutable WETH9 address paired with ANVL.
    function weth() external view returns (address);

    /// @notice ETH reserved from mine() fees for future LP operations.
    ///         Increments by the LP fee split, i.e. 50% of currentFeeWei().
    function lpReserveEthWei() external view returns (uint256);

    /// @notice ANVL minted to this contract and reserved for future LP operations.
    ///         Increments by 10% of the miner reward, truncated by MAX_SUPPLY headroom.
    function lpReserveTokenWei() external view returns (uint256);

    /// @notice ANVL/WETH Uniswap v3 pool created at deployment.
    function liquidityPool() external view returns (address);

    /// @notice Uniswap v3 NFT id for the tiny seed position.
    function seedPositionId() external view returns (uint256);

    /// @notice Uniswap v3 NFT id for the main reserve position, 0 before trigger.
    function mainPositionId() external view returns (uint256);

    /// @notice True after accumulated LP reserves have been deployed.
    function liquidityLive() external view returns (bool);

    /// @notice Supply threshold required before deployLiquidityReserves().
    function liquidityTriggerSupply() external pure returns (uint256);

    /// @notice Captured at deploy time from `blockhash(block.number - 1)`.
    ///         Folded into every τ so a deployer cannot pre-compute the
    ///         epoch-0 winning nonce before the deploy block is finalised.
    function genesisBlockHash() external view returns (bytes32);

    /// @notice Per-miner epoch counter γ(m) — strictly monotonic, non-transferable.
    ///         Incorporated into τ(m,n) so each mine creates a unique challenge
    ///         bound to this address and its history. Wallet rotation provides
    ///         zero advantage (Theorem 1.9, MATH.md).
    function minerEpochCount(address miner) external view returns (uint64);

    /// @notice Epoch entropy for the current epoch.
    ///         Normal path: ε[n] = H( H(blockhash(lastMineBlock[n-1]) ‖ prevrandao ‖ timestamp) ‖ D[n] ).
    ///         Fallback path (when blockhash window >255 blocks expired):
    ///           ε[n] = H( H(prevrandao ‖ timestamp) ‖ D[n] ) — emits EntropyFallback.
    ///         Set at the close of each epoch. Mandatory for the off-chain kernel;
    ///         any nonce precomputed before this value is known has probability
    ///         D[n]/2^256 of being valid (MATH.md Theorem 1.11).
    function epochEntropy() external view returns (bytes32);

    /// @notice Block number at which the most recent mine() succeeded.
    ///         Used to derive the next epoch entropy via blockhash().
    function lastMineBlock() external view returns (uint256);

    /// @notice True when the contract was deployed via factory and
    ///         initializePool() has not yet been called.
    ///         mine() will revert with PoolNotInitialized while this is true.
    function pendingGenesis() external view returns (bool);

    /// @notice Compute the inner hash ι(miner, epoch) for the current state.
    ///         Off-chain callers use this to build the kernel job.
    ///         ι = H(τ ‖ currentEpoch), where τ = H(miner ‖ γ(miner) ‖ genesisBlockHash).
    function getInner(address miner) external view returns (bytes32);

    /// @notice Verify whether a nonce would be accepted right now for `miner`.
    function isValidNonce(address miner, uint256 nonce) external view returns (bool);

    /// @notice Wei owed to `payer` from a previously failed refund. Claim
    ///         via `claimRefund()` after fixing the receive() path.
    function pendingRefundsWei(address payer) external view returns (uint256);

    /* ===================== mutators ===================== */

    /// @notice Submit a proof of work along with the protocol fee.
    /// @dev    Reverts unless all of:
    ///         (a) Cascade PoW: κ(msg.sender, nonce, currentEpoch) < currentDifficulty
    ///         (b) msg.value >= currentFeeWei()
    ///         (c) reward at the current epoch is non-zero
    ///         (d) supply cap not exceeded
    ///         (e) pool has been initialized (pendingGenesis == false)
    ///
    ///         Fee/mint accounting on success:
    ///           lpFee      = floor(currentFeeWei() * 5_000 / 10_000)
    ///           devFee     = currentFeeWei() - lpFee
    ///           lpReward   = floor(rewardPaid * 1_000 / 10_000), cap-truncated
    ///
    ///         Excess ETH is refunded to msg.sender. If the refund transfer
    ///         fails, the amount is queued for pull-style claim.
    function mine(uint256 nonce) external payable;

    /// @notice Re-attempt delivery of fees that previously failed to reach
    ///         feeRecipient. If delivery fails again, fees remain queued
    ///         (stuckFeesWei is restored) and an event is emitted — they
    ///         are never lost.
    function sweepStuckFees() external;

    /// @notice Pull-style claim for a previously queued refund. Reverts with
    ///         `NoPendingRefund` if msg.sender has no balance to claim.
    function claimRefund() external;

    /// @notice Permissionlessly deploy accumulated LP reserves after the 50%
    ///         totalSupply trigger. Mints the main full-range LP NFT to Anvil256.
    function deployLiquidityReserves() external;

    /// @notice Permissionlessly add post-trigger LP reserves to the main position.
    ///         Separate from mine() so miners do not pay Uniswap gas every epoch.
    function dripLiquidityReserves() external;

    /// @notice Initialize the Uniswap pool after a CREATE2 factory deploy.
    ///         Permissionless — any caller may supply the seed ETH (>= SEED_ETH_WEI).
    ///         The sqrtPriceX96 must match the value locked in at construction.
    ///         Reverts after the first successful call.
    function initializePool(uint160 sqrtPriceX96) external payable;
}
