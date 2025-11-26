// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console} from "forge-std/Test.sol";

import {ERC20Faucet6} from "../src/ERC20Faucet6.sol";
import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";
import {IERC7575} from "../src/interfaces/IERC7575.sol";
import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";

/**
 * @title RegisterVaultInvestmentConfig Test
 * @dev Tests that when registering a new vault on a ShareToken that already has
 *      investment configuration, the new vault automatically gets configured with:
 *      1. The correct investment vault for its asset
 *      2. The investment manager
 *      3. Proper allowances for investment operations
 */
contract RegisterVaultInvestmentConfigTest is Test {
    // Test tokens
    ERC20Faucet6 public usdc;
    ERC20Faucet6 public usdt;
    ERC20Faucet6 public dai; // Third asset for testing new vault registration

    // Investment target system (WERC7575)
    WERC7575ShareToken public investmentShareToken;
    WERC7575Vault public investmentUsdcVault;
    WERC7575Vault public investmentUsdtVault;
    WERC7575Vault public investmentDaiVault; // For the new vault test

    // Upgradeable system under test
    ShareTokenUpgradeable public shareToken;
    ERC7575VaultUpgradeable public usdcVault;
    ERC7575VaultUpgradeable public usdtVault;

    address public owner = address(0x1);
    address public investmentManager = address(0x2);
    address public validator = address(0x3);

    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 1e6; // 1B tokens (6 decimals)

    function setUp() public {
        vm.startPrank(owner);

        // Deploy test tokens
        usdc = new ERC20Faucet6("USD Coin", "USDC", INITIAL_SUPPLY);
        usdt = new ERC20Faucet6("Tether USD", "USDT", INITIAL_SUPPLY);
        dai = new ERC20Faucet6("Dai Stablecoin", "DAI", INITIAL_SUPPLY);

        // Deploy investment target system (WERC7575)
        investmentShareToken = new WERC7575ShareToken("Investment USD", "iUSD");
        investmentUsdcVault = new WERC7575Vault(address(usdc), investmentShareToken);
        investmentUsdtVault = new WERC7575Vault(address(usdt), investmentShareToken);
        investmentDaiVault = new WERC7575Vault(address(dai), investmentShareToken);

        // Configure investment system
        investmentShareToken.registerVault(address(usdc), address(investmentUsdcVault));
        investmentShareToken.registerVault(address(usdt), address(investmentUsdtVault));
        investmentShareToken.registerVault(address(dai), address(investmentDaiVault));
        investmentShareToken.setValidator(validator);
        investmentShareToken.setKycAdmin(validator);
        investmentShareToken.setRevenueAdmin(validator);

        vm.stopPrank();

        // Set up KYC permissions for future ShareToken
        vm.startPrank(validator);
        investmentShareToken.setKycVerified(address(0), true); // Will be updated after ShareToken deployment
        vm.stopPrank();

        vm.startPrank(owner);

        // Deploy upgradeable ShareToken system
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Multi-Asset Vault Shares", "MAVS", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy initial vaults (USDC and USDT)
        usdcVault = _deployVault(address(usdc));
        usdtVault = _deployVault(address(usdt));

        // Register initial vaults
        shareToken.registerVault(address(usdc), address(usdcVault));
        shareToken.registerVault(address(usdt), address(usdtVault));

        // Configure investment system AFTER initial vaults are registered
        shareToken.setInvestmentManager(investmentManager);
        shareToken.setInvestmentShareToken(address(investmentShareToken));

        vm.stopPrank();

        // Update KYC for the actual ShareToken address
        vm.startPrank(validator);
        investmentShareToken.setKycVerified(address(shareToken), true);
        vm.stopPrank();
    }

    function _deployVault(address asset) internal returns (ERC7575VaultUpgradeable) {
        return _deployVault(asset, address(shareToken));
    }

    /**
     * @dev Test that registering a new vault automatically configures investment settings
     * when ShareToken already has investment configuration
     */
    function test_RegisterVault_AutoConfiguresInvestmentSettings() public {
        // Verify pre-conditions: ShareToken has investment configuration
        assertEq(shareToken.getInvestmentShareToken(), address(investmentShareToken));
        assertEq(shareToken.getInvestmentManager(), investmentManager);

        // Deploy a new DAI vault
        ERC7575VaultUpgradeable daiVault = _deployVault(address(dai));

        // Verify the vault exists but isn't registered yet
        assertEq(shareToken.vault(address(dai)), address(0));

        // Register the new vault - this should automatically configure investment settings
        vm.prank(owner);
        shareToken.registerVault(address(dai), address(daiVault));

        // Verify the vault was registered
        assertEq(shareToken.vault(address(dai)), address(daiVault));

        // CRITICAL TEST: Verify automatic investment configuration occurred

        // 1. Check that the vault's investment manager was set
        assertEq(daiVault.getInvestmentManager(), investmentManager, "Investment manager should be automatically set");

        // 2. Check that the vault's investment vault was set to the correct DAI investment vault
        // Note: We can't directly check getInvestmentVault() as it's not exposed,
        // but we can verify by checking if investment operations work

        // 3. Verify that ShareToken has allowance to spend investment ShareToken on behalf of the vault
        uint256 allowance = investmentShareToken.allowance(address(shareToken), address(daiVault));
        assertEq(allowance, type(uint256).max, "Vault should have unlimited allowance from ShareToken");

        console.log("New DAI vault automatically configured with:");
        console.log("  - Investment manager:", daiVault.getInvestmentManager());
        console.log("  - Investment ShareToken allowance:", allowance);
    }

    /**
     * @dev Test that existing vaults also got configured when investment was set up
     */
    function test_ExistingVaults_HaveInvestmentConfiguration() public {
        // Check that existing vaults (USDC and USDT) were configured when investment was set up
        assertEq(usdcVault.getInvestmentManager(), investmentManager, "USDC vault should have investment manager");
        assertEq(usdtVault.getInvestmentManager(), investmentManager, "USDT vault should have investment manager");

        // Check allowances
        uint256 usdcAllowance = investmentShareToken.allowance(address(shareToken), address(usdcVault));
        uint256 usdtAllowance = investmentShareToken.allowance(address(shareToken), address(usdtVault));

        assertEq(usdcAllowance, type(uint256).max, "USDC vault should have unlimited allowance");
        assertEq(usdtAllowance, type(uint256).max, "USDT vault should have unlimited allowance");
    }

    /**
     * @dev Test that registering vault with fake address correctly fails
     */
    function test_RegisterVault_RejectsNonContractAddresses() public {
        // This tests the strict asset validation we added
        address fakeVault = makeAddr("fakeVault");

        // This should revert because it's not a real contract that implements asset()
        vm.prank(owner);
        vm.expectRevert();
        shareToken.registerVault(makeAddr("fakeAsset"), fakeVault);
    }

    /**
     * @dev Test that investment configuration only happens when both conditions are met:
     * 1. Investment ShareToken is configured
     * 2. Vault address is a deployed contract
     */
    function test_RegisterVault_ConditionalInvestmentConfiguration() public {
        // Deploy a new ShareToken without investment configuration
        ShareTokenUpgradeable newShareToken;
        {
            ShareTokenUpgradeable newShareTokenImpl = new ShareTokenUpgradeable();
            bytes memory initData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "New Shares", "NEW", owner);
            ERC1967Proxy newProxy = new ERC1967Proxy(address(newShareTokenImpl), initData);
            newShareToken = ShareTokenUpgradeable(address(newProxy));
        }

        // Deploy a real vault for the new ShareToken
        ERC7575VaultUpgradeable realVault;
        {
            ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
            bytes memory initData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(address(usdc)), address(newShareToken), owner);
            ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
            realVault = ERC7575VaultUpgradeable(address(vaultProxy));
        }

        // Register vault when no investment configuration exists - should not fail
        vm.prank(owner);
        newShareToken.registerVault(address(usdc), address(realVault));

        // Verify vault was registered but has no investment configuration
        assertEq(newShareToken.vault(address(usdc)), address(realVault));
        assertEq(newShareToken.getInvestmentShareToken(), address(0));
        assertEq(realVault.getInvestmentManager(), owner); // Should be default (owner)
    }

    /**
     * @dev Test that registerVault validates vault asset matches provided asset parameter
     */
    function test_RegisterVault_ValidatesAssetMatch() public {
        // Deploy a vault for DAI (not yet registered)
        ERC7575VaultUpgradeable daiTestVault = _deployVault(address(dai));

        // This should work - DAI vault with DAI asset
        vm.prank(owner);
        shareToken.registerVault(address(dai), address(daiTestVault));

        // Deploy another vault for USDT
        ERC7575VaultUpgradeable usdtTestVault = _deployVault(address(usdt));

        // Create a fake asset address
        address fakeAsset = makeAddr("fakeAsset");

        // This should fail - trying to register USDT vault as fake asset
        vm.prank(owner);
        vm.expectRevert(IERC7575Errors.AssetMismatch.selector);
        shareToken.registerVault(fakeAsset, address(usdtTestVault));

        console.log("Asset validation works correctly:");
        console.log("  - Correct asset-vault pairing accepted");
        console.log("  - Mismatched asset-vault pairing rejected");
    }

    /**
     * @dev Test that registerVault validates vault's share token matches this ShareToken
     */
    function test_RegisterVault_ValidatesShareToken() public {
        // Create a different ShareToken
        ShareTokenUpgradeable otherShareToken;
        {
            ShareTokenUpgradeable otherShareTokenImpl = new ShareTokenUpgradeable();
            bytes memory initData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Other Shares", "OTHER", owner);
            ERC1967Proxy otherProxy = new ERC1967Proxy(address(otherShareTokenImpl), initData);
            otherShareToken = ShareTokenUpgradeable(address(otherProxy));
        }

        // Deploy a vault for the other ShareToken
        ERC7575VaultUpgradeable vaultForOtherShareToken = _deployVault(address(dai), address(otherShareToken));

        // Try to register this vault with our ShareToken - should fail due to share token mismatch
        vm.prank(owner);
        vm.expectRevert(IERC7575Errors.VaultShareMismatch.selector);
        shareToken.registerVault(address(dai), address(vaultForOtherShareToken));

        console.log("Share token validation works correctly:");
        console.log("  - Vault configured for different ShareToken properly rejected");
    }

    function _deployVault(address asset, address shareTokenAddress) internal returns (ERC7575VaultUpgradeable) {
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(asset), shareTokenAddress, owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        return ERC7575VaultUpgradeable(address(vaultProxy));
    }

    /**
     * @dev Test that setInvestmentShareToken can only be set once
     */
    function test_SetInvestmentShareToken_OnlyOnce() public {
        // Deploy a new ShareToken without investment configuration
        ShareTokenUpgradeable newShareToken;
        {
            ShareTokenUpgradeable newShareTokenImpl = new ShareTokenUpgradeable();
            bytes memory initData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "New Shares", "NEW", owner);
            ERC1967Proxy newProxy = new ERC1967Proxy(address(newShareTokenImpl), initData);
            newShareToken = ShareTokenUpgradeable(address(newProxy));
        }

        // Verify initial state - no investment ShareToken set
        assertEq(newShareToken.getInvestmentShareToken(), address(0));

        // First call should succeed
        vm.prank(owner);
        newShareToken.setInvestmentShareToken(address(investmentShareToken));

        // Verify it was set
        assertEq(newShareToken.getInvestmentShareToken(), address(investmentShareToken));

        // Second call should fail
        vm.prank(owner);
        vm.expectRevert(IERC7575Errors.InvestmentShareTokenAlreadySet.selector);
        newShareToken.setInvestmentShareToken(makeAddr("anotherShareToken"));

        console.log("Investment ShareToken can only be set once:");
        console.log("  - First call succeeded");
        console.log("  - Second call properly rejected");
    }

    /**
     * @dev Test that unregisterVault requires vault to be inactive
     */
    function test_UnregisterVault_RequiresInactiveVault() public {
        // Deploy and register a new vault
        ERC7575VaultUpgradeable testVault = _deployVault(address(dai));
        vm.prank(owner);
        shareToken.registerVault(address(dai), address(testVault));

        // Try to unregister while vault is still active - should fail
        vm.prank(owner);
        vm.expectRevert(IERC7575Errors.CannotUnregisterActiveVault.selector);
        shareToken.unregisterVault(address(dai));

        // Deactivate the vault first
        vm.prank(owner);
        testVault.setVaultActive(false);

        // Now unregistering should work
        vm.prank(owner);
        shareToken.unregisterVault(address(dai));

        // Verify vault was unregistered
        assertEq(shareToken.vault(address(dai)), address(0));

        console.log("Vault active status validation works correctly:");
        console.log("  - Active vault unregistration properly rejected");
        console.log("  - Inactive vault unregistration succeeded");
    }

    /**
     * @dev Test complete investment flow with newly registered vault
     */
    function test_RegisterVault_InvestmentFlowWorks() public {
        // Create a new asset for this test to avoid conflicts
        ERC20Faucet6 testToken = new ERC20Faucet6("Test Token", "TEST", INITIAL_SUPPLY);

        // Create dedicated investment vault for test token
        WERC7575Vault investmentTestVault = new WERC7575Vault(address(testToken), investmentShareToken);

        // Configure the investment system for this test token
        vm.prank(owner);
        investmentShareToken.registerVault(address(testToken), address(investmentTestVault));

        // Deploy and register new test token vault
        ERC7575VaultUpgradeable testVault = _deployVault(address(testToken));
        vm.prank(owner);
        shareToken.registerVault(address(testToken), address(testVault));

        // Seed test contract with test token first
        testToken.transfer(address(this), 20000 * 1e6);

        // Seed test vault with assets for investment
        testToken.transfer(address(testVault), 10000 * 1e6);

        // Attempt investment operation - this should work because vault was auto-configured
        vm.prank(investmentManager);
        uint256 investmentAmount = 5000 * 1e6;

        // This should work without reverting
        uint256 sharesReceived = testVault.investAssets(investmentAmount);

        assertGt(sharesReceived, 0, "Investment should return shares");

        // Verify the investment was recorded in ShareToken's invested assets
        uint256 totalInvested = shareToken.getInvestedAssets();
        assertGt(totalInvested, 0, "ShareToken should track invested assets");

        console.log("Investment flow successful:");
        console.log("  - Amount invested:", investmentAmount);
        console.log("  - Shares received:", sharesReceived);
        console.log("  - Total invested assets:", totalInvested);
    }
}
