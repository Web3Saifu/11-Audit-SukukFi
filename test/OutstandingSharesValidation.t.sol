// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";

import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

contract OutstandingSharesValidationTest is Test {
    WERC7575ShareToken public shareToken;
    WERC7575Vault public usdcVault;
    WERC7575Vault public daiVault;
    ERC20Faucet public usdc;
    ERC20Faucet public dai;

    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        // Deploy faucet tokens with different decimals to test decimal normalization
        usdc = new ERC20Faucet("USD Coin", "USDC", 1_000_000 * 10 ** 6);
        dai = new ERC20Faucet("Dai Stablecoin", "DAI", 1_000_000 * 10 ** 18);

        // Override decimals by using vm.mockCall for testing different decimals
        // USDC typically has 6 decimals
        vm.mockCall(address(usdc), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));

        // DAI has 18 decimals (default)
        vm.mockCall(address(dai), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        // Deploy share token
        shareToken = new WERC7575ShareToken("Multi-Asset Share Token", "MAST");

        // Deploy vaults
        usdcVault = new WERC7575Vault(address(usdc), shareToken);
        daiVault = new WERC7575Vault(address(dai), shareToken);

        // Register vaults with share token
        shareToken.registerVault(address(usdc), address(usdcVault));
        shareToken.registerVault(address(dai), address(daiVault));

        // KYC users who will receive shares (validator is owner by default here)
        shareToken.setKycVerified(user1, true);
        shareToken.setKycVerified(user2, true);

        // Setup user balances using faucet
        // Use the owner's initial supply rather than faucet to avoid cooldown issues
        usdc.transfer(user1, 1000 * 10 ** 6); // 1000 USDC
        dai.transfer(user2, 1000 * 10 ** 18); // 1000 DAI
    }

    /**
     * @dev Test that vault unregistration fails when vault has outstanding assets
     */
    function testCannotUnregisterVaultWithOutstandingAssets() public {
        // User deposits assets into vault
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);
        usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();

        // Verify vault has assets
        assertEq(usdcVault.totalAssets(), 100 * 10 ** 6);

        // Try to unregister vault - should fail
        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultAssetBalance.selector);
        shareToken.unregisterVault(address(usdc));

        // Verify vault is still registered
        assertEq(shareToken.vault(address(usdc)), address(usdcVault));
    }

    /**
     * @dev Test that vault unregistration fails when vault has asset balance
     * This tests the double-safety check using direct IERC20 balance verification
     */
    function testCannotUnregisterVaultWithAssetBalance() public {
        // Directly transfer assets to vault (simulating edge case)
        usdc.transfer(address(usdcVault), 50 * 10 ** 6);

        // Verify vault has asset balance
        assertEq(usdc.balanceOf(address(usdcVault)), 50 * 10 ** 6);

        // Try to unregister vault - will fail on first check (totalAssets)
        // because our vault implementation returns actual balance as totalAssets
        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultAssetBalance.selector);
        shareToken.unregisterVault(address(usdc));
    }

    /**
     * @dev Test successful vault unregistration when no outstanding assets
     */
    function testSuccessfulVaultUnregistration() public {
        // Verify vault has no assets initially
        assertEq(usdcVault.totalAssets(), 0);
        assertEq(usdc.balanceOf(address(usdcVault)), 0);

        // Should succeed - no outstanding assets
        vm.expectEmit(true, true, false, false);
        emit VaultUpdate(address(usdc), address(0));
        shareToken.unregisterVault(address(usdc));

        // Verify vault is unregistered
        assertEq(shareToken.vault(address(usdc)), address(0));

        // Verify authorization is also removed
        // The vault should no longer be able to mint shares
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        vm.prank(address(usdcVault));
        shareToken.mint(user1, 100);
    }

    /**
     * @dev Test vault unregistration after users withdraw all assets
     */
    function testVaultUnregistrationAfterWithdrawal() public {
        // User deposits assets
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);
        uint256 shares = usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();

        // Verify vault has assets and user has shares
        assertEq(usdcVault.totalAssets(), 100 * 10 ** 6);
        assertEq(shareToken.balanceOf(user1), shares);

        // Cannot unregister while assets exist
        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultAssetBalance.selector);
        shareToken.unregisterVault(address(usdc));

        // User withdraws all assets by redeeming shares
        // In the real system, user would use permit for self-approval
        // For testing, let's simulate complete withdrawal by having the vault transfer assets back
        // and burn shares (simulating successful redeem)

        // Simulate vault transferring assets back to user
        vm.prank(address(usdcVault));
        usdc.transfer(user1, 100 * 10 ** 6);

        // Simulate vault burning user's shares
        vm.prank(address(usdcVault));
        shareToken.burn(user1, shares);

        // Verify vault is empty and user got their assets back
        assertEq(usdcVault.totalAssets(), 0);
        assertEq(usdc.balanceOf(address(usdcVault)), 0);
        assertEq(shareToken.balanceOf(user1), 0);

        // Now unregistration should succeed
        shareToken.unregisterVault(address(usdc));
        assertEq(shareToken.vault(address(usdc)), address(0));
    }

    /**
     * @dev Test that unregistration fails for non-existent vault
     */
    function testCannotUnregisterNonExistentVault() public {
        address fakeAsset = address(0x9999);

        vm.expectRevert(IERC7575Errors.AssetNotRegistered.selector);
        shareToken.unregisterVault(fakeAsset);
    }

    /**
     * @dev Test that unregistration fails with zero address
     */
    function testCannotUnregisterZeroAddress() public {
        vm.expectRevert(IERC7575Errors.ZeroAddress.selector);
        shareToken.unregisterVault(address(0));
    }

    /**
     * @dev Test multiple vault scenario - can only unregister empty vaults
     */
    function testMultipleVaultScenario() public {
        // User1 deposits in USDC vault
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);
        usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();

        // User2 deposits in DAI vault
        vm.startPrank(user2);
        dai.approve(address(daiVault), 100 * 10 ** 18);
        uint256 daiShares = daiVault.deposit(100 * 10 ** 18, user2);
        vm.stopPrank();

        // Cannot unregister either vault with outstanding assets
        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultAssetBalance.selector);
        shareToken.unregisterVault(address(usdc));

        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultAssetBalance.selector);
        shareToken.unregisterVault(address(dai));

        // User2 withdraws from DAI vault
        // Simulate complete withdrawal by vault transferring assets and burning shares
        uint256 daiAssets = dai.balanceOf(address(daiVault));

        vm.prank(address(daiVault));
        dai.transfer(user2, daiAssets);

        // Manually burn the user's shares to simulate complete withdrawal
        vm.prank(address(daiVault));
        shareToken.burn(user2, daiShares);

        // Verify DAI vault is now empty
        assertEq(daiVault.totalAssets(), 0);
        assertEq(dai.balanceOf(address(daiVault)), 0);
        assertEq(shareToken.balanceOf(user2), 0);

        // Now can unregister DAI vault but not USDC vault
        shareToken.unregisterVault(address(dai));
        assertEq(shareToken.vault(address(dai)), address(0));

        // USDC vault still cannot be unregistered
        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultAssetBalance.selector);
        shareToken.unregisterVault(address(usdc));
        assertEq(shareToken.vault(address(usdc)), address(usdcVault));
    }

    /**
     * @dev Test that vault registration authorization is properly cleaned up
     */
    function testVaultAuthorizationCleanup() public {
        // Verify vault is initially authorized
        assertEq(shareToken.vault(address(usdc)), address(usdcVault));

        // Vault can mint shares
        vm.prank(address(usdcVault));
        shareToken.mint(user1, 100);
        assertEq(shareToken.balanceOf(user1), 100);

        // Remove vault (it's empty so should succeed)
        shareToken.unregisterVault(address(usdc));

        // Verify vault is no longer registered
        assertEq(shareToken.vault(address(usdc)), address(0));

        // Verify vault can no longer mint shares (authorization removed)
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        vm.prank(address(usdcVault));
        shareToken.mint(user1, 100);
    }

    // Event declaration for testing
    event VaultUpdate(address indexed asset, address vault);
}
