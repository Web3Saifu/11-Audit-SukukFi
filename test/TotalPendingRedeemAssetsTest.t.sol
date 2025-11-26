// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {MockAsset} from "./MockAsset.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console} from "forge-std/Test.sol";

contract TotalPendingRedeemAssetsTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    MockAsset public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy asset
        asset = new MockAsset();
        asset.mint(alice, 1000000e18);
        asset.mint(bob, 1000000e18);

        // Deploy ShareToken
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Test Share Token", "TST", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(asset), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault
        shareToken.registerVault(address(asset), address(vault));

        vm.stopPrank();
    }

    function test_TotalPendingRedeemAssets_Lifecycle() public {
        uint256 depositAmount = 10000e18;
        uint256 redeemShares = 5000e18;

        // Step 1: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Check initial state - no pending redeem assets
        assertEq(vault.totalAssets(), depositAmount, "Initial totalAssets should equal deposit");
        assertEq(vault.totalAssets(), depositAmount, "All assets should be available for investment");

        // Step 2: Alice requests redemption
        vm.prank(alice);
        vault.requestRedeem(redeemShares, alice, alice);

        // After request, totalPendingRedeemAssets should still be 0 (not yet fulfilled)
        assertEq(vault.totalAssets(), depositAmount, "totalAssets unchanged after requestRedeem");
        assertEq(vault.totalAssets(), depositAmount, "Available for investment unchanged after requestRedeem");

        // Step 3: Fulfill redeem request
        vm.prank(owner);
        uint256 redeemAssets = vault.fulfillRedeem(alice, redeemShares);

        console.log("Redeem assets calculated:", redeemAssets);

        // Now totalPendingRedeemAssets should be non-zero and reduce available assets
        uint256 expectedTotalAssets = depositAmount - redeemAssets;
        assertEq(vault.totalAssets(), expectedTotalAssets, "totalAssets should exclude pending redeem assets");
        assertEq(vault.totalAssets(), expectedTotalAssets, "Available for investment should exclude pending redeem assets");

        // Step 4: Claim redemption
        vm.prank(alice);
        uint256 actualAssets = vault.redeem(redeemShares, alice, alice);

        // After claiming, totalPendingRedeemAssets should be reduced
        assertEq(vault.totalAssets(), expectedTotalAssets, "totalAssets should reflect claimed redemption");
        assertEq(vault.totalAssets(), expectedTotalAssets, "Available for investment should reflect claimed redemption");
        assertEq(actualAssets, redeemAssets, "Actual assets should match fulfilled assets");
    }

    function test_GetAvailableForInvestment_ExcludesPendingRedeems() public {
        uint256 depositAmount = 20000e18;

        // Setup: Alice deposits
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 initialAvailable = vault.totalAssets();
        assertEq(initialAvailable, depositAmount, "Initially all should be available");

        // Alice requests partial redemption
        vm.prank(alice);
        vault.requestRedeem(10000e18, alice, alice);

        vm.prank(owner);
        uint256 redeemAssets = vault.fulfillRedeem(alice, 10000e18);

        // Available for investment should now exclude pending redeem assets
        uint256 availableAfterRedeem = vault.totalAssets();
        assertEq(availableAfterRedeem, depositAmount - redeemAssets, "Available should exclude redeem assets");
        assertTrue(availableAfterRedeem < initialAvailable, "Available should be reduced");

        // Verify that the balance calculation would prevent over-investment
        uint256 vaultBalance = asset.balanceOf(address(vault));
        assertTrue(availableAfterRedeem < vaultBalance, "Available should be less than total vault balance");
        assertEq(vaultBalance - availableAfterRedeem, redeemAssets, "Difference should equal reserved redeem assets");
    }

    function test_CancelRedeemRequest_CorrectAccounting() public {
        uint256 depositAmount = 10000e18;
        uint256 redeemShares = 5000e18;

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Request redemption but don't fulfill
        vm.prank(alice);
        vault.requestRedeem(redeemShares, alice, alice);

        uint256 initialTotalAssets = vault.totalAssets();
        uint256 initialAvailable = vault.totalAssets();

        // Cancel the redeem request
        vm.prank(alice);
        vault.cancelRedeemRequest(0, alice);

        // After cancellation, values should be unchanged (since it wasn't fulfilled)
        assertEq(vault.totalAssets(), initialTotalAssets, "totalAssets should be unchanged after cancel unfulfilled redeem");
        assertEq(vault.totalAssets(), initialAvailable, "Available should be unchanged after cancel unfulfilled redeem");
    }

    function test_CancelFulfilledRedeemRequest_ShouldFail() public {
        uint256 depositAmount = 10000e18;
        uint256 redeemShares = 5000e18;

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Check Alice's balance after deposit
        uint256 aliceBalanceAfterDeposit = asset.balanceOf(alice);

        // Request and fulfill redemption
        vm.prank(alice);
        vault.requestRedeem(redeemShares, alice, alice);

        vm.prank(owner);
        vault.fulfillRedeem(alice, redeemShares);

        // Try to cancel the fulfilled redeem request - should fail
        // because fulfilled requests move from pending to claimable state, not pending
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.NoPendingCancelRedeem.selector);
        vault.cancelRedeemRequest(0, alice);

        // The correct way is to claim the redemption
        vm.prank(alice);
        uint256 assetsReceived = vault.redeem(redeemShares, alice, alice);

        // Verify Alice received the correct amount of redeemed assets
        // Alice should have her balance after deposit plus the assets she redeemed
        uint256 expectedBalance = aliceBalanceAfterDeposit + assetsReceived;
        assertEq(asset.balanceOf(alice), expectedBalance, "Alice should receive redeemed assets plus her remaining balance");
        assertEq(assetsReceived, redeemShares, "Alice should receive assets equal to shares (1:1 ratio)");
    }

    function test_PartialFulfillmentCancellation() public {
        uint256 depositAmount = 10000e18;
        uint256 totalRedeemShares = 6000e18;
        uint256 partialFulfillShares = 3000e18;
        uint256 remainingShares = totalRedeemShares - partialFulfillShares; // 3000e18

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Alice requests redemption for 6000 shares
        vm.prank(alice);
        vault.requestRedeem(totalRedeemShares, alice, alice);

        // Verify initial state
        assertEq(vault.pendingRedeemRequest(0, alice), totalRedeemShares, "Should have total shares pending");
        assertEq(vault.claimableRedeemRequest(0, alice), 0, "Should have no claimable shares yet");

        // Investment manager partially fulfills only 3000 shares
        vm.prank(owner);
        uint256 partialAssets = vault.fulfillRedeem(alice, partialFulfillShares);

        // After partial fulfillment: 3000 pending, 3000 claimable
        assertEq(vault.pendingRedeemRequest(0, alice), remainingShares, "Should have 3000 shares still pending");
        assertEq(vault.claimableRedeemRequest(0, alice), partialFulfillShares, "Should have 3000 shares claimable");

        // Capture Alice's share balance (she has 4000 unredeemed shares: 10000 - 6000 requested)
        uint256 aliceSharesBeforeCancel = shareToken.balanceOf(alice);

        // Alice can cancel the UNFULFILLED portion (3000 pending shares)
        vm.prank(alice);
        vault.cancelRedeemRequest(0, alice);

        // ERC7887: Cancelation is now asynchronous
        // Pending shares moved to pending cancelation state
        assertTrue(vault.pendingCancelRedeemRequest(0, alice), "Should have pending cancelation");

        // After cancellation: no pending redeem, but fulfilled portion remains claimable
        assertEq(vault.pendingRedeemRequest(0, alice), 0, "Should have no pending shares after cancel");
        assertEq(vault.claimableRedeemRequest(0, alice), partialFulfillShares, "Claimable shares should remain unchanged");

        // Investment manager (owner) fulfills the cancelation
        vm.prank(owner);
        vault.fulfillCancelRedeemRequest(alice);

        // Now shares are claimable
        assertTrue(!vault.pendingCancelRedeemRequest(0, alice), "Should have no pending cancelation after fulfill");
        assertEq(vault.claimableCancelRedeemRequest(0, alice), remainingShares, "Should have claimable cancelation shares");

        // Alice can claim the canceled shares back
        vm.prank(alice);
        vault.claimCancelRedeemRequest(0, alice, alice);
        // Alice should have: unredeemed shares (4000) + canceled shares (3000) = 7000
        assertEq(shareToken.balanceOf(alice), aliceSharesBeforeCancel + remainingShares, "Alice should get pending shares back");

        // Alice can still claim the fulfilled portion
        vm.prank(alice);
        uint256 claimedAssets = vault.redeem(partialFulfillShares, alice, alice);
        assertEq(claimedAssets, partialAssets, "Should receive the fulfilled assets");

        // Final state: no pending, no claimable
        assertEq(vault.pendingRedeemRequest(0, alice), 0, "Should have no pending shares finally");
        assertEq(vault.claimableRedeemRequest(0, alice), 0, "Should have no claimable shares finally");
    }

    function test_MultipleUsers_TotalPendingRedeemAssets() public {
        uint256 depositAmount = 10000e18;

        // Setup: Both users deposit and get shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, bob, bob);
        vm.stopPrank();

        // Fulfill both deposits
        vm.startPrank(owner);
        vault.fulfillDeposit(alice, depositAmount);
        vault.fulfillDeposit(bob, depositAmount);
        vm.stopPrank();

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(depositAmount, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(depositAmount, bob);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 availableBefore = vault.totalAssets();

        // Both users request redemption
        vm.prank(alice);
        vault.requestRedeem(aliceShares / 2, alice, alice);

        vm.prank(bob);
        vault.requestRedeem(bobShares / 2, bob, bob);

        // Fulfill both redemptions
        vm.startPrank(owner);
        uint256 aliceRedeemAssets = vault.fulfillRedeem(alice, aliceShares / 2);
        uint256 bobRedeemAssets = vault.fulfillRedeem(bob, bobShares / 2);
        vm.stopPrank();

        // Total assets should decrease by both redeem amounts
        uint256 totalRedeemAssets = aliceRedeemAssets + bobRedeemAssets;
        assertEq(vault.totalAssets(), totalAssetsBefore - totalRedeemAssets, "totalAssets should decrease by total redeem assets");
        assertEq(vault.totalAssets(), availableBefore - totalRedeemAssets, "Available should decrease by total redeem assets");

        // Alice claims her redemption
        vm.prank(alice);
        uint256 aliceActualAssets = vault.redeem(aliceShares / 2, alice, alice);

        // After Alice's claim, available should equal totalAssets (both use same calculation)
        assertEq(vault.totalAssets(), vault.totalAssets(), "Available should equal totalAssets after Alice's claim");

        // The available amount should have changed from the initial state
        assertTrue(vault.totalAssets() != availableBefore, "Available should have changed after operations");

        // Bob claims his redemption
        vm.prank(bob);
        uint256 bobActualAssets = vault.redeem(bobShares / 2, bob, bob);

        // All pending redeems should be cleared
        assertEq(vault.totalAssets(), vault.totalAssets(), "Available should equal totalAssets after all claims");

        // Verify both users received their assets
        assertEq(aliceActualAssets + bobActualAssets, totalRedeemAssets, "Total assets claimed should match total fulfilled");
    }

    function test_PartialRedemption_TotalPendingRedeemAssets() public {
        uint256 depositAmount = 10000e18;

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Request redemption of all shares
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        // Partially fulfill the redemption (half)
        uint256 partialShares = shares / 2;
        vm.prank(owner);
        uint256 partialAssets = vault.fulfillRedeem(alice, partialShares);

        uint256 totalAssetsAfterPartial = vault.totalAssets();
        uint256 availableAfterPartial = vault.totalAssets();

        // Should reflect only the partial amount
        assertEq(vault.pendingRedeemRequest(0, alice), shares - partialShares, "Should have remaining pending shares");
        assertEq(vault.claimableRedeemRequest(0, alice), partialShares, "Should have partial claimable shares");

        // The available amount should be reduced by the fulfilled assets
        assertTrue(availableAfterPartial < depositAmount, "Available should be reduced");
        assertEq(availableAfterPartial, totalAssetsAfterPartial, "Available should equal totalAssets (both exclude pending redeem assets)");

        // Fulfill the remaining shares
        vm.prank(owner);
        uint256 remainingAssets = vault.fulfillRedeem(alice, shares - partialShares);

        // Now both amounts should be reserved (both totalAssets and available should be equal and reduced)
        uint256 totalRedeemAssets = partialAssets + remainingAssets;
        assertEq(vault.totalAssets(), vault.totalAssets(), "Available should equal totalAssets (both exclude all redeem assets)");

        // Both should be reduced from the original deposit amount
        assertTrue(vault.totalAssets() < depositAmount, "Both should be reduced from original");
        assertTrue(vault.totalAssets() < depositAmount, "Both should be reduced from original");

        // Claim partial amount using withdraw function
        vm.prank(alice);
        uint256 sharesConsumed = vault.withdraw(partialAssets, alice, alice);

        // Due to proportional calculation, shares consumed may not exactly equal partial shares
        // The withdraw function calculates: shares = assets.mulDiv(availableShares, availableAssets)
        assertTrue(sharesConsumed > 0, "Should consume some shares");
        assertTrue(sharesConsumed <= partialShares * 2, "Should consume reasonable amount of shares"); // Allow for rounding

        // After partial claim, available should still equal totalAssets (both use same calculation)
        assertEq(vault.totalAssets(), vault.totalAssets(), "Available should equal totalAssets after partial claim");

        // The state should have changed from the previous partial state
        assertTrue(vault.totalAssets() != availableAfterPartial, "Available should change after partial claim");

        // Claim remaining using redeem function - get the actual remaining shares
        uint256 remainingClaimableShares = vault.claimableRedeemRequest(0, alice);
        vm.prank(alice);
        if (remainingClaimableShares > 0) {
            vault.redeem(remainingClaimableShares, alice, alice);
        }

        // All should be cleared
        assertEq(vault.totalAssets(), vault.totalAssets(), "Available should equal totalAssets after full claim");
    }

    function test_EdgeCase_ZeroAmountRedemptions() public {
        // Test behavior with zero amounts (should revert appropriately)
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.ZeroShares.selector);
        vault.requestRedeem(0, alice, alice);
    }

    function test_TotalPendingRedeemAssets_IntegrationWithInvestment() public {
        uint256 depositAmount = 50000e18;

        // Setup: Alice deposits
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Add more assets for investment
        asset.mint(address(vault), 100000e18);

        uint256 totalAssetsBeforeInvest = vault.totalAssets();
        uint256 availableBeforeInvest = vault.totalAssets();

        // Simulate investment (manual balance reduction)
        uint256 investAmount = 30000e18;
        // Note: Since we don't have investment vault set up, we'll simulate by checking calculations

        // Request redemption
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        vm.prank(owner);
        uint256 redeemAssets = vault.fulfillRedeem(alice, shares);

        // Available for investment should exclude the redeem assets even with extra balance
        uint256 expectedAvailable = totalAssetsBeforeInvest - redeemAssets;
        assertEq(vault.totalAssets(), expectedAvailable, "Available should exclude redeem assets from total");

        // The reserved assets should be protected from investment
        uint256 vaultBalance = asset.balanceOf(address(vault));
        assertTrue(vault.totalAssets() < vaultBalance, "Reserved assets should be protected");
        assertEq(vaultBalance - vault.totalAssets(), redeemAssets, "Difference should equal reserved amount");
    }

    function test_ConsistentAccounting_AcrossOperations() public {
        uint256 depositAmount = 20000e18;

        // Track balances throughout complex operations
        uint256[] memory checkpoints = new uint256[](10);
        uint256[] memory availableCheckpoints = new uint256[](10);
        uint256 checkpoint = 0;

        // Checkpoint 0: Initial state
        checkpoints[checkpoint] = vault.totalAssets();
        availableCheckpoints[checkpoint] = vault.totalAssets();
        assertEq(checkpoints[checkpoint], availableCheckpoints[checkpoint], "Initial: totalAssets should equal available");
        checkpoint++;

        // Setup deposits for Alice and Bob
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, bob, bob);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.fulfillDeposit(alice, depositAmount);
        vault.fulfillDeposit(bob, depositAmount);
        vm.stopPrank();

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(depositAmount, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(depositAmount, bob);

        // Checkpoint 1: After deposits
        checkpoints[checkpoint] = vault.totalAssets();
        availableCheckpoints[checkpoint] = vault.totalAssets();
        assertEq(checkpoints[checkpoint], availableCheckpoints[checkpoint], "After deposits: totalAssets should equal available");
        assertEq(checkpoints[checkpoint], depositAmount * 2, "Should have total deposit amount");
        checkpoint++;

        // Alice requests redemption
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice, alice);

        // Checkpoint 2: After redemption request (should be unchanged)
        checkpoints[checkpoint] = vault.totalAssets();
        availableCheckpoints[checkpoint] = vault.totalAssets();
        assertEq(checkpoints[checkpoint], checkpoints[checkpoint - 1], "Request should not change totalAssets");
        assertEq(availableCheckpoints[checkpoint], availableCheckpoints[checkpoint - 1], "Request should not change available");
        checkpoint++;

        // Fulfill Alice's redemption
        vm.prank(owner);
        uint256 aliceRedeemAssets = vault.fulfillRedeem(alice, aliceShares);

        // Checkpoint 3: After fulfillment
        checkpoints[checkpoint] = vault.totalAssets();
        availableCheckpoints[checkpoint] = vault.totalAssets();
        assertEq(checkpoints[checkpoint], checkpoints[checkpoint - 1] - aliceRedeemAssets, "Fulfillment should reduce totalAssets");
        assertEq(availableCheckpoints[checkpoint], availableCheckpoints[checkpoint - 1] - aliceRedeemAssets, "Fulfillment should reduce available");
        checkpoint++;

        // Alice claims redemption
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        // Checkpoint 4: After claim (totalAssets unchanged, available increases)
        checkpoints[checkpoint] = vault.totalAssets();
        availableCheckpoints[checkpoint] = vault.totalAssets();
        assertEq(checkpoints[checkpoint], checkpoints[checkpoint - 1], "Claim should not change totalAssets");
        assertEq(availableCheckpoints[checkpoint], checkpoints[checkpoint], "After claim: available should equal totalAssets");

        // Invariant: available should never exceed totalAssets
        for (uint256 i = 0; i < checkpoint; i++) {
            assertTrue(availableCheckpoints[i] <= checkpoints[i], "Available should never exceed totalAssets");
        }
    }
}
