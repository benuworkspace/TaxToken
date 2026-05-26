// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title TaxToken
/// @author Absalom Benu
/// @notice ERC20 token with configurable transfer tax mechanism
/// @dev Implements treasury tax and burn tax on every transfer.
///      Tax is calculated in basis points (bps) where 100 bps = 1%.
///      Certain addresses can be exempted from tax (owner, treasury, DEX pairs).
///
/// Tax Flow per Transfer:
///   amount received by recipient = amount - treasuryTax - burnTax
///   treasuryTax → sent to treasuryWallet
///   burnTax     → burned (sent to address(0), reduces totalSupply)
///
contract TaxToken is ERC20, ERC20Pausable, Ownable {

    // __________ Constants _________________

    /// @notice Maximum total tax in basis points (25%)
    /// @dev This cannot be changed after deployment - protects users
    ///      from malicious tax increases (rug pull via tax)
    uint256 public constant MAX_TOTAL_TAX_BPS = 2_500;

    /// @notice Basis points denominator
    /// @dev 10_000 bps = 100%. Used in all tax calculations.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice INitial token supply: 1 billion tokens
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;


    // ____________ State Valiables _________________

    /// @notice Treasury tax rate in basis points
    /// @dev Default 300 bps = 3%. Changeable by owner witihin MAX_TOTAL_TAX_BPS.
    uint256 public treasuryTaxBps;

    /// @notice Burn tax rate in basis points
    /// @dev Default 200 bps = 2%. Changeable by owner witihin MAX_TOTAL_TAX_BPS.
    uint256 public burnTaxBps;

    /// @notice Wallet that receives treasury tax
    /// @dev Can be EOA, multisig, or another contract
    address public treasuryWallet;

    /// @notice Total amount of tax collected across all transfers
    /// @dev Includes both treasury tax & burn tax
    uint256 public totalTaxCollected;

    /// @notice Total amount of tokens burned via burn tax
    /// @dev Does not include manual burns via burn()
    uint256 public totalBurnedViaTax;

    /// @notice Mapping of addresses exempt from transfer tax
    /// @dev Exempt addesses pay/receive full amount without tax deduction
    mapping(address => bool) private _isExemptFromTax;


    // _____________ Events _________________

    /// @notice Emitted when tax is applied to a transfer
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Original transfer amount before tax
    /// @param treasuryTaxAmount Amount sent to treasury
    /// @param burnTaxAmount Amount burned
    /// @param amountAfterTax Amount received by Recipient
    event TaxApplied(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 treasuryTaxAmount,
        uint256 burnTaxAmount,
        uint256 amountAfterTax
    );

    /// @notice Emitted when treasury tax rate is update
    event TreasuryTaxUpdated(
        uint256 indexed oldTaxBps,
        uint256 indexed newTaxBps
    );

    /// @notice Emitted when burn tax rate is update
    event BurnTaxUpdated(
        uint256 indexed oldTaxBps,
        uint256 indexed newTaxBps
    );

    /// @notice Emitted when treasury wallet is updated
    event TreasuryWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet
    );

    /// @notice Emitted when an address exemption status is changed
    event ExemptionUpdated(
        address indexed account,
        bool isExempt
    );


    // __________ Errors ________________________

    /// @notice Thrown when total tax would exceed maximum allowed
    /// @param requested Total tax rate requested in bps
    /// @param maximum Maximum allowed total tax in bps
    error TaxTooHigh(uint256 requested, uint256 maximum);

    /// @notice Thrown when zero address is provided where not allowed
    error InvalidAddress();

    /// @notice Thrown when new value is same as current value
    error NoChangeDetected();

    /// @notice Thrown when tax calculation would result in
    ///         recipient receiving zero or negative tokens
    error TransferAmountTooSmall(uint256 amount, uint256 totalTax);


    // ______________ Constructor ____________________________

    /// @notice Deploy tax token with initial configuration
    /// @param _treasuryWallet Address to receive treasury tax
    /// @param _treasuryTaxBps Intial tax treasury in basis points
    /// @param _burnTaxBps Initial burn tax in basis points
    constructor(
        address _treasuryWallet,
        uint256 _treasuryTaxBps,
        uint256 _burnTaxBps
    )
        ERC20("Tax Example Token", "TAX")
        Ownable(msg.sender)
    {
        // Validasi treasury wallet
        if (_treasuryWallet == address(0)) revert InvalidAddress();

        // Validasi total tax tidak melebihi maximum
        uint256 totalTax = _treasuryTaxBps + _burnTaxBps;
        if (totalTax > MAX_TOTAL_TAX_BPS) {
            revert TaxTooHigh(totalTax, MAX_TOTAL_TAX_BPS);
        }

        //Set konfigurasi
        treasuryWallet = _treasuryWallet;
        treasuryTaxBps = _treasuryTaxBps;
        burnTaxBps     = _burnTaxBps;

        // Set exemptions awal
        // Ketiga address ini tidak boleh kena tax
        _isExemptFromTax[msg.sender]        = true;     // owner
        _isExemptFromTax[address(this)]     = true;     // contract itu sendiri
        _isExemptFromTax[_treasuryWallet]   = true;     // treasury wallet

        // Emit events untuk exemption awal
        emit ExemptionUpdated(msg.sender, true);
        emit ExemptionUpdated(address(this), true);
        emit ExemptionUpdated(_treasuryWallet, true);

        // Mint initial supply ke deployer
        _mint(msg.sender, INITIAL_SUPPLY);
    }


    // _______________ Core Override ____________________________

    /// @notice Override _update to inject tax logic into every transfer
    /// @dev This function is called by transfer(), transferFrom(), mint(), burn()
    ///      Tax is only applied when:
    ///      - Contract is not paused (handle by ERC20Pausable)
    ///      - Neither sender or recipient is exempt from tax
    ///      - This is a regular transfer (not mint or burn)
    ///
    /// @param from Sender address (address(0) for mint)
    /// @param to Recipient address (address(0) for burn)
    /// @param amount Transfer amount
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Pausable) {

        // _____ Kondisi 1: Ini adalah MINT (from == address(0)) _____
        // Saat mint, tidak ada tax - langsung proses
        // Kenapa? Mint adalah penciptaan token baru oleh owner
        // Bukan transfer antar user - tax tidak relevan
        if (from == address(0)) {
            super._update(from, to, amount);
            return;
        }

        // _______ Kondisi 2: Ini adalah BURN (to == address(0)) ______
        // Saat burn manual tidak ada tax - langsung proses
        // Kenapa? User membakar token milik sendiri secara sengaja
        // Mengenakan tax diatas burn manual adalah double punishment
        if (to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        // ______ Kondisi 3: Salah satu address exempt dari tax
        // Transfer melibatkan exempt address -> tidak ada tax
        // Kenapa cek keduanya (from & to)?
        // -> Exempt from: owner tidak kena tax saat kirim token
        // -> Exempt to: treasury tidak kena tax saat menerima token
        if (_isExemptFromTax[from] || _isExemptFromTax[to]) {
            super._update(from, to, amount);
            return;
        }

        // _______ Kondisi 4: Transfer biasa - KENAKAN TAX ____________

        // Hitung jumlah tax
        uint256 treasuryTaxAmount = (amount * treasuryTaxBps) / BPS_DENOMINATOR;
        uint256 burnTaxAmount     = (amount * burnTaxBps) / BPS_DENOMINATOR;
        uint256 totalTaxAmount    = treasuryTaxAmount + burnTaxAmount;
        uint256 amountAfterTax    = amount - totalTaxAmount;

        // Validasi: penerima harus menerima token > 0
        // Edge case: amount sangat kecil, tax dibulatkan ke 0
        // Kalau amountAftreTax == 0, transfer tidak ada gunanya
        if (amountAfterTax == 0) {
            revert TransferAmountTooSmall(amount, totalTaxAmount);
        }

        // __ Step 1: Transfer amount setelah tax ke penerima ______
        // Ini adalah transfer utama yang dilihat user
        super._update(from, to, amountAfterTax);

        // __ Step 2: Transfer treasury tax ke treasury wallet ______
        // Hanya dilakukan kalau treasury tax > 0
        // Kenapa cek > 0? Kalau treasury tax di-set ke 0,
        // tidak perlu emit transfer event yang tidak berguna
        if (treasuryTaxAmount > 0) {
            super._update(from, treasuryWallet, treasuryTaxAmount);
        }

        // ___ Step 3: Burn Tax _____________________________________
        // Kirim ke address(0) - ini yang mengurangi totalSupply
        // Hanya dilakukan kalau burn tax > 0
        if (burnTaxAmount > 0) {
            super._update(from, address(0), burnTaxAmount);
        }

        // ___ Step 4: Update Statistik _____________________________
        totalTaxCollected += totalTaxAmount;
        totalBurnedViaTax += burnTaxAmount;

        // ___ Step 5: Emit event breakdown tax _____________________
        emit TaxApplied(
            from,
            to, 
            amount,
            treasuryTaxAmount,
            burnTaxAmount,
            amountAfterTax
        );
    }


    // _______________ Admin Function ____________________________

    /// @notice Update treasury tax rate
    /// @param newTaxBps New treasury tax in basis points
    function setTreasuryTax(uint256 newTaxBps) external onlyOwner {
        // Cek apakah ada perubahan
        if (newTaxBps == treasuryTaxBps) revert NoChangeDetected();

        // Validasi total tax tidak melebihi maximum
        // Gunakan newTaxBps + burnTaxBps (bukan yang lama)
        uint256 newTotalTax = newTaxBps + burnTaxBps;
        if (newTotalTax > MAX_TOTAL_TAX_BPS) {
            revert TaxTooHigh(newTotalTax, MAX_TOTAL_TAX_BPS);
        }

        uint256 oldTax   = treasuryTaxBps;
        treasuryTaxBps   = newTaxBps;

        emit TreasuryTaxUpdated(oldTax, newTaxBps);
    }

    /// @notice Update burn tax rate
    /// @param newTaxBps New burn tax in basis points
    function setBurnTax(uint256 newTaxBps) external onlyOwner {
        if (newTaxBps == burnTaxBps) revert NoChangeDetected();

        uint256 newTotalTax = treasuryTaxBps + newTaxBps;
        if (newTaxBps > MAX_TOTAL_TAX_BPS) {
            revert TaxTooHigh(newTotalTax, MAX_TOTAL_TAX_BPS);
        }

        uint256 oldTax = burnTaxBps;
        burnTaxBps     = newTaxBps;

        emit BurnTaxUpdated(oldTax, newTaxBps);
    }

    /// @notice Update treasury wallet address
    /// @param newWallet New treasury wallet address
    function setTreasuryWallet(address newWallet) external onlyOwner {
        if (newWallet == address(0)) revert InvalidAddress();
        if (newWallet == treasuryWallet) revert NoChangeDetected();

        address oldWallet = treasuryWallet;

        // Hapus exemption dari wallet lama
        _isExemptFromTax[oldWallet] = false;
        emit ExemptionUpdated(oldWallet, false);

        // Set wallet baru
        treasuryWallet = newWallet;

        // Tambahkan exemption untuk wallet baru
        // Treasury wallet tidak boleh kena tax saat receive atau send
        _isExemptFromTax[newWallet] = true;
        emit ExemptionUpdated(newWallet, true);

        emit TreasuryWalletUpdated(oldWallet, newWallet);
    }

    /// @notice Add or remove address from tax exemption list
    /// @param account Address to update exemprion for
    /// @param exempt True to exempt, false to remove exemption
    function setExemption(
        address account,
        bool exempt
    ) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        if (_isExemptFromTax[account] == exempt) revert NoChangeDetected();

        _isExemptFromTax[account] = exempt;

        emit ExemptionUpdated(account, exempt);
    }

    /// @notice Pause all token transfer
    /// @dev Use in emergency situations only
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause token transfer
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Mint new token to specified address
    /// @dev Only owner can mint. Tax is not applied to minting.
    /// @param to Recipient of newly minted tokens
    /// @param amount Amount to mint in token units (wei)
    function min(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        _mint(to, amount);
    }


    // ___________ View Fuctions ________________________________

    /// @notice Check if an address is exempt from tax
    /// @param account Address to check
    /// @return True if exempt, false if not
    function isExemptFromTax(address account) external view returns (bool) {
        return _isExemptFromTax[account];
    }

    /// @notice Get all tax configuration in a single call
    /// @dev Reduces frontend RPC calls
    /// @return _treasuryTaxBps Currunt treasury tax rate
    /// @return _burnTaxBps Current burn tax rate
    /// @return _totalTaxBps Total tax rate
    /// @return _treasuryWallet Current treasury wallet
    /// @return _maxTotalTaxBps Maximum allowed total tax
    function getTaxInfo() external view returns (
        uint256 _treasuryTaxBps,
        uint256 _burnTaxBps,
        uint256 _totalTaxBps,
        address _treasuryWallet,
        uint256 _maxTotalTaxBps
    ) {
        return (
            treasuryTaxBps,
            burnTaxBps,
            treasuryTaxBps + burnTaxBps,
            treasuryWallet,
            MAX_TOTAL_TAX_BPS
        );
    }

    /// @notice Calculate tax breakdown for a given transfer amount
    /// @dev Useful for frontend to show users exact amounts before transfer
    /// @param amount Transfer amount to calculate tax for
    /// @return treasuryTaxAmount Amount that will go to treasury
    /// @return burnTaxAmount Amount that will be burn
    /// @return amountAfterTax Amount recipient will receive
    function calculateTax(uint256 amount) external view returns (
        uint256 treasuryTaxAmount,
        uint256 burnTaxAmount,
        uint256 amountAfterTax
    ) {
        treasuryTaxAmount = (amount * treasuryTaxBps) / BPS_DENOMINATOR;
        burnTaxAmount     = (amount * burnTaxBps) / BPS_DENOMINATOR;
        amountAfterTax    = amount - treasuryTaxAmount - burnTaxAmount;
    }

    /// @notice Get token statistics
    /// @return _totalSupply Current total supply
    /// @return _totalTaxCollected Total tax collected since development
    /// @return _totalBurnViaTax Total burned via burn tax mecanism
    function getTokenStats() external view returns (
        uint256 _totalSupply,
        uint256 _totalTaxCollected,
        uint256 _totalBurnViaTax
    ) {
        return (
            totalSupply(),
            totalTaxCollected,
            totalBurnedViaTax
        );
    }
}