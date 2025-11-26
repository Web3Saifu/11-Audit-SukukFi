// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/WERC7575ShareToken.sol";
import "../src/WERC7575Vault.sol";
import "./MockAsset.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title EdgeCases_KYC
 * @notice Tests for KYC verification enforcement in WERC7575Vault
 *
 * IMPORTANT: WERC7575Vault (non-upgradeable, synchronous) DOES enforce KYC
 * - Synchronous deposit/mint operations
 * - KYC enforced at mint time (when receiver gets shares)
 * - Not async like ERC7575VaultUpgradeable (which uses requestDeposit)
 *
 * KYC Patterns Tested:
 * 1. Deposit fails if receiver not KYC verified
 * 2. Deposit succeeds if receiver is KYC verified
 * 3. Mint fails if receiver not KYC verified
 * 4. KYC revocation prevents future deposits
 * 5. KYC status is independent per account
 */
contract EdgeCasesKYC is Test {
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

        vm.stopPrank();

        // Approve vault for all accounts
        vm.prank(alice);
        asset.approve(address(vault), 500000e18);
        vm.prank(bob);
        asset.approve(address(vault), 500000e18);
        vm.prank(owner);
        asset.approve(address(vault), 500000e18);
    }

    // ========== TEST 1: No KYC Verification Initially ==========
    /**
     * @notice Accounts are not KYC verified by default
     */
    function testKYC_NoVerificationInitially() public {
        assertFalse(shareToken.isKycVerified(alice), "Alice should not be verified initially");
        assertFalse(shareToken.isKycVerified(bob), "Bob should not be verified initially");
    }

    // ========== TEST 2: Deposit Fails If Receiver Not KYC Verified ==========
    /**
     * @notice WERC7575Vault enforces KYC: cannot deposit to unverified receiver
     */
    function testKYC_DepositFailsIfReceiverNotVerified() public {
        // Alice is not KYC verified
        assertFalse(shareToken.isKycVerified(alice));

        // Try to deposit to unverified alice
        vm.prank(owner);
        vm.expectRevert(); // KycRequired
        vault.deposit(1000e18, alice);
    }

    // ========== TEST 3: Deposit Succeeds If Receiver Is KYC Verified ==========
    /**
     * @notice After KYC verification, deposit succeeds
     */
    function testKYC_DepositSucceedsIfReceiverVerified() public {
        // Verify alice
        vm.prank(owner);
        shareToken.setKycVerified(alice, true);

        // Now deposit to alice should succeed
        vm.prank(owner);
        uint256 shares = vault.deposit(1000e18, alice);

        assertTrue(shares > 0, "Deposit should succeed and return shares");
        assertEq(shareToken.balanceOf(alice), shares);
    }

    // ========== TEST 4: Mint Fails If Receiver Not KYC Verified ==========
    /**
     * @notice Mint also enforces KYC on receiver
     */
    function testKYC_MintFailsIfReceiverNotVerified() public {
        // Bob is not KYC verified
        assertFalse(shareToken.isKycVerified(bob));

        // Try to mint to unverified bob
        vm.prank(owner);
        vm.expectRevert(); // KycRequired
        vault.mint(1000e18, bob);
    }

    // ========== TEST 5: Mint Succeeds If Receiver Is KYC Verified ==========
    /**
     * @notice Mint succeeds after KYC verification
     */
    function testKYC_MintSucceedsIfReceiverVerified() public {
        // Verify bob
        vm.prank(owner);
        shareToken.setKycVerified(bob, true);

        // Mint to verified bob
        vm.prank(owner);
        uint256 assets = vault.mint(1000e18, bob);

        assertTrue(assets > 0, "Mint should succeed");
        assertEq(shareToken.balanceOf(bob), 1000e18);
    }

    // ========== TEST 6: KYC Admin Can Verify Accounts ==========
    /**
     * @notice KYC admin (owner) can mark accounts as verified
     */
    function testKYC_AdminCanVerify() public {
        vm.prank(owner);
        shareToken.setKycVerified(alice, true);

        assertTrue(shareToken.isKycVerified(alice));
    }

    // ========== TEST 7: KYC Admin Can Revoke Verification ==========
    /**
     * @notice KYC admin can revoke verification
     */
    function testKYC_AdminCanRevoke() public {
        // Verify alice
        vm.prank(owner);
        shareToken.setKycVerified(alice, true);
        assertTrue(shareToken.isKycVerified(alice));

        // Revoke alice
        vm.prank(owner);
        shareToken.setKycVerified(alice, false);

        assertFalse(shareToken.isKycVerified(alice));
    }

    // ========== TEST 8: Only KYC Admin Can Change Status ==========
    /**
     * @notice Non-admin cannot change KYC status
     */
    function testKYC_OnlyAdminCanChange() public {
        // Alice tries to verify bob
        vm.prank(alice);
        vm.expectRevert(); // OnlyKycAdmin
        shareToken.setKycVerified(bob, true);

        // Bob should still not be verified
        assertFalse(shareToken.isKycVerified(bob));
    }

    // ========== TEST 9: Multiple Accounts Can Be Verified ==========
    /**
     * @notice Admin can verify multiple accounts independently
     */
    function testKYC_MultipleAccounts() public {
        vm.prank(owner);
        shareToken.setKycVerified(alice, true);

        vm.prank(owner);
        shareToken.setKycVerified(bob, true);

        assertTrue(shareToken.isKycVerified(alice));
        assertTrue(shareToken.isKycVerified(bob));
    }

    // ========== TEST 10: KYC Status Is Independent Per Account ==========
    /**
     * @notice KYC verification is per-account
     */
    function testKYC_IndependentPerAccount() public {
        // Verify only alice
        vm.prank(owner);
        shareToken.setKycVerified(alice, true);

        assertTrue(shareToken.isKycVerified(alice));
        assertFalse(shareToken.isKycVerified(bob));

        // Verify bob too
        vm.prank(owner);
        shareToken.setKycVerified(bob, true);

        assertTrue(shareToken.isKycVerified(alice));
        assertTrue(shareToken.isKycVerified(bob));

        // Revoke alice only
        vm.prank(owner);
        shareToken.setKycVerified(alice, false);

        assertFalse(shareToken.isKycVerified(alice));
        assertTrue(shareToken.isKycVerified(bob));
    }

    // ========== TEST 11: KYC Status Can Be Toggled Multiple Times ==========
    /**
     * @notice KYC can be verified/revoked multiple times
     */
    function testKYC_MultipleCycles() public {
        for (uint256 i = 0; i < 5; i++) {
            bool shouldVerify = i % 2 == 0;
            vm.prank(owner);
            shareToken.setKycVerified(alice, shouldVerify);

            assertEq(shareToken.isKycVerified(alice), shouldVerify);
        }

        // After 5 cycles (verify, revoke, verify, revoke, verify) -> verified
        assertTrue(shareToken.isKycVerified(alice));
    }

    // ========== TEST 12: Revoked KYC Blocks Subsequent Deposits ==========
    /**
     * @notice After KYC revocation, deposits to that account fail
     */
    function testKYC_RevocationBlocksDeposits() public {
        // Verify and deposit to alice
        vm.prank(owner);
        shareToken.setKycVerified(alice, true);

        vm.prank(owner);
        uint256 shares1 = vault.deposit(1000e18, alice);
        assertTrue(shares1 > 0);

        // Revoke alice's KYC
        vm.prank(owner);
        shareToken.setKycVerified(alice, false);

        // Now deposit to alice should fail
        vm.prank(owner);
        vm.expectRevert(); // KycRequired
        vault.deposit(1000e18, alice);

        // But alice's original shares still exist
        assertEq(shareToken.balanceOf(alice), shares1);
    }
}
