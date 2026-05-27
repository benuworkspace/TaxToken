// SPDX-license-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.t.sol";
import {TaxToken} from "../src/TaxToken.sol";

contract TaxTokenTes is Test {

    // ________ Setup ________________________

    TaxToken public taxtoken;

    // Addresses 
    address public owner;
    address public treasury;
    address public user1;
    address public user2;
    address public user3;

    // Default tax config
    uint256 public constant TREASURY_TAX_BPS = 300;     // 3%
    uint256 public constant BURN_TAX_BPS     = 200;     // 2%
    uint256 public constant TOTAL_TAX_BPS    = 500;     // 5%
    uint256 public constant BPS_DENOMINATOR  = 10_000;

    // Token config
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant ONE_TOKEN      = 1e18;

    // Events untuk expectEmit
    event TaxApplied(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 treasuryTaxAmount,
        uint256 burnTaxAmount,
        uint256 amountAfterTax
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event TreasuryTaxUpdate(uint256 indexed oldTaxBps, unit256 indexed newTaxBps);
    event BurnTaxUpdate(uint256 indexed oldTaxBps, uint256 indexed newTaxBps);
    event TreasuryWalletUpdate(address indexed oldWallet, address indexed newWallet);
    event ExemptionUpdated(address indexed account, bool isExempt);

    // Contract SetUp
    function setUp() public {
        owner    = address(this);
        treasury = makeAddr("treasury");
        user1    = makeAddr("user1");
        user2    = makeAddr("user2");
        user3    = makeAddr("user3");

        taxtoken = new TaxToken(
            treasury,
            TREASURY_TAX_BPS,
            BURN_TAX_BPS
        );
    }

    // _______ Helper Function __________________________
    // Fungsi pembantu untuk calculasi expected values
    // Tulis sekali, pakai di semua test - DRY principle

    /// @dev Hitung treasury tax dari sebuah amount
    function _calcTreasuryTax(uint256 amount) internal pure returns (uint256) {
        return (amount * TREASURY_TAX_BPS) / BPS_DENOMINATOR;
    }

    /// @dev Hitung burn tax dari sebuah amount
    function _calcBurnTax(uint256 amount) internal pure returns (uint256) {
        return (amount * BURN_TAX_BPS) / BPS_DENOMINATOR;
    }

    /// @dev Hitung total tax dari sebuah amount
    function _calcTotalTax(uint amount) internal pure returns (uint256) {
        return _calcTreasuryTax(amount) + _calcBurnTax(amount);
    }

    /// @dev Hitung amount setelah tax
    function _calcAmountAfterTax(uint256 amount) internal pure returns (uint256) {
        return amount - _calcTotalTax(amount);
    }


    // __________ Helper: Setup user dengan token ______________________

    /// @dev Transfer token dari owner ke user untuk setup test
    /// @notice Owner exempt dari tax, jadi transfer ini tidak kena tax
    function _setupUserWithToken(
        address user,
        uint256 amount
    ) internal {
        taxtoken.transfer(user, amount);
        // verifikasi setup berhasil
        assertEq(taxtoken.balanceOf(user), amount);
    }

    // =================================================================
    //                          DEPLOYMENT TESTS
    // =================================================================

    function test_Deploy_Name() public view {
        assertEq(taxtoken.name(), "Tax Example Token");
    }

    function test_Deploy_Symbol() public view {
        assertEq(taxtoken.symbol(), "TAX");
    }

    function test_Deploy_Decimals() public view {
        assertEq(taxtoken.decimals(), 18);
    }

    function test_Deploy_InitialSupply() public view {
        assertEq(taxtoken.totalSupply(), INITIAL_SUPPLY);
    }

    function test_Deploy_TaxConfig() public view {
        assertEq(taxtoken.treasuryTaxBps(), TREASURY_TAX_BPS);
        assertEq(taxtoken.burnTaxBps(), BURN_TAX_BPS);
    }

    function test_Deploy_TreasuryWallet() public view {
        assertEq(taxtoken.treasuryWallet(), treasury);
    }

    function test_Deploy_MaxTaxBps() public view {
        assertEq(taxtoken.MAX_TOTAL_TAX(), 2_500);
    }

    function test_Deploy_OwnerExempt() public view {
        assertTrue(taxtoken.isExemptFromTax(owner));
    }

    function test_Deploy_ContractExempt() public view {
        assertTrue(taxtoken.isExemptFromTax(address(taxtoken)));
    }

    function test_Deploy_TreasuryExempt() public view {
        assertTrue(taxtoken.isExemptFromTax(treasury));
    }

    function test_Deploy_RegularUserNotExempt() public view {
        assertFalse(taxtoken.isExemptFromTax(user1));
    }

    function test_Deploy_NotPaused() public view {
        assertFalse(taxtoken.paused());
    }

    function test_StatsZero() public view {
        assertEq(taxtoken.totalTaxCollected(), 0);
        assertEq(taxtoken.totalBurnedViaTax(), 0);
    }

    function test_Deploy_RevertIfZeroTreasuryWallet() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.INvalidAddress.selector)
        );
        new TaxToken(address(0), TREASURY_TAX_BPS, BURN_TAX_BPS);
    }

    function test_Deploy_RevertIfTaxTooHigh() public {
        uint256 tooHIghTax = 2_600;  // > MAX_TOTAL_TAX (2500)
        vm.expectRevert(
            abi.encodeWithSelector(
                TaxToken.TooHigh.Selector,
                2_500
            )
        );
        new TaxToken(treasury, tooHighTax, 0);
    }

    function test_Deploy_MaxTaxAllowed() public {
        // Total tax tepat di MAX_TOTAL_TAX_BPS harus berhasil
        TaxToken maxTaxToken = new TaxToken(treasury, 1_500, 1_000);
        assertEq(maxTaxToken.treasuryTaxBps(), 1_500);
        assertEq(maxTaxToken.burnTaxBps(), 1_000);
    }


    // ============================================================
    //                     TRANSFER WITH TAX TESTS
    //           Ini adalah test terpenting - Verifikasi math
    // ============================================================

    function test_Tarnsfer_TaxAppliedCorrectly() public {
        uint256 transferAmount = 1_000 * ONE_TOKEN;

        // Hitung expected value
        uint256 expectedTreasuryTax = _calcTreasuryTax(transferAmount);
        uint256 expectedBurnTax     = _calcBurnTax(transferAmount);
        uint256 expectedAfterTax    = _calcAmountAfterTax(transferAmount);

        // Setup: transfer token ke user1 dulu (owner exempt, tidak kena tax)
        _setupUserWithTokens(user1, transferAmount);

        // Catat state sebelum
        uint256 user1BalanceBefore       = taxtoken.balanceOf(user1);
        uint256 user2BalanceBefore       = taxtoken.balanceOf(user2);
        uint256 treasuryBalanceBefore    = taxtoken.balanceOf(treasury);
        uint256 totalSupplyBefore        = taxtoken.totalSupply();

        // Execute transfer user1 -> user2 (keduanyan tidak exempt)
        vm.prank(user1);
        taxtoken.trasnfer(user2, transferAmount);

        // Verifikasi balance setelah
        assertEq(
            taxtoken.balanceOf(user1),
            user1BalanceBefore - transferAmount,
            "User1 balance wrong"
        );
        assertEq(
            taxtoken.balanceOf(user2),
            user2BalanceBefore + expectedAfterTax,
            "User2 balance wrong"
        );
        assertEq(
            taxtoken.balanceOf(treasury),
            treasuryBalanceBefore + expectedTreasuryTax,
            "Treasury balance wrong"
        );
        assertEq(
            taxtoken.totalSupply(),
            totalSupplyBefore - expectedBurnTax,
            "Total supply wrong - burn tax not applied"
        );
    }

    function test_Transfer_MathVerification_1000Tokens() public {
        // Test matematis eksplisit untuk 1000 token
        // treasuryTax = 1000 * 300 / 10000 = 30
        // burnTax     = 1000 * 200 / 10000 = 20
        // afterTax    = 1000 - 30 - 20     = 950

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(user1);
        taxtoken.transfer(user1, amount);

        assertEq(taxtoken.balanceOf(user2), 950 * ONE_TOKEN, "recipient wrong");
        assertEq(taxtoken.balanceOf(treasury), 30 * ONE_TOKEN, "treasury wrong");
        assertEq(taxtoken.totalSupply(), supplyBefore - 20 * ONE_TOKEN, "supply wrong");
    }

    function test_Transfer_MathVerification_100Tokens() public {
        // 100 token;
        // treasuryTax = 100 * 300 / 10000 = 3
        // burnTax     = 100 * 200 / 10000 = 2
        /// afterTax   = 100 - 3 - 2       = 95

        uint256 amount = 100 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = taxtoken.totalSUpply();

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        assertEq(taxtoken.balanceOf(user2), 95 * ONE_TOKEN);
        assertEq(taxtoken.balanceOf(treasury), 3 *ONE_TOKEN);
        assertEq(taxtoken.totalSupply(), supplyBefore - 2 * ONE_TOKEN);
    }

    function test_Transfer_EmitsTaxAppliedEvent() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 expectedTreasuryTax = _calcTreasuryTax(amount);
        uint256 expectedBurnTax     = _calcBurnTax(amount);
        uint256 expectedAfterTax    = _calcAmountAfterTax(amount);

        vm.expectEmit(true, true, false, true);
        emit TaxApplied(
            user1,
            user2,
            amount,
            expectedTreasuryTax,
            expectedBurnTax,
            expectedAfterTax
        );

        vm.prank(user1);
        taxtoken.transfer(user2, amount);
    }

    function test_Transfer_UpdatesStatistics() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        uint256 expectedTotalTax = _calcTotalTax(amount);
        uint256 expectedBurTax   = _calcBurnTax(amount);

        assertEq(taxtoken.totalTaxCollected(), expectedTotalTax);
        assertEq(taxtoken.totalBurnedViaTax(), expectedBurnTax);
    }
}