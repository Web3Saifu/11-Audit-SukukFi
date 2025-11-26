// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

contract MockERC20 is ERC20 {
    uint8 private _customDecimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title ComprehensiveHelperFunctionsTest
 * @dev Test suite for comprehensive vault helper functions for monitoring and management
 */
contract ComprehensiveHelperFunctionsTest is Test {
    ERC7575VaultUpgradeable vault;
    ShareTokenUpgradeable shareToken;
    MockERC20 asset;
    address owner = address(0x1);
    address alice = address(0x2);
    address bob = address(0x3);
    address charlie = address(0x4);

    function setUp() public {
        // Deploy asset token (6 decimals like USDC)
        asset = new MockERC20("USDC", "USDC", 6);

        // Set owner to this test contract
        owner = address(this);

        // Deploy ShareToken implementation and proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Vault Shares", "vSHARE", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault implementation and proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(address(asset)), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault in share token
        shareToken.registerVault(address(asset), address(vault));

        // Mint assets to users
        asset.mint(alice, 100000e6); // 100k USDC
        asset.mint(bob, 100000e6); // 100k USDC
        asset.mint(charlie, 100000e6); // 100k USDC

        // Approve vault for spending
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_VaultMetrics() public {
        // Initial state
        ERC7575VaultUpgradeable.VaultMetrics memory metrics = vault.getVaultMetrics();

        assertEq(metrics.totalPendingDepositAssets, 0, "No pending deposits initially");
        assertEq(metrics.totalClaimableRedeemAssets, 0, "No claimable redeems initially");
        assertEq(metrics.scalingFactor, 1e12, "Scaling factor should be 1e12 for 6-decimal asset");
        assertEq(metrics.totalAssets, 0, "No assets initially");
        assertEq(metrics.activeDepositRequestersCount, 0, "No active deposit requesters");
        assertEq(metrics.activeRedeemRequestersCount, 0, "No active redeem requesters");
        assertTrue(metrics.isActive, "Vault should be active");
        assertEq(metrics.asset, address(asset), "Asset address should match");
        assertEq(metrics.shareToken, address(shareToken), "Share token address should match");
        assertEq(metrics.investmentManager, owner, "Investment manager should be owner");
        assertEq(metrics.investmentVault, address(0), "No investment vault initially");

        // Create some requests
        vm.prank(alice);
        vault.requestDeposit(1000e6, alice, alice); // 1000 USDC

        vm.prank(bob);
        vault.requestDeposit(2000e6, bob, bob); // 2000 USDC

        // Check updated metrics
        metrics = vault.getVaultMetrics();
        assertEq(metrics.totalPendingDepositAssets, 3000e6, "Should have 3000 USDC pending");
        assertEq(metrics.activeDepositRequestersCount, 2, "Should have 2 active deposit requesters");
    }

    function test_ControllerStatus_SingleUser() public {
        // Get initial status
        ERC7575VaultUpgradeable.ControllerStatus memory status = vault.getControllerStatus(alice);

        assertEq(status.controller, alice, "Controller should be Alice");
        assertEq(status.pendingDepositAssets, 0, "No pending deposits");
        assertEq(status.claimableDepositShares, 0, "No claimable deposit shares");
        assertEq(status.pendingRedeemShares, 0, "No pending redeems");
        assertEq(status.claimableRedeemAssets, 0, "No claimable redeem assets");
        assertEq(status.claimableRedeemShares, 0, "No claimable redeem shares");

        // Alice requests deposit
        vm.prank(alice);
        vault.requestDeposit(1000e6, alice, alice);

        status = vault.getControllerStatus(alice);
        assertEq(status.pendingDepositAssets, 1000e6, "Should have 1000 USDC pending");
        assertEq(status.claimableDepositShares, 0, "No claimable shares yet");

        // Fulfill deposit
        vm.prank(owner);
        uint256 shares = vault.fulfillDeposit(alice, 1000e6);

        status = vault.getControllerStatus(alice);
        assertEq(status.pendingDepositAssets, 0, "No more pending deposits");
        assertEq(status.claimableDepositShares, shares, "Should have claimable shares");

        // Claim shares
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        status = vault.getControllerStatus(alice);
        assertEq(status.claimableDepositShares, 0, "No more claimable shares");

        // Request redemption
        vm.prank(alice);
        vault.requestRedeem(shares / 2, alice, alice);

        status = vault.getControllerStatus(alice);
        assertEq(status.pendingRedeemShares, shares / 2, "Should have pending redeem shares");
        assertEq(status.claimableRedeemAssets, 0, "No claimable redeem assets yet");

        // Fulfill redemption
        vm.prank(owner);
        uint256 redeemAssets = vault.fulfillRedeem(alice, shares / 2);

        status = vault.getControllerStatus(alice);
        assertEq(status.pendingRedeemShares, 0, "No more pending redeems");
        assertEq(status.claimableRedeemAssets, redeemAssets, "Should have claimable redeem assets");
        assertEq(status.claimableRedeemShares, shares / 2, "Should have claimable redeem shares");
    }

    function test_ControllerStatusBatch() public {
        // Create requests from multiple users
        vm.prank(alice);
        vault.requestDeposit(1000e6, alice, alice);

        vm.prank(bob);
        vault.requestDeposit(2000e6, bob, bob);

        vm.prank(charlie);
        vault.requestDeposit(3000e6, charlie, charlie);

        // Get batch status
        address[] memory controllers = new address[](3);
        controllers[0] = alice;
        controllers[1] = bob;
        controllers[2] = charlie;

        ERC7575VaultUpgradeable.ControllerStatus[] memory statuses = vault.getControllerStatusBatch(controllers);

        assertEq(statuses.length, 3, "Should return 3 statuses");

        assertEq(statuses[0].controller, alice, "First should be Alice");
        assertEq(statuses[0].pendingDepositAssets, 1000e6, "Alice should have 1000 USDC pending");

        assertEq(statuses[1].controller, bob, "Second should be Bob");
        assertEq(statuses[1].pendingDepositAssets, 2000e6, "Bob should have 2000 USDC pending");

        assertEq(statuses[2].controller, charlie, "Third should be Charlie");
        assertEq(statuses[2].pendingDepositAssets, 3000e6, "Charlie should have 3000 USDC pending");
    }

    function test_PaginatedDepositRequesters() public {
        // Create multiple deposit requests
        vm.prank(alice);
        vault.requestDeposit(1000e6, alice, alice);

        vm.prank(bob);
        vault.requestDeposit(2000e6, bob, bob);

        vm.prank(charlie);
        vault.requestDeposit(3000e6, charlie, charlie);

        // Test pagination
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses, uint256 total, bool hasMore) = vault.getDepositControllerStatusBatchPaginated(0, 2);

        assertEq(statuses.length, 2, "Should return 2 requesters");
        assertEq(total, 3, "Total should be 3");
        assertTrue(hasMore, "Should have more");

        // Get second page
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses2, uint256 total2, bool hasMore2) = vault.getDepositControllerStatusBatchPaginated(2, 2);

        assertEq(statuses2.length, 1, "Should return 1 requester on second page");
        assertEq(total2, 3, "Total should still be 3");
        assertFalse(hasMore2, "Should not have more");
    }

    function test_PaginatedControllerStatus() public {
        // Create requests
        vm.prank(alice);
        vault.requestDeposit(1000e6, alice, alice);

        vm.prank(bob);
        vault.requestDeposit(2000e6, bob, bob);

        // Test paginated controller status for deposit requesters
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses, uint256 total, bool hasMore) = vault.getDepositControllerStatusBatchPaginated(0, 10);

        assertEq(statuses.length, 2, "Should return 2 statuses");
        assertEq(total, 2, "Total should be 2");
        assertFalse(hasMore, "Should not have more");

        assertTrue(
            (statuses[0].controller == alice && statuses[0].pendingDepositAssets == 1000e6) || (statuses[0].controller == bob && statuses[0].pendingDepositAssets == 2000e6),
            "Should have correct pending amounts"
        );
    }

    function test_ActiveRequestersCount() public {
        // Initially no requesters
        (uint256 depositCount, uint256 redeemCount) = vault.getActiveRequestersCount();
        assertEq(depositCount, 0, "No deposit requesters initially");
        assertEq(redeemCount, 0, "No redeem requesters initially");

        // Create deposit requests
        vm.prank(alice);
        vault.requestDeposit(1000e6, alice, alice);

        vm.prank(bob);
        vault.requestDeposit(2000e6, bob, bob);

        (depositCount, redeemCount) = vault.getActiveRequestersCount();
        assertEq(depositCount, 2, "Should have 2 deposit requesters");
        assertEq(redeemCount, 0, "Still no redeem requesters");

        // Fulfill and claim deposits, then create redeem requests
        vm.startPrank(owner);
        uint256 aliceShares = vault.fulfillDeposit(alice, 1000e6);
        uint256 bobShares = vault.fulfillDeposit(bob, 2000e6);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(bob);
        vault.deposit(2000e6, bob);

        (depositCount, redeemCount) = vault.getActiveRequestersCount();
        assertEq(depositCount, 0, "No more deposit requesters after claiming");
        assertEq(redeemCount, 0, "Still no redeem requesters");

        // Create redeem requests
        vm.prank(alice);
        vault.requestRedeem(aliceShares / 2, alice, alice);

        vm.prank(bob);
        vault.requestRedeem(bobShares / 2, bob, bob);

        (depositCount, redeemCount) = vault.getActiveRequestersCount();
        assertEq(depositCount, 0, "Still no deposit requesters");
        assertEq(redeemCount, 2, "Should have 2 redeem requesters");
    }

    function test_ComprehensiveWorkflow() public {
        // Create deposits
        vm.prank(alice);
        vault.requestDeposit(1000e6, alice, alice);
        vm.prank(bob);
        vault.requestDeposit(2000e6, bob, bob);

        // Check metrics
        ERC7575VaultUpgradeable.VaultMetrics memory metrics = vault.getVaultMetrics();
        assertEq(metrics.totalPendingDepositAssets, 3000e6, "Should have 3000 USDC pending");
        assertEq(metrics.activeDepositRequestersCount, 2, "Should have 2 active deposit requesters");

        // Fulfill deposits
        vm.startPrank(owner);
        uint256 aliceShares = vault.fulfillDeposit(alice, 1000e6);
        uint256 bobShares = vault.fulfillDeposit(bob, 2000e6);
        vm.stopPrank();

        // Check controller statuses
        ERC7575VaultUpgradeable.ControllerStatus memory aliceStatus = vault.getControllerStatus(alice);
        assertEq(aliceStatus.claimableDepositShares, aliceShares, "Alice should have claimable shares");

        // Claim shares
        vm.prank(alice);
        vault.deposit(1000e6, alice);
        vm.prank(bob);
        vault.deposit(2000e6, bob);

        // Request redemptions
        vm.prank(alice);
        vault.requestRedeem(aliceShares / 2, alice, alice);
        vm.prank(bob);
        vault.requestRedeem(bobShares / 2, bob, bob);

        // Check final metrics
        metrics = vault.getVaultMetrics();
        assertEq(metrics.activeDepositRequestersCount, 0, "No more deposit requesters");
        assertEq(metrics.activeRedeemRequestersCount, 2, "Should have 2 redeem requesters");

        // Test paginated redeem requesters
        (ERC7575VaultUpgradeable.ControllerStatus[] memory redeemStatuses,,) = vault.getRedeemControllerStatusBatchPaginated(0, 10);

        assertEq(redeemStatuses.length, 2, "Should have 2 redeem requesters");
        assertTrue(redeemStatuses[0].pendingRedeemShares > 0 && redeemStatuses[1].pendingRedeemShares > 0, "Both should have pending redeem shares");
    }
}
