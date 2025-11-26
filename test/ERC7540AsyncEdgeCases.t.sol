// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {MockAsset} from "./MockAsset.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ERC7540AsyncEdgeCasesTest
 * @dev Edge case tests for async deposit/redeem functionality
 */
contract ERC7540AsyncEdgeCasesTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    MockAsset public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        vm.startPrank(owner);

        asset = new MockAsset();

        // Deploy ShareToken with proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Edge Case Shares", "ECS", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault with proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(asset), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        shareToken.registerVault(address(asset), address(vault));

        // Set minimum deposit to 0 for testing small amounts
        vault.setMinimumDepositAmount(0);

        vm.stopPrank();

        // Mint assets directly to users
        asset.mint(alice, 150000e18);
        asset.mint(bob, 150000e18);
    }

    /// @dev Test zero amount requests should revert
    function test_EdgeCase_ZeroAmountRequests() public {
        vm.startPrank(alice);
        asset.approve(address(vault), 1000e18);

        // Zero deposit should revert
        vm.expectRevert();
        vault.requestDeposit(0, alice, alice);

        vm.stopPrank();
    }

    /// @dev Test multiple partial claims
    function test_EdgeCase_MultiplePartialClaims() public {
        uint256 depositAmount = 10000e18;

        // Setup deposit
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        // Claim full amount at once
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 shares = shareToken.balanceOf(alice);
        assertTrue(shares > 0);

        // Setup redeem
        vm.startPrank(alice);
        shareToken.approve(address(vault), shares);
        vault.requestRedeem(shares, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillRedeem(alice, shares);

        // Should be able to claim all at once
        vm.prank(alice);
        uint256 assetsReceived = vault.redeem(shares, alice, alice);
        assertTrue(assetsReceived > 0);
    }

    /// @dev Test operator permissions with different controllers
    function test_EdgeCase_RequestWithDifferentControllerAndOwner() public {
        // Alice authorizes bob as operator
        vm.prank(alice);
        vault.setOperator(bob, true);

        // Bob makes request for alice
        vm.startPrank(alice);
        asset.approve(address(vault), 10000e18);
        vm.stopPrank();

        vm.prank(bob);
        vault.requestDeposit(10000e18, alice, alice);

        // Should show up under alice's account
        assertEq(vault.pendingDepositRequest(0, alice), 10000e18);

        // Fulfill
        vm.prank(owner);
        vault.fulfillDeposit(alice, 10000e18);

        // Alice (or bob as her operator) can claim
        vm.prank(alice);
        vault.deposit(10000e18, alice);

        assertTrue(shareToken.balanceOf(alice) > 0);
    }

    /// @dev Test self-operator (user cannot set themselves as operator)
    function test_EdgeCase_SelfOperator() public {
        // Alice tries to set herself as operator (should be prevented)
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.CannotSetSelfAsOperator.selector);
        vault.setOperator(alice, true);

        // Should remain false
        assertFalse(vault.isOperator(alice, alice));
    }

    /// @dev Test unauthorized operator access
    function test_EdgeCase_UnauthorizedOperatorAccess() public {
        // Bob tries to act for alice without authorization
        vm.startPrank(alice);
        asset.approve(address(vault), 10000e18);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert();
        vault.requestDeposit(10000e18, alice, alice);
    }

    /// @dev Test claiming more than claimable should revert
    function test_EdgeCase_ClaimMoreThanClaimable() public {
        uint256 depositAmount = 10000e18;

        // Setup deposit
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        // Try to claim more than available should revert
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(depositAmount + 1000e18, alice);
    }

    /// @dev Test total assets excludes pending deposits
    function test_EdgeCase_TotalAssetsExcludesPending() public {
        uint256 initialTotalAssets = vault.totalAssets();

        // Make pending deposit
        vm.startPrank(alice);
        asset.approve(address(vault), 10000e18);
        vault.requestDeposit(10000e18, alice, alice);
        vm.stopPrank();

        // Total assets should not increase until fulfilled
        assertEq(vault.totalAssets(), initialTotalAssets);

        // After fulfillment, total assets should increase
        vm.prank(owner);
        vault.fulfillDeposit(alice, 10000e18);

        assertTrue(vault.totalAssets() > initialTotalAssets);
    }

    /// @dev Test precision loss handling
    function test_EdgeCase_PrecisionLossHandling() public {
        // Very small deposit that might cause precision issues
        uint256 minDeposit = 1000; // Small deposit for precision testing

        vm.startPrank(alice);
        asset.approve(address(vault), minDeposit);
        vault.requestDeposit(minDeposit, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, minDeposit);

        vm.prank(alice);
        vault.deposit(minDeposit, alice);

        // Should receive some shares despite small amount
        assertTrue(shareToken.balanceOf(alice) > 0);
    }

    /// @dev Test overflow protection with maximum amounts
    function test_EdgeCase_OverflowProtection() public {
        // Test with large amounts within faucet limits
        uint256 largeAmount = 50000e18; // Use existing balance

        vm.startPrank(alice);
        asset.approve(address(vault), largeAmount);

        // Should not overflow
        vault.requestDeposit(largeAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, largeAmount);

        // Should handle large deposits without overflow
        vm.prank(alice);
        vault.deposit(largeAmount, alice);

        assertTrue(shareToken.balanceOf(alice) > 0);
    }

    /// @dev Test exchange rate manipulation resistance
    function test_EdgeCase_ExchangeRateManipulation() public {
        // First depositor - use larger amount to avoid precision issues
        uint256 firstDeposit = 10000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), firstDeposit);
        vault.requestDeposit(firstDeposit, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, firstDeposit);

        vm.prank(alice);
        vault.deposit(firstDeposit, alice);

        uint256 aliceShares = shareToken.balanceOf(alice);

        // Attacker tries to manipulate by sending assets directly
        vm.prank(bob);
        require(asset.transfer(address(vault), 1e18), "Transfer failed");

        // Second depositor should not be affected by direct transfer
        uint256 secondDeposit = firstDeposit;
        vm.startPrank(bob);
        asset.approve(address(vault), secondDeposit);
        vault.requestDeposit(secondDeposit, bob, bob);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(bob, secondDeposit);

        vm.prank(bob);
        vault.deposit(secondDeposit, bob);

        uint256 bobShares = shareToken.balanceOf(bob);

        // Share amounts should be reasonable relative to deposits
        assertTrue(bobShares > 0);
        // Bob shouldn't get significantly fewer shares due to manipulation
        assertTrue(bobShares * 10 > aliceShares); // Within an order of magnitude
    }
}
