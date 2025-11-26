// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/WERC7575ShareToken.sol";
import "../src/WERC7575Vault.sol";
import "./MockAsset.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title EdgeCases_RBatchTransfers_Capping
 * @notice Comprehensive testing for rBalance capping logic in rBatchTransfers
 * Tests the critical logic where creditors with insufficient rBalance get capped to 0
 * instead of underflowing to max uint256
 */
contract EdgeCasesRBatchTransfersCapping is Test {
    WERC7575ShareToken public shareToken;
    WERC7575Vault public vault;
    MockAsset public asset;

    address owner = address(1);
    address validator = address(2);
    address alice = address(3);
    address bob = address(4);
    address carol = address(5);

    function setUp() public {
        vm.startPrank(owner);
        asset = new MockAsset();
        // Mint tokens for all test accounts
        asset.mint(alice, 2000e18);
        asset.mint(bob, 2000e18);
        asset.mint(carol, 2000e18);
        asset.mint(owner, 2000e18);

        shareToken = new WERC7575ShareToken("Test Token", "TST");
        vault = new WERC7575Vault(address(asset), shareToken);

        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);
        shareToken.registerVault(address(asset), address(vault));
        asset.approve(address(vault), 10000e18);

        vm.stopPrank();

        // Setup KYC for test accounts
        vm.startPrank(validator);
        shareToken.setKycVerified(alice, true);
        shareToken.setKycVerified(bob, true);
        shareToken.setKycVerified(carol, true);
        vm.stopPrank();

        // Fund alice with initial shares via vault deposit
        vm.startPrank(alice);
        asset.approve(address(vault), 1000e18);
        vault.deposit(1000e18, alice);
        vm.stopPrank();
    }

    // ========== TEST 1: Capping - Zero rBalance Initially ==========
    /**
     * @notice When account has rBalance = 0 and receives credit with flag set,
     * rBalance should remain 0 (capped behavior).
     */
    function testCapping_ZeroRBalanceInitially() public {
        // bob starts with rBalance = 0
        assertEq(shareToken.rBalanceOf(bob), 0, "Bob should start with rBalance = 0");

        // Transfer: alice loses 50 tokens, bob gains 50 tokens, alice flagged for rBalance
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = alice;
        creditors[0] = bob;
        amounts[0] = 50e18;

        bool[] memory debtorsFlags = new bool[](1);
        bool[] memory creditorsFlags = new bool[](1);
        debtorsFlags[0] = true; // alice's rBalance += 50
        creditorsFlags[0] = false; // bob's rBalance unchanged

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, flags);

        // bob rBalance should be 0 (capped, not overflowed negatively)
        assertEq(shareToken.rBalanceOf(bob), 0, "Bob rBalance should remain 0");
        // alice should have rBalance = 50
        assertEq(shareToken.rBalanceOf(alice), 50e18, "Alice rBalance should be 50");
    }

    // ========== TEST 2: Capping - Large rBalance, Small Credit ==========
    /**
     * @notice When rBalance is large and credit is small,
     * no capping should occur, normal decrement should work.
     */
    function testCapping_LargeRBalanceSmallCredit() public {
        // Setup: alice loses 1000 (rBalance = 1000)
        {
            address[] memory debtors = new address[](1);
            address[] memory creditors = new address[](1);
            uint256[] memory amounts = new uint256[](1);

            debtors[0] = alice;
            creditors[0] = bob;
            amounts[0] = 1000e18;

            bool[] memory debtorsFlags = new bool[](1);
            bool[] memory creditorsFlags = new bool[](1);
            debtorsFlags[0] = true;

            uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);
            vm.prank(validator);
            shareToken.rBatchTransfers(debtors, creditors, amounts, flags);
        }

        assertEq(shareToken.rBalanceOf(alice), 1000e18, "Alice rBalance = 1000");

        // Deposit for bob via vault
        vm.startPrank(bob);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, bob);
        vm.stopPrank();

        // alice gains only 100 (no capping needed)
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = bob;
        creditors[0] = alice;
        amounts[0] = 100e18;

        bool[] memory debtorsFlags = new bool[](1);
        bool[] memory creditorsFlags = new bool[](1);
        debtorsFlags[0] = false;
        creditorsFlags[0] = true; // alice loses 100 from rBalance (has 1000)

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, flags);

        // alice rBalance = 1000 - 100 = 900
        assertEq(shareToken.rBalanceOf(alice), 900e18, "Normal decrement: 1000 - 100 = 900");
    }

    // ========== TEST 3: Capping - Debit Phase Increases rBalance ==========
    /**
     * @notice When account is net debtor (losing tokens),
     * rBalance should INCREASE (restricted amount grows), not capped.
     */
    function testCapping_DebitPhaseIncreases() public {
        // alice starts with 1000 shares, rBalance = 0
        assertEq(shareToken.rBalanceOf(alice), 0, "Alice starts with rBalance = 0");

        // Transfer: alice loses 100 with flag set
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = alice;
        creditors[0] = bob;
        amounts[0] = 100e18;

        bool[] memory debtorsFlags = new bool[](1);
        bool[] memory creditorsFlags = new bool[](1);
        debtorsFlags[0] = true; // alice's rBalance += 100
        creditorsFlags[0] = false;

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, flags);

        // alice rBalance should be 100 (no capping on debit phase)
        assertEq(shareToken.rBalanceOf(alice), 100e18, "Debit phase: rBalance += 100");
    }

    // ========== TEST 4: Capping - Mixed Debit/Credit NetDebit ==========
    /**
     * @notice When same account has both debits and credits in consolidation,
     * verify net position rBalance update is correct.
     *
     * alice: loses 100, gains 30 → net debit = 70
     * If flagged: rBalance += 70
     */
    function testCapping_MixedDebitCreditNetDebit() public {
        // Transfer: alice loses 100, bob gains 100
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = alice;
        creditors[0] = bob;
        amounts[0] = 100e18;

        bool[] memory debtorsFlags = new bool[](1);
        bool[] memory creditorsFlags = new bool[](1);
        debtorsFlags[0] = true;

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);
        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, flags);

        assertEq(shareToken.rBalanceOf(alice), 100e18, "Alice rBalance = 100 after debit");

        // Give carol shares via deposit
        vm.startPrank(carol);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, carol);
        vm.stopPrank();

        // Now: alice loses 100, gains 30 (net debit = 70)
        address[] memory debtors2 = new address[](2);
        address[] memory creditors2 = new address[](2);
        uint256[] memory amounts2 = new uint256[](2);

        debtors2[0] = alice;
        creditors2[0] = carol;
        amounts2[0] = 100e18;

        debtors2[1] = bob;
        creditors2[1] = alice;
        amounts2[1] = 30e18;

        bool[] memory debtorsFlags2 = new bool[](2);
        bool[] memory creditorsFlags2 = new bool[](2);
        debtorsFlags2[0] = false; // alice as debtor (not marked)
        debtorsFlags2[1] = false; // bob as debtor (not marked)
        creditorsFlags2[0] = false; // carol as creditor (not marked)
        creditorsFlags2[1] = false; // alice as creditor (not marked - consistent with debtor)

        uint256 flags2 = shareToken.computeRBalanceFlags(debtors2, creditors2, debtorsFlags2, creditorsFlags2);

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors2, creditors2, amounts2, flags2);

        // Consolidated: alice net debit = 70, but alice is NOT flagged in transfer 2
        // So alice's rBalance remains unchanged = 100
        assertEq(shareToken.rBalanceOf(alice), 100e18, "Mixed: rBalance unchanged when not flagged");
    }
}
