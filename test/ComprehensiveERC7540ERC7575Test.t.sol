// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {IERC7575, IERC7575ShareExtended} from "../src/interfaces/IERC7575.sol";
import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {MockAsset} from "./MockAsset.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ComprehensiveERC7540ERC7575Test
 * @dev COMPLETE test suite for EVERY requirement in ERC7540 and ERC7575 specifications
 */
contract ComprehensiveERC7540ERC7575Test is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    MockAsset public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    // Events for testing
    event DepositRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets);
    event RedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares);
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event VaultUpdate(address indexed asset, address vault);

    function setUp() public {
        vm.startPrank(owner);

        asset = new MockAsset();

        // Deploy ShareToken with proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Comprehensive Shares", "COMP", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault with proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(asset), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Configure

        shareToken.registerVault(address(asset), address(vault));

        vm.stopPrank();

        // Mint assets to users
        asset.mint(alice, 200000e18);
        asset.mint(bob, 200000e18);
        asset.mint(charlie, 200000e18);
    }

    // =============================================================================
    // ERC7540 DEPOSIT TESTS - ALL REQUIRED METHODS
    // =============================================================================

    /// @dev Test requestDeposit method - complete spec compliance
    function test_ERC7540_RequestDeposit_Complete() public {
        uint256 assets = 10000e18;

        vm.startPrank(alice);
        asset.approve(address(vault), assets);

        // Test event emission
        vm.expectEmit(true, true, true, true);
        emit DepositRequest(alice, alice, 0, alice, assets);

        // Test return value
        uint256 requestId = vault.requestDeposit(assets, alice, alice);
        assertEq(requestId, 0, "Request ID should be 0");

        vm.stopPrank();

        // Test state changes
        assertEq(vault.pendingDepositRequest(0, alice), assets);
        assertEq(vault.claimableDepositRequest(0, alice), 0);

        // Test asset transfer
        assertEq(asset.balanceOf(address(vault)), assets);
        assertEq(asset.balanceOf(alice), 200000e18 - assets);
    }

    /// @dev Test pendingDepositRequest - MUST not include claimable
    function test_ERC7540_PendingDepositRequest_ExcludesClaimable() public {
        uint256 assets = 5000e18;

        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, alice, alice);
        vm.stopPrank();

        // Before fulfillment - should be in pending
        assertEq(vault.pendingDepositRequest(0, alice), assets);
        assertEq(vault.claimableDepositRequest(0, alice), 0);

        // After fulfillment - should move from pending to claimable
        vm.prank(owner);
        vault.fulfillDeposit(alice, assets);

        assertEq(vault.pendingDepositRequest(0, alice), 0);
        assertEq(vault.claimableDepositRequest(0, alice), assets);
    }

    /// @dev Test claimableDepositRequest - MUST not include pending
    function test_ERC7540_ClaimableDepositRequest_ExcludesPending() public {
        uint256 assets1 = 3000e18;
        uint256 assets2 = 2000e18;

        // First request - fulfill it
        vm.startPrank(alice);
        asset.approve(address(vault), assets1 + assets2);
        vault.requestDeposit(assets1, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, assets1);

        // Second request - don't fulfill it
        vm.startPrank(alice);
        vault.requestDeposit(assets2, alice, alice);
        vm.stopPrank();

        // Claimable should only include fulfilled amount
        assertEq(vault.claimableDepositRequest(0, alice), assets1);
        assertEq(vault.pendingDepositRequest(0, alice), assets2);
    }

    /// @dev Test deposit method with 3-parameter overload (ERC7540 requirement)
    function test_ERC7540_DepositWithController() public {
        uint256 assets = 8000e18;

        // Setup fulfilled request
        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, assets);

        // Test 3-parameter deposit
        vm.prank(alice);
        uint256 shares = vault.deposit(assets, bob, alice); // deposit for bob, controlled by alice

        assertEq(shareToken.balanceOf(bob), shares);
        assertEq(vault.claimableDepositRequest(0, alice), 0);
    }

    // =============================================================================
    // ERC7540 REDEEM TESTS - ALL REQUIRED METHODS
    // =============================================================================

    /// @dev Test requestRedeem method - complete spec compliance
    function test_ERC7540_RequestRedeem_Complete() public {
        // Setup: Give alice some shares first
        uint256 depositAssets = 10000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), depositAssets);
        vault.requestDeposit(depositAssets, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAssets);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAssets, alice);

        // Now test requestRedeem
        vm.startPrank(alice);

        // Test event emission
        vm.expectEmit(true, true, true, true);
        emit RedeemRequest(alice, alice, 0, alice, shares);

        // Test return value
        uint256 requestId = vault.requestRedeem(shares, alice, alice);
        assertEq(requestId, 0, "Request ID should be 0");

        vm.stopPrank();

        // Test state changes
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
        assertEq(vault.claimableRedeemRequest(0, alice), 0);

        // Test share transfer
        assertEq(shareToken.balanceOf(alice), 0);
        assertEq(shareToken.balanceOf(address(vault)), shares);
    }

    /// @dev Test pendingRedeemRequest - MUST not include claimable
    function test_ERC7540_PendingRedeemRequest_ExcludesClaimable() public {
        // Setup shares
        uint256 depositAssets = 10000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), depositAssets);
        vault.requestDeposit(depositAssets, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAssets);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAssets, alice);

        // Request redeem
        vm.startPrank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.stopPrank();

        // Before fulfillment
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
        assertEq(vault.claimableRedeemRequest(0, alice), 0);

        // After fulfillment
        vm.prank(owner);
        vault.fulfillRedeem(alice, shares);

        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertEq(vault.claimableRedeemRequest(0, alice), shares);
    }

    /// @dev Test claimableRedeemRequest - MUST not include pending
    function test_ERC7540_ClaimableRedeemRequest_ExcludesPending() public {
        // Setup shares
        uint256 depositAssets = 20000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), depositAssets);
        vault.requestDeposit(depositAssets, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAssets);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAssets, alice);

        uint256 shares1 = shares / 2;
        uint256 shares2 = shares - shares1;

        // First redeem request - fulfill it
        vm.startPrank(alice);
        vault.requestRedeem(shares1, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillRedeem(alice, shares1);

        // Second redeem request - don't fulfill it
        vm.startPrank(alice);
        vault.requestRedeem(shares2, alice, alice);
        vm.stopPrank();

        // Claimable should only include fulfilled amount
        assertEq(vault.claimableRedeemRequest(0, alice), shares1);
        assertEq(vault.pendingRedeemRequest(0, alice), shares2);
    }

    // =============================================================================
    // ERC7540 OPERATOR TESTS - ALL REQUIRED METHODS
    // =============================================================================

    /// @dev Test setOperator - complete functionality
    function test_ERC7540_SetOperator_Complete() public {
        // Test event emission
        vm.expectEmit(true, true, false, true);
        emit OperatorSet(alice, bob, true);

        vm.prank(alice);
        bool result = vault.setOperator(bob, true);

        assertTrue(result);
        assertTrue(vault.isOperator(alice, bob));

        // Test revoke
        vm.expectEmit(true, true, false, true);
        emit OperatorSet(alice, bob, false);

        vm.prank(alice);
        vault.setOperator(bob, false);

        assertFalse(vault.isOperator(alice, bob));
    }

    /// @dev Test isOperator - query functionality
    function test_ERC7540_IsOperator() public {
        assertFalse(vault.isOperator(alice, bob));
        assertFalse(vault.isOperator(bob, alice));

        vm.prank(alice);
        vault.setOperator(bob, true);

        assertTrue(vault.isOperator(alice, bob));
        assertFalse(vault.isOperator(bob, alice)); // Not symmetric
    }

    /// @dev Test operator permissions for requestDeposit
    function test_ERC7540_OperatorRequestDeposit() public {
        uint256 assets = 5000e18;

        // Alice authorizes Bob
        vm.prank(alice);
        vault.setOperator(bob, true);

        // Bob can make request for Alice
        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vm.stopPrank();

        vm.prank(bob);
        vault.requestDeposit(assets, alice, alice);

        assertEq(vault.pendingDepositRequest(0, alice), assets);
    }

    /// @dev Test operator permissions for requestRedeem
    function test_ERC7540_OperatorRequestRedeem() public {
        // Setup shares for alice
        uint256 assets = 5000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, assets);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        // Alice authorizes Bob
        vm.prank(alice);
        vault.setOperator(bob, true);

        // Bob can request redeem for Alice
        vm.prank(bob);
        vault.requestRedeem(shares, alice, alice);

        assertEq(vault.pendingRedeemRequest(0, alice), shares);
    }

    // =============================================================================
    // ERC4626 MAX FUNCTIONS INTERPRETATION IN ERC7540 CONTEXT
    // =============================================================================

    /// @dev Test maxDeposit interpretation in async context
    function test_ERC7540_MaxDeposit_AsyncInterpretation() public {
        // Initially, no claimable deposits
        assertEq(vault.maxDeposit(alice), 0);

        // After making a request (but not fulfilled), still 0
        uint256 assets = 1000e18;
        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, alice, alice);
        vm.stopPrank();

        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0 before fulfillment");

        // After fulfillment, should equal claimable amount
        vm.prank(owner);
        vault.fulfillDeposit(alice, assets);

        assertEq(vault.maxDeposit(alice), assets, "maxDeposit should equal claimable after fulfill");

        // After claiming, back to 0
        vm.prank(alice);
        vault.deposit(assets, alice);

        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0 after claiming");
    }

    /// @dev Test maxMint interpretation in async context
    function test_ERC7540_MaxMint_AsyncInterpretation() public {
        uint256 assets = 1000e18;

        // Initially 0
        assertEq(vault.maxMint(alice), 0);

        // Make and fulfill request
        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, assets);

        // Should match claimable shares
        uint256 claimableShares = vault.claimableDepositRequest(0, alice);
        uint256 expectedShares = vault.convertToShares(claimableShares);
        assertEq(vault.maxMint(alice), expectedShares);

        // After claiming, back to 0
        vm.prank(alice);
        vault.mint(expectedShares, alice);

        assertEq(vault.maxMint(alice), 0);
    }

    // =============================================================================
    // ERC7575 TESTS - ALL REQUIRED METHODS AND BEHAVIORS
    // =============================================================================

    /// @dev Test share() method - MUST return share token address
    function test_ERC7575_Share() public view {
        address shareAddress = vault.share();
        assertEq(shareAddress, address(shareToken));
    }

    /// @dev Test vault() method on share token
    function test_ERC7575_VaultLookup() public {
        address vaultAddress = shareToken.vault(address(asset));
        assertEq(vaultAddress, address(vault));

        // Test with non-existent asset
        MockAsset otherAsset = new MockAsset();
        assertEq(shareToken.vault(address(otherAsset)), address(0));
    }

    /// @dev Test VaultUpdate event via unregister and register
    function test_ERC7575_VaultUpdateEvent() public {
        // Deploy a real new vault for the same asset
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        address newVault = address(vaultProxy);

        // First deactivate existing vault, then unregister
        vm.prank(owner);
        vault.setVaultActive(false);

        vm.expectEmit(true, false, false, true);
        emit VaultUpdate(address(asset), address(0));
        vm.prank(owner);
        shareToken.unregisterVault(address(asset));

        // Then register new vault
        vm.expectEmit(true, false, false, true);
        emit VaultUpdate(address(asset), newVault);
        vm.prank(owner);
        shareToken.registerVault(address(asset), newVault);

        assertEq(shareToken.vault(address(asset)), newVault);
    }

    /// @dev Test ERC165 interface support - ERC7575 requirement
    function test_ERC7575_ERC165Support() public view {
        // Vault interface ID: 0x2f0a18c5
        assertTrue(vault.supportsInterface(0x2f0a18c5));

        // Share interface ID: 0x0a13f305 (full IERC7575ShareExtended with getRegisteredAssets and getCirculatingSupplyAndAssets)
        assertTrue(shareToken.supportsInterface(0x0a13f305));

        // Should also support ERC7575 interface
        assertTrue(vault.supportsInterface(type(IERC7575).interfaceId));
        assertTrue(shareToken.supportsInterface(type(IERC7575ShareExtended).interfaceId));
    }

    /// @dev Test multi-asset behavior - shares single token across assets
    function test_ERC7575_MultiAssetSharing() public {
        MockAsset asset2 = new MockAsset();
        asset2.mint(alice, 100000e18);

        // Deploy second vault for asset2
        vm.startPrank(owner);
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(asset2), address(shareToken), owner);
        ERC1967Proxy vaultProxy2 = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        ERC7575VaultUpgradeable vault2 = ERC7575VaultUpgradeable(address(vaultProxy2));

        shareToken.registerVault(address(asset2), address(vault2));
        vm.stopPrank();

        // Both vaults should use same share token
        assertEq(vault.share(), vault2.share());
        assertEq(vault.share(), address(shareToken));

        // Deposit to both vaults
        vm.startPrank(alice);
        asset.approve(address(vault), 5000e18);
        vault.requestDeposit(5000e18, alice, alice);

        asset2.approve(address(vault2), 3000e18);
        vault2.requestDeposit(3000e18, alice, alice);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.fulfillDeposit(alice, 5000e18);
        vault2.fulfillDeposit(alice, 3000e18);
        vm.stopPrank();

        vm.startPrank(alice);
        vault.deposit(5000e18, alice);
        vault2.deposit(3000e18, alice);
        vm.stopPrank();

        // Alice should have shares from both vaults in same token
        assertTrue(shareToken.balanceOf(alice) > 0);
    }

    // =============================================================================
    // REQUEST ID AND STATE MANAGEMENT TESTS
    // =============================================================================

    /// @dev Test that requestId 0 aggregates requests by controller
    function test_ERC7540_RequestIdZeroAggregation() public {
        uint256 assets1 = 2000e18;
        uint256 assets2 = 3000e18;

        vm.startPrank(alice);
        asset.approve(address(vault), assets1 + assets2);

        // Multiple requests should aggregate
        vault.requestDeposit(assets1, alice, alice);
        vault.requestDeposit(assets2, alice, alice);

        vm.stopPrank();

        // Should be aggregated in pending
        assertEq(vault.pendingDepositRequest(0, alice), assets1 + assets2);
    }

    /// @dev Test state transitions: Pending -> Claimable -> Claimed
    function test_ERC7540_StateTransitions() public {
        uint256 assets = 1000e18;

        // Initial state
        assertEq(vault.pendingDepositRequest(0, alice), 0);
        assertEq(vault.claimableDepositRequest(0, alice), 0);

        // Request -> Pending state
        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, alice, alice);
        vm.stopPrank();

        assertEq(vault.pendingDepositRequest(0, alice), assets);
        assertEq(vault.claimableDepositRequest(0, alice), 0);

        // Fulfill -> Claimable state
        vm.prank(owner);
        vault.fulfillDeposit(alice, assets);

        assertEq(vault.pendingDepositRequest(0, alice), 0);
        assertEq(vault.claimableDepositRequest(0, alice), assets);

        // Claim -> Final state
        vm.prank(alice);
        vault.deposit(assets, alice);

        assertEq(vault.pendingDepositRequest(0, alice), 0);
        assertEq(vault.claimableDepositRequest(0, alice), 0);
    }

    // =============================================================================
    // PREVIEW FUNCTIONS REVERT REQUIREMENT
    // =============================================================================

    /// @dev Test all preview functions revert as required by ERC7540
    function test_ERC7540_PreviewFunctionsRevert() public {
        vm.expectRevert(IERC7575Errors.AsyncFlow.selector);
        vault.previewDeposit(1000e18);

        vm.expectRevert(IERC7575Errors.AsyncFlow.selector);
        vault.previewMint(1000e18);

        vm.expectRevert(IERC7575Errors.AsyncFlow.selector);
        vault.previewWithdraw(1000e18);

        vm.expectRevert(IERC7575Errors.AsyncFlow.selector);
        vault.previewRedeem(1000e18);
    }

    // =============================================================================
    // ERROR HANDLING AND EDGE CASES
    // =============================================================================

    /// @dev Test MUST revert conditions for requestDeposit
    function test_ERC7540_RequestDepositRevertConditions() public {
        // Zero amount (fails zero check)
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.ZeroAssets.selector);
        vault.requestDeposit(0, alice, alice);

        // Insufficient approval
        vm.prank(alice);
        vm.expectRevert();
        vault.requestDeposit(1000e18, alice, alice);

        // Invalid owner (not caller and not approved operator)
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.InvalidOwner.selector);
        vault.requestDeposit(1000e18, alice, bob); // Alice trying to deposit for Bob without approval
    }

    /// @dev Test MUST revert conditions for requestRedeem
    function test_ERC7540_RequestRedeemRevertConditions() public {
        // Zero shares
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.ZeroShares.selector);
        vault.requestRedeem(0, alice, alice);

        // Insufficient balance
        vm.prank(alice);
        vm.expectRevert();
        vault.requestRedeem(1000e18, alice, alice);
    }

    /// @dev Test unauthorized operator access
    function test_ERC7540_UnauthorizedOperator() public {
        uint256 assets = 1000e18;

        vm.startPrank(alice);
        asset.approve(address(vault), assets);
        vm.stopPrank();

        // Bob tries to act for Alice without authorization
        vm.prank(bob);
        vm.expectRevert(IERC7575Errors.InvalidOwner.selector);
        vault.requestDeposit(assets, alice, alice);
    }
}
