// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {MockAsset} from "./MockAsset.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

/**
 * @title MaxFunctionsBehaviorTest
 * @dev Focused test to clarify maxDeposit/maxMint behavior in ERC7540 context
 *
 * This test addresses the fundamental question:
 * Should maxDeposit/maxMint return:
 * A) Maximum amount that can be REQUESTED via requestDeposit/requestMint
 * B) Maximum amount that can be CLAIMED via deposit/mint (claimable amount)
 *
 * Current implementation: B (claimable amounts)
 */
contract MaxFunctionsBehaviorTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    MockAsset public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    function setUp() public {
        vm.startPrank(owner);

        asset = new MockAsset();

        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Max Behavior Test", "MBT", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(asset), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        shareToken.registerVault(address(asset), address(vault));

        vm.stopPrank();

        asset.mint(alice, 1000000e18);
    }

    /// @dev Demonstrate current maxDeposit behavior - returns claimable amounts
    function test_MaxDeposit_CurrentBehavior_ClaimableAmounts() public {
        console.log("=== Testing maxDeposit Current Behavior ===");

        uint256 requestAmount = 10000e18;

        // Phase 1: No requests yet
        uint256 maxBefore = vault.maxDeposit(alice);
        console.log("maxDeposit before any requests:", maxBefore);
        assertEq(maxBefore, 0, "Should be 0 initially");

        // Phase 2: Make a request (goes to pending)
        vm.startPrank(alice);
        asset.approve(address(vault), requestAmount);
        vault.requestDeposit(requestAmount, alice, alice);
        vm.stopPrank();

        uint256 maxAfterRequest = vault.maxDeposit(alice);
        console.log("maxDeposit after request (pending):", maxAfterRequest);
        assertEq(maxAfterRequest, 0, "Should still be 0 - only pending, not claimable");

        // Phase 3: Owner fulfills request (moves to claimable)
        vm.prank(owner);
        vault.fulfillDeposit(alice, requestAmount);

        uint256 maxAfterFulfill = vault.maxDeposit(alice);
        console.log("maxDeposit after fulfill (claimable):", maxAfterFulfill);
        assertEq(maxAfterFulfill, requestAmount, "Should equal claimable amount");

        // Phase 4: Alice claims half the amount
        uint256 claimAmount = requestAmount / 2;
        vm.prank(alice);
        vault.deposit(claimAmount, alice);

        uint256 maxAfterPartialClaim = vault.maxDeposit(alice);
        console.log("maxDeposit after partial claim:", maxAfterPartialClaim);
        assertEq(maxAfterPartialClaim, requestAmount - claimAmount, "Should equal remaining claimable");

        // Phase 5: Alice claims rest
        vm.prank(alice);
        vault.deposit(requestAmount - claimAmount, alice);

        uint256 maxAfterFullClaim = vault.maxDeposit(alice);
        console.log("maxDeposit after full claim:", maxAfterFullClaim);
        assertEq(maxAfterFullClaim, 0, "Should be 0 - nothing left to claim");
    }

    /// @dev Demonstrate current maxMint behavior - returns claimable shares
    function test_MaxMint_CurrentBehavior_ClaimableShares() public {
        console.log("=== Testing maxMint Current Behavior ===");

        uint256 requestAmount = 10000e18;

        // Phase 1: No requests yet
        assertEq(vault.maxMint(alice), 0, "Should be 0 initially");

        // Phase 2: Make and fulfill request
        vm.startPrank(alice);
        asset.approve(address(vault), requestAmount);
        vault.requestDeposit(requestAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, requestAmount);

        // Phase 3: maxMint should return expected shares for claimable amount
        uint256 expectedShares = vault.convertToShares(requestAmount);
        uint256 maxMintValue = vault.maxMint(alice);
        console.log("Expected shares:", expectedShares);
        console.log("maxMint value:", maxMintValue);
        assertEq(maxMintValue, expectedShares, "maxMint should equal claimable shares");

        // Phase 4: Use mint to claim shares
        vm.prank(alice);
        vault.mint(expectedShares, alice);

        assertEq(vault.maxMint(alice), 0, "Should be 0 after claiming all shares");
    }

    /// @dev Test that maxDeposit represents what can actually be deposited
    function test_MaxDeposit_RepresentsActualDepositCapacity() public {
        uint256 requestAmount = 5000e18;

        // Setup claimable amount
        vm.startPrank(alice);
        asset.approve(address(vault), requestAmount);
        vault.requestDeposit(requestAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, requestAmount);

        uint256 maxDepositValue = vault.maxDeposit(alice);
        assertEq(maxDepositValue, requestAmount);

        // Alice should be able to deposit exactly this amount
        vm.prank(alice);
        vault.deposit(maxDepositValue, alice);
        // Should not revert

        // Trying to deposit more than maxDeposit should fail
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1, alice); // No more claimable
    }

    /// @dev Test maxMint represents what can actually be minted
    function test_MaxMint_RepresentsActualMintCapacity() public {
        uint256 requestAmount = 5000e18;

        // Setup claimable amount
        vm.startPrank(alice);
        asset.approve(address(vault), requestAmount);
        vault.requestDeposit(requestAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, requestAmount);

        uint256 maxMintValue = vault.maxMint(alice);
        assertTrue(maxMintValue > 0);

        // Alice should be able to mint exactly this amount
        vm.prank(alice);
        vault.mint(maxMintValue, alice);
        // Should not revert

        // Trying to mint more than maxMint should fail
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(1, alice); // No more claimable
    }

    /// @dev Compare with traditional ERC4626 behavior (if this were synchronous)
    function test_CompareWithTraditionalERC4626_Interpretation() public {
        console.log("=== Comparison with Traditional ERC4626 Interpretation ===");

        // In traditional ERC4626:
        // - maxDeposit would return max amount that can be deposited immediately
        // - This might be unlimited (type(uint256).max) or limited by vault capacity

        // In ERC7540 async:
        // - maxDeposit returns max amount that can be claimed via deposit()
        // - This is based on fulfilled requests, not request capacity

        uint256 requestAmount = 1000e18;

        console.log("Traditional ERC4626 would likely return type(uint256).max for maxDeposit");
        console.log("ERC7540 async returns claimable amount for maxDeposit");

        // Show the difference
        vm.startPrank(alice);
        asset.approve(address(vault), requestAmount);
        vault.requestDeposit(requestAmount, alice, alice);
        vm.stopPrank();

        console.log("After requestDeposit (but not fulfilled):");
        console.log("- Traditional interpretation would still allow max deposits");
        console.log("- ERC7540 interpretation:", vault.maxDeposit(alice), "(0 because nothing claimable)");

        vm.prank(owner);
        vault.fulfillDeposit(alice, requestAmount);

        console.log("After fulfillment:");
        console.log("- ERC7540 interpretation:", vault.maxDeposit(alice), "(equals claimable amount)");

        assertTrue(true); // Just for demonstration
    }

    /// @dev Test multiple users have independent max values
    function test_MaxFunctions_IndependentPerUser() public {
        address bob = makeAddr("bob");
        asset.mint(bob, 100000e18);

        uint256 aliceAmount = 3000e18;
        uint256 bobAmount = 7000e18;

        // Setup different claimable amounts for each user
        vm.startPrank(alice);
        asset.approve(address(vault), aliceAmount);
        vault.requestDeposit(aliceAmount, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), bobAmount);
        vault.requestDeposit(bobAmount, bob, bob);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.fulfillDeposit(alice, aliceAmount);
        vault.fulfillDeposit(bob, bobAmount);
        vm.stopPrank();

        // Each user should have their own max values
        assertEq(vault.maxDeposit(alice), aliceAmount);
        assertEq(vault.maxDeposit(bob), bobAmount);

        // Should not affect each other
        vm.prank(alice);
        vault.deposit(aliceAmount, alice);

        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxDeposit(bob), bobAmount); // Bob's unchanged
    }
}
