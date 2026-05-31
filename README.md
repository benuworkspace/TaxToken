# TaxToken — ERC20 with Configurable Transfer Tax

A production-ready ERC20 token with configurable treasury
and burn tax mechanisms. Built with OpenZeppelin contracts,
comprehensive test coverage, and full Etherscan verification.

## Deployed Contract

| Network | Address | Etherscan |
|---------|---------|-----------|
| Sepolia Testnet | `0xE467Dc791117747123720fb6ccf47deF2aae9055` | [View on Etherscan](https://sepolia.etherscan.io/address/0xe467dc791117747123720fb6ccf47def2aae9055) |

## How Tax Works

Every transfer between non-exempt addresses automatically
deducts tax before the recipient receives tokens:
Transfer Amount: 1,000 TAX

Treasury Tax (3%): 30 TAX → treasury wallet Burn Tax (2%): 20 TAX → burned (reduces supply) ───────────────────────────── Recipient receives: 950 TAX


Tax is calculated in basis points (bps):
- 100 bps = 1%
- 300 bps = 3%
- Maximum total tax: 2,500 bps (25%) — hardcoded, cannot be changed

## Features

- ✅ **Standard ERC20** — fully compatible with wallets and DEX
- ✅ **Treasury Tax** — configurable % sent to treasury wallet
- ✅ **Burn Tax** — configurable % permanently burned each transfer
- ✅ **Exempt List** — addresses that bypass tax (owner, treasury, DEX pairs)
- ✅ **Configurable** — owner can update tax rates within safe limits
- ✅ **Pausable** — emergency pause for all transfers
- ✅ **Max Tax Cap** — hard limit of 25% prevents rug pull via tax
- ✅ **Mintable** — owner can mint additional tokens
- ✅ **Verified** — source code publicly verified on Etherscan

## Token Info

| Property | Value |
|----------|-------|
| Name | Tax Example Token |
| Symbol | TAX |
| Decimals | 18 |
| Initial Supply | 1,000,000,000 TAX |
| Treasury Tax | 3% (300 bps) |
| Burn Tax | 2% (200 bps) |
| Total Tax | 5% (500 bps) |
| Max Total Tax | 25% (2,500 bps) |
| Network | Sepolia Testnet |

## Tax Configuration

### Exempt Addresses
These addresses are not subject to transfer tax:

| Address | Reason |
|---------|--------|
| Contract deployer | Initial setup and liquidity operations |
| Contract itself | Internal operations |
| Treasury wallet | Avoids double taxation on received tax |
| Custom exemptions | DEX pairs, partner contracts (set by owner) |

### Updating Tax Rates

```solidity
// Update treasury tax (only owner)
token.setTreasuryTax(500);  // 5%

// Update burn tax (only owner)
token.setBurnTax(100);      // 1%

// Total must not exceed 2,500 bps (25%)
```

### Adding DEX Pair to Exempt List

After listing on Uniswap or other DEX, add the pair
address to the exempt list to prevent AMM calculation issues:

```solidity
// Add Uniswap V2 pair to exempt list (only owner)
token.setExemption(uniswapPairAddress, true);
```

## Architecture

```bash
TaxToken.sol
│
├── Inheritance
│   ├── ERC20Pausable    → standard token + pause
│   └── Ownable          → access control
│
├── Constants
│   └── MAX_TOTAL_TAX_BPS = 2500 (25%)
│
├── State Variables
│   ├── uint256 treasuryTaxBps    (default: 300 = 3%)
│   ├── uint256 burnTaxBps        (default: 200 = 2%)
│   ├── address treasuryWallet
│   ├── uint256 totalTaxCollected
│   ├── uint256 totalBurned
│   └── mapping _isExemptFromTax
│
├── Events
│   ├── TaxApplied
│   ├── TreasuryTaxUpdated
│   ├── BurnTaxUpdated
│   ├── TreasuryWalletUpdated
│   └── ExemptionUpdated
│
├── Errors
│   ├── TaxTooHigh
│   ├── InvalidTreasuryWallet
│   ├── InvalidAddress
│   └── NoChangeDetected
│
├── Constructor
│   ├── ERC20("Tax Example Token", "TAX")
│   ├── Ownable(msg.sender)
│   ├── Set treasuryWallet
│   ├── Set initial tax rates
│   ├── Set exemptions (this, owner, treasury)
│   └── Mint initial supply ke deployer
│
├── Core Override
│   └── _update()        ← jantung contract ini
│       ├── Check paused (dari ERC20Pausable)
│       ├── Check exemption
│       ├── Calculate tax
│       ├── Transfer ke penerima
│       ├── Transfer treasury tax
│       ├── Burn tax
│       └── Update statistics + emit event
│
├── Admin Functions (onlyOwner)
│   ├── setTreasuryTax()
│   ├── setBurnTax()
│   ├── setTreasuryWallet()
│   ├── setExemption()
│   ├── pause()
│   ├── unpause()
│   └── mint()
│
└── View Functions
    ├── isExemptFromTax()
    ├── getTaxInfo()
    └── calculateTax()
```


## Test Coverage

```bash
forge test --gas-report
```

**65 tests — all passing**

| Category | Tests |
|----------|-------|
| Deployment | 15 |
| Transfer with Tax | 7 |
| Exemption | 8 |
| Tax Configuration | 8 |
| Treasury Wallet | 7 |
| Pause | 3 |
| View Functions | 4 |
| Edge Cases | 3 |
| Fuzz Testing | 3 |
| Gas Report | 3 |

### Gas Usage

| Function | Avg Gas |
|----------|---------|
| transfer (with tax) | ~85,000 |
| transfer (exempt) | ~55,000 |
| setTreasuryTax | ~30,000 |
| setExemption | ~28,000 |

> Note: Transfer with tax costs more than standard ERC20
> because each transfer executes three sub-transfers:
> recipient, treasury, and burn.

## Deployment

```bash
# Clone and setup
git clone https://github.com/benuworkspace/taxtoken
cd hari-05
forge install

# Configure environment
cp .env.example .env
# Fill in PRIVATE_KEY, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY

# Run tests
forge test

# Deploy
forge script script/DeployTaxToken.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast
```

## Security Considerations

**1. Max Tax Cap**
`MAX_TOTAL_TAX_BPS` is a `constant` hardcoded at 2,500 (25%).
It cannot be changed by anyone after deployment.
This prevents rug pulls via tax manipulation.

**2. Centralization Risk**
Owner can update tax rates and treasury wallet.
For production deployment, consider:
- Transferring ownership to a multisig (Gnosis Safe)
- Adding a timelock for tax changes
- Renouncing ownership after initial setup

**3. DEX Compatibility**
Tax tokens require users to set slippage tolerance
above the total tax rate when trading on DEX.
For 5% total tax, set slippage to at least 6%.

**4. DeFi Protocol Compatibility**
Fee-on-transfer tokens may not be compatible with
all DeFi protocols. Always test compatibility before
integrating with lending or yield farming protocols.

**5. Integer Division Rounding**
Tax calculations use integer division which rounds
down. Very small transfers (< 10,000 wei) may result
in zero tax deduction due to rounding.

## License

MIT