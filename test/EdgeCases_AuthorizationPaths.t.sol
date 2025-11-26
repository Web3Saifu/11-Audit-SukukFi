// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC7575VaultUpgradeable.sol";
import "../src/ShareTokenUpgradeable.sol";
import "./MockAsset.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title EdgeCases_AuthorizationPaths
 * @notice Tests for authorization patterns - operator vs direct caller
 * Tests how vault authorization checks work with ShareTokenUpgradeable
 *
 * Authorization Patterns Tested:
 * 1. Direct caller: owner == msg.sender
 * 2. Operator approved: isOperator(owner, msg.sender) == true
 * 3. Both paths available: both conditions satisfied
 * 4. Neither path: should revert InvalidOwner/InvalidCaller
 */
contract EdgeCasesAuthorizationPaths is Test {
    ShareTokenUpgradeable public shareToken;
    ERC7575VaultUpgradeable public vault;
    MockAsset public asset;

    address owner = address(1);
    address investmentManager = address(2);
    address alice = address(3);
    address bob = address(4);
    address charlie = address(6);

    function setUp() public {
        vm.startPrank(owner);
        asset = new MockAsset();
        asset.mint(alice, 500000e18);
        asset.mint(bob, 500000e18);
        asset.mint(charlie, 500000e18);

        // Deploy ShareToken with proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Share Token", "SHARE", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy vault with proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(address(asset)), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault with share token
        shareToken.registerVault(address(asset), address(vault));
        shareToken.setInvestmentManager(investmentManager);

        vm.stopPrank();

        // Approve vault for all accounts
        vm.prank(alice);
        asset.approve(address(vault), 500000e18);
        vm.prank(bob);
        asset.approve(address(vault), 500000e18);
        vm.prank(charlie);
        asset.approve(address(vault), 500000e18);
    }

    // ========== TEST 1: isOperator Returns False Initially ==========
    /**
     * @notice By default, no one is approved as operator
     */
    function testAuthorizationPaths_NoOperatorInitially() public {
        assertFalse(shareToken.isOperator(alice, bob), "Bob should not be operator initially");
        assertFalse(shareToken.isOperator(alice, charlie), "Charlie should not be operator initially");
        assertFalse(shareToken.isOperator(bob, alice), "Alice should not be operator for bob");
    }

    // ========== TEST 2: setOperator Approves Operator ==========
    /**
     * @notice Alice can approve bob as operator via setOperator
     */
    function testAuthorizationPaths_SetOperatorApproves() public {
        vm.prank(alice);
        bool approved = shareToken.setOperator(bob, true);

        assertTrue(approved, "setOperator should return true");
        assertTrue(shareToken.isOperator(alice, bob), "Bob should be approved after setOperator");
    }

    // ========== TEST 3: setOperator Revokes Operator ==========
    /**
     * @notice Alice can revoke bob as operator
     */
    function testAuthorizationPaths_SetOperatorRevokes() public {
        // First approve
        vm.prank(alice);
        shareToken.setOperator(bob, true);
        assertTrue(shareToken.isOperator(alice, bob));

        // Then revoke
        vm.prank(alice);
        bool revoked = shareToken.setOperator(bob, false);

        assertTrue(revoked, "setOperator(false) should return true");
        assertFalse(shareToken.isOperator(alice, bob), "Bob should be revoked");
    }

    // ========== TEST 4: Operator Relationship is Directional ==========
    /**
     * @notice If alice approves bob, it doesn't mean bob approves alice
     */
    function testAuthorizationPaths_OperatorIsDirectional() public {
        vm.prank(alice);
        shareToken.setOperator(bob, true);

        // Alice approved bob
        assertTrue(shareToken.isOperator(alice, bob), "Bob should be operator for alice");

        // But bob did not approve alice
        assertFalse(shareToken.isOperator(bob, alice), "Alice should not be operator for bob");
    }

    // ========== TEST 5: Multiple Operators for Same Account ==========
    /**
     * @notice Alice can approve multiple operators independently
     */
    function testAuthorizationPaths_MultipleOperators() public {
        vm.prank(alice);
        shareToken.setOperator(bob, true);

        vm.prank(alice);
        shareToken.setOperator(charlie, true);

        // Both should be approved
        assertTrue(shareToken.isOperator(alice, bob), "Bob should be approved");
        assertTrue(shareToken.isOperator(alice, charlie), "Charlie should be approved");
    }

    // ========== TEST 6: Operator Can Be Approved for Different Accounts ==========
    /**
     * @notice Bob can be operator for alice but not charlie unless charlie also approves
     */
    function testAuthorizationPaths_OperatorForDifferentAccounts() public {
        // Alice approves bob
        vm.prank(alice);
        shareToken.setOperator(bob, true);

        // Charlie does NOT approve bob
        // Verify states
        assertTrue(shareToken.isOperator(alice, bob), "Bob operator for alice");
        assertFalse(shareToken.isOperator(charlie, bob), "Bob NOT operator for charlie");
    }

    // ========== TEST 7: Self Approval Blocked ==========
    /**
     * @notice Account cannot approve itself as operator - this is explicitly prevented
     */
    function testAuthorizationPaths_SelfApprovalBlocked() public {
        vm.prank(alice);
        vm.expectRevert(); // CannotSetSelfAsOperator
        shareToken.setOperator(alice, true);

        // Verify self is still not operator
        assertFalse(shareToken.isOperator(alice, alice), "Self-operator should not be allowed");
    }

    // ========== TEST 8: Self Cannot Be Operator ==========
    /**
     * @notice Attempting to revoke self as operator also fails (can't set self)
     */
    function testAuthorizationPaths_SelfCannotBeOperator() public {
        // Attempting to set self as operator should always fail
        vm.prank(alice);
        vm.expectRevert(); // CannotSetSelfAsOperator

        shareToken.setOperator(alice, false); // Even revoke attempt fails

        assertFalse(shareToken.isOperator(alice, alice));
    }

    // ========== TEST 9: Operator Status Persists Across Calls ==========
    /**
     * @notice Once approved, operator status persists until revoked
     */
    function testAuthorizationPaths_OperatorPersists() public {
        // Approve
        vm.prank(alice);
        shareToken.setOperator(bob, true);
        assertTrue(shareToken.isOperator(alice, bob));

        // Check multiple times - should remain approved
        assertTrue(shareToken.isOperator(alice, bob));
        assertTrue(shareToken.isOperator(alice, bob));

        // Status remains until explicitly revoked
        assertTrue(shareToken.isOperator(alice, bob));
    }

    // ========== TEST 10: Rapid Approval/Revocation Cycles ==========
    /**
     * @notice Operator status can be toggled rapidly
     */
    function testAuthorizationPaths_RapidCycles() public {
        for (uint256 i = 0; i < 5; i++) {
            bool shouldApprove = i % 2 == 0;

            vm.prank(alice);
            shareToken.setOperator(bob, shouldApprove);

            bool expected = shouldApprove;
            assertEq(shareToken.isOperator(alice, bob), expected, "Status should toggle correctly");
        }
    }

    // ========== TEST 11: Multiple Accounts Can Approve Same Operator ==========
    /**
     * @notice Many owners can approve the same operator independently
     */
    function testAuthorizationPaths_OneOperatorManyOwners() public {
        // Alice approves bob
        vm.prank(alice);
        shareToken.setOperator(bob, true);

        // Charlie also approves bob
        vm.prank(charlie);
        shareToken.setOperator(bob, true);

        // Bob is approved by both
        assertTrue(shareToken.isOperator(alice, bob), "Bob operator for alice");
        assertTrue(shareToken.isOperator(charlie, bob), "Bob operator for charlie");

        // Alice revokes bob, but charlie still approves
        vm.prank(alice);
        shareToken.setOperator(bob, false);

        assertFalse(shareToken.isOperator(alice, bob), "Bob revoked for alice");
        assertTrue(shareToken.isOperator(charlie, bob), "Bob still operator for charlie");
    }

    // ========== TEST 12: Operator and VaultIntegration ==========
    /**
     * @notice Operator is checked in vault authorization functions
     * This test documents that the vault uses ShareToken.isOperator()
     */
    function testAuthorizationPaths_VaultUsesOperator() public {
        // Note: We can't fully test vault operations without KYC setup,
        // but we verify that the vault has the isOperator method
        assertTrue(address(vault) != address(0));
        // The vault.isOperator() method delegates to shareToken
        assertFalse(vault.isOperator(alice, bob));

        vm.prank(alice);
        shareToken.setOperator(bob, true);

        // Now vault should see bob as operator for alice
        assertTrue(vault.isOperator(alice, bob), "Vault should see operator from ShareToken");
    }
}
