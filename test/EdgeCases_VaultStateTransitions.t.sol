// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC7575VaultUpgradeable.sol";
import "../src/WERC7575ShareToken.sol";
import "./MockAsset.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title EdgeCases_VaultStateTransitions
 * @notice Tests for vault state transitions (active/inactive)
 * Critical for validating that pausing/unpausing works correctly
 * and that operations are properly blocked when vault is inactive
 */
contract EdgeCasesVaultStateTransitions is Test {
    WERC7575ShareToken public shareToken;
    ERC7575VaultUpgradeable public vault;
    MockAsset public asset;

    address owner = address(1);
    address investmentManager = address(2);
    address alice = address(3);
    address bob = address(4);

    function setUp() public {
        vm.startPrank(owner);
        asset = new MockAsset();
        asset.mint(alice, 500000e18);
        asset.mint(bob, 500000e18);

        shareToken = new WERC7575ShareToken("Share Token", "SHARE");

        // Deploy vault
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(address(asset)), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        shareToken.setValidator(owner);
        shareToken.setKycAdmin(owner);
        shareToken.registerVault(address(asset), address(vault));
        vault.setInvestmentManager(investmentManager);

        vm.stopPrank();

        // Setup KYC
        vm.prank(owner);
        shareToken.setKycVerified(alice, true);
        vm.prank(owner);
        shareToken.setKycVerified(bob, true);

        // Approve vault
        vm.prank(alice);
        asset.approve(address(vault), 500000e18);
        vm.prank(bob);
        asset.approve(address(vault), 500000e18);
    }

    // ========== TEST 1: Vault Starts Active ==========
    /**
     * @notice Vault should be active by default after initialization
     */
    function testVaultStateTransitions_StartsActive() public {
        bool isActive = vault.isVaultActive();
        assertTrue(isActive, "Vault should be active by default");
    }

    // ========== TEST 2: Can Deposit When Active ==========
    /**
     * @notice Test that deposits work when vault is active
     */
    function testVaultStateTransitions_DepositWhenActive() public {
        assertTrue(vault.isVaultActive(), "Vault should be active");

        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(1000e18, alice, alice);

        assertEq(requestId, 0, "Request ID should be 0");
        assertEq(vault.pendingDepositRequest(0, alice), 1000e18, "Deposit should be pending");
    }

    // ========== TEST 3: Cannot Deposit When Inactive ==========
    /**
     * @notice Test that deposits revert when vault is inactive
     */
    function testVaultStateTransitions_DepositWhenInactive() public {
        // Deactivate vault
        vm.prank(owner);
        vault.setVaultActive(false);

        assertFalse(vault.isVaultActive(), "Vault should be inactive");

        // Try to deposit
        vm.prank(alice);
        vm.expectRevert();
        vault.requestDeposit(1000e18, alice, alice);
    }

    // ========== TEST 4: Reactivation Allows Deposits ==========
    /**
     * @notice Test that reactivating vault allows deposits again
     */
    function testVaultStateTransitions_ReactivationAllowsDeposits() public {
        // Deactivate
        vm.prank(owner);
        vault.setVaultActive(false);

        // Verify inactive
        assertFalse(vault.isVaultActive());

        // Try deposit - should fail
        vm.prank(alice);
        vm.expectRevert();
        vault.requestDeposit(1000e18, alice, alice);

        // Reactivate
        vm.prank(owner);
        vault.setVaultActive(true);

        // Verify active
        assertTrue(vault.isVaultActive());

        // Now deposit should work
        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(1000e18, alice, alice);

        assertEq(requestId, 0, "Deposit should succeed after reactivation");
    }

    // ========== TEST 5: Multiple State Transitions ==========
    /**
     * @notice Test multiple transitions: active → inactive → active → inactive
     */
    function testVaultStateTransitions_MultipleTransitions() public {
        // Initial: active
        assertTrue(vault.isVaultActive());

        // Transition 1: deactivate
        vm.prank(owner);
        vault.setVaultActive(false);
        assertFalse(vault.isVaultActive());

        // Transition 2: activate
        vm.prank(owner);
        vault.setVaultActive(true);
        assertTrue(vault.isVaultActive());

        // Transition 3: deactivate
        vm.prank(owner);
        vault.setVaultActive(false);
        assertFalse(vault.isVaultActive());

        // Transition 4: activate
        vm.prank(owner);
        vault.setVaultActive(true);
        assertTrue(vault.isVaultActive());
    }

    // ========== TEST 6: Pending Deposits Persist After Deactivation ==========
    /**
     * @notice Pending deposits should not be affected by vault state changes
     */
    function testVaultStateTransitions_PendingDepositsNotAffected() public {
        // Make a deposit while active
        vm.prank(alice);
        vault.requestDeposit(1000e18, alice, alice);

        // Verify pending
        uint256 pendingBefore = vault.pendingDepositRequest(0, alice);
        assertEq(pendingBefore, 1000e18, "Should have 1000 pending");

        // Deactivate vault
        vm.prank(owner);
        vault.setVaultActive(false);

        // Pending should still be there after deactivation
        uint256 pendingAfter = vault.pendingDepositRequest(0, alice);
        assertEq(pendingAfter, pendingBefore, "Pending deposit should persist after deactivation");
    }

    // ========== TEST 7: State Change Emits Event ==========
    /**
     * @notice Test that state changes emit VaultActiveStateChanged event
     */
    function testVaultStateTransitions_StateChangeEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit VaultActiveStateChanged(false);
        vault.setVaultActive(false);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit VaultActiveStateChanged(true);
        vault.setVaultActive(true);
    }

    // ========== TEST 8: Only Owner Can Change State ==========
    /**
     * @notice Test that only owner can change vault active state
     */
    function testVaultStateTransitions_OnlyOwnerCanChangeState() public {
        // Non-owner tries to change state
        vm.prank(alice);
        vm.expectRevert();
        vault.setVaultActive(false);

        // Vault should still be active
        assertTrue(vault.isVaultActive());

        // Owner can change state
        vm.prank(owner);
        vault.setVaultActive(false);

        assertFalse(vault.isVaultActive());
    }

    // ========== TEST 9: Rapid State Changes ==========
    /**
     * @notice Test rapid successive state changes
     */
    function testVaultStateTransitions_RapidStateChanges() public {
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(owner);
            vault.setVaultActive(i % 2 == 0);

            bool expected = (i % 2 == 0);
            assertEq(vault.isVaultActive(), expected, "State should match expected after change");
        }
    }

    // ========== TEST 10: Inactive Vault Query Works ==========
    /**
     * @notice Test that isVaultActive() query works correctly in both states
     */
    function testVaultStateTransitions_IsVaultActiveQuery() public {
        // Active state
        assertTrue(vault.isVaultActive());

        // Inactive state
        vm.prank(owner);
        vault.setVaultActive(false);

        assertFalse(vault.isVaultActive());

        // Active again
        vm.prank(owner);
        vault.setVaultActive(true);

        assertTrue(vault.isVaultActive());
    }

    // ========== TEST 11: Deposit Failure When Inactive ==========
    /**
     * @notice Test that deposit fails immediately when vault is inactive
     */
    function testVaultStateTransitions_DepositFailsWhenInactive() public {
        // Deactivate
        vm.prank(owner);
        vault.setVaultActive(false);

        // Try deposit with large amount
        vm.prank(alice);
        vm.expectRevert();
        vault.requestDeposit(100000e18, alice, alice);

        // Verify no pending deposit was created
        assertEq(vault.pendingDepositRequest(0, alice), 0, "No pending deposit should be created");
    }

    // ========== TEST 12: Cannot New Requests When Inactive ==========
    /**
     * @notice Test that new requests cannot be made when vault is inactive
     */
    function testVaultStateTransitions_CannotNewRequestsWhenInactive() public {
        // Request and clear one deposit
        vm.prank(alice);
        vault.requestDeposit(1000e18, alice, alice);

        // Deactivate vault
        vm.prank(owner);
        vault.setVaultActive(false);

        // Try to make new request - should fail
        vm.prank(bob);
        vm.expectRevert();
        vault.requestDeposit(1000e18, bob, bob);

        // Verify no new pending was created
        assertEq(vault.pendingDepositRequest(0, bob), 0, "No pending for bob");

        // But alice's original pending should still be there
        assertEq(vault.pendingDepositRequest(0, alice), 1000e18, "Alice's pending should persist");
    }

    // Event definition for testing
    event VaultActiveStateChanged(bool indexed isActive);
}
