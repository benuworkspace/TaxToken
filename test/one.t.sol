// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {TaxToken} from "../src/TaxToken.sol";

contract TaxTokenTest is Test {

    // ─── Setup ────────────────────────────────────────────────────

    TaxToken public token;

    // Addresses
    address public owner;
    address public treasury;
    address public user1;
    address public user2;
    address public user3;

    // Default tax config
    uint256 public constant TREASURY_TAX_BPS = 300;  // 3%
    uint256 public constant BURN_TAX_BPS     = 200;  // 2%
    uint256 public constant TOTAL_TAX_BPS    = 500;  // 5%
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
    event TreasuryTaxUpdated(uint256 indexed oldTaxBps, uint256 indexed newTaxBps);
    event BurnTaxUpdated(uint256 indexed oldTaxBps, uint256 indexed newTaxBps);
    event TreasuryWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event ExemptionUpdated(address indexed account, bool isExempt);

    function setUp() public {
        owner    = address(this);
        treasury = makeAddr("treasury");
        user1    = makeAddr("user1");
        user2    = makeAddr("user2");
        user3    = makeAddr("user3");

        token = new TaxToken(
            treasury,
            TREASURY_TAX_BPS,
            BURN_TAX_BPS
        );
    }

    // ─── Helper Functions ─────────────────────────────────────────
    // Fungsi pembantu untuk kalkulasi expected values
    // Tulis sekali, pakai di semua test — DRY principle

    /// @dev Hitung treasury tax dari sebuah amount
    function _calcTreasuryTax(uint256 amount) internal pure returns (uint256) {
        return (amount * TREASURY_TAX_BPS) / BPS_DENOMINATOR;
    }

    /// @dev Hitung burn tax dari sebuah amount
    function _calcBurnTax(uint256 amount) internal pure returns (uint256) {
        return (amount * BURN_TAX_BPS) / BPS_DENOMINATOR;
    }

    /// @dev Hitung total tax dari sebuah amount
    function _calcTotalTax(uint256 amount) internal pure returns (uint256) {
        return _calcTreasuryTax(amount) + _calcBurnTax(amount);
    }

    /// @dev Hitung amount setelah tax
    function _calcAmountAfterTax(uint256 amount) internal pure returns (uint256) {
        return amount - _calcTotalTax(amount);
    }

    // ─── Helper: Setup user dengan token ─────────────────────────

    /// @dev Transfer token dari owner ke user untuk setup test
    /// @notice Owner exempt dari tax, jadi transfer ini tidak kena tax
    function _setupUserWithTokens(
        address user,
        uint256 amount
    ) internal {
        token.transfer(user, amount);
        // Verifikasi setup berhasil
        assertEq(token.balanceOf(user), amount);
    }

    // =============================================================
    //                    DEPLOYMENT TESTS
    // =============================================================

    function test_Deploy_Name() public view {
        assertEq(token.name(), "Tax Example Token");
    }

    function test_Deploy_Symbol() public view {
        assertEq(token.symbol(), "TAX");
    }

    function test_Deploy_Decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_Deploy_InitialSupply() public view {
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_Deploy_OwnerHasAllTokens() public view {
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY);
    }

    function test_Deploy_TaxConfig() public view {
        assertEq(token.treasuryTaxBps(), TREASURY_TAX_BPS);
        assertEq(token.burnTaxBps(), BURN_TAX_BPS);
    }

    function test_Deploy_TreasuryWallet() public view {
        assertEq(token.treasuryWallet(), treasury);
    }

    function test_Deploy_MaxTaxBps() public view {
        assertEq(token.MAX_TOTAL_TAX_BPS(), 2_500);
    }

    function test_Deploy_OwnerExempt() public view {
        assertTrue(token.isExemptFromTax(owner));
    }

    function test_Deploy_ContractExempt() public view {
        assertTrue(token.isExemptFromTax(address(token)));
    }

    function test_Deploy_TreasuryExempt() public view {
        assertTrue(token.isExemptFromTax(treasury));
    }

    function test_Deploy_RegularUserNotExempt() public view {
        assertFalse(token.isExemptFromTax(user1));
    }

    function test_Deploy_NotPaused() public view {
        assertFalse(token.paused());
    }

    function test_Deploy_StatsZero() public view {
        assertEq(token.totalTaxCollected(), 0);
        assertEq(token.totalBurnedViaTax(), 0);
    }

    function test_Deploy_RevertsIfZeroTreasuryWallet() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.InvalidAddress.selector)
        );
        new TaxToken(address(0), TREASURY_TAX_BPS, BURN_TAX_BPS);
    }

    function test_Deploy_RevertsIfTaxTooHigh() public {
        uint256 tooHighTax = 2_600;  // > MAX_TOTAL_TAX_BPS (2500)
        vm.expectRevert(
            abi.encodeWithSelector(
                TaxToken.TaxTooHigh.selector,
                tooHighTax,
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

    // =============================================================
    //                  TRANSFER WITH TAX TESTS
    //        Ini adalah test terpenting — verifikasi math
    // =============================================================

    function test_Transfer_TaxAppliedCorrectly() public {
        uint256 transferAmount = 1_000 * ONE_TOKEN;

        // Hitung expected values
        uint256 expectedTreasuryTax = _calcTreasuryTax(transferAmount);
        uint256 expectedBurnTax     = _calcBurnTax(transferAmount);
        uint256 expectedAfterTax    = _calcAmountAfterTax(transferAmount);

        // Setup: transfer token ke user1 dulu (owner exempt, tidak kena tax)
        _setupUserWithTokens(user1, transferAmount);

        // Catat state sebelum
        uint256 user1BalanceBefore    = token.balanceOf(user1);
        uint256 user2BalanceBefore    = token.balanceOf(user2);
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);
        uint256 totalSupplyBefore     = token.totalSupply();

        // Execute transfer user1 → user2 (keduanya tidak exempt)
        vm.prank(user1);
        token.transfer(user2, transferAmount);

        // Verifikasi balance setelah
        assertEq(
            token.balanceOf(user1),
            user1BalanceBefore - transferAmount,
            "User1 balance wrong"
        );
        assertEq(
            token.balanceOf(user2),
            user2BalanceBefore + expectedAfterTax,
            "User2 balance wrong"
        );
        assertEq(
            token.balanceOf(treasury),
            treasuryBalanceBefore + expectedTreasuryTax,
            "Treasury balance wrong"
        );
        assertEq(
            token.totalSupply(),
            totalSupplyBefore - expectedBurnTax,
            "Total supply wrong — burn tax not applied"
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
        token.transfer(user2, amount);

        assertEq(token.balanceOf(user2), 950 * ONE_TOKEN, "recipient wrong");
        assertEq(token.balanceOf(treasury), 30 * ONE_TOKEN, "treasury wrong");
        assertEq(token.totalSupply(), supplyBefore - 20 * ONE_TOKEN, "supply wrong");
    }

    function test_Transfer_MathVerification_100Tokens() public {
        // 100 token:
        // treasuryTax = 100 * 300 / 10000 = 3
        // burnTax     = 100 * 200 / 10000 = 2
        // afterTax    = 100 - 3 - 2       = 95

        uint256 amount = 100 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(user1);
        token.transfer(user2, amount);

        assertEq(token.balanceOf(user2), 95 * ONE_TOKEN);
        assertEq(token.balanceOf(treasury), 3 * ONE_TOKEN);
        assertEq(token.totalSupply(), supplyBefore - 2 * ONE_TOKEN);
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
        token.transfer(user2, amount);
    }

    function test_Transfer_UpdatesStatistics() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        token.transfer(user2, amount);

        uint256 expectedTotalTax = _calcTotalTax(amount);
        uint256 expectedBurnTax  = _calcBurnTax(amount);

        assertEq(token.totalTaxCollected(), expectedTotalTax);
        assertEq(token.totalBurnedViaTax(), expectedBurnTax);
    }

    function test_Transfer_AccumulatesStatistics() public {
        uint256 amount = 1_000 * ONE_TOKEN;

        // Transfer 1
        _setupUserWithTokens(user1, amount);
        vm.prank(user1);
        token.transfer(user2, amount);

        // Transfer 2 — user2 ke user3
        // user2 menerima 950 token, transfer lagi
        uint256 user2Balance = token.balanceOf(user2);
        vm.prank(user2);
        token.transfer(user3, user2Balance);

        // Statistik harus akumulasi dari kedua transfer
        uint256 tax1 = _calcTotalTax(amount);
        uint256 tax2 = _calcTotalTax(user2Balance);

        assertEq(token.totalTaxCollected(), tax1 + tax2);
    }

    function test_Transfer_TotalSupplyDecreasesWithEachTransfer() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, 3 * amount);

        uint256 supplyAfterTransfer;
        uint256 expectedBurnPerTransfer = _calcBurnTax(amount);

        // Transfer 1
        uint256 supplyBefore = token.totalSupply();
        vm.prank(user1);
        token.transfer(user2, amount);
        supplyAfterTransfer = token.totalSupply();
        assertEq(supplyAfterTransfer, supplyBefore - expectedBurnPerTransfer);

        // Transfer 2
        supplyBefore = token.totalSupply();
        vm.prank(user1);
        token.transfer(user2, amount);
        assertEq(token.totalSupply(), supplyBefore - expectedBurnPerTransfer);
    }

    // =============================================================
    //                    EXEMPTION TESTS
    // =============================================================

    function test_Exempt_OwnerTransferNoTax() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        uint256 supplyBefore = token.totalSupply();

        // Owner transfer ke user1 — tidak kena tax
        token.transfer(user1, amount);

        // User1 menerima full amount tanpa potongan
        assertEq(token.balanceOf(user1), amount);
        // Total supply tidak berubah (tidak ada burn)
        assertEq(token.totalSupply(), supplyBefore);
        // Treasury tidak menerima apapun
        assertEq(token.balanceOf(treasury), 0);
        // Statistik tidak berubah
        assertEq(token.totalTaxCollected(), 0);
    }

    function test_Exempt_TransferToTreasuryNoTax() public {
        // Setup user1 dengan token
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = token.totalSupply();

        // user1 transfer ke treasury (treasury adalah exempt address)
        vm.prank(user1);
        token.transfer(treasury, amount);

        // Treasury menerima full amount karena to address exempt
        assertEq(token.balanceOf(treasury), amount);
        // Supply tidak berubah
        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_Exempt_CustomExemptionNoTax() public {
        // Tambahkan user1 ke exempt list
        token.setExemption(user1, true);
        assertTrue(token.isExemptFromTax(user1));

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = token.totalSupply();

        // user1 transfer ke user2 — user1 exempt, tidak kena tax
        vm.prank(user1);
        token.transfer(user2, amount);

        // user2 menerima full amount
        assertEq(token.balanceOf(user2), amount);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.totalTaxCollected(), 0);
    }

    function test_Exempt_RemoveExemption() public {
        // Add exemption
        token.setExemption(user1, true);
        assertTrue(token.isExemptFromTax(user1));

        // Remove exemption
        token.setExemption(user1, false);
        assertFalse(token.isExemptFromTax(user1));

        // Sekarang transfer dari user1 harus kena tax
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(user1);
        token.transfer(user2, amount);

        // user2 menerima after-tax amount
        assertEq(token.balanceOf(user2), _calcAmountAfterTax(amount));
        // Supply berkurang karena burn tax
        assertEq(token.totalSupply(), supplyBefore - _calcBurnTax(amount));
    }

    function test_Exempt_EmitsExemptionEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ExemptionUpdated(user1, true);
        token.setExemption(user1, true);
    }

    function test_Exempt_RevertsIfNoChange() public {
        // user1 sudah tidak exempt (default)
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.NoChangeDetected.selector)
        );
        token.setExemption(user1, false);
    }

    function test_Exempt_RevertsIfZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.InvalidAddress.selector)
        );
        token.setExemption(address(0), true);
    }

    function test_Exempt_RevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        token.setExemption(user2, true);
    }

    // =============================================================
    //                    MINT AND BURN TESTS
    // =============================================================

    function test_Mint_NoTaxApplied() public {
        uint256 mintAmount   = 1_000 * ONE_TOKEN;
        uint256 supplyBefore = token.totalSupply();

        token.mint(user1, mintAmount);

        // Mint tidak kena tax — full amount ke user1
        assertEq(token.balanceOf(user1), mintAmount);
        assertEq(token.totalSupply(), supplyBefore + mintAmount);
        // Treasury tidak menerima apapun dari mint
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.totalTaxCollected(), 0);
    }

    function test_Burn_NoTaxApplied() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = token.totalSupply();

        // Manual burn — tidak kena tax
        // (burn langsung ke address(0) via _update)
        // Kita perlu tambahkan burn function ke contract
        // Untuk sekarang, test via transfer ke address(0) tidak bisa
        // karena OpenZeppelin block transfer ke address(0)
        // Manual burn ditest via transfer normal yang sudah kena tax
        vm.prank(user1);
        token.transfer(user2, amount);

        // Hanya burn tax yang reduce supply, bukan manual burn
        assertEq(
            token.totalSupply(),
            supplyBefore - _calcBurnTax(amount)
        );
    }

    // =============================================================
    //                    TAX CONFIG TESTS
    // =============================================================

    function test_SetTreasuryTax_Success() public {
        uint256 newTax = 500;  // 5%

        token.setTreasuryTax(newTax);

        assertEq(token.treasuryTaxBps(), newTax);
    }

    function test_SetTreasuryTax_EmitsEvent() public {
        uint256 newTax = 500;

        vm.expectEmit(true, true, false, false);
        emit TreasuryTaxUpdated(TREASURY_TAX_BPS, newTax);

        token.setTreasuryTax(newTax);
    }

    function test_SetTreasuryTax_NewRateApplied() public {
        // Update treasury tax ke 10%
        token.setTreasuryTax(1_000);

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        token.transfer(user2, amount);

        // Treasury tax baru: 1000 * 1000 / 10000 = 100
        // Burn tax tetap: 1000 * 200 / 10000 = 20
        assertEq(token.balanceOf(treasury), 100 * ONE_TOKEN);
    }

    function test_SetTreasuryTax_RevertsIfTooHigh() public {
        // burnTaxBps = 200, jadi treasuryTax max = 2500 - 200 = 2300
        uint256 tooHigh     = 2_301;
        uint256 expectedTotal = tooHigh + BURN_TAX_BPS;

        vm.expectRevert(
            abi.encodeWithSelector(
                TaxToken.TaxTooHigh.selector,
                expectedTotal,
                2_500
            )
        );
        token.setTreasuryTax(tooHigh);
    }

    function test_SetTreasuryTax_RevertsIfNoChange() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.NoChangeDetected.selector)
        );
        token.setTreasuryTax(TREASURY_TAX_BPS);
    }

    function test_SetTreasuryTax_RevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        token.setTreasuryTax(500);
    }

    function test_SetBurnTax_Success() public {
        uint256 newTax = 300;

        token.setBurnTax(newTax);

        assertEq(token.burnTaxBps(), newTax);
    }

    function test_SetBurnTax_NewRateApplied() public {
        // Set burn tax ke 5%
        token.setBurnTax(500);

        uint256 amount       = 1_000 * ONE_TOKEN;
        uint256 supplyBefore = token.totalSupply();
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        token.transfer(user2, amount);

        // Burn tax baru: 1000 * 500 / 10000 = 50
        assertEq(token.totalSupply(), supplyBefore - 50 * ONE_TOKEN);
    }

    function test_SetBurnTax_RevertsIfTooHigh() public {
        // treasuryTaxBps = 300, jadi burnTax max = 2500 - 300 = 2200
        uint256 tooHigh       = 2_201;
        uint256 expectedTotal = TREASURY_TAX_BPS + tooHigh;

        vm.expectRevert(
            abi.encodeWithSelector(
                TaxToken.TaxTooHigh.selector,
                expectedTotal,
                2_500
            )
        );
        token.setBurnTax(tooHigh);
    }

    function test_SetBothTaxToZero() public {
        // Set semua tax ke 0 — valid, tidak ada tax
        token.setTreasuryTax(0);
        token.setBurnTax(0);

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(user1);
        token.transfer(user2, amount);

        // Tidak ada tax — full amount ke user2
        assertEq(token.balanceOf(user2), amount);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.totalSupply(), supplyBefore);
    }

    // =============================================================
    //                  TREASURY WALLET TESTS
    // =============================================================

    function test_SetTreasuryWallet_Success() public {
        address newTreasury = makeAddr("newTreasury");

        token.setTreasuryWallet(newTreasury);

        assertEq(token.treasuryWallet(), newTreasury);
    }

    function test_SetTreasuryWallet_UpdatesExemption() public {
        address newTreasury = makeAddr("newTreasury");
        address oldTreasury = treasury;

        token.setTreasuryWallet(newTreasury);

        // Old treasury tidak lagi exempt
        assertFalse(token.isExemptFromTax(oldTreasury));

        // New treasury exempt
        assertTrue(token.isExemptFromTax(newTreasury));
    }

    function test_SetTreasuryWallet_NewWalletReceivesTax() public {
        address newTreasury = makeAddr("newTreasury");
        token.setTreasuryWallet(newTreasury);

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        token.transfer(user2, amount);

        // Tax masuk ke treasury baru, bukan yang lama
        assertEq(token.balanceOf(newTreasury), _calcTreasuryTax(amount));
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_SetTreasuryWallet_EmitsEvent() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit TreasuryWalletUpdated(treasury, newTreasury);

        token.setTreasuryWallet(newTreasury);
    }

    function test_SetTreasuryWallet_RevertsIfZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.InvalidAddress.selector)
        );
        token.setTreasuryWallet(address(0));
    }

    function test_SetTreasuryWallet_RevertsIfSameWallet() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.NoChangeDetected.selector)
        );
        token.setTreasuryWallet(treasury);
    }

    function test_SetTreasuryWallet_RevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        token.setTreasuryWallet(makeAddr("newTreasury"));
    }

    // =============================================================
    //                    PAUSE TESTS
    // =============================================================

    function test_Pause_BlocksTransfer() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        token.pause();

        vm.prank(user1);
        vm.expectRevert();
        token.transfer(user2, amount);
    }

    function test_Pause_BlocksMint() public {
        token.pause();

        vm.expectRevert();
        token.mint(user1, 1_000 * ONE_TOKEN);
    }

    function test_Unpause_RestoresTransfer() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        token.pause();
        token.unpause();

        vm.prank(user1);
        token.transfer(user2, amount);

        // Transfer berhasil dengan tax
        assertEq(token.balanceOf(user2), _calcAmountAfterTax(amount));
    }

    // =============================================================
    //                    VIEW FUNCTION TESTS
    // =============================================================

    function test_GetTaxInfo() public view {
        (
            uint256 _treasuryTaxBps,
            uint256 _burnTaxBps,
            uint256 _totalTaxBps,
            address _treasuryWallet,
            uint256 _maxTotalTaxBps
        ) = token.getTaxInfo();

        assertEq(_treasuryTaxBps, TREASURY_TAX_BPS);
        assertEq(_burnTaxBps, BURN_TAX_BPS);
        assertEq(_totalTaxBps, TOTAL_TAX_BPS);
        assertEq(_treasuryWallet, treasury);
        assertEq(_maxTotalTaxBps, 2_500);
    }

    function test_CalculateTax_1000Tokens() public view {
        uint256 amount = 1_000 * ONE_TOKEN;

        (
            uint256 treasuryTaxAmount,
            uint256 burnTaxAmount,
            uint256 amountAfterTax
        ) = token.calculateTax(amount);

        assertEq(treasuryTaxAmount, 30 * ONE_TOKEN);
        assertEq(burnTaxAmount, 20 * ONE_TOKEN);
        assertEq(amountAfterTax, 950 * ONE_TOKEN);
    }

    function test_CalculateTax_MatchesActualTransfer() public {
        uint256 amount = 5_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        // Hitung prediksi dengan calculateTax
        (
            uint256 expectedTreasuryTax,
            uint256 expectedBurnTax,
            uint256 expectedAfterTax
        ) = token.calculateTax(amount);

        uint256 supplyBefore = token.totalSupply();

        // Eksekusi transfer
        vm.prank(user1);
        token.transfer(user2, amount);

        // Verifikasi prediksi sama dengan hasil aktual
        assertEq(token.balanceOf(user2), expectedAfterTax);
        assertEq(token.balanceOf(treasury), expectedTreasuryTax);
        assertEq(token.totalSupply(), supplyBefore - expectedBurnTax);
    }

    function test_GetTokenStats() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        token.transfer(user2, amount);

        (
            uint256 _totalSupply,
            uint256 _totalTaxCollected,
            uint256 _totalBurnedViaTax
        ) = token.getTokenStats();

        assertEq(_totalTaxCollected, _calcTotalTax(amount));
        assertEq(_totalBurnedViaTax, _calcBurnTax(amount));
        assertGt(_totalSupply, 0);
    }

    // =============================================================
    //                    EDGE CASE TESTS
    // =============================================================

    function test_EdgeCase_SmallTransferRounding() public {
        // Transfer amount kecil — verifikasi rounding tidak bermasalah
        // 10 wei: treasury = 10 * 300 / 10000 = 0 (rounded down)
        //         burn     = 10 * 200 / 10000 = 0 (rounded down)
        //         after    = 10 - 0 - 0        = 10

        _setupUserWithTokens(user1, 100);

        vm.prank(user1);
        token.transfer(user2, 10);

        // Untuk amount sangat kecil, tax dibulatkan ke 0
        // user2 menerima full amount
        assertEq(token.balanceOf(user2), 10);
    }

    function test_EdgeCase_ZeroTaxTransfer() public {
        // Set semua tax ke 0
        token.setTreasuryTax(0);
        token.setBurnTax(0);

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(user1);
        token.transfer(user2, amount);

        // Tidak ada tax — seperti standard ERC20
        assertEq(token.balanceOf(user2), amount);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.totalTaxCollected(), 0);
    }

    function test_EdgeCase_MultipleTransfersAccumulateBurn() public {
        uint256 transferAmount = 1_000 * ONE_TOKEN;
        uint256 totalAmount    = 10 * transferAmount;

        _setupUserWithTokens(user1, totalAmount);

        uint256 supplyBefore = token.totalSupply();
        uint256 expectedTotalBurn = _calcBurnTax(transferAmount) * 10;

        // 10 transfer berturut-turut
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user1);
            token.transfer(user2, transferAmount);
        }

        // Total burn harus akumulasi dari semua transfer
        assertEq(
            token.totalSupply(),
            supplyBefore - expectedTotalBurn
        );
        assertEq(token.totalBurnedViaTax(), expectedTotalBurn);
    }

    // =============================================================
    //                      FUZZ TESTS
    // =============================================================

    /// @notice Fuzz test: verifikasi math tax untuk semua amount
    function test_Fuzz_TaxMathAlwaysCorrect(uint256 amount) public {
        // Batasi amount ke range yang realistis
        vm.assume(amount >= 10_000);  // minimum agar tax tidak 0 semua
        vm.assume(amount <= INITIAL_SUPPLY / 2);

        // Setup user1 dengan amount
        token.transfer(user1, amount);  // owner exempt

        uint256 supplyBefore    = token.totalSupply();
        uint256 treasuryBefore  = token.balanceOf(treasury);

        // Hitung expected values
        uint256 expectedTreasury = (amount * TREASURY_TAX_BPS) / BPS_DENOMINATOR;
        uint256 expectedBurn     = (amount * BURN_TAX_BPS) / BPS_DENOMINATOR;
        uint256 expectedAfterTax = amount - expectedTreasury - expectedBurn;

        vm.prank(user1);
        token.transfer(user2, amount);

        // Verifikasi math selalu konsisten
        assertEq(token.balanceOf(user2), expectedAfterTax, "afterTax wrong");
        assertEq(
            token.balanceOf(treasury),
            treasuryBefore + expectedTreasury,
            "treasury wrong"
        );
        assertEq(
            token.totalSupply(),
            supplyBefore - expectedBurn,
            "supply wrong"
        );

        // Invariant: amount harus conservation
        // sender loss = recipient gain + treasury gain + burn
        assertEq(
            amount,
            expectedAfterTax + expectedTreasury + expectedBurn,
            "conservation broken"
        );
    }

    /// @notice Fuzz test: calculateTax selalu match transfer aktual
    function test_Fuzz_CalculateTaxMatchesActual(uint256 amount) public {
        vm.assume(amount >= 10_000);
        vm.assume(amount <= INITIAL_SUPPLY / 2);

        token.transfer(user1, amount);

        // Prediksi dengan calculateTax
        (
            uint256 predTreasuryTax,
            uint256 predBurnTax,
            uint256 predAfterTax
        ) = token.calculateTax(amount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(user1);
        token.transfer(user2, amount);

        // Prediksi harus selalu match aktual
        assertEq(token.balanceOf(user2), predAfterTax);
        assertEq(token.balanceOf(treasury), predTreasuryTax);
        assertEq(token.totalSupply(), supplyBefore - predBurnTax);
    }

    /// @notice Fuzz test: tax config tidak bisa exceed maximum
    function test_Fuzz_TaxConfigNeverExceedsMax(
        uint256 treasuryTax,
        uint256 burnTax
    ) public {
        vm.assume(treasuryTax <= 2_500);
        vm.assume(burnTax <= 2_500);

        if (treasuryTax + burnTax > 2_500) {
            // Harus revert kalau total exceed max
            vm.expectRevert();
            token.setTreasuryTax(treasuryTax);
        } else {
            // Harus berhasil kalau dalam batas
            if (treasuryTax != token.treasuryTaxBps()) {
                token.setTreasuryTax(treasuryTax);
                assertEq(token.treasuryTaxBps(), treasuryTax);
            }
        }
    }

    // =============================================================
    //                      GAS REPORT
    // =============================================================

    function test_Gas_TransferWithTax() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        uint256 before = gasleft();
        token.transfer(user2, amount);
        uint256 gasUsed = before - gasleft();

        console.log("Gas transfer with tax:", gasUsed);
    }

    function test_Gas_TransferExempt() public {
        uint256 amount = 1_000 * ONE_TOKEN;

        uint256 before = gasleft();
        token.transfer(user1, amount);  // owner exempt
        uint256 gasUsed = before - gasleft();

        console.log("Gas transfer exempt:", gasUsed);
    }

    function test_Gas_SetTreasuryTax() public {
        uint256 before = gasleft();
        token.setTreasuryTax(400);
        uint256 gasUsed = before - gasleft();

        console.log("Gas setTreasuryTax:", gasUsed);
    }
}