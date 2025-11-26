// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {IERC7575, IERC7575Share, IERC7575ShareExtended} from "../src/interfaces/IERC7575.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ERC7575MultiAssetTest
 * @dev Tests for multi-asset capabilities of ERC7575 vault system
 */
contract ERC7575MultiAssetTest is Test {
    ShareTokenUpgradeable public shareToken;

    ERC20Faucet public usdcAsset;
    ERC20Faucet public daiAsset;
    ERC20Faucet public wethAsset;

    ERC7575VaultUpgradeable public usdcVault;
    ERC7575VaultUpgradeable public daiVault;
    ERC7575VaultUpgradeable public wethVault;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy shared ShareToken
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Multi-Asset Shares", "MAS", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy assets
        usdcAsset = new ERC20Faucet("TestUSDC", "USDC", 1000000 * 1e18);
        vm.warp(block.timestamp + 1 hours + 1);
        daiAsset = new ERC20Faucet("TestDAI", "DAI", 1000000 * 1e18);
        vm.warp(block.timestamp + 1 hours + 1);
        wethAsset = new ERC20Faucet("TestWETH", "WETH", 1000000 * 1e18);

        // Deploy vaults
        usdcVault = _deployVault(IERC20(usdcAsset), "USDC Vault", "vUSDC");
        daiVault = _deployVault(IERC20(daiAsset), "DAI Vault", "vDAI");
        wethVault = _deployVault(IERC20(wethAsset), "WETH Vault", "vWETH");

        // Configure all vaults

        shareToken.registerVault(address(usdcAsset), address(usdcVault));
        shareToken.registerVault(address(daiAsset), address(daiVault));
        shareToken.registerVault(address(wethAsset), address(wethVault));

        vm.stopPrank();

        // Give users assets
        usdcAsset.faucetAmountFor(alice, 100000e18);
        vm.warp(block.timestamp + 1 hours + 1);
        daiAsset.faucetAmountFor(alice, 100000e18);
        vm.warp(block.timestamp + 1 hours + 1);
        wethAsset.faucetAmountFor(alice, 100000e18);
    }

    function _deployVault(IERC20 asset, string memory name, string memory symbol) internal returns (ERC7575VaultUpgradeable) {
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory initData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        return ERC7575VaultUpgradeable(address(vaultProxy));
    }

    /// @dev Test that all vaults use the same share token
    function test_MultiAsset_SharedShareToken() public view {
        assertEq(usdcVault.share(), address(shareToken));
        assertEq(daiVault.share(), address(shareToken));
        assertEq(wethVault.share(), address(shareToken));
    }

    /// @dev Test vault lookup functionality
    function test_MultiAsset_VaultLookup() public view {
        assertEq(shareToken.vault(address(usdcAsset)), address(usdcVault));
        assertEq(shareToken.vault(address(daiAsset)), address(daiVault));
        assertEq(shareToken.vault(address(wethAsset)), address(wethVault));
    }

    /// @dev Test cross-asset deposits result in shared shares
    function test_MultiAsset_CrossAssetDeposits() public {
        uint256 depositAmount = 10000e18;

        // Deposit to USDC vault
        vm.startPrank(alice);
        usdcAsset.approve(address(usdcVault), depositAmount);
        usdcVault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        usdcVault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        usdcVault.deposit(depositAmount, alice);

        uint256 sharesAfterUsdc = shareToken.balanceOf(alice);
        assertTrue(sharesAfterUsdc > 0);

        // Deposit to DAI vault
        vm.startPrank(alice);
        daiAsset.approve(address(daiVault), depositAmount);
        daiVault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        daiVault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        daiVault.deposit(depositAmount, alice);

        uint256 sharesAfterDai = shareToken.balanceOf(alice);

        // Alice should have more shares after depositing to both vaults
        assertTrue(sharesAfterDai > sharesAfterUsdc);
    }

    /// @dev Test share transferability across vaults
    function test_MultiAsset_ShareTransferability() public {
        uint256 depositAmount = 10000e18;

        // Alice deposits to USDC vault
        vm.startPrank(alice);
        usdcAsset.approve(address(usdcVault), depositAmount);
        usdcVault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(owner);
        usdcVault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        usdcVault.deposit(depositAmount, alice);

        uint256 aliceShares = shareToken.balanceOf(alice);
        assertTrue(aliceShares > 0);

        // Alice transfers shares to Bob
        vm.prank(alice);
        require(shareToken.transfer(bob, aliceShares / 2), "Transfer failed");

        // Bob should be able to use shares in any vault
        uint256 bobShares = shareToken.balanceOf(bob);
        assertTrue(bobShares > 0);

        // Bob can redeem shares (but needs to go through the vault that has the assets)
        vm.startPrank(bob);
        shareToken.approve(address(usdcVault), bobShares);
        usdcVault.requestRedeem(bobShares, bob, bob);
        vm.stopPrank();

        // Fulfill the redeem
        vm.prank(owner);
        usdcVault.fulfillRedeem(bob, bobShares);

        assertTrue(usdcVault.claimableRedeemRequest(0, bob) > 0);
    }

    /// @dev Test VaultUpdate events via unregister and register
    function test_MultiAsset_VaultUpdate() public {
        // Deploy a real new vault for the same asset
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, usdcAsset, address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        address newVault = address(vaultProxy);

        // First deactivate the existing vault, then unregister
        vm.prank(owner);
        usdcVault.setVaultActive(false);

        vm.prank(owner);
        vm.expectEmit();
        emit IERC7575Share.VaultUpdate(address(usdcAsset), address(0));
        shareToken.unregisterVault(address(usdcAsset));

        // Then register the new vault
        vm.prank(owner);
        vm.expectEmit();
        emit IERC7575Share.VaultUpdate(address(usdcAsset), newVault);
        shareToken.registerVault(address(usdcAsset), newVault);

        assertEq(shareToken.vault(address(usdcAsset)), newVault);
    }

    /// @dev Test interface compliance
    function test_MultiAsset_InterfaceCompliance() public view {
        // All vaults should support ERC7575
        assertTrue(usdcVault.supportsInterface(type(IERC7575).interfaceId));
        assertTrue(daiVault.supportsInterface(type(IERC7575).interfaceId));
        assertTrue(wethVault.supportsInterface(type(IERC7575).interfaceId));

        // ShareToken should support IERC7575ShareExtended
        assertTrue(shareToken.supportsInterface(type(IERC7575ShareExtended).interfaceId));
    }

    /// @dev Test authorization controls
    function test_MultiAsset_ShareTokenAuthorization() public {
        // Only registered vaults can mint/burn
        assertTrue(shareToken.isVault(address(usdcVault)));
        assertTrue(shareToken.isVault(address(daiVault)));
        assertTrue(shareToken.isVault(address(wethVault)));

        // Unauthorized address cannot mint
        vm.prank(alice);
        vm.expectRevert();
        shareToken.mint(alice, 1000e18);

        // Owner can revoke authorization by unregistering vault (requires no outstanding shares)
        // First deactivate the vault, then unregister
        vm.prank(owner);
        usdcVault.setVaultActive(false);

        vm.prank(owner);
        shareToken.unregisterVault(address(usdcAsset));

        assertFalse(shareToken.isVault(address(usdcVault)));
    }

    /// @dev Test registry consistency
    function test_MultiAsset_RegistryConsistency() public {
        // Each asset should map to exactly one vault
        assertEq(shareToken.vault(address(usdcAsset)), address(usdcVault));
        assertEq(shareToken.vault(address(daiAsset)), address(daiVault));
        assertEq(shareToken.vault(address(wethAsset)), address(wethVault));

        // Unknown asset should return zero address
        ERC20Faucet unknownAsset = new ERC20Faucet("UnknownToken", "UNK", 1000000 * 1e18);
        assertEq(shareToken.vault(address(unknownAsset)), address(0));
    }

    /// @dev Test preview functions revert (async flow requirement)
    function test_MultiAsset_PreviewFunctionsRevert() public {
        vm.expectRevert();
        usdcVault.previewDeposit(1000e18);

        vm.expectRevert();
        daiVault.previewMint(1000e18);

        vm.expectRevert();
        wethVault.previewWithdraw(1000e18);

        vm.expectRevert();
        usdcVault.previewRedeem(1000e18);
    }
}
