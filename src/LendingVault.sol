// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @title LendingVault
/// @notice Per-currency lender vault for TrueLend. Lenders deposit the borrowable
/// asset and receive shares; the hook (deployer) is the only borrower.
///
/// Accounting model:
///  - Lender side: ERC-20 shares over `totalAssets()` = cash + outstanding debt
///    (reserves excluded). Virtual-offset conversion blunts inflation attacks.
///  - Borrow side: a global `borrowIndex` (WAD) accrues interest linearly at the
///    kinked utilization rate; debt positions are tracked as index shares by the
///    hook. debtAssets(shares) = shares * borrowIndex / WAD.
///  - Reserves: a slice of accrued interest, first loss capital for `writeOff`.
///    Losses beyond reserves socialize pro-rata via the share price.
contract LendingVault is ERC20 {
    using SafeTransferLib for ERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    ERC20 public immutable asset;
    address public immutable hook;

    // interest rate model (immutable config)
    uint16 public immutable baseRateBps; // rate at U = 0
    uint16 public immutable slope1Bps; // added rate at U = kink
    uint16 public immutable kinkBps; // e.g. 8000
    uint16 public immutable slope2Bps; // added rate from kink to 100%
    uint16 public immutable utilCapBps; // hard borrow cap, e.g. 9000
    uint16 public immutable reserveFactorBps; // e.g. 1000
    uint32 public immutable rateCeilingBps; // absolute APR cap, e.g. 40000 (400%)

    uint256 public borrowIndex = WAD;
    uint256 public totalBorrowShares;
    uint256 public reserves; // asset units
    uint256 public totalUncoveredShortfall; // lifetime bad debt socialized to lenders
    uint64 public lastAccrual;

    event Deposited(address indexed lender, uint256 assets, uint256 shares);
    event Redeemed(address indexed lender, uint256 assets, uint256 shares);
    event Borrowed(address indexed receiver, uint256 assets, uint256 debtShares);
    event Repaid(uint256 assets, uint256 debtShares);
    event Accrued(uint256 interest, uint256 toReserves, uint256 newIndex);
    event WrittenOff(uint256 debtShares, uint256 shortfallAssets, uint256 fromReserves);

    error OnlyHook();
    error ZeroAmount();
    error UtilizationCapExceeded();
    error InsufficientCash();

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(
        ERC20 _asset,
        address _hook,
        uint16 _baseRateBps,
        uint16 _slope1Bps,
        uint16 _kinkBps,
        uint16 _slope2Bps,
        uint16 _utilCapBps,
        uint16 _reserveFactorBps,
        uint32 _rateCeilingBps
    ) ERC20(string.concat("TrueLend ", _asset.name()), string.concat("tl", _asset.symbol()), _asset.decimals()) {
        asset = _asset;
        hook = _hook;
        baseRateBps = _baseRateBps;
        slope1Bps = _slope1Bps;
        kinkBps = _kinkBps;
        slope2Bps = _slope2Bps;
        utilCapBps = _utilCapBps;
        reserveFactorBps = _reserveFactorBps;
        rateCeilingBps = _rateCeilingBps;
        lastAccrual = uint64(block.timestamp);
    }

    // ------------------------------------------------------------------ views

    function cash() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        return bal > reserves ? bal - reserves : 0;
    }

    /// @notice The borrow index as of now (storage index plus pending accrual),
    /// so every view is fresh even before accrue() is called this block.
    function currentBorrowIndex() public view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0 || totalBorrowShares == 0) return borrowIndex;
        uint256 debtAtStored = FullMath.mulDiv(totalBorrowShares, borrowIndex, WAD);
        uint256 total = cash() + debtAtStored;
        uint256 uBps = total == 0 ? 0 : FullMath.mulDiv(debtAtStored, BPS, total);
        uint256 r = rateBps(uBps);
        return borrowIndex + FullMath.mulDiv(borrowIndex, r * dt, BPS * YEAR);
    }

    function totalDebtAssets() public view returns (uint256) {
        return FullMath.mulDiv(totalBorrowShares, currentBorrowIndex(), WAD);
    }

    /// @notice Lender-owned assets: cash + debt owed back (reserves excluded).
    function totalAssets() public view returns (uint256) {
        return cash() + totalDebtAssets();
    }

    /// @notice Utilization in bps.
    function utilizationBps() public view returns (uint256) {
        uint256 debt = totalDebtAssets();
        uint256 total = cash() + debt;
        return total == 0 ? 0 : FullMath.mulDiv(debt, BPS, total);
    }

    /// @notice Current borrow APR in bps for a given utilization.
    function rateBps(uint256 uBps) public view returns (uint256) {
        uint256 r = baseRateBps;
        if (uBps <= kinkBps) {
            r += FullMath.mulDiv(slope1Bps, uBps, kinkBps);
        } else {
            uint256 excess = uBps - kinkBps;
            r += slope1Bps + FullMath.mulDiv(slope2Bps, excess, BPS - kinkBps);
        }
        return r > rateCeilingBps ? rateCeilingBps : r;
    }

    function debtAssetsForShares(uint256 debtShares) public view returns (uint256) {
        return FullMath.mulDiv(debtShares, currentBorrowIndex(), WAD);
    }

    /// @dev rounds debt shares UP — debt never understated.
    function debtSharesForAssets(uint256 assets) public view returns (uint256) {
        return FullMath.mulDivRoundingUp(assets, WAD, currentBorrowIndex());
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return FullMath.mulDiv(assets, totalSupply + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return FullMath.mulDiv(shares, totalAssets() + VIRTUAL_ASSETS, totalSupply + VIRTUAL_SHARES);
    }

    // ------------------------------------------------------------------ accrual

    function accrue() public {
        uint256 newIndex = currentBorrowIndex();
        lastAccrual = uint64(block.timestamp);
        uint256 indexDelta = newIndex - borrowIndex;
        if (indexDelta == 0) return;
        borrowIndex = newIndex;

        uint256 interest = FullMath.mulDiv(totalBorrowShares, indexDelta, WAD);
        uint256 toReserves = FullMath.mulDiv(interest, reserveFactorBps, BPS);
        reserves += toReserves; // rest of the interest accrues to lenders via totalAssets
        emit Accrued(interest, toReserves, borrowIndex);
    }

    // ------------------------------------------------------------------ lenders

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        accrue();
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposited(receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        accrue();
        assets = convertToAssets(shares);
        if (assets > cash()) revert InsufficientCash();
        _burn(msg.sender, shares);
        asset.safeTransfer(receiver, assets);
        emit Redeemed(msg.sender, assets, shares);
    }

    // ------------------------------------------------------------------ hook: borrow side

    /// @notice Borrow `assets` for `receiver`; returns the debt shares the hook
    /// must attribute to the borrowing position.
    function borrow(uint256 assets, address receiver) external onlyHook returns (uint256 debtShares) {
        if (assets == 0) revert ZeroAmount();
        accrue();
        uint256 cash_ = cash();
        if (assets > cash_) revert InsufficientCash();

        uint256 debtAfter = totalDebtAssets() + assets;
        uint256 totalAfter = cash_ - assets + debtAfter;
        // cross-multiplied: no floor-division rounding in the borrower's favor
        if (debtAfter * BPS > uint256(utilCapBps) * totalAfter) revert UtilizationCapExceeded();

        debtShares = debtSharesForAssets(assets);
        totalBorrowShares += debtShares;
        asset.safeTransfer(receiver, assets);
        emit Borrowed(receiver, assets, debtShares);
    }

    /// @notice Repay debt. Assets must already be approved by (or held at) the hook.
    /// @param assets asset amount being repaid (transferred from the hook)
    /// @param maxDebtShares position's remaining shares; burned shares are capped here
    /// @return sharesBurned debt shares extinguished
    /// @return assetsUsed assets actually consumed (excess is NOT pulled)
    function repay(uint256 assets, uint256 maxDebtShares)
        external
        onlyHook
        returns (uint256 sharesBurned, uint256 assetsUsed)
    {
        if (assets == 0) revert ZeroAmount();
        accrue();
        sharesBurned = FullMath.mulDiv(assets, WAD, borrowIndex); // rounds down: favors vault
        if (sharesBurned > maxDebtShares) sharesBurned = maxDebtShares;
        assetsUsed = FullMath.mulDivRoundingUp(sharesBurned, borrowIndex, WAD);
        if (assetsUsed > assets) assetsUsed = assets;
        totalBorrowShares -= sharesBurned;
        asset.safeTransferFrom(msg.sender, address(this), assetsUsed);
        emit Repaid(assetsUsed, sharesBurned);
    }

    /// @notice Extinguish unrecoverable debt shares. Reserves absorb the shortfall
    /// first; any remainder socializes pro-rata through the share price (the debt
    /// simply disappears from totalAssets).
    function writeOff(uint256 debtShares) external onlyHook returns (uint256 shortfallAfterReserves) {
        if (debtShares == 0) return 0;
        accrue();
        uint256 shortfall = debtAssetsForShares(debtShares);
        totalBorrowShares -= debtShares;

        uint256 fromReserves = shortfall > reserves ? reserves : shortfall;
        reserves -= fromReserves; // freed reserves stay in the vault -> back lenders
        shortfallAfterReserves = shortfall - fromReserves;
        totalUncoveredShortfall += shortfallAfterReserves;
        emit WrittenOff(debtShares, shortfall, fromReserves);
    }
}
