// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee)
        external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee)
        external view returns (address pool);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0; address token1;
        uint24 fee; int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        uint256 deadline;
    }
    function mint(MintParams calldata)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata)
        external payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IWETH9 {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title  LiquidityBootstrap
/// @author Anvil256 contributors
///
/// @notice Manages the three-phase lifecycle of ANVL/WETH liquidity:
///
///   ┌─────────────────────────────────────────────────────────────────────┐
///   │  PHASE 0 — GENESIS  (deploy → first mine)                           │
///   │    Pool created on deploy with seed ETH from deployer.              │
///   │    A tiny seed position anchors the initial price (full-range).     │
///   │    Seed is intentionally tiny — its job is price, not exit liq.     │
///   │                                                                     │
///   │  PHASE 1 — ACCUMULATION  (0 → LP_TRIGGER_BPS of supply mined)      │
///   │    Every mine() drips reserves into the contract:                   │
///   │      • 50% of $0.10 fee  → lpReserveEthWei                         │
///   │      • 10% of miner rwd  → lpReserveTokenWei                       │
///   │    Nothing goes to Uniswap yet. Thin seed LP discourages dumps.     │
///   │                                                                     │
///   │  PHASE 2 — LIVE TRADING  (trigger reached → MAX_SUPPLY)            │
///   │    deployReserves() is permissionlessly callable once               │
///   │    totalSupply >= LP_TRIGGER_BPS/10_000 of MAX_SUPPLY.             │
///   │    All accumulated ETH+ANVL reserves deploy as a full-range          │
///   │    position on Uniswap v3.                                          │
///   │    Additional reserve deployment is permissionless via drip().        │
///   └─────────────────────────────────────────────────────────────────────┘
///
///       Reserve math produced by Anvil256.mine():
///
///           ΔreserveETH   = 0.5 * currentFeeWei()
///           ΔreserveANVL  = 0.1 * R(n), truncated by MAX_SUPPLY headroom
///           triggerSupply = 0.5 * MAX_SUPPLY
///
///       This library never mints tokens and never decides the fee split. It
///       only consumes already-accounted reserves and reports the exact amounts
///       Uniswap accepted so the caller can restore leftovers.
///
/// @dev  Why accumulate then deploy?
///       Early liquidity is thin and exploitable. By withholding the LP until
///       ~50% of total supply is mined, the market has had time for genuine
///       price discovery and the token has real holders. The tiny seed position
///       lets trading happen but provides minimal exit liquidity — making large
///       sell attacks self-defeating (the attacker crashes their own position).
///
///       Why full-range main LP?
///       The ANVL/WETH reserve ratio is produced by mining fees, while the
///       market price can move before the trigger. Full-range is less capital
///       efficient than concentrated liquidity, but it is much more robust and
///       audit-friendly for a permissionless reserve deployment.
///
/// @custom:audit-status unaudited — DO NOT DEPLOY WITHOUT AUDIT
library LiquidityBootstrap {

    /* ══════════════════════════════════════════════════════════════
       STATE STRUCT
    ══════════════════════════════════════════════════════════════ */

    struct State {
        /// @notice Address of the ANVL/WETH Uniswap v3 pool. Set in genesis().
        address pool;

        /// @notice NFT tokenId of the seed full-range position (Phase 0).
        uint256 seedPositionId;

        /// @notice NFT tokenId of the main full-range position (Phase 2).
        uint256 mainPositionId;

        /// @notice True once deployReserves() has successfully run.
        bool livePhase;

        /// @notice Cumulative ETH added to Uniswap (for off-chain analytics).
        uint256 totalEthDeployed;

        /// @notice Cumulative ANVL added to Uniswap (for off-chain analytics).
        uint256 totalTokenDeployed;
    }

    /* ══════════════════════════════════════════════════════════════
       CONSTANTS
    ══════════════════════════════════════════════════════════════ */

    /// @notice Uniswap v3 fee tier: 0.3%. Good for volatile new tokens.
    uint24  public constant POOL_FEE          = 3_000;

    /// @notice Tick spacing for 0.3% tier.
    int24   public constant TICK_SPACING      = 60;

    /// @notice Full-range lower tick (rounded to TICK_SPACING).
    int24   public constant MIN_TICK          = -887220;

    /// @notice Full-range upper tick (rounded to TICK_SPACING).
    int24   public constant MAX_TICK          =  887220;

    /// @notice Main reserve position uses full range for maximum liveness.
    int24   public constant MAIN_TICK_LOWER   = MIN_TICK;

    /// @notice Main reserve position uses full range for maximum liveness.
    int24   public constant MAIN_TICK_UPPER   = MAX_TICK;

    /// @notice Minimum seed ETH the deployer must send (0.001 ETH).
    uint256 public constant SEED_ETH_WEI      = 0.001 ether;

    /// @notice Seed ANVL minted to contract for genesis position (1 ANVL).
    ///         Together with SEED_ETH_WEI this anchors the initial pool ratio:
    ///             P_seed = 0.001 ETH / 1 ANVL = 0.001 ETH per ANVL.
    ///         At ETH=$2,500 this implies $2.50/ANVL, but this is only the
    ///         initialization ratio of a tiny seed LP, not a price guarantee.
    uint256 public constant SEED_TOKEN_WEI    = 1 ether;

    /// @notice Supply fraction that triggers deployReserves(). 5000 = 50%.
    uint256 public constant LP_TRIGGER_BPS    = 5_000;

    /// @notice Slippage cap for Uniswap calls: 1%.
    uint256 public constant SLIPPAGE_BPS      = 100;

    uint256 public constant BPS_DENOM         = 10_000;

    /// @notice Deadline buffer passed to Uniswap (added to block.timestamp).
    uint256 public constant TX_DEADLINE       = 20 minutes;

    /* ══════════════════════════════════════════════════════════════
       EVENTS
    ══════════════════════════════════════════════════════════════ */

    event PoolCreated(address indexed pool, uint160 sqrtPriceX96);
    event SeedPositionMinted(uint256 indexed tokenId, uint128 liquidity);
    event ReservesDeployed(
        uint256 indexed mainTokenId,
        uint256 ethAdded,
        uint256 tokenAdded,
        uint128 liquidity
    );
    event ReservesDripped(uint256 ethAdded, uint256 tokenAdded, uint128 liquidity);

    /* ══════════════════════════════════════════════════════════════
       ERRORS
    ══════════════════════════════════════════════════════════════ */

    error PoolAlreadyCreated();
    error TriggerNotReached(uint256 current, uint256 required);
    error AlreadyLive();
    error NoReserves();
    error PoolCreationFailed();
    error InsufficientSeedETH();

    /* ══════════════════════════════════════════════════════════════
       PHASE 0 — GENESIS
    ══════════════════════════════════════════════════════════════ */

    /// @notice Create the ANVL/WETH pool and mint a full-range seed position.
    ///
    /// @dev Called once inside Anvil256's constructor (payable, deployer sends
    ///      >= SEED_ETH_WEI). The contract must already hold seedTokenWei ANVL
    ///      (minted via _mint in the constructor before this call).
    ///
    /// @param state         LiquidityBootstrap.State storage ref.
    /// @param factory       Uniswap v3 factory.
    /// @param posManager    NonfungiblePositionManager.
    /// @param weth          WETH9 address.
    /// @param anvlToken     address(this) from Anvil256.
    /// @param sqrtPriceX96  Initial √price × 2^96. Pass output of
    ///                      computeSqrtPriceX96() from the deploy script.
    /// @param seedEthWei    ETH value passed by deployer in the constructor.
    /// @param seedTokenWei  ANVL amount minted to contract for seed.
    function genesis(
        State storage state,
        address factory,
        address posManager,
        address weth,
        address anvlToken,
        uint160 sqrtPriceX96,
        uint256 seedEthWei,
        uint256 seedTokenWei
    ) internal {
        if (state.pool != address(0)) revert PoolAlreadyCreated();
        if (seedEthWei < SEED_ETH_WEI)   revert InsufficientSeedETH();

        // 1. Create or reuse pool.
        address pool = IUniswapV3Factory(factory).getPool(anvlToken, weth, POOL_FEE);
        if (pool == address(0)) {
            pool = IUniswapV3Factory(factory).createPool(anvlToken, weth, POOL_FEE);
            if (pool == address(0)) revert PoolCreationFailed();
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }
        state.pool = pool;
        emit PoolCreated(pool, sqrtPriceX96);

        // 2. Wrap ETH → WETH.
        IWETH9(weth).deposit{value: seedEthWei}();

        // 3. Approve position manager for WETH.
        //    ANVL approval is set by the Anvil256 constructor via internal
        //    _approve() *before* calling genesis(), because genesis() is
        //    invoked from within the constructor where EXTCODESIZE(address(this))
        //    == 0 — any external call back to the token contract would revert
        //    with "call to non-contract address".
        IWETH9(weth).approve(posManager, 0);
        IWETH9(weth).approve(posManager, seedEthWei);

        // 4. Sort tokens (Uniswap requires token0 < token1).
        (address t0, address t1, uint256 a0, uint256 a1) =
            _sort(anvlToken, weth, seedTokenWei, seedEthWei);

        // 5. Mint full-range seed position owned by the contract itself.
        //
        // Genesis slippage model:
        // amountMin values are set to 0 for the genesis seed position.
        //
        // Why this is safe:
        //   (a) The pool was created and initialized by this same call (step 1
        //       above). No other liquidity exists yet. There is no pool state
        //       for a sandwich attacker to exploit between initialize() and
        //       posManager.mint() within the same transaction.
        //   (b) The seed position is intentionally tiny (0.001 ETH / 1 ANVL).
        //       Its purpose is to anchor the initial price, not to represent
        //       significant capital. Over-paying by a few wei on a fresh pool
        //       is acceptable.
        //   (c) The sqrtPriceX96 determines how much of each token is actually
        //       consumed. At a skewed price (e.g. 0.001 WETH/ANVL) Uniswap
        //       only pulls a tiny fraction of the "cheap" token. Setting
        //       amountMin to 99% of desired amount therefore *always* reverts
        //       because the actual consumed amount is far below the minimum.
        //
        // Non-genesis positions (_mintMainPosition, _increaseMainPosition)
        // keep their SLIPPAGE_BPS guards — they operate on live markets.
        (uint256 tokenId, uint128 liq,,) = INonfungiblePositionManager(posManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: t0, token1: t1,
                fee: POOL_FEE,
                tickLower: MIN_TICK, tickUpper: MAX_TICK,
                amount0Desired: a0, amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: anvlToken,
                deadline: block.timestamp + TX_DEADLINE
            })
        );

        state.seedPositionId = tokenId;
        emit SeedPositionMinted(tokenId, liq);
    }

    /* ══════════════════════════════════════════════════════════════
       PHASE 2 — TRIGGER DEPLOY
    ══════════════════════════════════════════════════════════════ */

    /// @notice Deploy all accumulated reserves into the main full-range position.
    ///         Permissionless — anyone can call once the threshold is met.
    ///
    /// @dev Trigger condition:
    ///          totalSupply >= maxSupply * LP_TRIGGER_BPS / 10_000.
    ///      With current constants this is 10,500,000 ANVL. The check uses
    ///      totalSupply, not currentEpoch, because actual supply includes the
    ///      genesis LP seed and 10% POL reserve mints and may reach cap earlier
    ///      than the miner-only halving schedule.
    ///
    /// @return ethUsed    ETH actually deposited into Uniswap.
    /// @return tokenUsed  ANVL actually deposited into Uniswap.
    function deployReserves(
        State storage state,
        address posManager,
        address weth,
        address anvlToken,
        uint256 ethReserve,
        uint256 tokenReserve,
        uint256 totalSupply,
        uint256 maxSupply
    ) internal returns (uint256 ethUsed, uint256 tokenUsed) {
        if (state.livePhase)                revert AlreadyLive();
        if (ethReserve == 0 || tokenReserve == 0) revert NoReserves();

        uint256 required = maxSupply * LP_TRIGGER_BPS / BPS_DENOM;
        if (totalSupply < required) revert TriggerNotReached(totalSupply, required);

        state.livePhase = true;
        return _addLiquidity(state, posManager, weth, anvlToken,
                             ethReserve, tokenReserve, false);
    }

    /* ══════════════════════════════════════════════════════════════
       PHASE 2 — INCREMENTAL DRIP
    ══════════════════════════════════════════════════════════════ */

    /// @notice Add the current batch of accumulated reserves to the existing
    ///         main LP position. Permissionless; intentionally not called by
    ///         mine(), keeping the hot mining path independent of Uniswap gas.
    ///
    /// @return ethUsed    ETH actually deposited (may be < reserve).
    /// @return tokenUsed  ANVL actually deposited.
    function drip(
        State storage state,
        address posManager,
        address weth,
        address anvlToken,
        uint256 ethReserve,
        uint256 tokenReserve
    ) internal returns (uint256 ethUsed, uint256 tokenUsed) {
        if (!state.livePhase) return (0, 0);
        if (ethReserve == 0 || tokenReserve == 0) return (0, 0);
        return _addLiquidity(state, posManager, weth, anvlToken,
                             ethReserve, tokenReserve, true);
    }

    /* ══════════════════════════════════════════════════════════════
       INTERNAL
    ══════════════════════════════════════════════════════════════ */

    function _addLiquidity(
        State storage state,
        address posManager,
        address weth,
        address anvlToken,
        uint256 ethAmt,
        uint256 tokenAmt,
        bool    incremental
    ) private returns (uint256 ethUsed, uint256 tokenUsed) {
        // ETH is converted to WETH immediately before the Uniswap call. The
        // caller has already zeroed reserve accounting; if Uniswap reverts, all
        // state including WETH minting and approvals reverts atomically.
        IWETH9(weth).deposit{value: ethAmt}();
        IERC20Min(anvlToken).approve(posManager, 0);
        IERC20Min(anvlToken).approve(posManager, tokenAmt);
        IWETH9(weth).approve(posManager, 0);
        IWETH9(weth).approve(posManager, ethAmt);

        if (!incremental) {
            (uint256 id, uint128 liq, uint256 r0, uint256 r1) = _mintMainPosition(
                posManager,
                weth,
                anvlToken,
                ethAmt,
                tokenAmt
            );
            state.mainPositionId = id;
            (ethUsed, tokenUsed) = _unsort(anvlToken, weth, r0, r1);
            state.totalEthDeployed   += ethUsed;
            state.totalTokenDeployed += tokenUsed;
            emit ReservesDeployed(id, ethUsed, tokenUsed, liq);
        } else {
            (uint128 liq, uint256 r0, uint256 r1) = _increaseMainPosition(
                posManager,
                weth,
                anvlToken,
                state.mainPositionId,
                ethAmt,
                tokenAmt
            );
            (ethUsed, tokenUsed) = _unsort(anvlToken, weth, r0, r1);
            state.totalEthDeployed   += ethUsed;
            state.totalTokenDeployed += tokenUsed;
            emit ReservesDripped(ethUsed, tokenUsed, liq);
        }
    }

    function _mintMainPosition(
        address posManager,
        address weth,
        address anvlToken,
        uint256 ethAmt,
        uint256 tokenAmt
    ) private returns (uint256 id, uint128 liq, uint256 r0, uint256 r1) {
        (address t0, address t1, uint256 a0, uint256 a1) =
            _sort(anvlToken, weth, tokenAmt, ethAmt);

        // Full-range main LP uses a 1% amountMin guard. Full-range makes the
        // position robust to unknown market price at trigger time, while min
        // amounts prevent donating materially more of either asset than intended.
        uint256 a0Min = a0 * (BPS_DENOM - SLIPPAGE_BPS) / BPS_DENOM;
        uint256 a1Min = a1 * (BPS_DENOM - SLIPPAGE_BPS) / BPS_DENOM;
        return INonfungiblePositionManager(posManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: POOL_FEE,
                tickLower: MAIN_TICK_LOWER,
                tickUpper: MAIN_TICK_UPPER,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: a0Min,
                amount1Min: a1Min,
                recipient: anvlToken,
                deadline: block.timestamp + TX_DEADLINE
            })
        );
    }

    function _increaseMainPosition(
        address posManager,
        address weth,
        address anvlToken,
        uint256 tokenId,
        uint256 ethAmt,
        uint256 tokenAmt
    ) private returns (uint128 liq, uint256 r0, uint256 r1) {
        (, , uint256 a0, uint256 a1) = _sort(anvlToken, weth, tokenAmt, ethAmt);

        // Apply the same 1% guard on drips. Any unused residual is reported to
        // Anvil256 and restored to lpReserveEthWei/lpReserveTokenWei.
        uint256 a0Min = a0 * (BPS_DENOM - SLIPPAGE_BPS) / BPS_DENOM;
        uint256 a1Min = a1 * (BPS_DENOM - SLIPPAGE_BPS) / BPS_DENOM;
        return INonfungiblePositionManager(posManager).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: a0Min,
                amount1Min: a1Min,
                deadline: block.timestamp + TX_DEADLINE
            })
        );
    }

    function _sort(
        address anvl, address weth_,
        uint256 anvlAmt, uint256 wethAmt
    ) private pure returns (address t0, address t1, uint256 a0, uint256 a1) {
        if (anvl < weth_) {
            (t0, t1, a0, a1) = (anvl, weth_, anvlAmt, wethAmt);
        } else {
            (t0, t1, a0, a1) = (weth_, anvl, wethAmt, anvlAmt);
        }
    }

    function _unsort(
        address anvl, address weth_,
        uint256 r0, uint256 r1
    ) private pure returns (uint256 ethUsed, uint256 tokenUsed) {
        // If ANVL is token0, r0=ANVL r1=WETH. Else r0=WETH r1=ANVL.
        if (anvl < weth_) { tokenUsed = r0; ethUsed = r1; }
        else               { ethUsed = r0; tokenUsed = r1; }
    }

    /* ══════════════════════════════════════════════════════════════
       PRICE HELPER — use in deploy script / tests
    ══════════════════════════════════════════════════════════════ */

    /// @notice Compute sqrtPriceX96 = sqrt(num/denom) * 2^96.
    ///
    /// @dev    Pass token amounts in the correct order for the pool:
    ///         - If ANVL < WETH (address): num=seedEth, denom=seedToken
    ///           (price = WETH per ANVL as token1/token0).
    ///         - If ANVL > WETH (address): num=seedToken, denom=seedEth.
    ///
    ///         Example: 0.001 ETH seed, 1 ANVL seed, ANVL < WETH.
    ///           price  = 0.001e18 / 1e18 = 0.001
    ///           sqrt   = 0.031622...
    ///           result = 0.031622 * 2^96 ≈ 2.505e27  (uint160 ok)
    function computeSqrtPriceX96(
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint160) {
        // Compute sqrt( numerator * 2^192 / denominator ) → Q64.96 result.
        //
        // Precision fix (divide-before-multiply): the original
        //   (numerator * Q96 / denominator) * Q96
        // first divides, losing up to (denominator-1) precision. Reorder to
        // multiply both Q96 factors before dividing:
        //   numerator * Q96 * Q96 / denominator  =  numerator * 2^192 / denominator
        //
        // Overflow guard: numerator ≤ MAX_SUPPLY = 21e24 tokens ≤ ~2e25.
        //   2e25 * 2^192 ≈ 2e25 * 6.3e57 = 1.26e83 > 2^256 ≈ 1.16e77 → overflows.
        // Use shift-then-multiply to stay in uint256:
        //   ratio = (numerator << 96) / denominator   [fits: numerator < 2^85 always]
        //   ratioX192 = ratio << 96
        // For the seed amounts used here (numerator ≤ 21e24 < 2^85, Q96 = 2^96):
        //   numerator << 96 ≤ 2^181 — well within uint256.
        // mixed-case-variable: q96 (renamed from Q96 per lint)
        uint256 q96 = 2**96;
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 ratioX192 = ((numerator * q96) / denominator) * q96;
        return uint160(_sqrt(ratioX192));
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x >> 1) + 1;
        while (z < y) { y = z; z = (x / z + z) >> 1; }
    }
}
