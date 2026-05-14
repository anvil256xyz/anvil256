// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20}                 from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard}       from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAnvil256}             from "./interfaces/IAnvil256.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {PIController}          from "./libs/PIController.sol";
import {FeeOracle}             from "./libs/FeeOracle.sol";
import {MinerWindow}           from "./libs/MinerWindow.sol";
import {LiquidityBootstrap}    from "./libs/LiquidityBootstrap.sol";

/// @title  Anvil256 (ANVL)
/// @author Anvil256 contributors
///
/// @notice Fair-launch 21,000,000-cap ERC-20 with Keccak-Cascade proof-of-work,
///         deterministic fee accounting, and protocol-owned Uniswap v3 liquidity
///         on Base L2.
///
/// @dev    Economic identity, excluding final cap truncation:
///
///             minerMint(n) = R(n)
///             lpMint(n)    = floor(R(n) * LP_REWARD_BPS / 10_000) = 0.1R(n)
///             fee(n)       = currentFeeWei()
///             lpFee(n)     = floor(fee(n) * LIQUIDITY_FEE_BPS / 10_000)
///             devFee(n)    = fee(n) - lpFee(n)
///
///         Actual minting is hard-capped by MAX_SUPPLY via two layers:
///           1. mine() truncates reward first, then truncates lpMint to residual
///              headroom after the miner reward.
///           2. _update() enforces totalSupply + mint <= MAX_SUPPLY for every
///              ERC-20 mint path, including genesis LP seed and POL reserves.
///
///         Therefore:
///             S_seed + Σ(minerMintPaid(n) + lpMintPaid(n)) <= 21,000,000 ANVL
///
///         There is no dev premine or admin mint. It is intentionally not true
///         that every minted ANVL goes to miners: 1 ANVL seeds the official LP,
///         and 10% of each paid miner reward is reserved for protocol-owned LP.
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  SECURITY / ACCOUNTING MODEL (summary; see docs for proofs)      │
/// │                                                                  │
/// │  Fee flow (I2, I3, I7):                                          │
/// │    mine() -> [PoW valid] -> [LP reserves accounted] ->           │
/// │    feeRecipient.call{value:devFee, gas:80k} ->                   │
/// │    [if fail: stuckFeesWei += devFee] -> msg.sender refund        │
/// │                                                                  │
/// │    Invariant per successful mine:                                │
/// │      ΔlpReserveEthWei + ΔfeeRecipient + ΔstuckFeesWei = fee      │
/// │      ΔlpReserveTokenWei = min(0.1R(n), residual cap headroom)     │
/// │                                                                  │
/// │  Frontrun protection (MATH.md §4.5):                             │
/// │    tau(m,n) = H(m || gamma(m) || genesisBlockHash)               │
/// │    A valid nonce for miner M is cryptographically invalid for    │
/// │    any M' ≠ M. Frontrunning transfers the slot, not value.       │
/// │                                                                  │
/// │  Precompute protection (MATH.md Theorem 1.11):                   │
/// │    eps[n] = H(entropySource || D[n])                             │
/// │    Unknowable before epoch n-1 closes. Any nonce computed        │
/// │    before eps[n] is known has Pr[valid] = D[n]/2^256.           │
/// │    If blockhash window expired, prevrandao is folded             │
/// │    in as entropy source (emits EntropyFallback).                 │
/// │                                                                  │
/// │  Reentrancy: nonReentrant on all ETH-moving functions.           │
/// │  CEI order: all state updates before any external call.          │
/// │                                                                  │
/// │  CREATE2 GENESIS INITIALIZATION:                                 │
/// │    When Anvil256 is deployed via Anvil256Factory (CREATE2), the  │
/// │    constructor defers genesis so that Uniswap's                  │
/// │    balanceOf callback into address(this) never hits an empty     │
/// │    bytecode slot.  initializePool() must be called atomically    │
/// │    in the same transaction by the factory.  If initializePool()  │
/// │    is never called, mine() reverts with PoolNotInitialized.      │
/// └─────────────────────────────────────────────────────────────────┘
///
contract Anvil256 is ERC20, ReentrancyGuard, IAnvil256 {
    using LiquidityBootstrap for LiquidityBootstrap.State;

    /* ══════════════════════════════════════════════════════════════
       IMMUTABLE ECONOMIC CONSTANTS
    ══════════════════════════════════════════════════════════════ */

    /// @notice Hard supply cap enforced both proactively in mine() and finally in _update.
    uint256 public constant MAX_SUPPLY        = 21_000_000 ether;

    /// @notice Miner reward for the first 210,000 epochs, before the 10% POL reserve mint.
    uint256 public constant INITIAL_REWARD    = 50 ether;

    /// @notice Epochs per halving interval.
    uint256 public constant HALVING_INTERVAL  = 210_000;

    /// @notice Reward is defined as zero after 64 right-shift halvings.
    uint256 public constant MAX_HALVINGS      = 64;

    /// @notice PI controller setpoint for epoch duration (seconds).
    uint256 public constant TARGET_EPOCH_TIME = 120;

    /// @notice Epochs per difficulty rebase period.
    uint256 public constant ADJUSTMENT_PERIOD = 2_016;

    /// @notice Target seconds per rebase period (2016 × 120 s).
    uint256 public constant TARGET_WINDOW     = ADJUSTMENT_PERIOD * TARGET_EPOCH_TIME;

    /* ══════════════════════════════════════════════════════════════
       FEE CONSTANTS
    ══════════════════════════════════════════════════════════════ */

    /// @notice Protocol fee in micro-USD. 100,000 micro-USD = $0.10.
    uint256 public constant FEE_MICRO_USD        = 100_000;

    /// @notice Fee share reserved as ETH liquidity. 5,000 / 10,000 = 50%.
    uint256 public constant LIQUIDITY_FEE_BPS    = 5_000;

    /// @notice Extra minted ANVL reserved for LP. 1,000 / 10,000 = 10% of miner reward.
    uint256 public constant LP_REWARD_BPS        = 1_000;

    uint256 internal constant BPS_DENOMINATOR    = 10_000;

    /// @notice Reject oracle answers older than this (seconds).
    uint256 public constant ORACLE_MAX_STALENESS  = 24 hours;

    /* ══════════════════════════════════════════════════════════════
       GAS BUDGETS FOR OUTBOUND CALLS
    ══════════════════════════════════════════════════════════════ */

    uint256 internal constant FEE_TRANSFER_GAS    = 80_000;
    uint256 internal constant REFUND_TRANSFER_GAS = 80_000;
    uint256 internal constant SWEEP_TRANSFER_GAS  = 80_000;

    /* ══════════════════════════════════════════════════════════════
       IMMUTABLE ADDRESSES
    ══════════════════════════════════════════════════════════════ */

    /// @inheritdoc IAnvil256
    address public immutable override feeRecipient;

    /// @notice Chainlink-compatible ETH/USD aggregator on the deployment chain.
    AggregatorV3Interface public immutable ethUsdFeed;

    /// @inheritdoc IAnvil256
    address public immutable override uniswapFactory;

    /// @inheritdoc IAnvil256
    address public immutable override uniswapPositionManager;

    /// @inheritdoc IAnvil256
    address public immutable override weth;

    /// @inheritdoc IAnvil256
    bytes32 public immutable override genesisBlockHash;

    /* ══════════════════════════════════════════════════════════════
       MUTABLE STATE — EPOCH / DIFFICULTY
    ══════════════════════════════════════════════════════════════ */

    /// @inheritdoc IAnvil256
    uint256 public override currentEpoch;

    /// @inheritdoc IAnvil256
    uint256 public override currentDifficulty;

    /// @inheritdoc IAnvil256
    uint256 public override periodStartTime;

    /// @inheritdoc IAnvil256
    uint256 public override periodIndex;

    /// @inheritdoc IAnvil256
    int256 public override integralErrorWad;

    /* ══════════════════════════════════════════════════════════════
       MUTABLE STATE — CASCADE POW
    ══════════════════════════════════════════════════════════════ */

    /// @inheritdoc IAnvil256
    mapping(address => uint64) public override minerEpochCount;

    /// @inheritdoc IAnvil256
    bytes32 public override epochEntropy;

    /// @inheritdoc IAnvil256
    uint256 public override lastMineBlock;

    /* ══════════════════════════════════════════════════════════════
       SECURITY EVENTS
    ══════════════════════════════════════════════════════════════ */

    event EntropyFallback(uint256 indexed epoch, bytes32 source);

    /* ══════════════════════════════════════════════════════════════
       MUTABLE STATE — FEE ACCOUNTING
    ══════════════════════════════════════════════════════════════ */

    uint256 public stuckFeesWei;

    /// @inheritdoc IAnvil256
    uint256 public override lpReserveEthWei;

    /// @inheritdoc IAnvil256
    uint256 public override lpReserveTokenWei;

    /// @inheritdoc IAnvil256
    mapping(address => uint256) public override pendingRefundsWei;

    /* ══════════════════════════════════════════════════════════════
       MUTABLE STATE — NCT MINER WINDOW
    ══════════════════════════════════════════════════════════════ */

    MinerWindow.State internal _window;

    /// @dev Protocol-owned ANVL/WETH bootstrap state. LP NFTs are minted to
    ///      address(this); this contract intentionally exposes no collect,
    ///      decreaseLiquidity, transfer, or rescue function for those NFTs.
    LiquidityBootstrap.State internal _liquidity;

    /* ══════════════════════════════════════════════════════════════
       CREATE2 GENESIS INIT STATE
       ─────────────────────────────────────────────────────────────
        Factory deployment uses msg.value == 0 to defer Uniswap genesis until
        bytecode exists at address(this). Direct deployment uses msg.value >=
        SEED_ETH_WEI and runs genesis inline. In the factory path:

            constructor: _genesisSkipped = true, store sqrtPriceX96
            factory:     initializePool{value: seedEth}(sqrtPriceX96)
            mine():      blocked while _genesisSkipped == true

        The stored sqrtPriceX96 is a commit-reveal guard: an arbitrary caller may
        complete initialization, but cannot alter the initial pool price.
    ══════════════════════════════════════════════════════════════ */

    /// @dev True when genesis was skipped in the constructor and
    ///      initializePool() has not yet been called.
    bool private _genesisSkipped;

    /// @dev Stored sqrtPriceX96 for use by initializePool().
    ///      Zeroed after initializePool() succeeds.
    uint160 private _pendingSqrtPriceX96;

    /* ══════════════════════════════════════════════════════════════
       CONSTRUCTOR
    ══════════════════════════════════════════════════════════════ */

    /// @notice Deploy Anvil256.
    ///
    /// @dev    DIRECT DEPLOY (legacy / testing):
    ///           Send msg.value >= SEED_ETH_WEI.  Genesis runs inline.
    ///           Suffers from the EXTCODESIZE=0 bug on any fork of Uniswap
    ///           that does EXTCODESIZE checks in its callback path.
    ///           Use Anvil256Factory for production.
    ///
    ///         FACTORY DEPLOY (CREATE2, recommended):
    ///           Anvil256Factory calls this constructor with msg.value = 0.
    ///           Genesis is skipped; initializePool() is called immediately
    ///           after by the factory in the same transaction.
    ///           EXTCODESIZE(address(this)) > 0 when Uniswap callbacks fire.
    ///
    ///         Fee recipient separation is enforced at construction time:
    ///           feeRecipient != deployer and feeRecipient != address(0).
    ///         This prevents the deployer from both launching the contract and
    ///         being the dev-fee sink in the same transaction context.
    ///
    /// @param _initialDifficulty  Difficulty at epoch 0.  Must be > 0.
    /// @param _feeRecipient       Dev wallet.  Must != address(0) and != msg.sender.
    /// @param _ethUsdFeed         Chainlink ETH/USD aggregator.
    /// @param _uniswapFactory         Uniswap v3 factory.
    /// @param _uniswapPositionManager Uniswap v3 NonfungiblePositionManager.
    /// @param _weth                   WETH9 address.
    /// @param _sqrtPriceX96           Initial pool sqrt price.
    constructor(
        uint256 _initialDifficulty,
        address _feeRecipient,
        address _ethUsdFeed,
        address _uniswapFactory,
        address _uniswapPositionManager,
        address _weth,
        uint160 _sqrtPriceX96
    ) payable ERC20("Anvil256", "ANVL") {
        // ── Input validation ────────────────────────────────────────────
        if (_sqrtPriceX96 == 0)              revert InvalidSqrtPrice();
        if (_initialDifficulty == 0)         revert InvalidInitialDifficulty();
        if (_feeRecipient == address(0))     revert InvalidFeeRecipient();
        if (_feeRecipient == msg.sender)     revert FeeRecipientEqualsDeployer();
        if (_ethUsdFeed   == address(0))     revert InvalidOracle();
        if (_uniswapFactory         == address(0)) revert InvalidUniswapFactory();
        if (_uniswapPositionManager == address(0)) revert InvalidPositionManager();
        if (_weth                   == address(0)) revert InvalidWETH();

        // ── Immutables ──────────────────────────────────────────────────
        currentDifficulty      = _initialDifficulty;
        periodStartTime        = block.timestamp;
        feeRecipient           = _feeRecipient;
        ethUsdFeed             = AggregatorV3Interface(_ethUsdFeed);
        uniswapFactory         = _uniswapFactory;
        uniswapPositionManager = _uniswapPositionManager;
        weth                   = _weth;
        genesisBlockHash       = block.number > 0 ? blockhash(block.number - 1) : bytes32(0);

        // ── Genesis path selection ───────────────────────────────────────
        // msg.value is the explicit mode selector:
        //   >= SEED_ETH_WEI : direct deploy, run Uniswap genesis inline.
        //   == 0            : factory deploy, defer genesis to initializePool().
        //   otherwise       : reject partial seed funding.
        if (msg.value >= LiquidityBootstrap.SEED_ETH_WEI) {
            // ── Direct deploy path (legacy / local dev) ──────────────────
            // EXTCODESIZE == 0 here, so we use internal _approve() to avoid
            // the "call to non-contract address" revert that external
            // approve() would trigger.
            _mint(address(this), LiquidityBootstrap.SEED_TOKEN_WEI);
            _approve(
                address(this),
                _uniswapPositionManager,
                LiquidityBootstrap.SEED_TOKEN_WEI
            );
            _liquidity.genesis(
                _uniswapFactory,
                _uniswapPositionManager,
                _weth,
                address(this),
                _sqrtPriceX96,
                msg.value,
                LiquidityBootstrap.SEED_TOKEN_WEI
            );

            // Refund any excess above SEED_ETH_WEI. If refund fails, revert the
            // direct deploy path: otherwise deployer ETH would be trapped before
            // the protocol is live.
            uint256 seedRefund = msg.value - LiquidityBootstrap.SEED_ETH_WEI;
            if (seedRefund > 0) {
                (bool ok, ) = msg.sender.call{value: seedRefund, gas: REFUND_TRANSFER_GAS}("");
                if (!ok) revert SeedRefundFailed();
            }
        } else if (msg.value == 0) {
            // ── Factory (CREATE2) path ────────────────────────────────────
            // Genesis is deferred to initializePool().  Store the price for
            // later and mark genesis as pending.
            _genesisSkipped      = true;
            _pendingSqrtPriceX96 = _sqrtPriceX96;
        } else {
            // Partial ETH sent — not enough for seed, not zero.
            revert InsufficientSeedETH();
        }
    }

    /* ══════════════════════════════════════════════════════════════
       PERMISSIONLESS POOL INITIALIZER
       ─────────────────────────────────────────────────────────────
        Called by Anvil256Factory immediately after CREATE2 deployment in the
        same transaction. It is also permissionless by design: if a deployment
        path ever leaves genesis pending, any caller can supply seed ETH and
        complete initialization at the constructor-committed sqrtPriceX96.
    ══════════════════════════════════════════════════════════════ */

    /// @notice Initialize the Uniswap liquidity pool.
    ///
    /// @dev    Permissionless: anyone may call, but:
    ///           • Only valid when `_genesisSkipped == true` (i.e. deployed via
    ///             factory with msg.value == 0 in the constructor).
    ///           • Reverts if called more than once (PoolAlreadyCreated from
    ///             LiquidityBootstrap.genesis).
    ///           • Must be called before mine() will function (enforced by the
    ///             PoolNotInitialized guard at the top of mine()).
    ///
    ///         Why permissionless?
    ///           The factory calls it atomically so normally only the factory
    ///           triggers this path.  Making it permissionless means that if
    ///           the factory somehow leaves the contract in a half-initialized
    ///           state (e.g. a future upgraded factory), any external actor can
    ///           finish initialization by supplying the seed ETH — there is no
    ///           owner-only gate that could brick the protocol.
    ///
    /// @param sqrtPriceX96  Must match the value stored in _pendingSqrtPriceX96
    ///                      (the constructor argument).  Passing a different value
    ///                      reverts with SqrtPriceMismatch to prevent griefing.
    function initializePool(uint160 sqrtPriceX96)
        external
        payable
        nonReentrant
    {
        if (!_genesisSkipped)                     revert PoolAlreadyInitialized();
        if (sqrtPriceX96 != _pendingSqrtPriceX96) revert SqrtPriceMismatch();
        if (msg.value < LiquidityBootstrap.SEED_ETH_WEI) revert InsufficientSeedETH();

        // CEI: mark genesis complete before WETH/Uniswap calls. If any external
        // call reverts, the whole transaction reverts and these writes roll back.
        _genesisSkipped      = false;
        _pendingSqrtPriceX96 = 0;

        // Mint exactly the genesis LP seed. This is not a dev premine: the
        // recipient is address(this), and the immediately following genesis call
        // deposits it into the official ANVL/WETH full-range LP position.
        // Approve via internal _approve — at this point
        // EXTCODESIZE(address(this)) > 0 (constructor has returned), so we
        // could use the external approve path, but internal _approve is
        // equally correct and saves ~400 gas.
        _mint(address(this), LiquidityBootstrap.SEED_TOKEN_WEI);
        _approve(
            address(this),
            uniswapPositionManager,
            LiquidityBootstrap.SEED_TOKEN_WEI
        );

        // Call genesis — Uniswap callbacks back into this contract now work
        // because EXTCODESIZE(address(this)) > 0.
        _liquidity.genesis(
            uniswapFactory,
            uniswapPositionManager,
            weth,
            address(this),
            sqrtPriceX96,
            LiquidityBootstrap.SEED_ETH_WEI,
            LiquidityBootstrap.SEED_TOKEN_WEI
        );

        // Refund excess ETH to caller (factory relays it back to deployer).
        uint256 seedRefund = msg.value - LiquidityBootstrap.SEED_ETH_WEI;
        if (seedRefund > 0) {
            (bool ok, ) = msg.sender.call{value: seedRefund, gas: REFUND_TRANSFER_GAS}("");
            if (!ok) revert SeedRefundFailed();
        }
    }

    /* ══════════════════════════════════════════════════════════════
       VIEW FUNCTIONS
    ══════════════════════════════════════════════════════════════ */

    /// @inheritdoc IAnvil256
    function currentReward() public view override returns (uint256) {
        return _rewardAt(currentEpoch);
    }

    /// @inheritdoc IAnvil256
    function currentFeeWei() public view override returns (uint256) {
        return FeeOracle.microUsdToWei(ethUsdFeed, FEE_MICRO_USD, ORACLE_MAX_STALENESS);
    }

    /// @inheritdoc IAnvil256
    function liquidityPool() external view override returns (address) {
        return _liquidity.pool;
    }

    /// @inheritdoc IAnvil256
    function seedPositionId() external view override returns (uint256) {
        return _liquidity.seedPositionId;
    }

    /// @inheritdoc IAnvil256
    function mainPositionId() external view override returns (uint256) {
        return _liquidity.mainPositionId;
    }

    /// @inheritdoc IAnvil256
    function liquidityLive() external view override returns (bool) {
        return _liquidity.livePhase;
    }

    /// @inheritdoc IAnvil256
    function liquidityTriggerSupply() external pure override returns (uint256) {
        return MAX_SUPPLY * LiquidityBootstrap.LP_TRIGGER_BPS / BPS_DENOMINATOR;
    }

    /// @notice True when the contract has been deployed via factory but
    ///         initializePool() has not yet been called.
    function pendingGenesis() external view returns (bool) {
        return _genesisSkipped;
    }

    /// @inheritdoc IAnvil256
    function getInner(address miner) public view override returns (bytes32) {
        bytes32 tau = keccak256(abi.encode(
            miner,
            minerEpochCount[miner],
            genesisBlockHash
        ));
        return keccak256(abi.encode(tau, currentEpoch));
    }

    /// @inheritdoc IAnvil256
    function isValidNonce(address miner, uint256 nonce)
        external view override returns (bool)
    {
        return uint256(_cascadeHash(getInner(miner), nonce)) < currentDifficulty;
    }

    /* ══════════════════════════════════════════════════════════════
       MINE
    ══════════════════════════════════════════════════════════════ */

    /// @inheritdoc IAnvil256
    function mine(uint256 nonce) external payable override nonReentrant {
        // Block mining until the official pool is initialized.
        if (_genesisSkipped) revert PoolNotInitialized();

        /* ── 1. Cascade PoW verification ──
           inner = H(H(msg.sender || gamma(msg.sender) || genesisBlockHash) || epoch)
           kappa = H(H(inner || nonce) || epochEntropy)
           Accept iff uint256(kappa) < currentDifficulty.

           The miner address is inside `inner`; a mempool observer cannot reuse
           the nonce from another address because their tau/inner differs. */
        bytes32 inner = getInner(msg.sender);
        bytes32 kappa = _cascadeHash(inner, nonce);
        if (uint256(kappa) >= currentDifficulty) revert InvalidNonce();

        /* ── 2. Fee check ──
           currentFeeWei() = microUSD * 10^(12 + oracleDecimals) / oracleAnswer.
           The fee is computed before state mutation so every successful mine
           carries the same accounting identity in the emitted event and state. */
        uint256 fee = currentFeeWei();
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);
        uint256 refund = msg.value - fee;
        uint256 lpFee = fee * LIQUIDITY_FEE_BPS / BPS_DENOMINATOR;
        uint256 devFee = fee - lpFee;

        /* ── 3. Reward and cap arithmetic ──
           Reward schedule: R(n) = INITIAL_REWARD >> floor(n / HALVING_INTERVAL).
           Mint order is miner first, POL second:

               rewardPaid = min(R(n), MAX_SUPPLY - totalSupply)
               lpTarget   = floor(rewardPaid * LP_REWARD_BPS / 10_000)
               lpPaid     = min(lpTarget, remainingAfterReward)

           This preserves miner priority at the terminal cap boundary while still
           ensuring the POL reserve can never push totalSupply above MAX_SUPPLY. */
        uint256 reward = _rewardAt(currentEpoch);
        if (reward == 0) revert MiningEnded();
        uint256 supply = totalSupply();
        if (supply >= MAX_SUPPLY) revert SupplyCapReached();

        uint256 remaining = MAX_SUPPLY - supply;
        if (reward > remaining) reward = remaining;

        uint256 lpReward = reward * LP_REWARD_BPS / BPS_DENOMINATOR;
        uint256 headroomAfterReward = remaining - reward;
        if (lpReward > headroomAfterReward) lpReward = headroomAfterReward;

        /* ── 4-11. EFFECTS ──
           All storage writes precede ETH transfers. This is the CEI boundary for
           mine(): even if feeRecipient or msg.sender are contracts, they cannot
           reenter because nonReentrant is active and all protocol state already
           reflects the completed epoch. */

        _mint(msg.sender, reward);
        if (lpReward > 0) {
            _mint(address(this), lpReward);
            lpReserveTokenWei += lpReward;
        }
        if (lpFee > 0) {
            lpReserveEthWei += lpFee;
        }

        emit Mined(msg.sender, currentEpoch, nonce, kappa, reward, fee);
        emit LiquidityReserved(lpFee, lpReward);

        uint256 epochJustMined = currentEpoch;
        unchecked { currentEpoch += 1; }

        unchecked { minerEpochCount[msg.sender] += 1; }

        MinerWindow.record(_window, epochJustMined, msg.sender);

        _maybeAdjustDifficulty();

        bytes32 entropySource;
        if (lastMineBlock == 0 || block.number - lastMineBlock > 255) {
            entropySource = keccak256(abi.encode(
                bytes32(block.prevrandao),
                block.timestamp
            ));
            emit EntropyFallback(currentEpoch, entropySource);
        } else {
            entropySource = keccak256(abi.encode(
                blockhash(block.number - 1),
                bytes32(block.prevrandao),
                block.timestamp
            ));
        }
        bytes32 newEntropy = keccak256(abi.encode(entropySource, currentDifficulty));
        epochEntropy  = newEntropy;
        lastMineBlock = block.number;
        emit EpochEntropySet(currentEpoch, newEntropy);

        /* ── 12-13. INTERACTIONS ──
           devFee is push-style for UX, but failure is non-fatal and accounted in
           stuckFeesWei. Refund failure is converted to pull-style pendingRefunds.
           Invariant after this block:
              devFee == delta(feeRecipient.balance) + delta(stuckFeesWei)
              refund == delta(msg.sender.balance)   + delta(pendingRefundsWei[msg.sender])
        */

        (bool okFee, ) = feeRecipient.call{value: devFee, gas: FEE_TRANSFER_GAS}("");
        if (!okFee) {
            stuckFeesWei += devFee;
            emit FeeStuck(devFee, feeRecipient);
        }

        if (refund > 0) {
            (bool okRef, ) = msg.sender.call{value: refund, gas: REFUND_TRANSFER_GAS}("");
            if (!okRef) {
                pendingRefundsWei[msg.sender] += refund;
                emit RefundQueued(msg.sender, refund);
            }
        }
    }

    /* ══════════════════════════════════════════════════════════════
       DEPLOY LP RESERVES
    ══════════════════════════════════════════════════════════════ */

    /// @inheritdoc IAnvil256
    function deployLiquidityReserves() external override nonReentrant {
        // Optimistic-zero pattern: clear reserves before external Uniswap calls,
        // then restore any unused amounts. A revert rolls back the zeroing. This
        // prevents callbacks from observing stale reserve balances as available.
        uint256 ethReserve   = lpReserveEthWei;
        uint256 tokenReserve = lpReserveTokenWei;

        lpReserveEthWei   = 0;
        lpReserveTokenWei = 0;

        (uint256 ethUsed, uint256 tokenUsed) = _liquidity.deployReserves(
            uniswapPositionManager,
            weth,
            address(this),
            ethReserve,
            tokenReserve,
            totalSupply(),
            MAX_SUPPLY
        );

        lpReserveEthWei   = ethReserve   - ethUsed;
        lpReserveTokenWei = tokenReserve - tokenUsed;
    }

    /// @inheritdoc IAnvil256
    function dripLiquidityReserves() external override nonReentrant {
        // Same accounting as deployLiquidityReserves(), but increases the already
        // live main NFT. This is intentionally permissionless and separate from
        // mine() so the hot mining path does not pay Uniswap gas every epoch.
        uint256 ethReserve   = lpReserveEthWei;
        uint256 tokenReserve = lpReserveTokenWei;

        lpReserveEthWei   = 0;
        lpReserveTokenWei = 0;

        (uint256 ethUsed, uint256 tokenUsed) = _liquidity.drip(
            uniswapPositionManager,
            weth,
            address(this),
            ethReserve,
            tokenReserve
        );

        lpReserveEthWei   = ethReserve   - ethUsed;
        lpReserveTokenWei = tokenReserve - tokenUsed;
    }

    /* ══════════════════════════════════════════════════════════════
       SWEEP STUCK FEES
    ══════════════════════════════════════════════════════════════ */

    /// @inheritdoc IAnvil256
    function sweepStuckFees() external override nonReentrant {
        uint256 amt = stuckFeesWei;
        if (amt == 0) return;

        stuckFeesWei = 0;

        (bool ok, ) = feeRecipient.call{value: amt, gas: SWEEP_TRANSFER_GAS}("");
        if (ok) {
            emit FeesSwept(amt, feeRecipient);
        } else {
            stuckFeesWei = amt;
            emit FeesReQueued(amt, feeRecipient);
        }
    }

    /* ══════════════════════════════════════════════════════════════
       CLAIM REFUND
    ══════════════════════════════════════════════════════════════ */

    /// @inheritdoc IAnvil256
    function claimRefund() external override nonReentrant {
        uint256 amt = pendingRefundsWei[msg.sender];
        if (amt == 0) revert NoPendingRefund();

        pendingRefundsWei[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amt}("");
        if (!ok) {
            pendingRefundsWei[msg.sender] = amt;
            revert ClaimFailed();
        }

        emit RefundClaimed(msg.sender, amt);
    }

    /* ══════════════════════════════════════════════════════════════
       INTERNALS
    ══════════════════════════════════════════════════════════════ */

    function _cascadeHash(bytes32 inner, uint256 nonce)
        internal view returns (bytes32)
    {
        // abi.encode is intentionally used instead of abi.encodePacked so tuple
        // boundaries remain unambiguous across bytes32/uint256 and bytes32/bytes32.
        bytes32 mid = keccak256(abi.encode(inner, nonce));
        return keccak256(abi.encode(mid, epochEntropy));
    }

    function _rewardAt(uint256 epoch) internal pure returns (uint256) {
        // Solidity right shift on uint256 is exact floor division by 2^halvings.
        // Once halvings >= 64, the economic schedule is explicitly terminated
        // rather than relying on a microscopic non-zero wei reward tail.
        uint256 halvings = epoch / HALVING_INTERVAL;
        if (halvings >= MAX_HALVINGS) return 0;
        return INITIAL_REWARD >> halvings;
    }

    function _maybeAdjustDifficulty() internal {
        if (currentEpoch % ADJUSTMENT_PERIOD != 0) return;

        uint256 actualWindow = block.timestamp - periodStartTime;
        uint256 oldD         = currentDifficulty;

        // MinerWindow returns a non-positive concentration signal. PIController
        // subtracts it, so concentration contributes a non-negative penalty in
        // log-difficulty space: u = u_pi + |u_nct|.
        int256 uNct = MinerWindow.nctSignal(_window);

        (uint256 newD, int256 newI, int256 u) = PIController.step(
            oldD,
            actualWindow,
            TARGET_WINDOW,
            integralErrorWad,
            uNct
        );

        currentDifficulty = newD;
        integralErrorWad  = newI;
        periodStartTime   = block.timestamp;
        unchecked { periodIndex += 1; }

        emit DifficultyAdjusted(
            periodIndex,
            oldD,
            newD,
            actualWindow,
            TARGET_WINDOW,
            newI,
            u
        );
    }

    /* ══════════════════════════════════════════════════════════════
       ERC20 SUPPLY CAP SAFETY NET
    ══════════════════════════════════════════════════════════════ */

    function _update(address from, address to, uint256 value) internal override {
        // Final cap safety net for every mint path. mine() already does explicit
        // cap truncation for miner/POL ordering, but genesis and any future
        // internal mint path still pass through this invariant gate.
        if (from == address(0) && totalSupply() + value > MAX_SUPPLY) {
            revert SupplyCapReached();
        }
        super._update(from, to, value);
    }

    /* ══════════════════════════════════════════════════════════════
       ETH CUSTODY
    ══════════════════════════════════════════════════════════════ */

    receive() external payable {
        revert DirectETHNotAccepted();
    }
}
