// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ERC7887ComplianceTest
 * @dev Test suite to verify EIP-7887 compliance
 */
contract ERC7887ComplianceTest is Test {
    ShareTokenUpgradeable public shareTokenImpl;
    ShareTokenUpgradeable public shareToken;

    ERC7575VaultUpgradeable public vaultImpl;
    ERC7575VaultUpgradeable public vault;

    ERC20Faucet public asset;

    address public admin = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);

    uint256 public constant INITIAL_BALANCE = 100_000e18;

    // Events to check
    event DepositRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets);
    event CancelDepositRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets);
    event CancelDepositRequestClaimed(address indexed controller, address indexed receiver, uint256 indexed requestId, uint256 assets);

    event RedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares);
    event CancelRedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares);
    event CancelRedeemRequestClaimed(address indexed controller, address indexed receiver, uint256 indexed requestId, uint256 shares);

    function setUp() public {
        // Deploy asset
        asset = new ERC20Faucet("TestToken", "TEST", 1000000 * 1e18);

        // Deploy ShareToken implementation and proxy
        shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Multi-Asset Vault Shares", "mvSHARE", admin);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault implementation and proxy
        vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), admin);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Authorize vault to mint/burn shares
        shareToken.registerVault(address(asset), address(vault));

        // Setup test balances
        vm.warp(block.timestamp + 2 hours);
        asset.faucetAmountFor(alice, INITIAL_BALANCE);
        vm.warp(block.timestamp + 2 hours);
        asset.faucetAmountFor(bob, INITIAL_BALANCE);
    }

    function test_DepositCancellationFlow() public {
        uint256 depositAmount = 1000e18;

        // 1. Alice requests deposit
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit DepositRequest(alice, alice, 0, alice, depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        // Verify pending state
        assertEq(vault.pendingDepositRequest(0, alice), depositAmount);
        assertFalse(vault.pendingCancelDepositRequest(0, alice));

        // 2. Alice cancels deposit request
        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit CancelDepositRequest(alice, alice, 0, alice, depositAmount);
        vault.cancelDepositRequest(0, alice);
        vm.stopPrank();

        // Verify pending cancel state
        assertEq(vault.pendingDepositRequest(0, alice), 0);
        assertTrue(vault.pendingCancelDepositRequest(0, alice));
        assertEq(vault.claimableCancelDepositRequest(0, alice), 0);

        // 3. Verify blocking behavior: Alice cannot make new requests
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vm.expectRevert(abi.encodeWithSignature("DepositCancelationPending()"));
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        // 4. Admin fulfills cancel request
        vault.fulfillCancelDepositRequest(alice);

        // Verify claimable cancel state
        assertFalse(vault.pendingCancelDepositRequest(0, alice));
        assertEq(vault.claimableCancelDepositRequest(0, alice), depositAmount);

        // 5. Alice claims cancelled assets
        uint256 balanceBefore = asset.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit CancelDepositRequestClaimed(alice, alice, 0, depositAmount);
        vault.claimCancelDepositRequest(0, alice, alice);
        vm.stopPrank();

        // Verify final state
        assertEq(asset.balanceOf(alice), balanceBefore + depositAmount);
        assertEq(vault.claimableCancelDepositRequest(0, alice), 0);

        // 6. Verify blocking is lifted
        vm.startPrank(alice);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();
        assertEq(vault.pendingDepositRequest(0, alice), depositAmount);
    }

    function test_RedeemCancellationFlow() public {
        uint256 depositAmount = 1000e18;

        // Setup: Alice gets some shares first
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // 1. Alice requests redeem
        vm.startPrank(alice);
        shareToken.approve(address(vault), shares);

        vm.expectEmit(true, true, true, true);
        emit RedeemRequest(alice, alice, 0, alice, shares);
        vault.requestRedeem(shares, alice, alice);
        vm.stopPrank();

        // Verify pending state
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
        assertFalse(vault.pendingCancelRedeemRequest(0, alice));

        // 2. Alice cancels redeem request
        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit CancelRedeemRequest(alice, alice, 0, alice, shares);
        vault.cancelRedeemRequest(0, alice);
        vm.stopPrank();

        // Verify pending cancel state
        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertTrue(vault.pendingCancelRedeemRequest(0, alice));
        assertEq(vault.claimableCancelRedeemRequest(0, alice), 0);

        // 3. Verify blocking behavior: Alice cannot make new requests
        // Give Alice more shares so she passes the balance check
        vm.startPrank(alice);
        uint256 extraShares = 1000e18;
        // We need to get shares somehow. Let's deposit more assets.
        asset.approve(address(vault), extraShares);
        vault.requestDeposit(extraShares, alice, alice);
        vm.stopPrank();
        vault.fulfillDeposit(alice, extraShares);
        vm.prank(alice);
        vault.deposit(extraShares, alice); // Alice now has extraShares

        vm.startPrank(alice);
        shareToken.approve(address(vault), extraShares);
        vm.expectRevert(abi.encodeWithSignature("RedeemCancelationPending()"));
        vault.requestRedeem(extraShares, alice, alice);
        vm.stopPrank();

        // 4. Admin fulfills cancel request
        vault.fulfillCancelRedeemRequest(alice);

        // Verify claimable cancel state
        assertFalse(vault.pendingCancelRedeemRequest(0, alice));
        assertEq(vault.claimableCancelRedeemRequest(0, alice), shares);

        // 5. Alice claims cancelled shares
        uint256 balanceBefore = shareToken.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit CancelRedeemRequestClaimed(alice, alice, 0, shares);
        vault.claimCancelRedeemRequest(0, alice, alice);
        vm.stopPrank();

        // Verify final state
        assertEq(shareToken.balanceOf(alice), balanceBefore + shares);
        assertEq(vault.claimableCancelRedeemRequest(0, alice), 0);

        // 6. Verify blocking is lifted
        vm.startPrank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.stopPrank();
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
    }
}
