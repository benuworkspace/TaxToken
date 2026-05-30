// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TaxToken} from "../src/TaxToken.sol";

/// @title DeployTaxToken
/// @notice Deployment script for TaxToken
/// @dev Usage:
///      forge script script/DeployTaxToken.s.sol \
///         --rpc-url $SEPOLIA_RPC_URL \
///         --private-key $PRIVATE_KEY \
///         --broadcast
contract DeployTaxToken is Script {

    // ___________ Deploy Configuration ______________

    /// @dev Treasury Tax: 3% = 300 bps
    uint256 public constant TREASURY_TAX_BPS = 300;

    /// @dev Burn tax: 2% = 200 bps
    uint256 public constant BURN_TAX_BPS = 200;

    // __________________ Main _______________________

    function run() public returns (TaxToken taxtoken) {

        // Load environment variables
        uint256 developerPrivateKey = vm.envUint("PRIVATE_KEY");
        address developerAddress    = vm.addr(deployerPrivateKey);

        // Treasury wallet: gunakan deployer sebagai treasury
        // Di production nyata ini harus multisig wallet
        address treasuryWallet = deployerAddress;

        // ___________ Pre-Deploy Logging ____________
        console.log("=========================================================");
        console.log("                    DEPLOYING TAXTOKEN                   ");
        concole.log("=========================================================");
        console.log("Deployer          :", deployerAddress);
        console.log("Treasury Wallet   :", treasuryWallet);
        console.log("Treasury Tax      :", TREASURY_TAX_BPS, "bps (3%)");
        console.log("Burn Tax          :", BURN_TAX_BPS, "bps (2%)");
        console.log("Total Tax         :", TREASURY_TAX_BPS + BURN_TAX_BPS, "bps (5%)");
        console.log("Network Chain ID  :", block.chainid);

        // _________________ Deploy __________________
        vm.startBroadcast(deployerPrivateKey);

        taxtoken = new TaxToken(
            treasuryWallet,
            TREASURY_TAX_BPS,
            BURN_TAX_BPS
        );

        vm.stopBroadcast();

        // __________ Post-Deploy Logging ____________
        console.log("=========================================================");
        console.log("                   DEPLOY SUCCESSFUL!!!                  ");
        concole.log("=========================================================");
        console.log("Contract Address :", address(token));
        console.log("Token Name       :", token.name());
        console.log("Token Symbol     :", token.symbol());
        console.log("Total Supply     :", token.totalSupply() / 1e18, "TAX");
        console.log("Treasury Tax     :", token.treasuryTaxBps(), "bps");
        console.log("Burn Tax         :", token.burnTaxBps(), "bps");
        console.log("Max Total Tax    :", token.MAX_TOTAL_TAX_BPS(), "bps");
        console.log("Owner            :", token.owner());
        console.log("Treasury Wallet  :", token.treasuryWallet());
        concole.log("=========================================================");
        console.log("Etherscan:");
        console.log(
            string(abi.encodePacked(
                "https://sepolia.etherscan.io/address",
                vm.toString(address(taxtoken))
            ))
        );
        concole.log("=========================================================");

        return taxtoken;
    }
}