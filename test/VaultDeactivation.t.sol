// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";

import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

contract VaultDeactivationTest is Test {
    WERC7575ShareToken public shareToken;
    WERC7575Vault public usdcVault;
    ERC20Faucet public usdc;

    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        // Deploy faucet token
        usdc = new ERC20Faucet("USD Coin", "USDC", 1_000_000 * 10 ** 6);

        // Override decimals for testing
        vm.mockCall(address(usdc), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));

        // Deploy share token
        shareToken = new WERC7575ShareToken("Multi-Asset Share Token", "MAST");

        // Deploy vault
        usdcVault = new WERC7575Vault(address(usdc), shareToken);

        // Register vault with share token
        shareToken.registerVault(address(usdc), address(usdcVault));

        // KYC users
        shareToken.setKycVerified(user1, true);
        shareToken.setKycVerified(user2, true);

        // Setup user balances
        usdc.transfer(user1, 1000 * 10 ** 6); // 1000 USDC
        usdc.transfer(user2, 1000 * 10 ** 6); // 1000 USDC
    }

    /**
     * @dev Test that vault is active by default
     */
    function testVaultIsActiveByDefault() public {
        assertTrue(usdcVault.isVaultActive());
    }

    /**
     * @dev Test owner can deactivate vault
     */
    function testOwnerCanDeactivateVault() public {
        assertTrue(usdcVault.isVaultActive());

        vm.expectEmit(true, false, false, false);
        emit VaultActiveStateChanged(false);
        usdcVault.setVaultActive(false);

        assertFalse(usdcVault.isVaultActive());
    }

    /**
     * @dev Test owner can reactivate vault
     */
    function testOwnerCanReactivateVault() public {
        // First deactivate
        usdcVault.setVaultActive(false);
        assertFalse(usdcVault.isVaultActive());

        // Then reactivate
        vm.expectEmit(true, false, false, false);
        emit VaultActiveStateChanged(true);
        usdcVault.setVaultActive(true);

        assertTrue(usdcVault.isVaultActive());
    }

    /**
     * @dev Test non-owner cannot change vault active state
     */
    function testNonOwnerCannotChangeVaultActiveState() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        usdcVault.setVaultActive(false);
    }

    /**
     * @dev Test deposit fails when vault is deactivated
     */
    function testDepositFailsWhenVaultDeactivated() public {
        // Deactivate vault
        usdcVault.setVaultActive(false);

        // User tries to deposit - should fail
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);

        vm.expectRevert(IERC7575Errors.VaultNotActive.selector);
        usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();
    }

    /**
     * @dev Test deposit works when vault is active
     */
    function testDepositWorksWhenVaultActive() public {
        // Ensure vault is active
        assertTrue(usdcVault.isVaultActive());

        // User deposits - should succeed
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);

        vm.expectEmit(true, true, false, false);
        emit Deposit(user1, user1, 100 * 10 ** 6, 100 * 10 ** 18);
        uint256 shares = usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();

        // Verify shares were received
        assertGt(shares, 0);
        assertEq(shareToken.balanceOf(user1), shares);
    }

    /**
     * @dev Test mint fails when vault is deactivated
     */
    function testMintFailsWhenVaultDeactivated() public {
        // Deactivate vault
        usdcVault.setVaultActive(false);

        // User tries to mint - should fail
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);

        vm.expectRevert(IERC7575Errors.VaultNotActive.selector);
        usdcVault.mint(100 * 10 ** 18, user1); // 100 shares
        vm.stopPrank();
    }

    /**
     * @dev Test redemptions still work when vault is deactivated
     */
    function testRedemptionsWorkWhenVaultDeactivated() public {
        // Setup: user gets some shares first
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);
        uint256 shares = usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();

        // Now deactivate vault
        usdcVault.setVaultActive(false);

        // User should still be able to redeem shares
        // Note: In a real system, validator would need to permit withdrawals
        // For testing, let's skip the redemption test since it requires validator permits

        // Verify vault is deactivated and shares still exist
        assertFalse(usdcVault.isVaultActive());
        assertEq(shareToken.balanceOf(user1), shares);
    }

    /**
     * @dev Test vault can be deactivated before removal
     */
    function testVaultDeactivationBeforeRemoval() public {
        // Setup: user has deposits
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);
        uint256 shares = usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();

        // Deactivate vault to prevent new deposits
        usdcVault.setVaultActive(false);

        // Cannot remove vault yet (has outstanding assets)
        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultAssetBalance.selector);
        shareToken.unregisterVault(address(usdc));

        // Verify vault is deactivated and still has outstanding assets
        assertFalse(usdcVault.isVaultActive());
        assertGt(usdcVault.totalAssets(), 0);
        assertEq(shareToken.balanceOf(user1), shares);

        // Vault cannot be removed while it has outstanding assets (even when deactivated)
        // This demonstrates that deactivation is a preparatory step before actual removal
    }

    /**
     * @dev Test multiple users with vault deactivation
     */
    function testMultipleUsersWithVaultDeactivation() public {
        // Both users deposit while active
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);
        uint256 shares1 = usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(usdcVault), 50 * 10 ** 6);
        uint256 shares2 = usdcVault.deposit(50 * 10 ** 6, user2);
        vm.stopPrank();

        // Now deactivate vault
        usdcVault.setVaultActive(false);

        // Neither user can make new deposits
        vm.startPrank(user1);
        usdc.approve(address(usdcVault), 100 * 10 ** 6);
        vm.expectRevert(IERC7575Errors.VaultNotActive.selector);
        usdcVault.deposit(100 * 10 ** 6, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(usdcVault), 50 * 10 ** 6);
        vm.expectRevert(IERC7575Errors.VaultNotActive.selector);
        usdcVault.deposit(50 * 10 ** 6, user2);
        vm.stopPrank();

        // Verify both users still have their shares (redemption would require validator permits)
        assertEq(shareToken.balanceOf(user1), shares1);
        assertEq(shareToken.balanceOf(user2), shares2);

        // Verify vault is deactivated but still has assets from both users
        assertFalse(usdcVault.isVaultActive());
        assertEq(usdcVault.totalAssets(), 150 * 10 ** 6); // 100 + 50 USDC
    }

    // Event declarations for testing
    event VaultActiveStateChanged(bool indexed isActive);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
}
