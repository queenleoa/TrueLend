// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {LendingVault} from "../src/LendingVault.sol";

/// The test contract plays the hook role (vault's deployer == hook).
contract LendingVaultTest is Test {
    MockERC20 token;
    LendingVault vault;

    address lender = makeAddr("lender");
    address lender2 = makeAddr("lender2");
    address borrower = makeAddr("borrower");

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        // base 0%, slope1 4% to kink 80%, slope2 100%, cap 90%, reserve 10%, ceiling 400%
        vault = new LendingVault(ERC20(address(token)), address(this), 0, 400, 8000, 10_000, 9000, 1000, 40_000);

        token.mint(lender, 1_000_000e6);
        token.mint(lender2, 1_000_000e6);
        vm.prank(lender);
        token.approve(address(vault), type(uint256).max);
        vm.prank(lender2);
        token.approve(address(vault), type(uint256).max);
        token.approve(address(vault), type(uint256).max); // hook repayments
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(amount, who);
    }

    // ------------------------------------------------------------- lender basics

    function test_depositRedeem_roundTrip() public {
        uint256 shares = _deposit(lender, 100_000e6);
        assertEq(vault.totalAssets(), 100_000e6);
        vm.prank(lender);
        uint256 assets = vault.redeem(shares, lender);
        assertApproxEqAbs(assets, 100_000e6, 1);
        assertEq(token.balanceOf(lender), 1_000_000e6 - 100_000e6 + assets);
    }

    function test_sharePriceStartsAtOne() public {
        uint256 shares = _deposit(lender, 1000e6);
        assertApproxEqRel(shares, 1000e6 * 1e6, 1e12); // virtual-offset scale (1e6 shares/asset)
        assertApproxEqAbs(vault.convertToAssets(shares), 1000e6, 1);
    }

    function test_inflationAttack_blunted() public {
        // attacker: tiny deposit + big donation, then victim deposits
        _deposit(lender, 1); // attacker's 1 unit
        token.mint(address(vault), 10_000e6); // donation
        uint256 victimShares = _deposit(lender2, 5_000e6);
        // victim must retain nearly all value (loss bounded by virtual offset)
        uint256 victimAssets = vault.convertToAssets(victimShares);
        assertGt(victimAssets, 4_999e6);
    }

    function test_redeem_revertsWhenCashLent() public {
        _deposit(lender, 100_000e6);
        vault.borrow(85_000e6, borrower);
        uint256 shares = vault.balanceOf(lender);
        vm.prank(lender);
        vm.expectRevert(LendingVault.InsufficientCash.selector);
        vault.redeem(shares, lender);
        // partial redeem within cash works
        vm.prank(lender);
        vault.redeem(shares / 10, lender);
    }

    // ------------------------------------------------------------- borrow side

    function test_borrow_onlyHook() public {
        _deposit(lender, 100_000e6);
        vm.prank(lender);
        vm.expectRevert(LendingVault.OnlyHook.selector);
        vault.borrow(1e6, lender);
    }

    function test_borrow_utilizationCap() public {
        _deposit(lender, 100_000e6);
        // 90% cap: 90_000 borrow ok, 90_001 reverts
        vault.borrow(90_000e6, borrower);
        vm.expectRevert(LendingVault.UtilizationCapExceeded.selector);
        vault.borrow(1e6, borrower);
    }

    function test_borrow_transfersToReceiver() public {
        _deposit(lender, 100_000e6);
        uint256 debtShares = vault.borrow(40_000e6, borrower);
        assertEq(token.balanceOf(borrower), 40_000e6);
        assertApproxEqAbs(vault.debtAssetsForShares(debtShares), 40_000e6, 1);
        assertEq(vault.utilizationBps(), 4000);
    }

    // ------------------------------------------------------------- interest

    function test_rateCurve() public view {
        assertEq(vault.rateBps(0), 0);
        assertEq(vault.rateBps(4000), 200); // half-kink: 4% * 4000/8000 = 2%
        assertEq(vault.rateBps(8000), 400); // at kink: 4%
        assertEq(vault.rateBps(9000), 400 + 5000); // halfway up slope2: 4% + 100%*(10/20)
        assertEq(vault.rateBps(10_000), 400 + 10_000); // full: 104%
    }

    function test_accrual_oneYear() public {
        _deposit(lender, 100_000e6);
        uint256 debtShares = vault.borrow(50_000e6, borrower);

        skip(365 days);
        vault.accrue();

        // U = 50%, rate = 4% * 50/80 = 2.5% APR -> 1,250 interest
        uint256 debt = vault.debtAssetsForShares(debtShares);
        assertApproxEqRel(debt, 51_250e6, 1e15);
        // reserves take 10%: 125; lenders get 1,125
        assertApproxEqRel(vault.reserves(), 125e6, 1e15);
        assertApproxEqRel(vault.totalAssets(), 101_125e6, 1e15);
        // share price rose accordingly
        uint256 lenderAssets = vault.convertToAssets(vault.balanceOf(lender));
        assertApproxEqRel(lenderAssets, 101_125e6, 1e15);
    }

    function test_accrual_isIdempotentWithinBlock() public {
        _deposit(lender, 100_000e6);
        vault.borrow(50_000e6, borrower);
        skip(30 days);
        vault.accrue();
        uint256 index = vault.borrowIndex();
        vault.accrue();
        assertEq(vault.borrowIndex(), index);
    }

    function test_rateCeiling_caps() public view {
        // curve at 100% util = 104% APR < ceiling; verify ceiling would clamp
        assertLe(vault.rateBps(10_000), 40_000);
    }

    // ------------------------------------------------------------- repay

    function test_repay_partialAndFull() public {
        _deposit(lender, 100_000e6);
        uint256 debtShares = vault.borrow(50_000e6, borrower);
        skip(365 days);
        vault.accrue();

        token.mint(address(this), 60_000e6);
        // partial: repay 20k
        (uint256 burned1, uint256 used1) = vault.repay(20_000e6, debtShares);
        assertApproxEqAbs(used1, 20_000e6, 1);
        debtShares -= burned1;

        // full: repay remaining debt (overpay attempt: excess not pulled)
        uint256 remaining = vault.debtAssetsForShares(debtShares);
        uint256 balBefore = token.balanceOf(address(this));
        (uint256 burned2, uint256 used2) = vault.repay(remaining + 5_000e6, debtShares);
        assertEq(burned2, debtShares);
        assertApproxEqAbs(used2, remaining, 2);
        assertApproxEqAbs(balBefore - token.balanceOf(address(this)), used2, 0);
        assertEq(vault.totalBorrowShares(), 0);
    }

    function test_repay_roundingNeverUnderburns() public {
        _deposit(lender, 100_000e6);
        uint256 debtShares = vault.borrow(1_000e6, borrower);
        skip(17 weeks);
        token.mint(address(this), 2_000e6);
        uint256 debt = vault.debtAssetsForShares(debtShares);
        (uint256 burned, uint256 used) = vault.repay(debt + 1, debtShares);
        assertEq(burned, debtShares, "full debt extinguished");
        assertLe(used, debt + 1);
    }

    // ------------------------------------------------------------- write-off waterfall

    function test_writeOff_reservesFirst_thenShareHaircut() public {
        _deposit(lender, 100_000e6);
        uint256 debtShares = vault.borrow(50_000e6, borrower);
        skip(4 * 365 days); // build reserves: 2.5%*4y = 10% interest, 10% to reserves = ~500
        vault.accrue();
        uint256 reservesBefore = vault.reserves();
        assertGt(reservesBefore, 0);

        uint256 lenderAssetsBefore = vault.convertToAssets(vault.balanceOf(lender));

        // write off 10% of the position's debt shares
        uint256 lost = debtShares / 10;
        uint256 shortfallAssets = vault.debtAssetsForShares(lost);
        uint256 uncovered = vault.writeOff(lost);

        assertEq(uncovered, shortfallAssets - reservesBefore, "reserves absorbed first");
        assertEq(vault.reserves(), 0);
        uint256 lenderAssetsAfter = vault.convertToAssets(vault.balanceOf(lender));
        // lenders lose only the uncovered part
        assertApproxEqAbs(lenderAssetsBefore - lenderAssetsAfter, uncovered, 2);
    }

    function test_writeOff_fullyCoveredByReserves() public {
        _deposit(lender, 100_000e6);
        uint256 debtShares = vault.borrow(70_000e6, borrower);
        skip(10 * 365 days);
        vault.accrue();
        uint256 lenderAssetsBefore = vault.convertToAssets(vault.balanceOf(lender));

        // tiny write-off, big reserves
        uint256 uncovered = vault.writeOff(debtShares / 1000);
        assertEq(uncovered, 0);
        // lender value untouched
        assertGe(vault.convertToAssets(vault.balanceOf(lender)), lenderAssetsBefore - 2);
    }

    // ------------------------------------------------------------- fuzz

    function testFuzz_depositRedeem_neverProfitsAttacker(uint256 a, uint256 b) public {
        a = bound(a, 1e6, 500_000e6);
        b = bound(b, 1e6, 500_000e6);
        uint256 s1 = _deposit(lender, a);
        uint256 s2 = _deposit(lender2, b);
        vm.prank(lender);
        uint256 out1 = vault.redeem(s1, lender);
        vm.prank(lender2);
        uint256 out2 = vault.redeem(s2, lender2);
        // nobody withdraws more than they put in (no interest was generated)
        assertLe(out1, a);
        assertLe(out2, b);
        assertGe(out1 + 2, a - 2); // and loses at most rounding dust
        assertGe(out2 + 2, b - 2);
    }

    function testFuzz_borrowRepay_conservation(uint256 dep, uint256 bor, uint256 dt) public {
        dep = bound(dep, 1_000e6, 900_000e6);
        bor = bound(bor, 1e6, dep * 9 / 10 - 1e6);
        dt = bound(dt, 1, 2 * 365 days);

        _deposit(lender, dep);
        uint256 debtShares = vault.borrow(bor, borrower);
        skip(dt);
        vault.accrue();

        uint256 debt = vault.debtAssetsForShares(debtShares);
        assertGe(debt, bor); // interest never negative
        token.mint(address(this), debt + 1e6);
        (uint256 burned,) = vault.repay(debt + 1e6, debtShares);
        assertEq(burned, debtShares);

        // vault made whole + interest: lender can now redeem >= deposit
        uint256 lenderAssets = vault.convertToAssets(vault.balanceOf(lender));
        assertGe(lenderAssets + 2, dep);
    }

    /// The invariant the LeverageRouter's close path stands on: repaying ONE WEI
    /// more than debtAssetsForShares(shares) always burns every share. Repaying
    /// the exact debt can burn one share too few — debtOf floors shares·index/WAD
    /// and repay() floors assets·WAD/index, and floor∘floor can lose a share —
    /// but (debt+1)·WAD/index strictly exceeds the share count, so the cap binds.
    function testFuzz_repay_debtPlusOneWei_alwaysClearsAllShares(uint256 bor, uint256 dt) public {
        _deposit(lender, 500_000e6);
        bor = bound(bor, 1e6, 400_000e6);
        dt = bound(dt, 1, 730 days);

        uint256 debtShares = vault.borrow(bor, address(this));
        skip(dt);
        token.mint(address(this), bor); // cover accrued interest comfortably

        uint256 debt = vault.debtAssetsForShares(debtShares);
        (uint256 burned, uint256 used) = vault.repay(debt + 1, debtShares);
        assertEq(burned, debtShares, "all shares burned");
        assertEq(vault.totalBorrowShares(), 0);
        assertLe(used, debt + 1, "never consumes more than offered");
    }
}
