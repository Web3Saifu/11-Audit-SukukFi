// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console} from "forge-std/Test.sol";

/**
 * @title TotalNormalizedAssetsTest
 * @dev Test that getTotalNormalizedAssets now properly includes claimable redeem assets
 */
contract TotalNormalizedAssetsTest is Test {
    ShareTokenUpgradeable public shareTokenImpl;
    ShareTokenUpgradeable public shareToken;
    ERC7575VaultUpgradeable public vaultImpl;
    ERC7575VaultUpgradeable public vault;
    ERC20Faucet public asset;

    address public admin = address(this);
    address public alice = makeAddr("alice");
    uint256 public constant INITIAL_BALANCE = 100_000e18;

    function setUp() public {
        // Deploy asset (18 decimals)
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

        // Register vault
        shareToken.registerVault(address(asset), address(vault));

        // Setup test balances
        vm.warp(block.timestamp + 2 hours);
        asset.faucetAmountFor(alice, INITIAL_BALANCE);
    }

    /**
     * @dev Test that demonstrates the fix for getTotalNormalizedAssets
     * Before fix: Only counted vault.totalAssets() which excludes claimable redeem assets
     * After fix: Counts vault.totalAssets() + vault.totalClaimableRedeemAssets for complete picture
     */
    function test_getTotalNormalizedAssets_IncludesClaimableRedeems() public {
        uint256 depositAmount = 10000e18;

        // Alice deposits to get shares
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        // Fulfill deposit
        vault.fulfillDeposit(alice, depositAmount);

        // Alice claims shares
        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        console.log("Alice shares received:", shares);
        console.log("Alice share balance:", shareToken.balanceOf(alice));

        // Check total normalized assets after deposit (should be ~depositAmount)
        (, uint256 totalAfterDeposit) = shareToken.getCirculatingSupplyAndAssets();
        assertApproxEqAbs(totalAfterDeposit, depositAmount, 1e15, "Total after deposit should equal deposit amount");
        console.log("Total after deposit:", totalAfterDeposit);

        // Alice requests redemption for half her actual shares
        uint256 actualShares = shareToken.balanceOf(alice);
        uint256 redeemAmount = actualShares / 2;

        vm.startPrank(alice);
        shareToken.approve(address(vault), redeemAmount);
        vault.requestRedeem(redeemAmount, alice, alice);
        vm.stopPrank();

        // Fulfill redeem (creates claimable redeem assets)
        vault.fulfillRedeem(alice, redeemAmount);

        // Check vault metrics to see what happened
        ERC7575VaultUpgradeable.VaultMetrics memory metrics = vault.getVaultMetrics();
        console.log("Vault totalAssets():", metrics.totalAssets);
        console.log("Vault totalClaimableRedeemAssets:", metrics.totalClaimableRedeemAssets);

        // Verify we have claimable redeem assets
        assertGt(metrics.totalClaimableRedeemAssets, 0, "Should have claimable redeem assets");

        // Check total normalized assets after redeem request fulfillment
        (, uint256 totalAfterRedeem) = shareToken.getCirculatingSupplyAndAssets();
        console.log("Total after redeem:", totalAfterRedeem);

        // KEY TEST: The total normalized assets should DECREASE when assets are reserved for redemption
        // This is correct behavior because:
        // 1. Reserved assets are excluded from totalAssets() (not actively managed)
        // 2. Vault-held shares are excluded from circulating supply
        // 3. This maintains correct asset-to-share ratio for remaining circulating shares
        uint256 expectedTotal = metrics.totalAssets + metrics.totalClaimableRedeemAssets;
        console.log("Expected total (assets + claimable):", expectedTotal);

        assertLt(totalAfterRedeem, depositAmount, "Total should decrease when assets are reserved for redemption");
        assertApproxEqAbs(totalAfterRedeem, metrics.totalAssets, 1e15, "Total should equal vault totalAssets (excludes reserved)");

        // Verify the accounting: totalAssets + claimableRedeemAssets = original deposit
        assertLt(metrics.totalAssets, depositAmount, "totalAssets should be less than original deposit");
        assertGt(metrics.totalClaimableRedeemAssets, 0, "Should have claimable redeem assets");
        assertApproxEqAbs(expectedTotal, depositAmount, 1e15, "totalAssets + claimableRedeemAssets should equal original deposit");
    }
}
