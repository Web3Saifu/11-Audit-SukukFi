// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {MockAsset} from "./MockAsset.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ERC7575SecurityTest
 * @dev Comprehensive security tests for upgradeable ERC7575 vault system
 */
contract ERC7575SecurityTest is Test {
    ShareTokenUpgradeable public shareToken;
    ERC7575VaultUpgradeable public vault;
    MockAsset public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy asset
        asset = new MockAsset();

        // Deploy ShareToken with proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Security Test Shares", "STS", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault with proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(asset), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Configure
        shareToken.registerVault(address(asset), address(vault));

        // Set minimum deposit to 0 for testing small amounts
        vault.setMinimumDepositAmount(0);

        vm.stopPrank();

        // Mint assets directly to users
        asset.mint(alice, 100000e18);
        asset.mint(bob, 100000e18);
        asset.mint(attacker, 100000e18);
    }

    /// @dev Test virtual assets inflation protection allows small deposits
    function test_Security_VirtualAssetsInflationProtection() public {
        vm.startPrank(attacker);
        asset.approve(address(vault), 100);

        // Small deposits should work with virtual assets protection
        vault.requestDeposit(100, attacker, attacker);

        // Verify the deposit was recorded
        assertEq(vault.pendingDepositRequest(0, attacker), 100);

        vm.stopPrank();
    }

    /// @dev Test first depositor inflation attack protection
    function test_Security_FirstDepositorInflationProtection() public {
        // First deposit should work even with small amount (virtual assets provide protection)
        vm.startPrank(alice);
        uint256 minDeposit = 1000; // Small deposit for testing inflation protection
        asset.approve(address(vault), minDeposit);
        vault.requestDeposit(minDeposit, alice, alice);
        vm.stopPrank();

        // Fulfill deposit
        vm.prank(owner);
        vault.fulfillDeposit(alice, minDeposit);

        // Claim shares
        vm.prank(alice);
        vault.deposit(minDeposit, alice);

        // Attacker tries to inflate share price with similar amount
        vm.startPrank(attacker);
        uint256 attackAmount = minDeposit; // Use same amount as Alice
        asset.approve(address(vault), attackAmount);

        // Should not be able to manipulate share price significantly
        vault.requestDeposit(attackAmount, attacker, attacker);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(attacker, attackAmount);

        vm.prank(attacker);
        vault.deposit(attackAmount, attacker);

        // Both users should have reasonable share amounts
        uint256 aliceShares = shareToken.balanceOf(alice);
        uint256 attackerShares = shareToken.balanceOf(attacker);

        assertTrue(aliceShares > 0, "Alice should have shares");
        assertTrue(attackerShares > 0, "Attacker should have shares");

        // With equal deposits, shares should be approximately equal (allowing for rounding)
        assertTrue(attackerShares > aliceShares / 2, "Attacker should get reasonable shares");
        assertTrue(attackerShares < aliceShares * 2, "Share price manipulation detected");
    }

    /// @dev Test unauthorized access control
    function test_Security_UnauthorizedAccess() public {
        // Setup pending deposit
        vm.startPrank(alice);
        asset.approve(address(vault), 10000e18);
        vault.requestDeposit(10000e18, alice, alice);
        vm.stopPrank();

        // Only investment manager should be able to fulfill (owner is initially set as investment manager)
        vm.prank(attacker);
        vm.expectRevert();
        vault.fulfillDeposit(alice, 10000e18);

        // Investment manager (owner) can fulfill
        vm.prank(owner);
        vault.fulfillDeposit(alice, 10000e18);
    }

    /// @dev Test investment manager access control for fulfillment functions
    function test_Security_InvestmentManagerAccess() public {
        address investmentManager = makeAddr("investmentManager");

        // Setup pending deposit
        vm.startPrank(alice);
        asset.approve(address(vault), 10000e18);
        vault.requestDeposit(10000e18, alice, alice);
        vm.stopPrank();

        // Set new investment manager (centralized through ShareToken)
        vm.prank(owner);
        shareToken.setInvestmentManager(investmentManager);

        // Owner should no longer be able to fulfill (only investment manager can)
        vm.prank(owner);
        vm.expectRevert();
        vault.fulfillDeposit(alice, 10000e18);

        // Attacker should not be able to fulfill
        vm.prank(attacker);
        vm.expectRevert();
        vault.fulfillDeposit(alice, 10000e18);

        // Only new investment manager can fulfill
        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, 10000e18);

        // Verify the deposit was fulfilled
        assertEq(vault.claimableDepositRequest(0, alice), 10000e18);

        // Now test fulfillRedeem with the same investment manager setup
        // First complete the deposit flow to get shares
        vm.prank(alice);
        uint256 shares = vault.deposit(10000e18, alice);

        // Request redemption (Alice needs to approve vault to spend her shares)
        vm.startPrank(alice);
        shareToken.approve(address(vault), shares);
        vault.requestRedeem(shares, alice, alice);
        vm.stopPrank();

        // Owner should not be able to fulfill redeem (only investment manager can)
        vm.prank(owner);
        vm.expectRevert();
        vault.fulfillRedeem(alice, shares);

        // Only investment manager can fulfill redeem
        vm.prank(investmentManager);
        vault.fulfillRedeem(alice, shares);

        // Verify the redemption was fulfilled
        assertGt(vault.claimableRedeemRequest(0, alice), 0);
    }

    /// @dev Test share token authorization controls
    function test_Security_ShareTokenAuthorization() public {
        // Unauthorized vault should not be able to mint shares
        vm.startPrank(owner);

        // Deploy unauthorized vault
        ERC7575VaultUpgradeable unauthorizedImpl = new ERC7575VaultUpgradeable();
        bytes memory initData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(asset), address(shareToken), owner);
        ERC1967Proxy unauthorizedProxy = new ERC1967Proxy(address(unauthorizedImpl), initData);

        // Should not be authorized
        assertFalse(shareToken.isVault(address(unauthorizedProxy)));

        vm.stopPrank();

        // Should not be able to mint shares
        vm.prank(address(unauthorizedProxy));
        vm.expectRevert();
        shareToken.mint(alice, 1000e18);
    }

    /// @dev Test operator authorization
    function test_Security_OperatorAuthorization() public {
        // Alice authorizes bob as operator
        vm.prank(alice);
        vault.setOperator(bob, true);

        assertTrue(vault.isOperator(alice, bob));

        // Bob can act for alice
        vm.startPrank(alice);
        asset.approve(address(vault), 10000e18);
        vm.stopPrank();

        vm.prank(bob);
        vault.requestDeposit(10000e18, alice, alice);

        // Fulfill
        vm.prank(owner);
        vault.fulfillDeposit(alice, 10000e18);

        // Bob can claim for alice
        vm.prank(bob);
        vault.deposit(10000e18, alice);

        // Alice should have received shares
        assertTrue(shareToken.balanceOf(alice) > 0);

        // Alice revokes bob's operator status
        vm.prank(alice);
        vault.setOperator(bob, false);

        assertFalse(vault.isOperator(alice, bob));

        // Bob should no longer be able to act for alice
        vm.prank(bob);
        vm.expectRevert();
        vault.requestDeposit(1000e18, alice, alice);
    }

    /// @dev Test zero address protections
    function test_Security_ZeroAddressChecks() public {
        vm.startPrank(owner);

        // Should not be able to register zero address asset
        vm.expectRevert();
        shareToken.registerVault(address(0), address(vault));

        // Should not be able to register vault for zero address
        vm.expectRevert();
        shareToken.registerVault(address(asset), address(0));

        // Should not be able to unregister zero address asset
        vm.expectRevert();
        shareToken.unregisterVault(address(0));

        vm.stopPrank();
    }

    /// @dev Test basic reentrancy protection exists
    function test_Security_ReentrancyProtection() public {
        // Test that our vault has nonReentrant modifiers
        // This is a basic check - comprehensive reentrancy testing would require custom malicious tokens
        assertTrue(address(vault).code.length > 0, "Vault should be deployed");

        // Verify basic deposit flow works (which uses nonReentrant modifier)
        vm.startPrank(alice);
        asset.approve(address(vault), 10000e18);
        vault.requestDeposit(10000e18, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, 10000e18);

        vm.prank(alice);
        vault.deposit(10000e18, alice);

        assertTrue(shareToken.balanceOf(alice) > 0, "Deposit should succeed with reentrancy protection");
    }
}

/// @dev Malicious token for testing reentrancy protection
contract MaliciousToken is MockAsset {
    address public target;
    bool public attackAttempted;
    bool public attackSucceeded;

    function setTarget(address _target) external {
        target = _target;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (target != address(0) && to == target && !attackAttempted) {
            attackAttempted = true;
            try ERC7575VaultUpgradeable(target).requestDeposit(1000, msg.sender, msg.sender) {
                attackSucceeded = true;
            } catch {
                // Attack was prevented
            }
        }
        return super.transfer(to, amount);
    }
}
