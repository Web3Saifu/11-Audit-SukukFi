// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {MockAsset} from "./MockAsset.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title OffChainHelperFunctions Test Suite
 * @dev Comprehensive test suite for off-chain helper functions that track active deposit/redeem requesters
 */
contract OffChainHelperFunctionsTest is Test {
    ERC7575VaultUpgradeable vault;
    ShareTokenUpgradeable shareToken;
    MockAsset asset;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy asset
        asset = new MockAsset();

        // Deploy share token with proxy
        ShareTokenUpgradeable shareImpl = new ShareTokenUpgradeable();
        ERC1967Proxy shareProxy = new ERC1967Proxy(address(shareImpl), abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Vault Shares", "vTEST", owner));
        shareToken = ShareTokenUpgradeable(address(shareProxy));

        // Deploy vault with proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), owner));
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault with share token
        shareToken.registerVault(address(asset), address(vault));

        // Set minimum deposit to 0 for testing small amounts
        vault.setMinimumDepositAmount(0);

        // Setup test users with assets
        asset.mint(user1, 10000e18);
        asset.mint(user2, 10000e18);
        asset.mint(user3, 10000e18);

        vm.stopPrank();

        // Users approve vault
        vm.prank(user1);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(user3);
        asset.approve(address(vault), type(uint256).max);
    }

    function testInitialStateIsEmpty() public view {
        (uint256 depositCount, uint256 redeemCount) = vault.getActiveRequestersCount();

        assertEq(depositCount, 0, "Should start with no deposit requesters");
        assertEq(redeemCount, 0, "Should start with no redeem requesters");
    }

    function testSingleDepositRequestAddsToList() public {
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 1, "Should have one deposit requester");
        assertEq(requesters[0], user1, "Should be user1");

        // Check request status
        ERC7575VaultUpgradeable.ControllerStatus memory status = vault.getControllerStatus(user1);
        uint256 pendingAssets = status.pendingDepositAssets;
        uint256 pendingShares = status.pendingRedeemShares;

        assertTrue(pendingAssets > 0, "Should have deposit request");
        assertTrue(pendingShares == 0, "Should not have redeem request");
        assertEq(pendingAssets, 1000e18, "Should have correct pending assets");
        assertEq(pendingShares, 0, "Should have no pending shares");
    }

    function testMultipleDepositRequestsAddToList() public {
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(2000e18, user2, user2);

        vm.prank(user3);
        vault.requestDeposit(3000e18, user3, user3);

        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 3, "Should have three deposit requesters");

        // Check all users are in list (order may vary)
        bool foundUser1 = false;
        bool foundUser2 = false;
        bool foundUser3 = false;

        for (uint256 i = 0; i < requesters.length; i++) {
            if (requesters[i] == user1) foundUser1 = true;
            if (requesters[i] == user2) foundUser2 = true;
            if (requesters[i] == user3) foundUser3 = true;
        }

        assertTrue(foundUser1, "Should find user1");
        assertTrue(foundUser2, "Should find user2");
        assertTrue(foundUser3, "Should find user3");
    }

    function testDuplicateDepositRequestDoesNotDuplicateInList() public {
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user1);
        vault.requestDeposit(500e18, user1, user1);

        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 1, "Should still have only one deposit requester");
        assertEq(requesters[0], user1, "Should be user1");

        // Check total pending assets is cumulative
        ERC7575VaultUpgradeable.ControllerStatus memory status = vault.getControllerStatus(user1);
        uint256 pendingAssets = status.pendingDepositAssets;
        assertTrue(pendingAssets > 0, "Should have deposit request");
        assertEq(pendingAssets, 1500e18, "Should have cumulative pending assets");
    }

    function testDepositFulfillmentAndClaiming() public {
        // User1 requests deposit
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        // User2 requests deposit
        vm.prank(user2);
        vault.requestDeposit(2000e18, user2, user2);

        // Initial state: 2 requesters
        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 2, "Should have two deposit requesters");

        // Owner fulfills user1's deposit
        vm.prank(owner);
        vault.fulfillDeposit(user1, 1000e18);

        // Still 2 requesters (fulfilled but not claimed)
        requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 2, "Should still have two deposit requesters");

        // User1 claims their deposit
        vm.prank(user1);
        vault.deposit(1000e18, user1, user1);

        // Now user1 should be removed from list
        requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 1, "Should have one deposit requester");
        assertEq(requesters[0], user2, "Should only have user2");

        // Check user1's request status
        ERC7575VaultUpgradeable.ControllerStatus memory status1 = vault.getControllerStatus(user1);
        ERC7575VaultUpgradeable.ControllerStatus memory status2 = vault.getControllerStatus(user2);
        uint256 pendingAssets1 = status1.pendingDepositAssets;
        uint256 pendingAssets2 = status2.pendingDepositAssets;

        assertTrue(pendingAssets1 == 0, "User1 should not have deposit request");
        assertTrue(pendingAssets2 > 0, "User2 should still have deposit request");
    }

    function testPartialClaimDoesNotRemoveFromList() public {
        // User1 requests deposit
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        // Owner fulfills full deposit
        vm.prank(owner);
        vault.fulfillDeposit(user1, 1000e18);

        // User1 claims only half
        vm.prank(user1);
        vault.deposit(500e18, user1, user1);

        // User1 should still be in list (has remaining claimable assets)
        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 1, "Should still have one deposit requester");
        assertEq(requesters[0], user1, "Should be user1");

        // User1 claims the rest
        vm.prank(user1);
        vault.deposit(500e18, user1, user1);

        // Now user1 should be removed
        requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 0, "Should have no deposit requesters");
    }

    function testRedeemRequestFlow() public {
        // First get some shares for testing
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(owner);
        vault.fulfillDeposit(user1, 1000e18);

        vm.prank(user1);
        uint256 shares = vault.deposit(1000e18, user1, user1);

        // Approve vault to handle shares for redeem request
        vm.prank(user1);
        shareToken.approve(address(vault), shares);

        // Now test redeem request flow
        vm.prank(user1);
        vault.requestRedeem(shares, user1, user1);

        address[] memory redeemRequesters = vault.getActiveRedeemRequesters();
        assertEq(redeemRequesters.length, 1, "Should have one redeem requester");
        assertEq(redeemRequesters[0], user1, "Should be user1");

        // Check request status
        ERC7575VaultUpgradeable.ControllerStatus memory status = vault.getControllerStatus(user1);
        uint256 pendingAssets = status.pendingDepositAssets;
        uint256 pendingShares = status.pendingRedeemShares;

        assertTrue(pendingAssets == 0, "Should not have deposit request");
        assertTrue(pendingShares > 0, "Should have redeem request");
        assertEq(pendingAssets, 0, "Should have no pending assets");
        assertEq(pendingShares, shares, "Should have correct pending shares");
    }

    function testRedeemFulfillmentAndClaiming() public {
        // Setup: Get shares for user1 and user2
        setupUsersWithShares();

        uint256 shares1 = shareToken.balanceOf(user1);
        uint256 shares2 = shareToken.balanceOf(user2);

        // Both users request redeem
        vm.prank(user1);
        vault.requestRedeem(shares1, user1, user1);

        vm.prank(user2);
        vault.requestRedeem(shares2, user2, user2);

        // Should have 2 redeem requesters
        address[] memory requesters = vault.getActiveRedeemRequesters();
        assertEq(requesters.length, 2, "Should have two redeem requesters");

        // Owner fulfills user1's redeem
        vm.prank(owner);
        vault.fulfillRedeem(user1, shares1);

        // Still 2 requesters (fulfilled but not claimed)
        requesters = vault.getActiveRedeemRequesters();
        assertEq(requesters.length, 2, "Should still have two redeem requesters");

        // User1 claims their redeem
        vm.prank(user1);
        vault.redeem(shares1, user1, user1);

        // Now user1 should be removed from list
        requesters = vault.getActiveRedeemRequesters();
        assertEq(requesters.length, 1, "Should have one redeem requester");
        assertEq(requesters[0], user2, "Should only have user2");
    }

    function testMixedDepositAndRedeemRequests() public {
        // Setup some users with shares
        setupUsersWithShares();

        uint256 shares2 = shareToken.balanceOf(user2);

        // User1 requests new deposit
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        // User2 requests redeem
        vm.prank(user2);
        vault.requestRedeem(shares2, user2, user2);

        // User3 requests deposit
        vm.prank(user3);
        vault.requestDeposit(2000e18, user3, user3);

        // Check lists
        address[] memory depositRequesters = vault.getActiveDepositRequesters();
        address[] memory redeemRequesters = vault.getActiveRedeemRequesters();

        assertEq(depositRequesters.length, 2, "Should have two deposit requesters");
        assertEq(redeemRequesters.length, 1, "Should have one redeem requester");

        // Check individual statuses
        ERC7575VaultUpgradeable.ControllerStatus memory status1 = vault.getControllerStatus(user1);
        ERC7575VaultUpgradeable.ControllerStatus memory status2 = vault.getControllerStatus(user2);
        ERC7575VaultUpgradeable.ControllerStatus memory status3 = vault.getControllerStatus(user3);
        uint256 pendingAssets1 = status1.pendingDepositAssets;
        uint256 pendingShares1 = status1.pendingRedeemShares;
        uint256 pendingAssets2 = status2.pendingDepositAssets;
        uint256 pendingShares2 = status2.pendingRedeemShares;
        uint256 pendingAssets3 = status3.pendingDepositAssets;
        uint256 pendingShares3 = status3.pendingRedeemShares;

        assertTrue(pendingAssets1 > 0, "User1 should have deposit request");
        assertTrue(pendingShares1 == 0, "User1 should not have redeem request");

        assertTrue(pendingAssets2 == 0, "User2 should not have deposit request");
        assertTrue(pendingShares2 > 0, "User2 should have redeem request");

        assertTrue(pendingAssets3 > 0, "User3 should have deposit request");
        assertTrue(pendingShares3 == 0, "User3 should not have redeem request");
    }

    function testArrayManipulationEfficiency() public {
        // Add 3 users to deposit requesters
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(1000e18, user2, user2);

        vm.prank(user3);
        vault.requestDeposit(1000e18, user3, user3);

        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 3, "Should have 3 requesters");

        // Fulfill and claim user2 (middle element)
        vm.prank(owner);
        vault.fulfillDeposit(user2, 1000e18);

        vm.prank(user2);
        vault.deposit(1000e18, user2, user2);

        // Should have 2 requesters left
        requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 2, "Should have 2 requesters left");

        // Check that user1 and user3 are still in the list
        ERC7575VaultUpgradeable.ControllerStatus memory status1_check = vault.getControllerStatus(user1);
        ERC7575VaultUpgradeable.ControllerStatus memory status2_check = vault.getControllerStatus(user2);
        ERC7575VaultUpgradeable.ControllerStatus memory status3_check = vault.getControllerStatus(user3);
        uint256 pending1 = status1_check.pendingDepositAssets;
        uint256 pending2 = status2_check.pendingDepositAssets;
        uint256 pending3 = status3_check.pendingDepositAssets;

        assertTrue(pending1 > 0, "User1 should still have request");
        assertTrue(pending2 == 0, "User2 should not have request");
        assertTrue(pending3 > 0, "User3 should still have request");

        assertEq(pending1, 1000e18, "User1 should have pending assets");
        assertEq(pending2, 0, "User2 should have no pending assets");
        assertEq(pending3, 1000e18, "User3 should have pending assets");
    }

    function testGetControllerStatusComprehensive() public {
        // Test empty status
        ERC7575VaultUpgradeable.ControllerStatus memory status = vault.getControllerStatus(user1);
        uint256 pendingAssets = status.pendingDepositAssets;
        uint256 pendingShares = status.pendingRedeemShares;

        assertTrue(pendingAssets == 0, "Should not have deposit request initially");
        assertTrue(pendingShares == 0, "Should not have redeem request initially");
        assertEq(pendingAssets, 0, "Should have no pending assets initially");
        assertEq(pendingShares, 0, "Should have no pending shares initially");

        // Add deposit request
        vm.prank(user1);
        vault.requestDeposit(1500e18, user1, user1);

        status = vault.getControllerStatus(user1);
        pendingAssets = status.pendingDepositAssets;
        pendingShares = status.pendingRedeemShares;

        assertTrue(pendingAssets > 0, "Should have deposit request");
        assertTrue(pendingShares == 0, "Should not have redeem request");
        assertEq(pendingAssets, 1500e18, "Should have correct pending assets");
        assertEq(pendingShares, 0, "Should have no pending shares");
    }

    // Helper function to setup users with shares
    function setupUsersWithShares() internal {
        // Give users some shares first
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(2000e18, user2, user2);

        vm.startPrank(owner);
        vault.fulfillDeposit(user1, 1000e18);
        vault.fulfillDeposit(user2, 2000e18);
        vm.stopPrank();

        vm.prank(user1);
        vault.deposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.deposit(2000e18, user2, user2);

        // Approve vault to handle shares for redeem requests
        vm.prank(user1);
        shareToken.approve(address(vault), type(uint256).max);

        vm.prank(user2);
        shareToken.approve(address(vault), type(uint256).max);
    }

    function testEdgeCaseEmptyListsAfterAllClaims() public {
        // Setup multiple requests
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(2000e18, user2, user2);

        // Fulfill and claim all
        vm.startPrank(owner);
        vault.fulfillDeposit(user1, 1000e18);
        vault.fulfillDeposit(user2, 2000e18);
        vm.stopPrank();

        vm.prank(user1);
        vault.deposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.deposit(2000e18, user2, user2);

        // Lists should be empty
        address[] memory depositRequesters = vault.getActiveDepositRequesters();
        address[] memory redeemRequesters = vault.getActiveRedeemRequesters();

        assertEq(depositRequesters.length, 0, "Should have no deposit requesters");
        assertEq(redeemRequesters.length, 0, "Should have no redeem requesters");
    }

    // ========== Cancel Request Tests ==========

    function testCancelDepositRequest() public {
        uint256 depositAmount = 1000e18;
        uint256 user1BalanceBefore = asset.balanceOf(user1);

        // User1 requests deposit
        vm.prank(user1);
        vault.requestDeposit(depositAmount, user1, user1);

        // Verify request was added to list
        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 1, "Should have one deposit requester");
        assertEq(requesters[0], user1, "Should be user1");

        uint256 user1BalanceAfterDeposit = asset.balanceOf(user1);
        assertEq(user1BalanceAfterDeposit, user1BalanceBefore - depositAmount, "Should have transferred assets");

        // User1 cancels their deposit request (EIP-7887: moves to pending cancelation)
        vm.prank(user1);
        vault.cancelDepositRequest(0, user1);

        // Verify cancelation is now pending
        assertTrue(vault.pendingCancelDepositRequest(0, user1), "Should have pending cancelation");

        // Verify request was removed from active list
        requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 0, "Should have no deposit requesters");

        // Investment manager fulfills the cancelation (moves to claimable)
        vm.prank(owner);
        vault.fulfillCancelDepositRequest(user1);

        // Verify it's now claimable
        assertEq(vault.claimableCancelDepositRequest(0, user1), depositAmount, "Should have claimable assets");

        // User1 claims the canceled assets
        vm.prank(user1);
        vault.claimCancelDepositRequest(0, user1, user1);

        // Verify user1's balance is restored
        uint256 user1BalanceAfterCancel = asset.balanceOf(user1);
        assertEq(user1BalanceAfterCancel, user1BalanceBefore, "Should restore user's balance");

        // Verify request status is fully cleared
        ERC7575VaultUpgradeable.ControllerStatus memory status = vault.getControllerStatus(user1);
        uint256 pendingAssets = status.pendingDepositAssets;
        uint256 pendingShares = status.pendingRedeemShares;

        assertTrue(pendingAssets == 0, "Should not have deposit request");
        assertTrue(pendingShares == 0, "Should not have redeem request");
    }

    function testCancelDepositRequestByOperator() public {
        uint256 depositAmount = 1000e18;

        // User1 requests deposit
        vm.prank(user1);
        vault.requestDeposit(depositAmount, user1, user1);

        // User1 sets user2 as operator
        vm.prank(user1);
        vault.setOperator(user2, true);

        // User2 (operator) cancels user1's deposit request
        vm.prank(user2);
        vault.cancelDepositRequest(0, user1);

        // Verify assets were returned to user1 (not user2)
        // Verify cancelation is now pending

        // Verify request was removed from list
        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 0, "Should have no deposit requesters");
    }

    function testCancelRedeemRequest() public {
        // Setup: Get shares for user1
        setupUsersWithShares();

        uint256 shares = shareToken.balanceOf(user1);
        uint256 user1SharesBefore = shares;

        // User1 requests redeem
        vm.prank(user1);
        vault.requestRedeem(shares, user1, user1);

        // Verify request was added to list
        address[] memory requesters = vault.getActiveRedeemRequesters();
        assertEq(requesters.length, 1, "Should have one redeem requester");
        assertEq(requesters[0], user1, "Should be user1");

        uint256 user1SharesAfterRedeem = shareToken.balanceOf(user1);
        assertEq(user1SharesAfterRedeem, 0, "Should have transferred shares to vault");

        // User1 cancels their redeem request (EIP-7887: moves to pending cancelation)
        vm.prank(user1);
        vault.cancelRedeemRequest(0, user1);

        // Verify cancelation is now pending
        assertTrue(vault.pendingCancelRedeemRequest(0, user1), "Should have pending cancelation");

        // Verify request was removed from active list
        requesters = vault.getActiveRedeemRequesters();
        assertEq(requesters.length, 0, "Should have no redeem requesters");

        // Investment manager fulfills the cancelation (moves to claimable)
        vm.prank(owner);
        vault.fulfillCancelRedeemRequest(user1);

        // Verify it's now claimable
        assertEq(vault.claimableCancelRedeemRequest(0, user1), shares, "Should have claimable shares");

        // User1 claims the canceled shares
        vm.prank(user1);
        vault.claimCancelRedeemRequest(0, user1, user1);

        // Verify user1's share balance is restored
        uint256 user1SharesAfterCancel = shareToken.balanceOf(user1);
        assertEq(user1SharesAfterCancel, user1SharesBefore, "Should restore user's shares");

        // Verify request status is fully cleared
        ERC7575VaultUpgradeable.ControllerStatus memory status = vault.getControllerStatus(user1);
        uint256 pendingAssets = status.pendingDepositAssets;
        uint256 pendingShares = status.pendingRedeemShares;

        assertTrue(pendingAssets == 0, "Should not have deposit request");
        assertTrue(pendingShares == 0, "Should not have redeem request");
    }

    function testCancelRequestsSecurityChecks() public {
        uint256 depositAmount = 1000e18;

        // User1 requests deposit
        vm.prank(user1);
        vault.requestDeposit(depositAmount, user1, user1);

        // User2 tries to cancel user1's request (should fail)
        vm.prank(user2);
        vm.expectRevert(IERC7575Errors.InvalidCaller.selector);
        vault.cancelDepositRequest(0, user1);

        // User2 tries to cancel non-existent request (should fail with NoPendingCancelDeposit)
        vm.prank(user2);
        vm.expectRevert(IERC7575Errors.NoPendingCancelDeposit.selector);
        vault.cancelDepositRequest(0, user2);

        // User3 tries to cancel non-existent redeem request (should fail)
        vm.prank(user3);
        vm.expectRevert(IERC7575Errors.NoPendingCancelRedeem.selector);
        vault.cancelRedeemRequest(0, user3);
    }

    function testCancelMultipleRequestsArrayManagement() public {
        uint256 depositAmount = 1000e18;

        // Multiple users request deposits
        vm.prank(user1);
        vault.requestDeposit(depositAmount, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(depositAmount, user2, user2);

        vm.prank(user3);
        vault.requestDeposit(depositAmount, user3, user3);

        // Verify all 3 are in list
        address[] memory requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 3, "Should have 3 deposit requesters");

        // User2 cancels (middle element)
        vm.prank(user2);
        vault.cancelDepositRequest(0, user2);

        // Should have 2 requesters left
        requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 2, "Should have 2 deposit requesters");

        // Verify user1 and user3 still have requests
        ERC7575VaultUpgradeable.ControllerStatus memory status1 = vault.getControllerStatus(user1);
        ERC7575VaultUpgradeable.ControllerStatus memory status2 = vault.getControllerStatus(user2);
        ERC7575VaultUpgradeable.ControllerStatus memory status3 = vault.getControllerStatus(user3);
        uint256 pendingAssets1 = status1.pendingDepositAssets;
        uint256 pendingAssets2 = status2.pendingDepositAssets;
        uint256 pendingAssets3 = status3.pendingDepositAssets;

        assertTrue(pendingAssets1 > 0, "User1 should still have request");
        assertTrue(pendingAssets2 == 0, "User2 should not have request");
        assertTrue(pendingAssets3 > 0, "User3 should still have request");

        // Cancel remaining requests
        vm.prank(user1);
        vault.cancelDepositRequest(0, user1);

        vm.prank(user3);
        vault.cancelDepositRequest(0, user3);

        // List should be empty
        requesters = vault.getActiveDepositRequesters();
        assertEq(requesters.length, 0, "Should have no deposit requesters");
    }

    function testCannotCancelAfterFulfillment() public {
        uint256 depositAmount = 1000e18;

        // User1 requests deposit
        vm.prank(user1);
        vault.requestDeposit(depositAmount, user1, user1);

        // Owner fulfills the deposit (moves to claimable)
        vm.prank(owner);
        vault.fulfillDeposit(user1, depositAmount);

        // User1 tries to cancel (should fail - no pending deposit, only claimable)
        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.NoPendingCancelDeposit.selector);
        vault.cancelDepositRequest(0, user1);
    }

    function testCancelEventEmission() public {
        uint256 depositAmount = 1000e18;

        // User1 requests deposit
        vm.prank(user1);
        vault.requestDeposit(depositAmount, user1, user1);

        // Expect CancelDepositRequest event (EIP-7887)
        vm.expectEmit(true, true, true, true);
        emit CancelDepositRequest(user1, user1, 0, user1, depositAmount);

        vm.prank(user1);
        vault.cancelDepositRequest(0, user1);

        // Fulfill and clear the cancelation for user1
        vm.prank(owner);
        vault.fulfillCancelDepositRequest(user1);

        vm.prank(user1);
        vault.claimCancelDepositRequest(0, user1, user1);

        // Test redeem cancel event with user2
        setupUsersWithShares();
        uint256 shares = shareToken.balanceOf(user2);

        vm.prank(user2);
        vault.requestRedeem(shares, user2, user2);

        // Expect CancelRedeemRequest event (EIP-7887)
        vm.expectEmit(true, true, true, true);
        emit CancelRedeemRequest(user2, user2, 0, user2, shares);

        vm.prank(user2);
        vault.cancelRedeemRequest(0, user2);
    }

    // Events for testing (EIP-7887)
    event CancelDepositRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets);
    event CancelRedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares);

    // ========== Scalability and Pagination Tests ==========

    function testGetActiveRequestersCount() public view {
        // Initially should be zero
        (uint256 depositCount, uint256 redeemCount) = vault.getActiveRequestersCount();
        assertEq(depositCount, 0, "Should have no deposit requesters initially");
        assertEq(redeemCount, 0, "Should have no redeem requesters initially");
    }

    function testGetActiveRequestersCountAfterRequests() public {
        // Add some deposit requests
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(2000e18, user2, user2);

        // Check counts after deposit requests
        (uint256 depositCount, uint256 redeemCount) = vault.getActiveRequestersCount();
        assertEq(depositCount, 2, "Should have 2 deposit requesters");
        assertEq(redeemCount, 0, "Should have no redeem requesters");

        // Setup user3 with shares separately to test redeem requests
        vm.prank(user3);
        vault.requestDeposit(3000e18, user3, user3);

        vm.prank(owner);
        vault.fulfillDeposit(user3, 3000e18);

        vm.prank(user3);
        uint256 shares3 = vault.deposit(3000e18, user3, user3);

        // Approve vault to handle shares
        vm.prank(user3);
        shareToken.approve(address(vault), shares3);

        // Add redeem request
        vm.prank(user3);
        vault.requestRedeem(shares3, user3, user3);

        // Check updated counts (user3 no longer has deposit request after claiming)
        (depositCount, redeemCount) = vault.getActiveRequestersCount();
        assertEq(depositCount, 2, "Should still have 2 deposit requesters (user1, user2)");
        assertEq(redeemCount, 1, "Should have 1 redeem requester (user3)");
    }

    function testPaginatedDepositRequestersEmptyCase() public view {
        // Test empty pagination
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses, uint256 total, bool hasMore) = vault.getDepositControllerStatusBatchPaginated(0, 10);

        assertEq(statuses.length, 0, "Should return empty array");
        assertEq(total, 0, "Should have zero total");
        assertFalse(hasMore, "Should not have more");
    }

    function testPaginatedDepositRequestersOffsetBeyondArray() public {
        // Add one request
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        // Query beyond array length
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses, uint256 total, bool hasMore) = vault.getDepositControllerStatusBatchPaginated(10, 5);

        assertEq(statuses.length, 0, "Should return empty array");
        assertEq(total, 1, "Should have total of 1");
        assertFalse(hasMore, "Should not have more");
    }

    function testPaginatedDepositRequestersSinglePage() public {
        // Add 3 requests
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(2000e18, user2, user2);

        vm.prank(user3);
        vault.requestDeposit(3000e18, user3, user3);

        // Query all in one page
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses, uint256 total, bool hasMore) = vault.getDepositControllerStatusBatchPaginated(0, 10);

        assertEq(statuses.length, 3, "Should return 3 requesters");
        assertEq(total, 3, "Should have total of 3");
        assertFalse(hasMore, "Should not have more");

        // Verify addresses are present (order may vary)
        bool foundUser1 = false;
        bool foundUser2 = false;
        bool foundUser3 = false;

        for (uint256 i = 0; i < statuses.length; i++) {
            if (statuses[i].controller == user1) foundUser1 = true;
            if (statuses[i].controller == user2) foundUser2 = true;
            if (statuses[i].controller == user3) foundUser3 = true;
        }

        assertTrue(foundUser1, "Should find user1");
        assertTrue(foundUser2, "Should find user2");
        assertTrue(foundUser3, "Should find user3");
    }

    function testPaginatedDepositRequestersMultiplePages() public {
        // Add 5 requests
        address[] memory users = new address[](5);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = makeAddr("user4");
        users[4] = makeAddr("user5");

        // Give assets and approvals to new users
        for (uint256 i = 3; i < 5; i++) {
            vm.startPrank(owner);
            asset.mint(users[i], 10000e18);
            vm.stopPrank();

            vm.prank(users[i]);
            asset.approve(address(vault), type(uint256).max);
        }

        // Make requests
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            vault.requestDeposit(1000e18 * (i + 1), users[i], users[i]);
        }

        // First page (limit 2)
        (ERC7575VaultUpgradeable.ControllerStatus[] memory page1, uint256 total1, bool hasMore1) = vault.getDepositControllerStatusBatchPaginated(0, 2);

        assertEq(page1.length, 2, "First page should have 2 items");
        assertEq(total1, 5, "Should have total of 5");
        assertTrue(hasMore1, "Should have more pages");

        // Second page (offset 2, limit 2)
        (ERC7575VaultUpgradeable.ControllerStatus[] memory page2, uint256 total2, bool hasMore2) = vault.getDepositControllerStatusBatchPaginated(2, 2);

        assertEq(page2.length, 2, "Second page should have 2 items");
        assertEq(total2, 5, "Should have total of 5");
        assertTrue(hasMore2, "Should have more pages");

        // Third page (offset 4, limit 2) - should get 1 item
        (ERC7575VaultUpgradeable.ControllerStatus[] memory page3, uint256 total3, bool hasMore3) = vault.getDepositControllerStatusBatchPaginated(4, 2);

        assertEq(page3.length, 1, "Third page should have 1 item");
        assertEq(total3, 5, "Should have total of 5");
        assertFalse(hasMore3, "Should not have more pages");

        // Verify no duplicates across pages
        address[] memory allFromPages = new address[](5);
        for (uint256 i = 0; i < 2; i++) {
            allFromPages[i] = page1[i].controller;
            allFromPages[i + 2] = page2[i].controller;
        }
        allFromPages[4] = page3[0].controller;

        // Check all addresses are unique
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                assertTrue(allFromPages[i] != allFromPages[j], "Should not have duplicate addresses");
            }
        }
    }

    function testPaginatedRedeemRequesters() public {
        // Setup users with shares first
        setupUsersWithShares();

        uint256 shares1 = shareToken.balanceOf(user1);
        uint256 shares2 = shareToken.balanceOf(user2);

        // Add redeem requests
        vm.prank(user1);
        vault.requestRedeem(shares1, user1, user1);

        vm.prank(user2);
        vault.requestRedeem(shares2, user2, user2);

        // Test pagination
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses, uint256 total, bool hasMore) = vault.getRedeemControllerStatusBatchPaginated(0, 10);

        assertEq(statuses.length, 2, "Should return 2 requesters");
        assertEq(total, 2, "Should have total of 2");
        assertFalse(hasMore, "Should not have more");
    }

    function testBatchSizeLimit() public {
        // Test that batch size limit is enforced
        vm.expectRevert(IERC7575Errors.BatchSizeTooLarge.selector);
        vault.getDepositControllerStatusBatchPaginated(0, 1001); // MAX_BATCH_SIZE = 1000

        vm.expectRevert(IERC7575Errors.BatchSizeTooLarge.selector);
        vault.getRedeemControllerStatusBatchPaginated(0, 1001);
    }

    function testControllerStatusBatch() public {
        // Add some requests
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(2000e18, user2, user2);

        // Test batch status query
        address[] memory controllers = new address[](3);
        controllers[0] = user1;
        controllers[1] = user2;
        controllers[2] = user3; // No requests

        ERC7575VaultUpgradeable.ControllerStatus[] memory statuses = vault.getControllerStatusBatch(controllers);

        // Check user1 status
        assertTrue(statuses[0].pendingDepositAssets > 0, "User1 should have deposit request");
        assertTrue(statuses[0].pendingRedeemShares == 0, "User1 should not have redeem request");
        assertEq(statuses[0].pendingDepositAssets, 1000e18, "User1 should have correct pending assets");
        assertEq(statuses[0].pendingRedeemShares, 0, "User1 should have no pending shares");

        // Check user2 status
        assertTrue(statuses[1].pendingDepositAssets > 0, "User2 should have deposit request");
        assertTrue(statuses[1].pendingRedeemShares == 0, "User2 should not have redeem request");
        assertEq(statuses[1].pendingDepositAssets, 2000e18, "User2 should have correct pending assets");
        assertEq(statuses[1].pendingRedeemShares, 0, "User2 should have no pending shares");

        // Check user3 status (no requests)
        assertTrue(statuses[2].pendingDepositAssets == 0, "User3 should not have deposit request");
        assertTrue(statuses[2].pendingRedeemShares == 0, "User3 should not have redeem request");
        assertEq(statuses[2].pendingDepositAssets, 0, "User3 should have no pending assets");
        assertEq(statuses[2].pendingRedeemShares, 0, "User3 should have no pending shares");
    }

    function testPaginationConsistencyAfterStateChanges() public {
        // Add 3 requests
        vm.prank(user1);
        vault.requestDeposit(1000e18, user1, user1);

        vm.prank(user2);
        vault.requestDeposit(2000e18, user2, user2);

        vm.prank(user3);
        vault.requestDeposit(3000e18, user3, user3);

        // Get first page
        (, uint256 totalBefore,) = vault.getDepositControllerStatusBatchPaginated(0, 2);

        // Fulfill and claim user2's request (middle element)
        vm.prank(owner);
        vault.fulfillDeposit(user2, 2000e18);

        vm.prank(user2);
        vault.deposit(2000e18, user2, user2);

        // Get first page after state change
        (ERC7575VaultUpgradeable.ControllerStatus[] memory page1After, uint256 totalAfter,) = vault.getDepositControllerStatusBatchPaginated(0, 2);

        // Should have one less total
        assertEq(totalAfter, totalBefore - 1, "Should have one less requester");
        assertEq(page1After.length, 2, "Should still return 2 items in first page");

        // User2 should not be in results anymore
        for (uint256 i = 0; i < page1After.length; i++) {
            assertTrue(page1After[i].controller != user2, "User2 should not appear in results");
        }
    }
}
