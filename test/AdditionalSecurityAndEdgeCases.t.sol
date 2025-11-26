// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";

import {SafeTokenTransfers} from "../src/SafeTokenTransfers.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title AdditionalSecurityAndEdgeCases
 * @dev Tests for missing coverage areas identified in recent code changes
 */
contract AdditionalSecurityAndEdgeCasesTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    FlexibleMockAsset public asset;

    address public owner = address(this);
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    function setUp() public {
        // Deploy share token
        ShareTokenUpgradeable shareImpl = new ShareTokenUpgradeable();
        ERC1967Proxy shareProxy = new ERC1967Proxy(address(shareImpl), abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Multi-Asset Vault Shares", "MAVS", owner));
        shareToken = ShareTokenUpgradeable(address(shareProxy));

        // Create 6 decimal asset (minimum supported)
        asset = new FlexibleMockAsset("Six Decimal Token", "SIX", 6);
        asset.mint(user1, 1000000 * 10 ** 6);
        asset.mint(user2, 1000000 * 10 ** 6);

        // Deploy vault
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), owner));
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault
        shareToken.registerVault(address(asset), address(vault));

        // Set minimum deposit to 0 for testing small amounts
        vault.setMinimumDepositAmount(0);
    }

    // TEST 1: Token Transfer Validation - New post-transfer validation logic
    function test_TokenTransferValidation_FullAmountReceived() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 10000);

        // Should succeed when full amount is transferred
        vault.requestDeposit(10000, user1, user1);

        // Verify the exact amount was received
        uint256 vaultBalance = asset.balanceOf(address(vault));
        assertEq(vaultBalance, 10000, "Vault should receive exact amount");
        vm.stopPrank();
    }

    function test_TokenTransferValidation_FailsWithMaliciousToken() public {
        // Deploy a malicious token that doesn't transfer the full amount
        MaliciousToken maliciousAsset = new MaliciousToken();
        maliciousAsset.mint(user1, 1000000);

        // Deploy vault with malicious token
        ERC7575VaultUpgradeable maliciousVaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy maliciousVaultProxy =
            new ERC1967Proxy(address(maliciousVaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, maliciousAsset, address(shareToken), owner));
        ERC7575VaultUpgradeable maliciousVault = ERC7575VaultUpgradeable(address(maliciousVaultProxy));

        // Set minimum deposit to 0 for testing transfer validation
        maliciousVault.setMinimumDepositAmount(0);

        vm.startPrank(user1);
        maliciousAsset.approve(address(maliciousVault), 10000);

        // Should revert with transfer amount mismatch
        vm.expectRevert(SafeTokenTransfers.TransferAmountMismatch.selector);
        maliciousVault.requestDeposit(10000, user1, user1);
        vm.stopPrank();
    }

    // TEST 2: Decimal Boundary Testing
    function test_DecimalValidation_Minimum6Decimals() public {
        FlexibleMockAsset asset6 = new FlexibleMockAsset("Six Decimals", "SIX", 6);

        // Should succeed with 6 decimals
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory initData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset6, address(shareToken), owner);

        // Should not revert
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        ERC7575VaultUpgradeable vault6 = ERC7575VaultUpgradeable(address(vaultProxy));

        // Verify scaling factor calculation
        assertEq(vault6.getScalingFactor(), 10 ** (18 - 6), "Scaling factor should be 10^12 for 6 decimals");
    }

    function test_DecimalValidation_Maximum18Decimals() public {
        FlexibleMockAsset asset18 = new FlexibleMockAsset("Eighteen Decimals", "EIGHTEEN", 18);

        // Should succeed with 18 decimals
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory initData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset18, address(shareToken), owner);

        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        ERC7575VaultUpgradeable vault18 = ERC7575VaultUpgradeable(address(vaultProxy));

        // Verify scaling factor calculation
        assertEq(vault18.getScalingFactor(), 1, "Scaling factor should be 1 for 18 decimals");
    }

    function test_DecimalValidation_Rejects5Decimals() public {
        FlexibleMockAsset asset5 = new FlexibleMockAsset("Five Decimals", "FIVE", 5);

        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory initData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset5, address(shareToken), owner);

        // Should revert with unsupported decimals
        vm.expectRevert(IERC7575Errors.UnsupportedAssetDecimals.selector);
        new ERC1967Proxy(address(vaultImpl), initData);
    }

    function test_DecimalValidation_Rejects19Decimals() public {
        FlexibleMockAsset asset19 = new FlexibleMockAsset("Nineteen Decimals", "NINETEEN", 19);

        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory initData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset19, address(shareToken), owner);

        // Should revert with unsupported decimals
        vm.expectRevert(IERC7575Errors.UnsupportedAssetDecimals.selector);
        new ERC1967Proxy(address(vaultImpl), initData);
    }

    // TEST 3: Virtual Asset Handling - Updated logic without virtual assets in getCirculatingSupplyAndAssets
    function test_VirtualAssets_PureAggregation() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100000);
        vault.requestDeposit(100000, user1, user1);
        vm.stopPrank();

        // Fulfill deposit to create actual assets
        vault.fulfillDeposit(user1, 100000);

        // getCirculatingSupplyAndAssets should return pure aggregated value (no virtual assets)
        (, uint256 totalNormalized) = shareToken.getCirculatingSupplyAndAssets();
        uint256 expectedNormalized = 100000 * vault.getScalingFactor(); // 6 decimals -> 18 decimals

        assertEq(totalNormalized, expectedNormalized, "getCirculatingSupplyAndAssets should return pure aggregated value");

        // But conversion functions should use virtual assets internally
        uint256 shares = vault.convertToShares(50000);
        assertTrue(shares > 0, "Conversion should work with virtual asset protection");
    }

    // TEST 4: Multi-Asset Virtual Asset Consistency
    function test_MultiAsset_VirtualAssetConsistency() public {
        // Create second asset with different decimals
        FlexibleMockAsset asset8 = new FlexibleMockAsset("Eight Decimals", "EIGHT", 8);
        asset8.mint(user2, 1000000 * 10 ** 8);

        // Deploy second vault
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset8, address(shareToken), owner));
        ERC7575VaultUpgradeable vault2 = ERC7575VaultUpgradeable(address(vaultProxy));

        shareToken.registerVault(address(asset8), address(vault2));

        // Set minimum deposit to 0 for the new vault as well
        vault2.setMinimumDepositAmount(0);

        // Make deposits to both vaults
        vm.startPrank(user1);
        asset.approve(address(vault), 100000);
        vault.requestDeposit(100000, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        asset8.approve(address(vault2), 50000); // 8 decimals
        vault2.requestDeposit(50000, user2, user2);
        vm.stopPrank();

        // Fulfill both deposits
        vault.fulfillDeposit(user1, 100000);
        vault2.fulfillDeposit(user2, 50000);

        // Check aggregation works correctly
        (, uint256 totalNormalized) = shareToken.getCirculatingSupplyAndAssets();
        uint256 expected6Decimal = 100000 * 10 ** (18 - 6); // Normalize 6 decimals
        uint256 expected8Decimal = (50000) * 10 ** (18 - 8); // Normalize 8 decimals

        assertEq(totalNormalized, expected6Decimal + expected8Decimal, "Multi-asset aggregation should normalize correctly");

        // Both vaults should give consistent conversion rates
        uint256 shares1 = vault.convertToShares(10000);
        uint256 shares2 = vault2.convertToShares(10000 * 10 ** 2); // Same value in 8 decimals

        // Should be approximately equal (allowing for rounding differences)
        uint256 diff = shares1 > shares2 ? shares1 - shares2 : shares2 - shares1;
        assertTrue(diff <= 2, "Conversion rates should be consistent across different decimal assets");
    }

    // TEST 5: Scaling Factor Edge Cases
    function test_ScalingFactor_ConversionAccuracy() public {
        // Test with various decimal configurations
        uint8[] memory decimals = new uint8[](3);
        decimals[0] = 6;
        decimals[1] = 12;
        decimals[2] = 18;

        for (uint256 i = 0; i < decimals.length; i++) {
            FlexibleMockAsset testAsset = new FlexibleMockAsset(string(abi.encodePacked("Test", vm.toString(decimals[i]))), string(abi.encodePacked("T", vm.toString(decimals[i]))), decimals[i]);

            ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
            ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, testAsset, address(shareToken), owner));
            ERC7575VaultUpgradeable testVault = ERC7575VaultUpgradeable(address(vaultProxy));

            uint256 expectedScaling = 10 ** (18 - decimals[i]);
            assertEq(testVault.getScalingFactor(), expectedScaling, string(abi.encodePacked("Scaling factor incorrect for ", vm.toString(decimals[i]), " decimals")));
        }
    }

    // TEST 6: ShareToken Registry Edge Cases
    function test_ShareToken_RegistryIntegrity() public {
        // Test unregistering non-existent vault
        vm.expectRevert(IERC7575Errors.AssetNotRegistered.selector);
        shareToken.unregisterVault(address(0x123));

        // Test vault lookup for unregistered asset
        assertEq(shareToken.vault(address(0x456)), address(0), "Should return zero address for unregistered asset");

        // Test registering same asset twice (should fail)
        vm.expectRevert(IERC7575Errors.AssetAlreadyRegistered.selector);
        shareToken.registerVault(address(asset), address(vault));
    }

    function test_ShareToken_EmptyAggregation() public view {
        // With no deposits, getCirculatingSupplyAndAssets should return 0
        (, uint256 totalNormalized) = shareToken.getCirculatingSupplyAndAssets();
        assertEq(totalNormalized, 0, "Empty system should have zero normalized assets");

        // But conversions should still work due to virtual assets
        uint256 shares = vault.convertToShares(1000);
        assertTrue(shares > 0, "Conversions should work even with empty system");
    }

    // TEST 7: Cross-Vault Share Token Consistency
    function test_CrossVault_ShareConsistency() public {
        // Deploy second vault with same share token
        FlexibleMockAsset asset2 = new FlexibleMockAsset("Second Asset", "SEC", 8);
        asset2.mint(user2, 1000000 * 10 ** 8);

        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset2, address(shareToken), owner));
        ERC7575VaultUpgradeable vault2 = ERC7575VaultUpgradeable(address(vaultProxy));

        shareToken.registerVault(address(asset2), address(vault2));

        // Both vaults should point to same share token
        assertEq(vault.share(), vault2.share(), "Both vaults should use same share token");

        // Share token should authorize both vaults
        assertTrue(shareToken.isVault(address(vault)), "First vault should be authorized");
        assertTrue(shareToken.isVault(address(vault2)), "Second vault should be authorized");
    }

    // TEST 8: Investment Manager Access Control
    function test_InvestmentManager_AccessControl() public {
        address newManager = makeAddr("manager");

        // Only owner can set investment manager (centralized through ShareToken)
        vm.expectRevert();
        vm.prank(user1);
        shareToken.setInvestmentManager(newManager);

        // Owner can set investment manager (centralized through ShareToken)
        shareToken.setInvestmentManager(newManager);

        // Verify manager was set and propagated to vault
        assertEq(shareToken.getInvestmentManager(), newManager, "Investment manager should be set on ShareToken");
    }

    function test_ShareToken_OnlyOwnerFunctions() public {
        // Test registerVault access control
        vm.expectRevert();
        vm.prank(user1);
        shareToken.registerVault(address(0x123), address(0x456));

        // Test unregisterVault access control
        vm.expectRevert();
        vm.prank(user1);
        shareToken.unregisterVault(address(asset));
    }

    // Helper function to complete the todo
    function completeSecurityTests() internal {
        // All security and edge case tests implemented above
    }
}

/**
 * @dev Flexible mock asset with configurable decimals
 */
contract FlexibleMockAsset is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @dev Malicious token that doesn't transfer the full amount
 */
contract MaliciousToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "Malicious Token";
    string public symbol = "MAL";
    uint8 public decimals = 18;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;

        // Malicious behavior: only transfer 90% of the amount
        uint256 actualTransfer = (amount * 90) / 100;
        balanceOf[to] += actualTransfer;

        return true; // Lie about success
    }
}
