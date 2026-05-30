// SPDX-license-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
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
    event TreasuryTaxUpdated(uint256 indexed oldTaxBps, uint256 indexed newTaxBps);
    event BurnTaxUpdated(uint256 indexed oldTaxBps, uint256 indexed newTaxBps);
    event TreasuryWalletUpdated(address indexed oldWallet, address indexed newWallet);
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
    function _setupUserWithTokens(
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
        assertEq(taxtoken.MAX_TOTAL_TAX_BPS(), 2_500);
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
            abi.encodeWithSelector(TaxToken.InvalidAddress.selector)
        );
        new TaxToken(address(0), TREASURY_TAX_BPS, BURN_TAX_BPS);
    }

    function test_Deploy_RevertIfTaxTooHigh() public {
        uint256 tooHighTax = 2_600;  // > MAX_TOTAL_TAX (2500)
        vm.expectRevert(
            abi.encodeWithSelector(
                TaxToken.TaxTooHigh.selector,
                2_600,
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
        taxtoken.transfer(user2, transferAmount);

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

        uint256 supplyBefore = taxtoken.totalSupply();

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

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

        uint256 supplyBefore = taxtoken.totalSupply();

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
        uint256 expectedBurnTax   = _calcBurnTax(amount);

        assertEq(taxtoken.totalTaxCollected(), expectedTotalTax);
        assertEq(taxtoken.totalBurnedViaTax(), expectedBurnTax);
    }

    function test_Transfer_AccumulatesStatistics() public {
        uint256 amount = 1_000 * ONE_TOKEN;

        // Transfer 1
        _setupUserWithTokens(user1, amount);
        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Transfer 2 - user2 > user3
        // user 2 meneriman 950 token, transfer lagi
        uint256 user2Balance = taxtoken.balanceOf(user2);
        vm.prank(user2);
        taxtoken.transfer(user3, user2Balance);

        // Statistik harus akumulasi dari kedua transfer
        uint256 tax1 = _calcTotalTax(amount);
        uint256 tax2 = _calcTotalTax(user2Balance);

        assertEq(taxtoken.totalTaxCollected(), tax1 + tax2);
    }

    function test_TotalSupplyDecreasesWithEachTransfer() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, 3 * amount);

        uint256 supplyAfterTransfer;
        uint256 expectedBurnPerTransfer = _calcBurnTax(amount);

        // Transfer 1
        uint256 supplyBefore = taxtoken.totalSupply();
        vm.prank(user1);
        taxtoken.transfer(user2, amount);
        supplyAfterTransfer = taxtoken.totalSupply();
        assertEq(supplyAfterTransfer, supplyBefore - expectedBurnPerTransfer);

        // Transfer 2 
        supplyBefore = taxtoken.totalSupply();
        vm.prank(user1);
        taxtoken.transfer(user2, amount);
        assertEq(taxtoken.totalSupply(), supplyBefore - expectedBurnPerTransfer);
    }

    // ==========================================================
    //                    EXEMPTION TESTS
    // ==========================================================

    function test_Exempt_OwnerTransferNoTax() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        uint256 supplyBefore = taxtoken.totalSupply();

        // Owner transfer ke user1 - tidak kena tax
        taxtoken.transfer(user1, amount);

        // User1 menerima full amount tanpa potongan
        assertEq(taxtoken.balanceOf(user1), amount);
        // Total supply tidak berubah - tidak ada yang di burn
        assertEq(taxtoken.totalSupply(), supplyBefore);
        // Treasury tidak menerima apapun
        assertEq(taxtoken.balanceOf(treasury), 0);
        // Statistik tidak berubah
        assertEq(taxtoken.totalTaxCollected(), 0);
    }

    function test_Exempt_TransferToTreasuryNoTax() public {
        // Setup user1 dengan token
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = taxtoken.totalSupply();

        // User1 transfer ke treasury (treasury adalah exempt address)
        vm.prank(user1);
        taxtoken.transfer(treasury, amount);

        // Treasury menerima full amount karena sebagai exempt address
        assertEq(taxtoken.balanceOf(treasury), amount);
        // Supply tidak berubah
        assertEq(taxtoken.totalSupply(), supplyBefore);
    }

    function test_Exempt_CustomExemptionNoTax() public {
        // Tambahkan user1 ke exempt list
        taxtoken.setExemption(user1, true);
        assertTrue(taxtoken.isExemptFromTax(user1));

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = taxtoken.totalSupply();

        // user1 transfer ke user 2 - user1 exempt, tidak kena tax
        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // user2 menerima full amount
        assertEq(taxtoken.balanceOf(user2), amount);
        assertEq(taxtoken.totalSupply(), supplyBefore);
        assertEq(taxtoken.totalTaxCollected(), 0);
    }

    function test_Exempt_RemoveExemption() public {
        // Add Exemption
        taxtoken.setExemption(user1, true);
        assertTrue(taxtoken.isExemptFromTax(user1));

        // Remove exemption
        taxtoken.setExemption(user1, false);
        assertFalse(taxtoken.isExemptFromTax(user1));

        // Sekarang transfer dari user1 harus kena tax
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = taxtoken.totalSupply();

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // User2 menerima after tax amount
        assertEq(taxtoken.balanceOf(user2), _calcAmountAfterTax(amount));
        // Supply berkurang karena burn tax
        assertEq(taxtoken.totalSupply(), supplyBefore - _calcBurnTax(amount));
    }

    function test_Exempt_EmitsExemptionEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ExemptionUpdated(user1, true);
        taxtoken.setExemption(user1, true);
    }

    function test_Exempt_RevertsIfNoChange() public {
        // user1 sudah tidak exempt (default)
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.NoChangeDetected.selector)
        );
        taxtoken.setExemption(user1, false);
    }

    function test_Exempt_RevertsIfZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.InvalidAddress.selector)
        );
        taxtoken.setExemption(address(0), true);
    }

    function test_Exempt_RevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        taxtoken.setExemption(user2, true);
    }

    // ==================================================
    //                  MINT AND BURN TESTS
    // ==================================================

    function test_Mint_NoTaxApplied() public {
        uint256 mintAmount = 1_000 * ONE_TOKEN;
        uint256 supplyBefore = taxtoken.totalSupply();

        taxtoken.mint(user1, mintAmount);

        // Mint tidak kena tax - full amount ke user1
        assertEq(taxtoken.balanceOf(user1), mintAmount);
        assertEq(taxtoken.totalSupply(), supplyBefore + mintAmount);
        // Treasury tidak menerima apapun dari mint
        assertEq(taxtoken.balanceOf(treasury), 0);
        assertEq(taxtoken.totalTaxCollected(), 0);
    }

    function test_Burn_NoTaxApplied() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = taxtoken.totalSupply();

        // Manual burn - tidak kena tax
        // (burn langsung ke address(0) via _update)
        // Kita perlu tambahkan burn function ke contract
        // Untuk sekarang, test via transfer ke address(0) tidak bisa
        // karena OpenZeppelin block transfer ke address(0)
        // Manual burn dites via transfer normal yang sudah kena tax
        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Hanay burn tax yang reduce supply, bukan manual burn
        assertEq(
            taxtoken.totalSupply(),
            supplyBefore - _calcBurnTax(amount)
        );
    }

    // ====================================================
    //                   TAX CONFIG TESTS
    // ====================================================

    function test_SetTreasuryTax_Success() public {
        uint256 newTax = 500;  // 5%

        taxtoken.setTreasuryTax(newTax);

        assertEq(taxtoken.treasuryTaxBps(), newTax);
    }

    function test_SetTreasuryTax_EmitsEvent() public {
        uint256 newTax = 500;

        vm.expectEmit(true, true, false, false);
        emit TreasuryTaxUpdated(TREASURY_TAX_BPS, newTax);

        taxtoken.setTreasuryTax(newTax);
    }

    function test_SetTreasuryTax_NewRateApplied() public {
        // Update treaury tax ke 10%
        taxtoken.setTreasuryTax(1_000);

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Treasury tas baru: 1000 * 1000 / 10000 = 100
        // Burn tax tetap: 1000 * 200 / 10000 = 20
        assertEq(taxtoken.balanceOf(treasury), 100 * ONE_TOKEN);
    }

    function test_SetTreasuryTax_RevertsIfTooHigh() public {
        // burnTaxBps = 200, jadi treasuryTax max = 2500 - 200 = 2300
        uint256 tooHigh       = 2_301;
        uint256 expectedTotal = tooHigh + BURN_TAX_BPS;

        vm.expectRevert(
            abi.encodeWithSelector(
                TaxToken.TaxTooHigh.selector,
                expectedTotal,
                2_500
            )
        );
        taxtoken.setTreasuryTax(tooHigh);
    }

    function test_SetTreasuryTax_RevertsIfNoChange() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.NoChangeDetected.selector)
        );
        taxtoken.setTreasuryTax(TREASURY_TAX_BPS);
    }

    function test_SetTreasuryTax_RevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        taxtoken.setTreasuryTax(500);
    }

    function test_SetBurnTax_Success() public {
        uint256 newTax = 300;

        taxtoken.setBurnTax(newTax);

        assertEq(taxtoken.burnTaxBps(), newTax);
    }

    function test_SetBurnTax_NewRateApplied() public {
        // Set burn taxt ke 5%
        taxtoken.setBurnTax(500);

        uint256 amount       = 1_000 * ONE_TOKEN;
        uint256 supplyBefore = taxtoken.totalSupply();
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Burn tax baru: 1000 * 500 / 10000 = 50
        assertEq(taxtoken.totalSupply(), supplyBefore - 50 * ONE_TOKEN);
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
        taxtoken.setBurnTax(tooHigh);
    }

    function test_SetBothTaxToZero() public {
        // Set semua tax ke 0 - valid, tidak ada tax
        taxtoken.setTreasuryTax(0);
        taxtoken.setBurnTax(0);

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = taxtoken.totalSupply();

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Tidak ada tax - full amount ke user2
        assertEq(taxtoken.balanceOf(user2), amount);
        assertEq(taxtoken.balanceOf(treasury), 0);
        assertEq(taxtoken.totalSupply(), supplyBefore);
    }

    // ===================================================
    //                 TREASURY WALLET TESTS
    // ===================================================

    function test_SetTreasuryWallet_Success() public {
        address newTreasury = makeAddr("newTreasury");

        taxtoken.setTreasuryWallet(newTreasury);

        assertEq(taxtoken.treasuryWallet(), newTreasury);
    }

    function test_SetTreasuryWallet_UpdatesExemption() public {
        address newTreasury = makeAddr("newTreasury");
        address oldTreasury = treasury;

        taxtoken.setTreasuryWallet(newTreasury);

        // Old treasury tidak lagi exempt
        assertFalse(taxtoken.isExemptFromTax(oldTreasury));
        
        // New treasury exempt
        assertTrue(taxtoken.isExemptFromTax(newTreasury));
    }

    function test_SetTreasuryWallet_NewWalletReceivesTax() public {
        address newTreasury = makeAddr("newTreasury");
        taxtoken.setTreasuryWallet(newTreasury);

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Tax masuk ke treasury baru, bukan yang lama
        assertEq(taxtoken.balanceOf(newTreasury), _calcTreasuryTax(amount));
        assertEq(taxtoken.balanceOf(treasury), 0);
    }

    function test_SetTreasuryWallet_EmitsEvent() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit TreasuryWalletUpdated(treasury, newTreasury);

        taxtoken.setTreasuryWallet(newTreasury);
    }

    function test_SetTreasuryWallet_RevertsIfZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.InvalidAddress.selector)
        );
        taxtoken.setTreasuryWallet(address(0));
    }

    function test_SetTreasuryWallet_RevertsIfSameWallet() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaxToken.NoChangeDetected.selector)
        );
        taxtoken.setTreasuryWallet(treasury);
    }

    function test_SetTreasuryWallet_RevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        taxtoken.setTreasuryWallet(makeAddr("newTreasury"));
    }

    // ==========================================================
    //                        PAUSE TESTS
    // ==========================================================

    function test_Pause_BlocksTransfer() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        taxtoken.pause();

        vm.prank(user1);
        vm.expectRevert();
        taxtoken.transfer(user2, amount);
    }

    function test_Pause_BlocksMint() public {
        taxtoken.pause();

        vm.expectRevert();
        taxtoken.mint(user1, 1_000 * ONE_TOKEN);
    }

    function test_Unpause_RestoresTransfer() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, 1_000 * ONE_TOKEN);

        taxtoken.pause();
        taxtoken.unpause();

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Transfer berhasil dengan tax
        assertEq(taxtoken.balanceOf(user2), _calcAmountAfterTax(amount));
    }

    // ============================================================
    //                      VIEW FUNCTION TESTS
    // ============================================================

    function test_GetTaxInfo() public view {
        (
            uint256 _treasuryTaxBps,
            uint256 _burnTaxBps,
            uint256 _totalTaxBps,
            address _treasuryWallet,
            uint256 _maxTotalTaxBps
        ) = taxtoken.getTaxInfo();

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
        ) = taxtoken.calculateTax(amount);

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
        ) = taxtoken.calculateTax(amount);

        uint256 supplyBefore = taxtoken.totalSupply();

        // Eksekusi transfer
        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Verifikasi
        assertEq(taxtoken.balanceOf(user2), expectedAfterTax);
        assertEq(taxtoken.balanceOf(treasury), expectedTreasuryTax);
        assertEq(taxtoken.totalSupply(), supplyBefore - expectedBurnTax);
    }

    function test_GetTokenStats() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        (
            uint256 _totalSupply,
            uint256 _totalTaxCollected,
            uint256 _totalBurnedViaTax
        ) = taxtoken.getTokenStats();

        assertEq(_totalTaxCollected, _calcTotalTax(amount));
        assertEq(_totalBurnedViaTax, _calcBurnTax(amount));
        assertGt(_totalSupply, 0);
    }

    // ==============================================================
    //                        EDGE CASE TESTS
    // ==============================================================

    function test_EdgeCase_SmallTransferRounding() public {
        // Transfer amount kecil - verifikasi rounding tidak bermasalah
        // 10 wei: treasury = 10 * 300 / 10000 = 0 (rounded down)
        //         burn     = 10 * 200 / 10000 = 0 (rounded down)
        //         after    = 10 - 0 - 0       = 10

        _setupUserWithTokens(user1, 100);

        vm.prank(user1);
        taxtoken.transfer(user2, 10);

        // Untuk amount sangat kecil tax dibulatkan ke 0
        // User2 menerima full amount
        assertEq(taxtoken.balanceOf(user2), 10);
    }

    function test_EdgeCase_ZeroTaxTransfer() public {
        // Set semua tax ke 0
        taxtoken.setTreasuryTax(0);
        taxtoken.setBurnTax(0);

        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        uint256 supplyBefore = taxtoken.totalSupply();

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Tidak ada tax - seperti standar ERC20
        assertEq(taxtoken.balanceOf(user2), amount);
        assertEq(taxtoken.balanceOf(treasury), 0);
        assertEq(taxtoken.totalSupply(), supplyBefore);
        assertEq(taxtoken.totalTaxCollected(), 0);
    }

    function test_EdgeCase_MultipleTransferAccumulateBurn() public {
        uint256 transferAmount = 1_000 * ONE_TOKEN;
        uint256 totalAmount    = 10 * transferAmount;

        _setupUserWithTokens(user1, totalAmount);

        uint256 supplyBefore = taxtoken.totalSupply();
        uint256 expectedTotalBurn = _calcBurnTax(transferAmount) * 10;

        // 10 transfer berturut-turut
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user1);
            taxtoken.transfer(user2, transferAmount);
        }

        // Total burn harus akumulasi dari semua transfer
        assertEq(
            taxtoken.totalSupply(),
            supplyBefore - expectedTotalBurn
        );
        assertEq(taxtoken.totalBurnedViaTax(), expectedTotalBurn);
    }

    // ==================================================================
    //                              FUZZ TESTS
    // ==================================================================

    /// @notice Fuzz test: verifikasi math test untuk semua amount
    function test_Fuzz_TaxMathAlwaysCorrect(uint256 amount) public {
        // Batasi amount ke range yang realistis
        // Kita menggunakan bound() karena lebih effisien daripada vm.assume
        // baund() -> langsung membatasi rentang input sebelum test dijalankan
        // vm.assume() -> membuang input setelah di-generate (ineffisiensi)
        // vm.assume(amount >= 10_000);  // minimum agar tax tidak 0 semua
        // vm.assume(amount <= INITIAL_SUPPLY / 2);
        // bound() lebih efektif dan terkontrol
        amount = bound(amount, 1_000, INITIAL_SUPPLY / 2);

        // Setup user1 dengan amount
        taxtoken.transfer(user1, amount);  // owner exempt

        uint256 supplyBefore   = taxtoken.totalSupply();
        uint256 treasuryBefore = taxtoken.balanceOf(treasury);

        // Hitung expected values
        uint256 expectedTreasury = (amount * TREASURY_TAX_BPS) / BPS_DENOMINATOR;
        uint256 expectedBurn     = (amount * BURN_TAX_BPS) / BPS_DENOMINATOR;
        uint256 expectedAfterTax = amount - expectedTreasury - expectedBurn;

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Verifikasi math selalu konsisten
        assertEq(taxtoken.balanceOf(user2), expectedAfterTax, "afterTax wrong");
        assertEq(
            taxtoken.balanceOf(treasury),
            treasuryBefore + expectedTreasury,
            "treasury wrong"
        );
        assertEq(
            taxtoken.totalSupply(),
            supplyBefore - expectedBurn, "supply wrong"
        );

        // Invariants: amount harus conservation
        // Sender loss = recipient gain + treasury gain + burn
        assertEq(
            amount,
            expectedAfterTax + expectedTreasury + expectedBurn,
            "conservation broken"
        );
    }

    /// @notice Fuzz test: calculateTax selalu match transfer aktual
    function test_Fuzz_CalculateTaxMatchesActual(uint256 amount) public {
        // Kita menggunakan bound() karena lebih effisien daripada vm.assume
        // baund() -> langsung membatasi rentang input sebelum test dijalankan
        // vm.assume() -> membuang input setelah di-generate (ineffisiensi)
        // vm.assume(amount >= 10_000);
        // vm.assume(amount <= INITIAL_SUPPLY / 2);
        // bound() lebih efektif dan terkontrol
        amount = bound(amount, 10_000, INITIAL_SUPPLY / 2);

        taxtoken.transfer(user1, amount);

        // Prediksi dengan calculateTax
        (
            uint256 predTreasuryTax,
            uint256 predBurnTax,
            uint256 predAfterTax
        ) = taxtoken.calculateTax(amount);

        uint256 supplyBefore = taxtoken.totalSupply();

        vm.prank(user1);
        taxtoken.transfer(user2, amount);

        // Prediksi harus selalu match aktual
        // Tambahkan pesan assert supaya lebih mudah debug kalo gagal
        assertEq(taxtoken.balanceOf(user2), predAfterTax, "afterTax mismatch");
        assertEq(taxtoken.balanceOf(treasury), predTreasuryTax, "treasury mismatch");
        assertEq(taxtoken.totalSupply(), supplyBefore - predBurnTax, "supply mismatch");
    }

    /// @notice Fuzz test: test config tidak bisa exceed maximum
    function test_Fuzz_TaxConfigNeverExceedsMax(
        uint256 treasuryTax,
        uint256 burnTax
    ) public {
        // Kita menggunakan bound() karena lebih effisien daripada vm.assume
        // baund() -> langsung membatasi rentang input sebelum test dijalankan
        // vm.assume() -> membuang input setelah di-generate (ineffisiensi)
        treasuryTax = bound(treasuryTax, 0, 2_500);
        burnTax = bound(burnTax, 0, 2_500);
        // vm.assume(treasuryTax <= 2_500);
        // vm.assume(burnTax <= 2_500);

        uint256 currentTreasuryTax = taxtoken.treasuryTaxBps();
        uint256 currentBurnTax = taxtoken.burnTaxBps();

        // First update treasury tax against the current burn tax.
        if (treasuryTax + currentBurnTax > 2_500) {
            vm.expectRevert();
            taxtoken.setTreasuryTax(treasuryTax);
            return;
        }

        if (treasuryTax != currentTreasuryTax) {
            taxtoken.setTreasuryTax(treasuryTax);
        }

        // Then update burn tax against the new treasury tax.
        if (burnTax + treasuryTax > 2_500) {
            vm.expectRevert();
            taxtoken.setBurnTax(burnTax);
            return;
        }

        if (burnTax != currentBurnTax) {
            taxtoken.setBurnTax(burnTax);
        }

        // memastikan totalTax tidak melebihi 2500 bps
        assertLe(taxtoken.treasuryTaxBps() + taxtoken.burnTaxBps(), 2_500);
        assertEq(taxtoken.treasuryTaxBps(), treasuryTax);
        assertEq(taxtoken.burnTaxBps(), burnTax);
    }

    // =============================================================
    //                         GAS REPORT
    // =============================================================

    function test_Gas_TransferWithTax() public {
        uint256 amount = 1_000 * ONE_TOKEN;
        _setupUserWithTokens(user1, amount);

        vm.prank(user1);
        uint256 before = gasleft();
        taxtoken.transfer(user2, amount);
        uint256 gasUsed = before - gasleft();

        console.log("Gas transfer with tax:", gasUsed);
    }

    function test_Gas_TransferEXempt() public {
        uint256 amount = 1_000 * ONE_TOKEN;

        uint256 before = gasleft();
        taxtoken.transfer(user1, amount); // owner exempt
        uint256 gasUsed = before - gasleft();

        console.log("Gas transfer exempt:", gasUsed);
    }

    function test_Gas_SetTreasuryTax() public {
        uint256 before = gasleft();
        taxtoken.setTreasuryTax(400);
        uint256 gasUsed = before - gasleft();

        console.log("Gas setTreasuryTax:", gasUsed);
    }
}