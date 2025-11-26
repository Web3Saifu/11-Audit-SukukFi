// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC7575VaultUpgradeable.sol";
import "../src/WERC7575ShareToken.sol";
import "./MockAsset.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title EdgeCases_MinimumDepositBoundary
 * @notice Tests for minimum deposit amount boundary conditions
 * Critical for validating deposit request validation logic
 */
contract EdgeCasesMinimumDepositBoundary is Test {
    WERC7575ShareToken public shareToken;
    ERC7575VaultUpgradeable public vault;
    MockAsset public asset;

    address owner = address(1);
    address investmentManager = address(2);
    address alice = address(3);
    address bob = address(4);

    // The vault stores minimumDepositAmount as 1000 (uint16)
    // Actual minimum in assets = 1000 * 10^assetDecimals
    // For 18 decimals: 1000 * 10^18 = 1e21
    uint256 minimumDepositAmount = 1000e18; // 1000 tokens in human-readable terms

    function setUp() public {
        vm.startPrank(owner);
        asset = new MockAsset();
        // Need large amounts since minimum is 1000 * 10^18
        asset.mint(alice, 500000e18); // 500,000 tokens
        asset.mint(bob, 500000e18);

        shareToken = new WERC7575ShareToken("Share Token", "SHARE");

        // Deploy upgradeable vault using proxy pattern
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(address(asset)), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        shareToken.setValidator(owner);
        shareToken.setKycAdmin(owner);
        shareToken.registerVault(address(asset), address(vault));

        vault.setInvestmentManager(investmentManager);

        vm.stopPrank();

        // Setup KYC
        vm.prank(owner);
        shareToken.setKycVerified(alice, true);
        vm.prank(owner);
        shareToken.setKycVerified(bob, true);

        // Approve vault
        vm.prank(alice);
        asset.approve(address(vault), 500000e18);
        vm.prank(bob);
        asset.approve(address(vault), 500000e18);
    }

    // ========== TEST 1: Below Minimum - Should Revert ==========
    /**
     * @notice Test that deposit below minimumDepositAmount reverts
     * minimumDepositAmount = 1000e18
     * Test amount = 999e18
     */
    function testMinimumDepositBoundary_BelowMinimum() public {
        uint256 belowMinimum = minimumDepositAmount - 1e18;

        vm.prank(alice);
        vm.expectRevert(); // Should revert with validation error
        vault.requestDeposit(belowMinimum, alice, alice);

        // Verify no state changed (requestId is always 0)
        assertEq(vault.pendingDepositRequest(0, alice), 0, "No pending deposit should be created");
    }

    // ========== TEST 2: Exactly At Minimum - Should Succeed ==========
    /**
     * @notice Test that deposit at exactly minimumDepositAmount succeeds
     */
    function testMinimumDepositBoundary_AtMinimum() public {
        uint256 atMinimum = minimumDepositAmount;

        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(atMinimum, alice, alice);

        // Verify request was created (requestId is always 0 in this implementation)
        assertEq(requestId, 0, "Request ID should be 0");
        assertEq(vault.pendingDepositRequest(0, alice), atMinimum, "Pending assets should be recorded");
    }

    // ========== TEST 3: Just Above Minimum - Should Succeed ==========
    /**
     * @notice Test that deposit just above minimumDepositAmount succeeds
     */
    function testMinimumDepositBoundary_AboveMinimum() public {
        uint256 aboveMinimum = minimumDepositAmount + 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(aboveMinimum, alice, alice);

        // Verify request was created (requestId is always 0)
        assertEq(requestId, 0, "Request ID should be 0");
        assertEq(vault.pendingDepositRequest(0, alice), aboveMinimum, "Pending assets should be recorded");
    }

    // ========== TEST 4: Much Above Minimum - Should Succeed ==========
    /**
     * @notice Test large deposit succeeds
     */
    function testMinimumDepositBoundary_MuchAboveMinimum() public {
        uint256 largeDeposit = minimumDepositAmount * 10;

        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(largeDeposit, alice, alice);

        assertEq(requestId, 0, "Request ID should be 0");
        assertEq(vault.pendingDepositRequest(0, alice), largeDeposit, "Pending assets should be recorded");
    }

    // ========== TEST 5: Zero Deposit - Should Revert ==========
    /**
     * @notice Test that zero deposit reverts
     */
    function testMinimumDepositBoundary_ZeroDeposit() public {
        vm.prank(alice);
        vm.expectRevert(); // Should revert with validation error
        vault.requestDeposit(0, alice, alice);
    }

    // ========== TEST 6: Stress Test - Very Large Deposit ==========
    /**
     * @notice Test deposit with very large amount (boundary on upper end)
     */
    function testMinimumDepositBoundary_VeryLargeDeposit() public {
        // Test with a deposit that's 100x the minimum
        uint256 veryLargeDeposit = minimumDepositAmount * 100;

        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(veryLargeDeposit, alice, alice);

        assertEq(requestId, 0, "Request ID should be 0");
        assertEq(vault.pendingDepositRequest(0, alice), veryLargeDeposit, "Very large deposit should be recorded");
    }

    // ========== TEST 7: Multiple Requests - Each Must Meet Minimum ==========
    /**
     * @notice Test that each deposit request must separately meet minimum
     */
    function testMinimumDepositBoundary_MultipleRequests() public {
        uint256 halfMinimum = minimumDepositAmount / 2;

        // First request: half minimum (should revert)
        vm.prank(alice);
        vm.expectRevert();
        vault.requestDeposit(halfMinimum, alice, alice);

        // Second request: exactly minimum (should succeed)
        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(minimumDepositAmount, alice, alice);
        assertEq(requestId, 0, "Second request ID should be 0");

        // Third request: below minimum (should revert even though alice has pending)
        vm.prank(alice);
        vm.expectRevert();
        vault.requestDeposit(halfMinimum, alice, alice);

        // Fourth request: above minimum (should succeed)
        vm.prank(alice);
        uint256 requestId2 = vault.requestDeposit(minimumDepositAmount + 100e18, alice, alice);
        assertEq(requestId2, 0, "Fourth request ID should be 0");
    }

    // ========== TEST 8: Multiple Requests from Different Users ==========
    /**
     * @notice Test that multiple users can make separate deposit requests
     */
    function testMinimumDepositBoundary_DifferentControllerOwner() public {
        // alice makes a deposit request
        vm.prank(alice);
        uint256 requestId1 = vault.requestDeposit(minimumDepositAmount, alice, alice);
        assertEq(requestId1, 0, "Alice's request ID should be 0");

        // bob makes a separate deposit request
        vm.prank(bob);
        uint256 requestId2 = vault.requestDeposit(minimumDepositAmount, bob, bob);
        assertEq(requestId2, 0, "Bob's request ID should be 0");

        // Both should have their own pending deposits
        assertEq(vault.pendingDepositRequest(0, alice), minimumDepositAmount, "Alice's pending assets tracked");
        assertEq(vault.pendingDepositRequest(0, bob), minimumDepositAmount, "Bob's pending assets tracked");
    }

    // ========== TEST 9: Boundary - Maximum Safe Amount ==========
    /**
     * @notice Test deposit at maximum reasonable amount
     */
    function testMinimumDepositBoundary_MaximumAmount() public {
        uint256 maximumReasonable = 50000e18; // 50k tokens

        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(maximumReasonable, alice, alice);

        assertEq(requestId, 0, "Request ID should be 0");
        assertEq(vault.pendingDepositRequest(0, alice), maximumReasonable, "Maximum amount recorded");
    }

    // ========== TEST 10: Boundary - One Wei Below Minimum ==========
    /**
     * @notice Test that even 1 wei below minimum is rejected
     */
    function testMinimumDepositBoundary_OneWeiBelowMinimum() public {
        uint256 oneWeiBelowMinimum = minimumDepositAmount - 1;

        vm.prank(alice);
        vm.expectRevert();
        vault.requestDeposit(oneWeiBelowMinimum, alice, alice);
    }

    // ========== TEST 11: Boundary - One Wei Above Minimum ==========
    /**
     * @notice Test that 1 wei above minimum is accepted
     */
    function testMinimumDepositBoundary_OneWeiAboveMinimum() public {
        uint256 oneWeiAboveMinimum = minimumDepositAmount + 1;

        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(oneWeiAboveMinimum, alice, alice);

        assertEq(requestId, 0, "One wei above minimum should succeed with requestId 0");
    }
}
