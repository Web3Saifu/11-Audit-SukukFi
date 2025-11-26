// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/WERC7575ShareToken.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title EdgeCases_ComputeRBalanceFlags
 * @notice Comprehensive edge case testing for computeRBalanceFlags function
 * Tests boundary conditions, consolidation scenarios, and consistency enforcement
 */
contract EdgeCasesComputeRBalanceFlags is Test {
    WERC7575ShareToken public shareToken;

    function setUp() public {
        shareToken = new WERC7575ShareToken("Test Token", "TEST");
    }

    // ========== TEST 1: All Self-Transfers ==========
    /**
     * @notice When all transfers are self-transfers (debtor == creditor),
     * they should all be skipped in account aggregation.
     * Result: empty accounts array, flags == 0
     */
    function testAllSelfTransfers() public {
        address[] memory debtors = new address[](5);
        address[] memory creditors = new address[](5);
        bool[] memory debtorsFlags = new bool[](5);
        bool[] memory creditorsFlags = new bool[](5);

        // All self-transfers
        for (uint256 i = 0; i < 5; i++) {
            debtors[i] = address(uint160(1 + i));
            creditors[i] = address(uint160(1 + i)); // Same as debtor
            debtorsFlags[i] = true;
            creditorsFlags[i] = true;
        }

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // With all self-transfers skipped, should get flags == 0
        assertEq(flags, 0, "Self-transfers should result in flags == 0");
    }

    // ========== TEST 2: Maximum Batch Size (100) ==========
    /**
     * @notice Test with exactly MAX_BATCH_SIZE (100) transfers.
     * Worst case: 100 unique (debtor, creditor) pairs = 200 unique accounts
     * Verify function handles maximum size correctly
     */
    function testMaxBatchSize100() public {
        uint256 batchSize = 100;
        address[] memory debtors = new address[](batchSize);
        address[] memory creditors = new address[](batchSize);
        bool[] memory debtorsFlags = new bool[](batchSize);
        bool[] memory creditorsFlags = new bool[](batchSize);

        // Create 100 unique transfers: address(1)→address(101), address(2)→address(102), etc.
        for (uint256 i = 0; i < batchSize; i++) {
            debtors[i] = address(uint160(1 + i));
            creditors[i] = address(uint160(101 + i));
            debtorsFlags[i] = (i % 2 == 0); // Alternate which are flagged
            creditorsFlags[i] = (i % 3 == 0); // Different pattern for creditors
        }

        // Should complete without revert
        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // Verify some flags were set (at least for first debtor if flagged)
        if (debtorsFlags[0]) {
            uint256 expectedBit = (1 << 0);
            assertTrue((flags & expectedBit) != 0, "First debtor flag should be set");
        }
    }

    // ========== TEST 3: Complete Deduplication ==========
    /**
     * @notice When all 100 transfers use the same (debtor, creditor) pair,
     * consolidation results in just 2 unique accounts.
     * Flags should be applied to account positions 0 and 1 only.
     */
    function testCompleteDeduplication() public {
        address alice = address(1);
        address bob = address(2);
        uint256 batchSize = 100;

        address[] memory debtors = new address[](batchSize);
        address[] memory creditors = new address[](batchSize);
        bool[] memory debtorsFlags = new bool[](batchSize);
        bool[] memory creditorsFlags = new bool[](batchSize);

        // All transfers: alice -> bob
        for (uint256 i = 0; i < batchSize; i++) {
            debtors[i] = alice;
            creditors[i] = bob;
            debtorsFlags[i] = true; // Alice always flagged
            creditorsFlags[i] = false; // Bob never flagged
        }

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // Expected: alice at position 0 (flagged), bob at position 1 (not flagged)
        uint256 expectedFlags = (1 << 0); // Only bit 0 set
        assertEq(flags, expectedFlags, "Complete dedup: only alice flag should be set");
    }

    // ========== TEST 4: No Deduplication ==========
    /**
     * @notice When all transfers use unique (debtor, creditor) pairs,
     * consolidation creates 200 accounts (100 debtors + 100 creditors).
     * Flags should map to the correct account positions.
     */
    function testNoDeduplication() public {
        uint256 batchSize = 50; // Use 50 to avoid hitting limits
        address[] memory debtors = new address[](batchSize);
        address[] memory creditors = new address[](batchSize);
        bool[] memory debtorsFlags = new bool[](batchSize);
        bool[] memory creditorsFlags = new bool[](batchSize);

        // Each transfer uses unique addresses: i -> (100 + i)
        for (uint256 i = 0; i < batchSize; i++) {
            debtors[i] = address(uint160(1 + i));
            creditors[i] = address(uint160(101 + i));
            debtorsFlags[i] = (i == 0 || i == 24); // Flag first and middle debtors
            creditorsFlags[i] = (i == 5 || i == 49); // Flag some creditors
        }

        // Should complete without revert and produce expected flags
        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // Verify some flags are set
        assertTrue(flags != 0, "No-dedup case should have some flags set");

        // First debtor (address 1) should be flagged at position 0
        assertTrue((flags & 1) != 0, "First debtor should be flagged at position 0");
    }

    // ========== TEST 5: Flag Consistency - Debtor Appears Multiple Times ==========
    /**
     * @notice When a debtor appears in multiple transfers,
     * the flag must be consistent across all appearances.
     * If flagged in transfer 0, must be flagged in transfer N.
     * If not flagged in transfer 0, must not be flagged in transfer N.
     */
    function testFlagConsistencyMultipleDebtor() public {
        address alice = address(1);
        address bob = address(2);
        address carol = address(3);

        address[] memory debtors = new address[](3);
        address[] memory creditors = new address[](3);
        bool[] memory debtorsFlags = new bool[](3);
        bool[] memory creditorsFlags = new bool[](3);

        // Transfer 0: alice -> bob (alice flagged)
        debtors[0] = alice;
        creditors[0] = bob;
        debtorsFlags[0] = true;
        creditorsFlags[0] = false;

        // Transfer 1: alice -> carol (alice NOT flagged - INCONSISTENT!)
        debtors[1] = alice;
        creditors[1] = carol;
        debtorsFlags[1] = false; // Inconsistent with first discovery
        creditorsFlags[1] = false;

        // Transfer 2: bob -> carol (new accounts)
        debtors[2] = bob;
        creditors[2] = carol;
        debtorsFlags[2] = false;
        creditorsFlags[2] = false;

        // Should revert with InconsistentRAccounts
        vm.expectRevert();
        shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);
    }

    // ========== TEST 6: Flag Consistency - Creditor Appears Multiple Times ==========
    /**
     * @notice Similar to TEST 5 but for creditor role.
     * Creditor must have consistent flags across multiple appearances.
     */
    function testFlagConsistencyMultipleCreditor() public {
        address alice = address(1);
        address bob = address(2);
        address carol = address(3);

        address[] memory debtors = new address[](3);
        address[] memory creditors = new address[](3);
        bool[] memory debtorsFlags = new bool[](3);
        bool[] memory creditorsFlags = new bool[](3);

        // Transfer 0: alice -> bob (bob flagged as creditor)
        debtors[0] = alice;
        creditors[0] = bob;
        debtorsFlags[0] = false;
        creditorsFlags[0] = true;

        // Transfer 1: carol -> bob (bob appears again as creditor - must be flagged)
        debtors[1] = carol;
        creditors[1] = bob;
        debtorsFlags[1] = false;
        creditorsFlags[1] = false; // INCONSISTENT - bob not flagged here!

        // Transfer 2: alice -> carol
        debtors[2] = alice;
        creditors[2] = carol;
        debtorsFlags[2] = false;
        creditorsFlags[2] = false;

        // Should revert with InconsistentRAccounts
        vm.expectRevert();
        shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);
    }

    // ========== TEST 7: Flag Consistency - Same Address, Different Roles ==========
    /**
     * @notice When same address appears as debtor in one transfer and creditor in another,
     * flag must be consistent across both roles.
     * If marked for rBalance in debtor role, must be marked in creditor role too.
     */
    function testFlagConsistencyMixedRoles() public {
        address alice = address(1);
        address bob = address(2);

        address[] memory debtors = new address[](2);
        address[] memory creditors = new address[](2);
        bool[] memory debtorsFlags = new bool[](2);
        bool[] memory creditorsFlags = new bool[](2);

        // Transfer 0: alice -> bob (alice is debtor, flagged)
        debtors[0] = alice;
        creditors[0] = bob;
        debtorsFlags[0] = true;
        creditorsFlags[0] = false;

        // Transfer 1: bob -> alice (alice is creditor, NOT flagged - INCONSISTENT!)
        debtors[1] = bob;
        creditors[1] = alice;
        debtorsFlags[1] = false;
        creditorsFlags[1] = false; // Alice not flagged as creditor, but was flagged as debtor

        // Should revert with InconsistentRAccounts
        vm.expectRevert();
        shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);
    }

    // ========== TEST 8: Flag Consistency - Consistent Across Multiple Roles ==========
    /**
     * @notice When same address appears in multiple roles and multiple transfers,
     * flags must be consistently set or unset across all occurrences.
     */
    function testFlagConsistencyComplexScenario() public {
        address alice = address(1);
        address bob = address(2);
        address carol = address(3);

        address[] memory debtors = new address[](4);
        address[] memory creditors = new address[](4);
        bool[] memory debtorsFlags = new bool[](4);
        bool[] memory creditorsFlags = new bool[](4);

        // Transfer 0: alice -> bob (alice flagged as debtor)
        debtors[0] = alice;
        creditors[0] = bob;
        debtorsFlags[0] = true;
        creditorsFlags[0] = false;

        // Transfer 1: alice -> carol (alice flagged again as debtor - CONSISTENT)
        debtors[1] = alice;
        creditors[1] = carol;
        debtorsFlags[1] = true; // Consistent!
        creditorsFlags[1] = false;

        // Transfer 2: bob -> alice (alice is creditor, must be flagged)
        debtors[2] = bob;
        creditors[2] = alice;
        debtorsFlags[2] = false;
        creditorsFlags[2] = true; // Consistent with alice's flag

        // Transfer 3: carol -> alice (alice is creditor again)
        debtors[3] = carol;
        creditors[3] = alice;
        debtorsFlags[3] = false;
        creditorsFlags[3] = true; // Consistent!

        // Should succeed - all flags are consistent
        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // Verify alice got flagged at its account position (0)
        assertTrue((flags & 1) != 0, "Alice should be flagged at position 0");
    }

    // ========== TEST 9: Single Transfer ==========
    /**
     * @notice Minimum valid batch: 1 transfer.
     * Should create 2 accounts (debtor, creditor).
     */
    function testSingleTransfer() public {
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        bool[] memory debtorsFlags = new bool[](1);
        bool[] memory creditorsFlags = new bool[](1);

        debtors[0] = address(1);
        creditors[0] = address(2);
        debtorsFlags[0] = true;
        creditorsFlags[0] = true;

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // Both accounts should be flagged at positions 0 and 1
        uint256 expectedFlags = (1 << 0) | (1 << 1);
        assertEq(flags, expectedFlags, "Single transfer should flag both accounts");
    }

    // ========== TEST 10: Bidirectional Transfers ==========
    /**
     * @notice A -> B and B -> A (back and forth).
     * Both should be aggregated into same 2 accounts.
     * If A is flagged in first transfer, must be flagged in second.
     */
    function testBidirectionalTransfers() public {
        address alice = address(1);
        address bob = address(2);

        address[] memory debtors = new address[](2);
        address[] memory creditors = new address[](2);
        bool[] memory debtorsFlags = new bool[](2);
        bool[] memory creditorsFlags = new bool[](2);

        // Transfer 0: alice -> bob
        debtors[0] = alice;
        creditors[0] = bob;
        debtorsFlags[0] = true; // Mark alice
        creditorsFlags[0] = false; // Don't mark bob

        // Transfer 1: bob -> alice
        debtors[1] = bob;
        creditors[1] = alice;
        debtorsFlags[1] = false; // Don't mark bob (consistent - not marked before)
        creditorsFlags[1] = true; // Mark alice (consistent - marked as debtor before)

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // Alice (position 0) should be flagged, Bob (position 1) should not
        uint256 expectedFlags = (1 << 0);
        assertEq(flags, expectedFlags, "Bidirectional transfer: alice flagged, bob not");
    }

    // ========== TEST 11: Large Flag Position Mapping ==========
    /**
     * @notice Verify flag positions map correctly when accounts are
     * discovered in non-sequential order.
     * When A, B, C are debtors and later appear as creditors with new creditors (10-15),
     * the creditors (10-15) create new account entries.
     * Account positions: A(0), 10(1), B(2), 11(3), C(4), 12(5), 13(6), 14(7), 15(8)
     */
    function testLargeFlagPositionMapping() public {
        // Create scenario where accounts are debtors first, then appear with different creditors
        address[] memory debtors = new address[](6);
        address[] memory creditors = new address[](6);
        bool[] memory debtorsFlags = new bool[](6);
        bool[] memory creditorsFlags = new bool[](6);

        address a = address(1);
        address b = address(2);
        address c = address(3);

        // Transfer 0: A->10 (A flagged, 10 not flagged)
        debtors[0] = a;
        creditors[0] = address(10);
        debtorsFlags[0] = true;
        creditorsFlags[0] = false;

        // Transfer 1: B->11 (B flagged, 11 not flagged)
        debtors[1] = b;
        creditors[1] = address(11);
        debtorsFlags[1] = true;
        creditorsFlags[1] = false;

        // Transfer 2: C->12 (C flagged, 12 not flagged)
        debtors[2] = c;
        creditors[2] = address(12);
        debtorsFlags[2] = true;
        creditorsFlags[2] = false;

        // Transfer 3: A->13 (A reappears - must be consistent, flagged)
        debtors[3] = a; // Reappear
        creditors[3] = address(13); // New creditor
        debtorsFlags[3] = true;
        creditorsFlags[3] = false;

        // Transfer 4: B->14 (B reappears - must be consistent, flagged)
        debtors[4] = b;
        creditors[4] = address(14);
        debtorsFlags[4] = true;
        creditorsFlags[4] = false;

        // Transfer 5: C->15 (C reappears - must be consistent, flagged)
        debtors[5] = c;
        creditors[5] = address(15);
        debtorsFlags[5] = true;
        creditorsFlags[5] = false;

        // All flags consistent - should succeed
        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // Accounts: A(0), 10(1), B(2), 11(3), C(4), 12(5), 13(6), 14(7), 15(8)
        // Flagged: A, B, C at positions 0, 2, 4
        uint256 expectedFlags = (1 << 0) | (1 << 2) | (1 << 4);
        assertEq(flags, expectedFlags, "Flag positions should map to first discovery");
    }

    // ========== TEST 12: Zero Flags Array ==========
    /**
     * @notice When all debtorsFlags and creditorsFlags are false,
     * should produce flags == 0 (no accounts marked).
     */
    function testAllZeroFlags() public {
        address[] memory debtors = new address[](5);
        address[] memory creditors = new address[](5);
        bool[] memory debtorsFlags = new bool[](5); // All false
        bool[] memory creditorsFlags = new bool[](5); // All false

        for (uint256 i = 0; i < 5; i++) {
            debtors[i] = address(uint160(1 + i));
            creditors[i] = address(uint160(10 + i));
        }

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        assertEq(flags, 0, "All zero flags should produce flags == 0");
    }

    // ========== TEST 13: All Flags Set ==========
    /**
     * @notice When all flags are true.
     * All accounts should be flagged at their positions.
     */
    function testAllFlagsSet() public {
        address[] memory debtors = new address[](3);
        address[] memory creditors = new address[](3);
        bool[] memory debtorsFlags = new bool[](3);
        bool[] memory creditorsFlags = new bool[](3);

        for (uint256 i = 0; i < 3; i++) {
            debtors[i] = address(uint160(1 + i));
            creditors[i] = address(uint160(10 + i));
            debtorsFlags[i] = true;
            creditorsFlags[i] = true;
        }

        uint256 flags = shareToken.computeRBalanceFlags(debtors, creditors, debtorsFlags, creditorsFlags);

        // All 6 accounts (3 debtors + 3 creditors) should be flagged
        uint256 expectedFlags = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5);
        assertEq(flags, expectedFlags, "All flags set should flag all account positions");
    }
}
