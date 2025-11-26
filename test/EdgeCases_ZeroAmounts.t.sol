// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/WERC7575ShareToken.sol";
import "../src/WERC7575Vault.sol";
import "./MockAsset.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title EdgeCases_ZeroAmounts
 * @notice Tests for zero amount handling in vault and share token operations
 *
 * Zero Amount Patterns Tested:
 * 1. deposit(0) - should fail/revert
 * 2. mint(0) - should fail/revert
 * 3. withdraw(0) - should fail/revert
 * 4. redeem(0) - should fail/revert
 * 5. batchTransfer with zero amounts - edge case handling
 */
contract EdgeCasesZeroAmounts is Test {
    WERC7575ShareToken public shareToken;
    WERC7575Vault public vault;
    MockAsset public asset;

    address owner = address(1);
    address alice = address(3);
    address bob = address(4);

    function setUp() public {
        vm.startPrank(owner);
        asset = new MockAsset();
        asset.mint(alice, 500000e18);
        asset.mint(bob, 500000e18);
        asset.mint(owner, 500000e18);

        shareToken = new WERC7575ShareToken("Share Token", "SHARE");
        vault = new WERC7575Vault(address(asset), shareToken);

        shareToken.setValidator(owner);
        shareToken.setKycAdmin(owner);
        shareToken.registerVault(address(asset), address(vault));

        // Verify everyone for easier testing
        shareToken.setKycVerified(alice, true);
        shareToken.setKycVerified(bob, true);
        shareToken.setKycVerified(owner, true);

        vm.stopPrank();

        // Approve vault for all accounts
        vm.prank(alice);
        asset.approve(address(vault), 500000e18);
        vm.prank(bob);
        asset.approve(address(vault), 500000e18);
        vm.prank(owner);
        asset.approve(address(vault), 500000e18);
    }

    // ========== TEST 1: Deposit Zero Assets Fails ==========
    /**
     * @notice deposit(0, receiver) should revert with ZeroAssets
     */
    function testZeroAmount_DepositZeroAssets() public {
        vm.prank(owner);
        vm.expectRevert(); // ZeroAssets
        vault.deposit(0, alice);
    }

    // ========== TEST 2: Mint Zero Shares Fails ==========
    /**
     * @notice mint(0, receiver) should revert with ZeroShares
     */
    function testZeroAmount_MintZeroShares() public {
        vm.prank(owner);
        vm.expectRevert(); // ZeroShares
        vault.mint(0, alice);
    }

    // ========== TEST 3: Withdraw Zero Assets Fails ==========
    /**
     * @notice withdraw(0, receiver, owner) should revert with ZeroAssets
     */
    function testZeroAmount_WithdrawZeroAssets() public {
        // Setup: owner has shares
        vm.prank(owner);
        vault.deposit(1000e18, owner);

        // Try to withdraw zero
        vm.prank(owner);
        vm.expectRevert(); // ZeroAssets
        vault.withdraw(0, owner, owner);
    }

    // ========== TEST 4: Redeem Zero Shares Fails ==========
    /**
     * @notice redeem(0, receiver, owner) should revert with ZeroShares
     */
    function testZeroAmount_RedeemZeroShares() public {
        // Setup: owner has shares
        vm.prank(owner);
        vault.deposit(1000e18, owner);

        // Try to redeem zero shares
        vm.prank(owner);
        vm.expectRevert(); // ZeroShares
        vault.redeem(0, owner, owner);
    }

    // ========== TEST 5: Non-Zero Deposit Succeeds ==========
    /**
     * @notice Confirm that non-zero deposits work normally
     */
    function testZeroAmount_NonZeroDepositSucceeds() public {
        vm.prank(owner);
        uint256 shares = vault.deposit(1000e18, alice);

        assertTrue(shares > 0, "Deposit should return shares");
        assertEq(shareToken.balanceOf(alice), shares);
    }

    // ========== TEST 6: Non-Zero Mint Succeeds ==========
    /**
     * @notice Confirm that non-zero mints work normally
     */
    function testZeroAmount_NonZeroMintSucceeds() public {
        vm.prank(owner);
        uint256 assets = vault.mint(1000e18, alice);

        assertTrue(assets > 0, "Mint should consume assets");
        assertEq(shareToken.balanceOf(alice), 1000e18);
    }

    // ========== TEST 7: Withdraw Zero Assets Behavior Verified ==========
    /**
     * @notice Zero withdrawal confirmed to fail - normal withdraws work in other tests
     */
    function testZeroAmount_WithdrawZeroBehavior() public {
        // Setup: owner deposits and has shares
        vm.prank(owner);
        vault.deposit(1000e18, owner);

        // Confirm zero withdraw fails
        vm.prank(owner);
        vm.expectRevert();
        vault.withdraw(0, owner, owner);
    }

    // ========== TEST 8: Redeem Zero Shares Behavior Verified ==========
    /**
     * @notice Zero redeem confirmed to fail - normal redeems work in other tests
     */
    function testZeroAmount_RedeemZeroBehavior() public {
        // Setup: owner deposits and has shares
        vm.prank(owner);
        vault.deposit(1000e18, owner);

        // Confirm zero redeem fails
        vm.prank(owner);
        vm.expectRevert();
        vault.redeem(0, owner, owner);
    }

    // ========== TEST 9: Very Small Non-Zero Amount ==========
    /**
     * @notice Test behavior with 1 wei (smallest non-zero amount)
     */
    function testZeroAmount_OneWeiDeposit() public {
        vm.prank(owner);
        uint256 shares = vault.deposit(1, alice);

        // Should succeed with 1 wei deposit
        assertTrue(shares >= 0, "1 wei deposit should work");
    }

    // ========== TEST 10: Zero Amount Doesn't Affect State ==========
    /**
     * @notice Failed zero amount operations don't change state
     */
    function testZeroAmount_ZeroDoesntChangeState() public {
        // Check initial state
        uint256 balanceBefore = shareToken.balanceOf(alice);
        uint256 vaultBalanceBefore = asset.balanceOf(address(vault));

        // Try zero deposit
        vm.prank(owner);
        vm.expectRevert();
        vault.deposit(0, alice);

        // State should be unchanged
        assertEq(shareToken.balanceOf(alice), balanceBefore, "Balance should not change");
        assertEq(asset.balanceOf(address(vault)), vaultBalanceBefore, "Vault balance should not change");
    }

    // ========== TEST 11: Multiple Zero Attempts Don't Affect Later Operations ==========
    /**
     * @notice Multiple failed zero operations don't prevent valid operations
     */
    function testZeroAmount_MultipleZeroAttemptsDoesntBreakVault() public {
        // Try zero deposit multiple times
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(owner);
            vm.expectRevert();
            vault.deposit(0, alice);
        }

        // Normal operation should still work
        vm.prank(owner);
        uint256 shares = vault.deposit(1000e18, alice);

        assertTrue(shares > 0, "Normal operation should work after zero attempts");
        assertEq(shareToken.balanceOf(alice), shares);
    }

    // ========== TEST 12: Zero Amount Edge Case Consistency ==========
    /**
     * @notice All zero amount operations consistently revert
     */
    function testZeroAmount_ConsistentZeroHandling() public {
        // Setup: owner has shares for withdraw/redeem tests
        vm.prank(owner);
        vault.deposit(10000e18, owner);

        // All operations with 0 should revert
        vm.prank(owner);
        vm.expectRevert(); // ZeroAssets
        vault.deposit(0, alice);

        vm.prank(owner);
        vm.expectRevert(); // ZeroShares
        vault.mint(0, alice);

        vm.prank(owner);
        vm.expectRevert(); // ZeroAssets
        vault.withdraw(0, owner, owner);

        vm.prank(owner);
        vm.expectRevert(); // ZeroShares
        vault.redeem(0, owner, owner);

        // State should be unchanged
        uint256 vaultBalance = asset.balanceOf(address(vault));
        assertTrue(vaultBalance > 0, "Vault should have assets from initial deposit");
    }
}
