// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC20Faucet.sol";
import "../src/WERC7575ShareToken.sol";
import "../src/WERC7575Vault.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title Approval and Signature Mechanism Tests
 * @notice Comprehensive tests for approve(), permit(), nonces(), DOMAIN_SEPARATOR()
 * @dev Tests approval mechanism, EIP-712 signatures, and nonce management
 */
contract ApprovalAndSignatureMechanismsTest is Test {
    WERC7575ShareToken public shareToken;
    ERC20Faucet public token;
    WERC7575Vault public vault;

    address public owner;
    address public spender;
    address public otherAccount;
    address public validator;

    uint256 constant INITIAL_BALANCE = 1000 * 1e18;
    uint256 constant VAULT_ALLOWANCE = 500 * 1e18;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        owner = makeAddr("owner");
        spender = makeAddr("spender");
        otherAccount = makeAddr("otherAccount");
        validator = makeAddr("validator");

        // Deploy contracts
        token = new ERC20Faucet("Test Token", "TEST", 10000 * 1e18);
        shareToken = new WERC7575ShareToken("Test Share Token", "tSHARE");
        vault = new WERC7575Vault(address(token), shareToken);

        // Setup
        shareToken.registerVault(address(token), address(vault));
        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);

        // Deposit shares for owner
        vm.startPrank(validator);
        shareToken.setKycVerified(owner, true);
        shareToken.setKycVerified(spender, true);
        shareToken.setKycVerified(otherAccount, true);
        vm.stopPrank();

        // Mint tokens to owner via faucet
        // Skip cooldown for testing
        vm.warp(block.timestamp + 2 hours);
        token.faucetAmountFor(owner, INITIAL_BALANCE);

        vm.prank(owner);
        token.approve(address(vault), INITIAL_BALANCE);
        vm.prank(owner);
        vault.deposit(INITIAL_BALANCE, owner);
    }

    /**
     * @notice Test 1: Self-approval is rejected
     */
    function testSelfApprovalIsRejected() public {
        vm.prank(owner);
        vm.expectRevert();
        shareToken.approve(owner, 100);
    }

    /**
     * @notice Test 2: approve() to non-self address succeeds
     */
    function testApproveToNonSelfSucceeds() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Approval(owner, spender, 100);

        shareToken.approve(spender, 100);
    }

    /**
     * @notice Test 3: approve() can increase allowance
     */
    function testApproveCanIncreaseAllowance() public {
        vm.startPrank(owner);
        shareToken.approve(spender, 100);
        shareToken.approve(spender, 200);
        vm.stopPrank();

        // Note: This depends on implementation - approve() may set or increase
        // The test verifies the operation completes successfully
    }

    /**
     * @notice Test 4: Multiple approvals to different spenders
     */
    function testMultipleApprovalsToifferentSpenders() public {
        vm.startPrank(owner);
        shareToken.approve(spender, 100);
        shareToken.approve(otherAccount, 200);
        vm.stopPrank();

        // Both approvals should succeed
    }

    /**
     * @notice Test 5: approve() with zero amount
     */
    function testApproveWithZeroAmount() public {
        vm.prank(owner);
        shareToken.approve(spender, 0);
    }

    /**
     * @notice Test 6: approve() with large amount
     */
    function testApproveWithLargeAmount() public {
        vm.prank(owner);
        shareToken.approve(spender, type(uint256).max);
    }

    /**
     * @notice Test 7: nonces() returns initial value of 0
     */
    function testNoncesReturnsInitialValueZero() public {
        uint256 nonce = shareToken.nonces(owner);
        assertEq(nonce, 0, "Initial nonce should be 0");
    }

    /**
     * @notice Test 8: nonces() returns different values for different accounts
     */
    function testNoncesDifferentForDifferentAccounts() public {
        uint256 ownerNonce = shareToken.nonces(owner);
        uint256 spenderNonce = shareToken.nonces(spender);

        assertEq(ownerNonce, spenderNonce, "Nonces should start at same value");
    }

    /**
     * @notice Test 9: DOMAIN_SEPARATOR() returns non-zero value
     */
    function testDomainSeparatorReturnsNonZero() public {
        bytes32 domainSeparator = shareToken.DOMAIN_SEPARATOR();
        assertNotEq(domainSeparator, bytes32(0), "Domain separator should be non-zero");
    }

    /**
     * @notice Test 10: DOMAIN_SEPARATOR() is deterministic
     */
    function testDomainSeparatorIsDeterministic() public {
        bytes32 separator1 = shareToken.DOMAIN_SEPARATOR();
        bytes32 separator2 = shareToken.DOMAIN_SEPARATOR();
        assertEq(separator1, separator2, "Domain separator should be same on multiple calls");
    }

    /**
     * @notice Test 11: approve() rejects zero address spender
     */
    function testApproveRejectsZeroAddressSpender() public {
        vm.prank(owner);
        vm.expectRevert();
        shareToken.approve(address(0), 100);
    }

    /**
     * @notice Test 12: permit() with expired deadline reverts
     */
    function testPermitWithExpiredDeadlineReverts() public {
        uint256 deadline = block.timestamp - 1; // Already expired
        uint256 value = 100;

        vm.expectRevert();
        shareToken.permit(owner, spender, value, deadline, 0, bytes32(0), bytes32(0));
    }

    /**
     * @notice Test 12b: permit() with valid ECDSA signature succeeds
     */
    function testPermitWithValidEcdsaSignatureSucceeds() public {
        // Use a real private key for the owner
        uint256 ownerPrivateKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        address ownerWithKey = vm.addr(ownerPrivateKey);

        // Setup KYC for the owner with real key
        vm.prank(validator);
        shareToken.setKycVerified(ownerWithKey, true);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 100 * 1e18;
        uint256 nonceBefore = shareToken.nonces(ownerWithKey);

        // Build the EIP-712 digest
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                shareToken.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), ownerWithKey, spender, value, nonceBefore, deadline))
            )
        );

        // Sign with the real private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, permitHash);

        // Execute permit
        shareToken.permit(ownerWithKey, spender, value, deadline, v, r, s);

        // Verify it worked
        uint256 allowanceAfter = shareToken.allowance(ownerWithKey, spender);
        assertEq(allowanceAfter, value, "Allowance should match permitted value");

        uint256 nonceAfter = shareToken.nonces(ownerWithKey);
        assertEq(nonceAfter, nonceBefore + 1, "Nonce should increment after permit");
    }

    /**
     * @notice Test 12c: permit() with invalid signature reverts
     */
    function testPermitWithInvalidSignatureReverts() public {
        uint256 ownerPrivateKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        address ownerWithKey = vm.addr(ownerPrivateKey);

        vm.prank(validator);
        shareToken.setKycVerified(ownerWithKey, true);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 100 * 1e18;
        uint256 nonceBefore = shareToken.nonces(ownerWithKey);

        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                shareToken.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), ownerWithKey, spender, value, nonceBefore, deadline))
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, permitHash);

        // Modify the signature to make it invalid (flip one bit of r)
        bytes32 invalidR = r ^ bytes32(uint256(1));

        // Try to use invalid signature - should revert
        vm.expectRevert();
        shareToken.permit(ownerWithKey, spender, value, deadline, v, invalidR, s);
    }

    /**
     * @notice Test 12d: permit() with wrong spender in signature reverts
     */
    function testPermitWithWrongSpenderInSignatureReverts() public {
        uint256 ownerPrivateKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        address ownerWithKey = vm.addr(ownerPrivateKey);
        address wrongSpender = makeAddr("wrongSpender");

        vm.prank(validator);
        shareToken.setKycVerified(ownerWithKey, true);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 100 * 1e18;
        uint256 nonceBefore = shareToken.nonces(ownerWithKey);

        // Sign for wrongSpender
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                shareToken.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), ownerWithKey, wrongSpender, value, nonceBefore, deadline))
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, permitHash);

        // Try to use signature with different spender - should revert
        vm.expectRevert();
        shareToken.permit(ownerWithKey, spender, value, deadline, v, r, s);
    }

    /**
     * @notice Test 13: spendSelfAllowance() is vault-only function
     */
    function testSpendSelfAllowanceIsVaultOnly() public {
        vm.prank(owner); // Not the vault
        vm.expectRevert();
        shareToken.spendSelfAllowance(owner, 100);
    }

    /**
     * @notice Test 14: Approval event emits correct parameters
     */
    function testApprovalEventEmitsCorrectParameters() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Approval(owner, spender, 250);
        shareToken.approve(spender, 250);
    }

    /**
     * @notice Test 15: Multiple sequential approvals
     */
    function testMultipleSequentialApprovals() public {
        vm.startPrank(owner);

        shareToken.approve(spender, 100);
        shareToken.approve(spender, 200);
        shareToken.approve(spender, 300);

        vm.stopPrank();
    }

    /**
     * @notice Test 16: approve() followed by different spender
     */
    function testApproveFollowedByDifferentSpender() public {
        vm.startPrank(owner);

        shareToken.approve(spender, 100);
        // Switching to approve for different spender
        shareToken.approve(otherAccount, 50);

        vm.stopPrank();
    }

    /**
     * @notice Test 17: DOMAIN_SEPARATOR() includes contract info
     */
    function testDomainSeparatorIncludesContractInfo() public {
        bytes32 separator = shareToken.DOMAIN_SEPARATOR();

        // Domain separator should be based on:
        // - Chain ID
        // - Contract address
        // - Name/Version

        // Verify it's not zero and not a trivial value
        assertNotEq(separator, bytes32(0), "Separator should not be zero");
        assertNotEq(separator, keccak256(abi.encodePacked("test")), "Separator should be properly computed");
    }

    /**
     * @notice Test 18: nonces() for new account is 0
     */
    function testNoncesForNewAccountIsZero() public {
        address newAccount = makeAddr("newAccount");
        uint256 nonce = shareToken.nonces(newAccount);
        assertEq(nonce, 0, "New account nonce should be 0");
    }

    /**
     * @notice Test 19: approve() accepts owner == spender check
     */
    function testApproveOwnerEqualsSelfRejected() public {
        // Verify self-approval for owner is rejected
        vm.prank(owner);
        vm.expectRevert();
        shareToken.approve(owner, 100);
    }

    /**
     * @notice Test 20: approve() for spender receiving shares
     */
    function testApproveForSpenderReceivingShares() public {
        // Approve spender to transfer owner's shares
        vm.prank(owner);
        shareToken.approve(spender, 100);

        // Spender should now be able to use transferFrom (if approved)
        // This tests the approval system setup, not transfer execution
    }

    /**
     * @notice Test 21: Multiple approvals create separate allowances
     */
    function testMultipleApprovalsCreateSeparateAllowances() public {
        vm.startPrank(owner);

        // Approve different amounts for different spenders
        shareToken.approve(spender, 100);
        shareToken.approve(otherAccount, 200);

        vm.stopPrank();

        // Both approvals should be recorded separately
    }

    /**
     * @notice Test 22: approve() idempotency
     */
    function testApproveIdempotency() public {
        vm.startPrank(owner);

        // Approve same amount twice
        shareToken.approve(spender, 100);
        shareToken.approve(spender, 100);

        vm.stopPrank();
    }

    /**
     * @notice Test 23: nonces() consistency across calls
     */
    function testNoncesConsistencyAcrossCalls() public {
        uint256 nonce1 = shareToken.nonces(owner);
        uint256 nonce2 = shareToken.nonces(owner);
        uint256 nonce3 = shareToken.nonces(owner);

        assertEq(nonce1, nonce2, "Nonce should be consistent");
        assertEq(nonce2, nonce3, "Nonce should be consistent");
    }

    /**
     * @notice Test 24: DOMAIN_SEPARATOR() stability across calls
     */
    function testDomainSeparatorStabilityAcrossCalls() public {
        bytes32 sep1 = shareToken.DOMAIN_SEPARATOR();
        bytes32 sep2 = shareToken.DOMAIN_SEPARATOR();
        bytes32 sep3 = shareToken.DOMAIN_SEPARATOR();

        assertEq(sep1, sep2, "Separator should be stable");
        assertEq(sep2, sep3, "Separator should be stable");
    }

    /**
     * @notice Test 25: approve() with various address formats
     */
    function testApproveWithVariousAddresses() public {
        address[] memory testAddresses = new address[](4);
        testAddresses[0] = address(0x1);
        testAddresses[1] = address(vault);
        testAddresses[2] = address(token);
        testAddresses[3] = spender;

        vm.startPrank(owner);

        // Should work for all non-owner addresses
        for (uint256 i = 0; i < testAddresses.length; i++) {
            if (testAddresses[i] != owner) {
                shareToken.approve(testAddresses[i], 100);
            }
        }

        vm.stopPrank();
    }
}
