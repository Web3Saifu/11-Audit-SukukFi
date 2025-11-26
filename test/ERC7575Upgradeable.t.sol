// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ERC7575UpgradeableTest
 * @dev Test upgradeable implementation of ERC7575 vault and share token
 */
contract ERC7575UpgradeableTest is Test {
    ShareTokenUpgradeable public shareTokenImpl;
    ShareTokenUpgradeable public shareToken;

    ERC7575VaultUpgradeable public vaultImpl;
    ERC7575VaultUpgradeable public vault;

    ERC20Faucet public asset;

    address public admin = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);

    uint256 public constant INITIAL_BALANCE = 100_000e18;

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

    function test_Initialization() public view {
        assertEq(shareToken.name(), "Multi-Asset Vault Shares");
        assertEq(shareToken.symbol(), "mvSHARE");
        assertEq(shareToken.owner(), admin);

        // Vault no longer has name/symbol per ERC7575 spec - only share token does
        assertEq(vault.asset(), address(asset));
        assertEq(vault.share(), address(shareToken));
    }

    function test_BasicDepositFlow() public {
        uint256 depositAmount = 1000e18;

        // Alice requests deposit
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        // Check pending deposit
        assertEq(vault.pendingDepositRequest(0, alice), depositAmount);

        // Admin fulfills deposit
        vault.fulfillDeposit(alice, depositAmount);

        // Check claimable
        assertEq(vault.claimableDepositRequest(0, alice), depositAmount);

        // Alice claims shares
        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Verify shares received
        assertEq(shareToken.balanceOf(alice), shares);
        assertEq(shares, depositAmount); // 1:1 initially
    }

    function test_VaultRegistry() public view {
        assertEq(shareToken.vault(address(asset)), address(vault));
        assertTrue(shareToken.isVault(address(vault)));
    }

    function test_RedeemFlow() public {
        uint256 depositAmount = 1000e18;

        // First deposit to get shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Now test redeem
        vm.startPrank(alice);
        shareToken.approve(address(vault), shares);
        vault.requestRedeem(shares, alice, alice);
        vm.stopPrank();

        // Check pending redeem
        assertEq(vault.pendingRedeemRequest(0, alice), shares);

        // Fulfill redeem
        vault.fulfillRedeem(alice, shares);

        // Claim assets
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // Verify
        assertEq(assets, depositAmount);
        assertEq(asset.balanceOf(alice), INITIAL_BALANCE);
        assertEq(shareToken.balanceOf(alice), 0);
    }

    function test_CannotReinitialize() public {
        // Try to reinitialize ShareToken
        vm.expectRevert();
        shareToken.initialize("New Name", "NEW", address(0x123));

        // Try to reinitialize Vault
        vm.expectRevert();
        vault.initialize(IERC20Metadata(address(0x456)), address(0x789), address(0x123));
    }
}
