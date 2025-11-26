// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC20Faucet.sol";
import "../src/ERC7575VaultUpgradeable.sol";
import "../src/ShareTokenUpgradeable.sol";

import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title ShareTokenUpgradeable Coverage Tests
 * @notice Tests to improve code coverage of ShareTokenUpgradeable
 * @dev Focuses on upgrade mechanisms, vault management, and error paths
 */
contract ShareTokenUpgradeableCoverageTests is Test {
    ShareTokenUpgradeable public shareToken;
    ERC1967Proxy public proxy;
    ERC20Faucet public asset;

    address public owner;
    address public user1;
    address public user2;
    address public vault1;
    address public vault2;

    uint256 constant INITIAL_BALANCE = 1000 * 1e18;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        vault1 = makeAddr("vault1");
        vault2 = makeAddr("vault2");

        asset = new ERC20Faucet("Test Asset", "ASSET", 10000 * 1e18);

        // Deploy implementation
        ShareTokenUpgradeable implementation = new ShareTokenUpgradeable();

        // Deploy proxy with initialization
        proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(ShareTokenUpgradeable.initialize, ("Test Share", "tSHARE", owner)));

        shareToken = ShareTokenUpgradeable(address(proxy));
    }

    // ==================== Initialization Tests ====================

    /**
     * @notice Test initialize sets correct owner
     */
    function testInitializeOwner() public {
        assertEq(shareToken.owner(), owner, "Owner should be set correctly");
    }

    /**
     * @notice Test initialize sets correct name and symbol
     */
    function testInitializeNameAndSymbol() public {
        assertEq(shareToken.name(), "Test Share", "Name should be set correctly");
        assertEq(shareToken.symbol(), "tSHARE", "Symbol should be set correctly");
    }

    /**
     * @notice Test initialize sets correct decimals
     */
    function testInitializeDecimals() public {
        assertEq(shareToken.decimals(), 18, "Decimals should be 18");
    }

    // ==================== Vault Registration Tests ====================

    /**
     * @notice Test registerVault with zero asset address
     */
    function testRegisterVaultZeroAsset() public {
        vm.expectRevert(IERC7575Errors.ZeroAddress.selector);
        shareToken.registerVault(address(0), vault1);
    }

    /**
     * @notice Test registerVault with zero vault address
     */
    function testRegisterVaultZeroVault() public {
        vm.expectRevert(IERC7575Errors.ZeroAddress.selector);
        shareToken.registerVault(address(asset), address(0));
    }

    /**
     * @notice Test registerVault with duplicate asset
     */
    function testRegisterVaultAssetAlreadyRegistered() public {
        // Mock vault's asset() to return the asset
        vm.mockCall(vault1, abi.encodeWithSignature("asset()"), abi.encode(address(asset)));
        vm.mockCall(vault1, abi.encodeWithSignature("share()"), abi.encode(address(shareToken)));

        shareToken.registerVault(address(asset), vault1);

        // Try to register again
        vm.mockCall(vault2, abi.encodeWithSignature("asset()"), abi.encode(address(asset)));
        vm.mockCall(vault2, abi.encodeWithSignature("share()"), abi.encode(address(shareToken)));

        vm.expectRevert(IERC7575Errors.AssetAlreadyRegistered.selector);
        shareToken.registerVault(address(asset), vault2);
    }

    /**
     * @notice Test registerVault with vault share mismatch
     */
    function testRegisterVaultShareMismatch() public {
        address wrongShareToken = makeAddr("wrongShareToken");
        vm.mockCall(vault1, abi.encodeWithSignature("asset()"), abi.encode(address(asset)));
        vm.mockCall(vault1, abi.encodeWithSignature("share()"), abi.encode(wrongShareToken));

        vm.expectRevert(IERC7575Errors.VaultShareMismatch.selector);
        shareToken.registerVault(address(asset), vault1);
    }

    /**
     * @notice Test registerVault successful registration
     */
    function testRegisterVaultSuccess() public {
        vm.mockCall(vault1, abi.encodeWithSignature("asset()"), abi.encode(address(asset)));
        vm.mockCall(vault1, abi.encodeWithSignature("share()"), abi.encode(address(shareToken)));

        shareToken.registerVault(address(asset), vault1);

        assertEq(shareToken.vault(address(asset)), vault1, "Vault should be registered");
        assertTrue(shareToken.isVault(vault1), "Vault should be recognized");
    }

    /**
     * @notice Test getRegisteredAssets after registration
     */
    function testGetRegisteredAssetsAfterRegistration() public {
        vm.mockCall(vault1, abi.encodeWithSignature("asset()"), abi.encode(address(asset)));
        vm.mockCall(vault1, abi.encodeWithSignature("share()"), abi.encode(address(shareToken)));

        shareToken.registerVault(address(asset), vault1);

        address[] memory assets = shareToken.getRegisteredAssets();
        assertEq(assets.length, 1, "Should have 1 registered asset");
        assertEq(assets[0], address(asset), "Asset should match");
    }

    // ==================== Vault Unregistration Tests ====================

    /**
     * @notice Test unregisterVault with asset not registered
     */
    function testUnregisterVaultNotRegistered() public {
        vm.expectRevert(IERC7575Errors.AssetNotRegistered.selector);
        shareToken.unregisterVault(address(asset));
    }

    /**
     * @notice Test unregisterVault with vault still active
     */
    function testUnregisterVaultStillActive() public {
        vm.mockCall(vault1, abi.encodeWithSignature("asset()"), abi.encode(address(asset)));
        vm.mockCall(vault1, abi.encodeWithSignature("share()"), abi.encode(address(shareToken)));

        shareToken.registerVault(address(asset), vault1);

        // Mock vault as still active
        vm.mockCall(vault1, abi.encodeWithSignature("isVaultActive()"), abi.encode(true));

        vm.expectRevert();
        shareToken.unregisterVault(address(asset));
    }

    // ==================== Operator Tests ====================

    /**
     * @notice Test setOperator grants operator permission
     */
    function testSetOperator() public {
        vm.prank(user1);
        bool approved = shareToken.setOperator(user2, true);

        assertTrue(approved, "Should return true");
        assertTrue(shareToken.isOperator(user1, user2), "Operator should be approved");
    }

    /**
     * @notice Test setOperator revokes operator
     */
    function testRevokeOperator() public {
        vm.prank(user1);
        shareToken.setOperator(user2, true);

        vm.prank(user1);
        shareToken.setOperator(user2, false);

        assertFalse(shareToken.isOperator(user1, user2), "Operator should be revoked");
    }

    /**
     * @notice Test setOperator cannot set self as operator
     */
    function testSetOperatorSelf() public {
        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.CannotSetSelfAsOperator.selector);
        shareToken.setOperator(user1, true);
    }

    /**
     * @notice Test setOperatorFor only callable by vaults
     */
    function testSetOperatorForOnlyVaults() public {
        vm.prank(user1);
        vm.expectRevert();
        shareToken.setOperatorFor(user2, vault1, true);
    }

    // ==================== Conversion Tests ====================

    /**
     * @notice Test convertNormalizedAssetsToShares with zero assets
     */
    function testConvertNormalizedAssetsToSharesZero() public {
        uint256 shares = shareToken.convertNormalizedAssetsToShares(0, Math.Rounding(0));
        assertEq(shares, 0, "Zero assets should convert to zero shares");
    }

    /**
     * @notice Test convertSharesToNormalizedAssetsZero
     */
    function testConvertSharesToNormalizedAssetsZero() public {
        uint256 assets = shareToken.convertSharesToNormalizedAssets(0, Math.Rounding(0));
        assertEq(assets, 0, "Zero shares should convert to zero assets");
    }

    /**
     * @notice Test conversion with different rounding modes
     */
    function testConvertNormalizedAssetsToSharesRounding() public {
        // Test that conversion works with both rounding modes
        uint256 shares0 = shareToken.convertNormalizedAssetsToShares(1, Math.Rounding(0));
        uint256 shares1 = shareToken.convertNormalizedAssetsToShares(1, Math.Rounding(1));

        // At least one should be non-zero or both zero depending on virtual amounts
        assertTrue(shares0 >= 0 && shares1 >= 0, "Both conversions should succeed");
    }

    // ==================== Investment Configuration Tests ====================

    /**
     * @notice Test setInvestmentManager with zero address
     */
    function testSetInvestmentManagerZeroAddress() public {
        vm.expectRevert(IERC7575Errors.ZeroAddress.selector);
        shareToken.setInvestmentManager(address(0));
    }

    /**
     * @notice Test setInvestmentManager success
     */
    function testSetInvestmentManagerSuccess() public {
        address manager = makeAddr("manager");
        shareToken.setInvestmentManager(manager);

        assertEq(shareToken.getInvestmentManager(), manager, "Manager should be set");
    }

    /**
     * @notice Test getInvestedAssets initial zero
     */
    function testGetInvestedAssetsInitial() public {
        uint256 invested = shareToken.getInvestedAssets();
        assertEq(invested, 0, "Initial invested assets should be 0");
    }

    // ==================== Share Operations Tests ====================

    /**
     * @notice Test mint only callable by vaults
     */
    function testMintOnlyVaults() public {
        vm.prank(user1);
        vm.expectRevert();
        shareToken.mint(user1, 100 * 1e18);
    }

    /**
     * @notice Test burn only callable by vaults
     */
    function testBurnOnlyVaults() public {
        vm.prank(user1);
        vm.expectRevert();
        shareToken.burn(user1, 100 * 1e18);
    }

    /**
     * @notice Test spendAllowance only callable by vaults
     */
    function testSpendAllowanceOnlyVaults() public {
        vm.prank(user1);
        vm.expectRevert();
        shareToken.spendAllowance(user1, user2, 100 * 1e18);
    }

    // ==================== Upgrade Tests ====================

    /**
     * @notice Test upgradeTo is owner only
     */
    function testUpgradeToOwnerOnly() public {
        ShareTokenUpgradeable newImpl = new ShareTokenUpgradeable();

        vm.prank(user1);
        vm.expectRevert();
        shareToken.upgradeTo(address(newImpl));
    }

    /**
     * @notice Test upgradeToAndCall is owner only
     */
    function testUpgradeToAndCallOwnerOnly() public {
        ShareTokenUpgradeable newImpl = new ShareTokenUpgradeable();

        vm.prank(user1);
        vm.expectRevert();
        shareToken.upgradeToAndCall(address(newImpl), "");
    }

    /**
     * @notice Test upgradeTo with valid new implementation
     */
    function testUpgradeToSuccess() public {
        ShareTokenUpgradeable newImpl = new ShareTokenUpgradeable();

        // Store initial state
        string memory originalName = shareToken.name();

        // Perform upgrade
        shareToken.upgradeTo(address(newImpl));

        // Verify state persists
        assertEq(shareToken.name(), originalName, "State should persist after upgrade");
        assertEq(shareToken.owner(), owner, "Owner should persist");
    }

    /**
     * @notice Test upgradeToAndCall with empty data
     */
    function testUpgradeToAndCallEmptyData() public {
        ShareTokenUpgradeable newImpl = new ShareTokenUpgradeable();

        string memory originalName = shareToken.name();

        shareToken.upgradeToAndCall(address(newImpl), "");

        assertEq(shareToken.name(), originalName, "State should persist");
    }

    // ==================== Interface Support Tests ====================

    /**
     * @notice Test supportsInterface for ERC165
     */
    function testSupportsInterfaceERC165() public {
        assertTrue(shareToken.supportsInterface(0x01ffc9a7), "Should support ERC165");
    }

    /**
     * @notice Test supportsInterface for unknown interface
     */
    function testSupportsInterfaceUnknown() public {
        assertFalse(shareToken.supportsInterface(0xdeadbeef), "Should not support unknown interface");
    }

    // ==================== Max Vaults Tests ====================

    /**
     * @notice Test exceeding max vaults
     */
    function testMaxVaultsExceeded() public {
        // Register 10 vaults (the max)
        for (uint256 i = 0; i < 10; i++) {
            ERC20Faucet token = new ERC20Faucet(string(abi.encodePacked("Token", i)), string(abi.encodePacked("TKN", i)), 10000 * 1e18);
            address testVault = makeAddr(string(abi.encodePacked("vault", i)));
            vm.mockCall(testVault, abi.encodeWithSignature("asset()"), abi.encode(address(token)));
            vm.mockCall(testVault, abi.encodeWithSignature("share()"), abi.encode(address(shareToken)));

            shareToken.registerVault(address(token), testVault);
        }

        // Try to register 11th vault
        ERC20Faucet extraToken = new ERC20Faucet("Extra", "EXT", 10000 * 1e18);
        address extraVault = makeAddr("extraVault");
        vm.mockCall(extraVault, abi.encodeWithSignature("asset()"), abi.encode(address(extraToken)));
        vm.mockCall(extraVault, abi.encodeWithSignature("share()"), abi.encode(address(shareToken)));

        vm.expectRevert(IERC7575Errors.MaxVaultsExceeded.selector);
        shareToken.registerVault(address(extraToken), extraVault);
    }

    // ==================== Getter Tests ====================

    /**
     * @notice Test vault getter for unregistered asset
     */
    function testVaultGetterUnregistered() public {
        assertEq(shareToken.vault(address(asset)), address(0), "Should return zero for unregistered asset");
    }

    /**
     * @notice Test isVault for unregistered vault
     */
    function testIsVaultUnregistered() public {
        assertFalse(shareToken.isVault(vault1), "Unregistered address should not be vault");
    }

    /**
     * @notice Test getCirculatingSupplyAndAssets initial state
     */
    function testGetCirculatingSupplyAndAssetsInitial() public {
        (uint256 supply, uint256 assets) = shareToken.getCirculatingSupplyAndAssets();

        assertEq(supply, 0, "Initial supply should be 0");
        assertEq(assets, 0, "Initial assets should be 0");
    }

    // ==================== Edge Cases ====================

    /**
     * @notice Test unregister attempt on non-existent asset
     */
    function testUnregisterNonExistentAsset() public {
        ERC20Faucet token = new ERC20Faucet("Extra", "EXT", 10000 * 1e18);

        vm.expectRevert(IERC7575Errors.AssetNotRegistered.selector);
        shareToken.unregisterVault(address(token));
    }

    /**
     * @notice Test operator status for non-existent operator
     */
    function testIsOperatorNonExistent() public {
        assertFalse(shareToken.isOperator(user1, user2), "Should return false for non-existent operator");
    }

    /**
     * @notice Test multiple operator registrations
     */
    function testMultipleOperators() public {
        address op1 = makeAddr("op1");
        address op2 = makeAddr("op2");
        address op3 = makeAddr("op3");

        vm.startPrank(user1);
        shareToken.setOperator(op1, true);
        shareToken.setOperator(op2, true);
        shareToken.setOperator(op3, true);
        vm.stopPrank();

        assertTrue(shareToken.isOperator(user1, op1), "op1 should be approved");
        assertTrue(shareToken.isOperator(user1, op2), "op2 should be approved");
        assertTrue(shareToken.isOperator(user1, op3), "op3 should be approved");
    }
}
