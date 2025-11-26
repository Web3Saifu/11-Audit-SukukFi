// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {MockAsset} from "./MockAsset.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ERC7540MaxFunctionsTest
 * @dev Test the correct behavior of maxDeposit, maxMint, maxWithdraw, maxRedeem in ERC7540 async context
 */
contract ERC7540MaxFunctionsTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    MockAsset public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    function setUp() public {
        vm.startPrank(owner);

        asset = new MockAsset();

        // Deploy ShareToken with proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Max Test Shares", "MTS", owner);
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

        // Mint assets to alice
        asset.mint(alice, 100000e18);
    }

    /// @dev Test maxDeposit and maxMint behavior throughout async deposit lifecycle
    function test_MaxDepositMintLifecycle() public {
        uint256 depositAmount = 10000e18;

        // Initially, Alice has no claimable deposits
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0 initially");
        assertEq(vault.maxMint(alice), 0, "maxMint should be 0 initially");

        // Phase 1: Alice requests deposit
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        // After request, still no claimable amounts
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0 after request");
        assertEq(vault.maxMint(alice), 0, "maxMint should be 0 after request");

        // Phase 2: Owner fulfills the request
        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        // After fulfillment, Alice has claimable amounts
        assertEq(vault.maxDeposit(alice), depositAmount, "maxDeposit should equal claimable after fulfill");
        assertTrue(vault.maxMint(alice) > 0, "maxMint should be > 0 after fulfill");

        // Phase 3: Alice claims her deposit
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // After claiming, no more claimable amounts
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0 after claiming");
        assertEq(vault.maxMint(alice), 0, "maxMint should be 0 after claiming");
    }

    /// @dev Test maxWithdraw and maxRedeem behavior throughout async redeem lifecycle
    function test_MaxWithdrawRedeemLifecycle() public {
        uint256 depositAmount = 10000e18;

        // Setup: Get Alice some shares first
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Initially, Alice has no claimable redeems
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw should be 0 initially");
        assertEq(vault.maxRedeem(alice), 0, "maxRedeem should be 0 initially");

        // Phase 1: Alice requests redemption
        vm.startPrank(alice);
        shareToken.approve(address(vault), shares);
        vault.requestRedeem(shares, alice, alice);
        vm.stopPrank();

        // After request, still no claimable amounts
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw should be 0 after request");
        assertEq(vault.maxRedeem(alice), 0, "maxRedeem should be 0 after request");

        // Phase 2: Owner fulfills the redemption
        vm.prank(owner);
        vault.fulfillRedeem(alice, shares);

        // After fulfillment, Alice has claimable amounts
        assertTrue(vault.maxWithdraw(alice) > 0, "maxWithdraw should be > 0 after fulfill");
        assertEq(vault.maxRedeem(alice), shares, "maxRedeem should equal claimable shares after fulfill");

        // Phase 3: Alice claims her redemption
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        // After claiming, no more claimable amounts
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw should be 0 after claiming");
        assertEq(vault.maxRedeem(alice), 0, "maxRedeem should be 0 after claiming");
    }

    /// @dev Test that max functions reflect the ERC7540 note about syncing with claimable amounts
    function test_MaxFunctionsSyncWithClaimable() public {
        uint256 depositAmount = 5000e18;

        // Make request and fulfill
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, depositAmount);

        // Verify that max functions exactly match claimable amounts
        uint256 claimableAssets = vault.claimableDepositRequest(0, alice);
        assertEq(vault.maxDeposit(alice), claimableAssets, "maxDeposit should sync with claimableDepositRequest");

        // Verify mint amount relationship
        assertTrue(vault.maxMint(alice) > 0, "maxMint should reflect claimable shares");
    }

    /// @dev Test multiple users have independent max function values
    function test_MaxFunctionsPerUser() public {
        address bob = makeAddr("bob");
        asset.mint(bob, 50000e18);

        uint256 aliceDeposit = 10000e18;
        uint256 bobDeposit = 3000e18;

        // Alice makes and fulfills request
        vm.startPrank(alice);
        asset.approve(address(vault), aliceDeposit);
        vault.requestDeposit(aliceDeposit, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(alice, aliceDeposit);

        // Bob makes and fulfills different request
        vm.startPrank(bob);
        asset.approve(address(vault), bobDeposit);
        vault.requestDeposit(bobDeposit, bob, bob);
        vm.stopPrank();

        vm.prank(owner);
        vault.fulfillDeposit(bob, bobDeposit);

        // Each user should have their own max amounts
        assertEq(vault.maxDeposit(alice), aliceDeposit, "Alice maxDeposit should match her claimable");
        assertEq(vault.maxDeposit(bob), bobDeposit, "Bob maxDeposit should match his claimable");

        assertTrue(vault.maxMint(alice) > vault.maxMint(bob), "Alice should have more claimable mints");
    }
}
