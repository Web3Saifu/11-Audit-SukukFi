// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {IERC7540Operator} from "../src/interfaces/IERC7540.sol";
import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {MockAsset} from "./MockAsset.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

contract OperatorRedemptionTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    MockAsset public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob"); // operator
    address public investmentManager = makeAddr("investmentManager");

    function setUp() public {
        vm.startPrank(owner);

        asset = new MockAsset();

        // Deploy ShareToken with proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Test Shares", "TST", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault with proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(address(asset)), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault with share token
        shareToken.registerVault(address(asset), address(vault));
        shareToken.setInvestmentManager(investmentManager);

        vm.stopPrank();

        // Mint assets to alice
        asset.mint(alice, 100000e18);
    }

    /// @dev Test that operator can request redemption without user pre-approving vault
    function test_OperatorCanRequestRedemptionWithoutAllowance() public {
        uint256 depositAmount = 10000e18;

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        // Investment manager fulfills deposit
        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        // Alice claims her shares
        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Verify Alice has shares
        assertEq(shareToken.balanceOf(alice), shares);
        assertTrue(shares > 0);

        // Alice sets Bob as operator (does NOT need to approve vault)
        vm.prank(alice);
        shareToken.setOperator(bob, true);

        // Verify Bob is operator
        assertTrue(shareToken.isOperator(alice, bob));

        // Verify Alice has NOT approved vault for any amount
        assertEq(shareToken.allowance(alice, address(vault)), 0, "Alice should not have approved vault");

        // Bob (operator) should be able to request redemption on behalf of Alice
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        // Verify redemption request was successful
        assertEq(requestId, 0);
        assertEq(vault.pendingRedeemRequest(0, alice), shares);

        // Verify shares were transferred from Alice to vault
        assertEq(shareToken.balanceOf(alice), 0, "Alice shares should be transferred to vault");
        assertEq(shareToken.balanceOf(address(vault)), shares, "Vault should hold the shares");
    }

    /// @dev Test that non-operator without allowance cannot request redemption on behalf of user
    function test_NonOperatorCannotRequestRedemption() public {
        uint256 depositAmount = 10000e18;

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Bob tries to request redemption without being an operator or having allowance
        // Should revert with ERC20InsufficientAllowance since spendAllowance will fail
        vm.prank(bob);
        vm.expectRevert(); // Will revert with ERC20InsufficientAllowance
        vault.requestRedeem(shares, alice, alice);
    }

    /// @dev Test that spender WITH allowance can request redemption on behalf of user
    function test_SpenderWithAllowanceCanRequestRedemption() public {
        uint256 depositAmount = 10000e18;

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Alice approves Bob to spend her shares
        vm.prank(alice);
        shareToken.approve(bob, shares);

        // Bob (non-operator but with allowance) should be able to request redemption
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        // Verify redemption request was successful
        assertEq(requestId, 0);
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
        assertEq(shareToken.balanceOf(alice), 0);
        assertEq(shareToken.balanceOf(address(vault)), shares);

        // Verify allowance was spent
        assertEq(shareToken.allowance(alice, bob), 0, "Allowance should be spent");
    }

    /// @dev Test all authorization paths for requestRedeem
    function test_RedeemAuthorizationPaths() public {
        uint256 depositAmount = 10000e18;

        // Setup: Alice deposits and gets shares three times
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(alice);
            asset.approve(address(vault), depositAmount);
            vault.requestDeposit(depositAmount, alice, alice);
            vm.stopPrank();

            vm.prank(investmentManager);
            vault.fulfillDeposit(alice, depositAmount);

            vm.prank(alice);
            vault.deposit(depositAmount, alice);
        }

        uint256 totalShares = shareToken.balanceOf(alice);
        uint256 sharesPerTest = totalShares / 3;

        // PATH 1: Owner calling their own requestRedeem (no allowance needed)
        vm.prank(alice);
        vault.requestRedeem(sharesPerTest, alice, alice);
        assertEq(vault.pendingRedeemRequest(0, alice), sharesPerTest);

        // Reset for next test
        vm.prank(investmentManager);
        vault.fulfillRedeem(alice, sharesPerTest);
        vm.prank(alice);
        vault.redeem(sharesPerTest, alice, alice);

        // PATH 2: Operator calling on behalf of owner (no allowance needed)
        vm.prank(alice);
        shareToken.setOperator(bob, true);

        vm.prank(bob);
        vault.requestRedeem(sharesPerTest, alice, alice);
        assertEq(vault.pendingRedeemRequest(0, alice), sharesPerTest);

        // Reset for next test
        vm.prank(investmentManager);
        vault.fulfillRedeem(alice, sharesPerTest);
        vm.prank(bob);
        vault.redeem(sharesPerTest, alice, alice);

        // PATH 3: Non-operator with allowance calling on behalf of owner
        address charlie = makeAddr("charlie");
        vm.prank(alice);
        shareToken.approve(charlie, sharesPerTest);

        vm.prank(charlie);
        vault.requestRedeem(sharesPerTest, alice, alice);
        assertEq(vault.pendingRedeemRequest(0, alice), sharesPerTest);

        // Verify allowance was spent
        assertEq(shareToken.allowance(alice, charlie), 0, "Allowance should be spent");
    }

    /// @dev Test that user can request their own redemption without allowance to vault
    function test_UserCanRequestOwnRedemptionWithoutAllowance() public {
        uint256 depositAmount = 10000e18;

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Verify Alice has NOT approved vault
        assertEq(shareToken.allowance(alice, address(vault)), 0, "Alice should not have approved vault");

        // Alice should be able to request her own redemption without vault allowance
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        // Verify redemption request was successful
        assertEq(requestId, 0);
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
        assertEq(shareToken.balanceOf(alice), 0);
        assertEq(shareToken.balanceOf(address(vault)), shares);
    }

    /// @dev Test that operator can complete full redemption flow
    function test_OperatorCanCompleteFullRedemptionFlow() public {
        uint256 depositAmount = 10000e18;

        // Setup: Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Alice sets Bob as operator
        vm.prank(alice);
        shareToken.setOperator(bob, true);

        // Step 1: Bob requests redemption for Alice
        vm.prank(bob);
        vault.requestRedeem(shares, alice, alice);

        // Step 2: Investment manager fulfills redemption
        vm.prank(investmentManager);
        uint256 assets = vault.fulfillRedeem(alice, shares);
        assertTrue(assets > 0);

        // Verify claimable assets
        assertEq(vault.claimableRedeemRequest(0, alice), shares);

        // Step 3: Bob claims assets on behalf of Alice (as operator)
        vm.prank(bob);
        uint256 receivedAssets = vault.redeem(shares, alice, alice);

        // Verify Alice received her assets
        assertTrue(receivedAssets > 0);
        assertEq(asset.balanceOf(alice), receivedAssets + (100000e18 - depositAmount), "Alice should have received assets");

        // Verify shares were burned
        assertEq(shareToken.balanceOf(address(vault)), 0, "Shares should be burned");
        assertEq(vault.claimableRedeemRequest(0, alice), 0, "No more claimable shares");
    }

    /// @dev Test that vaultTransferFrom is restricted to vaults only
    function test_VaultTransferFromRestrictedToVaults() public {
        // Mint some shares to alice first
        vm.prank(address(vault)); // Only vault can mint
        shareToken.mint(alice, 1000e18);

        // Non-vault should not be able to call vaultTransferFrom
        vm.prank(bob);
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.vaultTransferFrom(alice, bob, 100e18);

        // Only vault can call vaultTransferFrom
        vm.prank(address(vault));
        bool success = shareToken.vaultTransferFrom(alice, address(vault), 100e18);
        assertTrue(success);
        assertEq(shareToken.balanceOf(alice), 900e18);
        assertEq(shareToken.balanceOf(address(vault)), 100e18);
    }
}
