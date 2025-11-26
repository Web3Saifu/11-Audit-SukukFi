// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC20Faucet.sol";
import "../src/WERC7575ShareToken.sol";
import "../src/WERC7575Vault.sol";
import "../src/interfaces/IERC7575Errors.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title WERC7575ShareToken Coverage Tests
 * @notice Tests to improve code coverage of critical functions
 * @dev Focuses on error paths, edge cases, and boundary conditions
 */
contract WERC7575ShareTokenCoverageTests is Test {
    WERC7575ShareToken public shareToken;
    ERC20Faucet public token;
    WERC7575Vault public vault;

    address public validator;
    address public revenueAdmin;
    address public user1;
    address public user2;
    address public user3;

    uint256 constant INITIAL_BALANCE = 1000 * 1e18;

    function setUp() public {
        validator = makeAddr("validator");
        revenueAdmin = makeAddr("revenueAdmin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        token = new ERC20Faucet("Test Token", "TEST", 100000 * 1e18);
        shareToken = new WERC7575ShareToken("Test Share", "tSHARE");
        vault = new WERC7575Vault(address(token), shareToken);

        shareToken.registerVault(address(token), address(vault));
        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);
        shareToken.setRevenueAdmin(revenueAdmin);

        // Setup users with balances
        vm.warp(block.timestamp + 2 hours); // Skip faucet cooldown
        token.faucetAmountFor(user1, INITIAL_BALANCE);
        token.faucetAmountFor(user2, INITIAL_BALANCE);
        token.faucetAmountFor(user3, INITIAL_BALANCE);

        // KYC all users
        vm.startPrank(validator);
        shareToken.setKycVerified(user1, true);
        shareToken.setKycVerified(user2, true);
        shareToken.setKycVerified(user3, true);
        vm.stopPrank();

        // Deposit to create shares
        vm.prank(user1);
        token.approve(address(vault), INITIAL_BALANCE);
        vm.prank(user1);
        vault.deposit(INITIAL_BALANCE, user1);

        vm.prank(user2);
        token.approve(address(vault), INITIAL_BALANCE);
        vm.prank(user2);
        vault.deposit(INITIAL_BALANCE, user2);

        vm.prank(user3);
        token.approve(address(vault), INITIAL_BALANCE);
        vm.prank(user3);
        vault.deposit(INITIAL_BALANCE, user3);
    }

    // ==================== batchTransfers Error Path Tests ====================

    /**
     * @notice Test batchTransfers reverts with ArrayTooLarge
     */
    function testBatchTransfersArrayTooLarge() public {
        address[] memory debtors = new address[](101); // Exceeds MAX_BATCH_SIZE
        address[] memory creditors = new address[](101);
        uint256[] memory amounts = new uint256[](101);

        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.ArrayTooLarge.selector);
        shareToken.batchTransfers(debtors, creditors, amounts);
    }

    /**
     * @notice Test batchTransfers reverts with ArrayLengthMismatch
     */
    function testBatchTransfersArrayLengthMismatchDebtor() public {
        address[] memory debtors = new address[](2);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        debtors[1] = user2;
        creditors[0] = user3;
        amounts[0] = 100 * 1e18;

        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.ArrayLengthMismatch.selector);
        shareToken.batchTransfers(debtors, creditors, amounts);
    }

    /**
     * @notice Test batchTransfers reverts with ArrayLengthMismatch - creditors
     */
    function testBatchTransfersArrayLengthMismatchCreditor() public {
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](2);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        creditors[1] = user3;
        amounts[0] = 100 * 1e18;

        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.ArrayLengthMismatch.selector);
        shareToken.batchTransfers(debtors, creditors, amounts);
    }

    /**
     * @notice Test batchTransfers reverts with ArrayLengthMismatch - amounts
     */
    function testBatchTransfersArrayLengthMismatchAmounts() public {
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](2);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 100 * 1e18;
        amounts[1] = 50 * 1e18;

        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.ArrayLengthMismatch.selector);
        shareToken.batchTransfers(debtors, creditors, amounts);
    }

    /**
     * @notice Test batchTransfers reverts with LowBalance
     */
    function testBatchTransfersLowBalance() public {
        address poorUser = makeAddr("poorUser");
        vm.prank(validator);
        shareToken.setKycVerified(poorUser, true);

        // poorUser has 0 balance

        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = poorUser;
        creditors[0] = user1;
        amounts[0] = 100 * 1e18; // Exceeds available balance

        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.LowBalance.selector);
        shareToken.batchTransfers(debtors, creditors, amounts);
    }

    /**
     * @notice Test batchTransfers with maximum batch size (100)
     */
    function testBatchTransfersMaxBatchSize() public {
        // Create 100 transfers
        address[] memory debtors = new address[](100);
        address[] memory creditors = new address[](100);
        uint256[] memory amounts = new uint256[](100);

        for (uint256 i = 0; i < 100; i++) {
            debtors[i] = user1;
            creditors[i] = i % 2 == 0 ? user2 : user3;
            amounts[i] = 1 * 1e18;
        }

        uint256 user1BalBefore = shareToken.balanceOf(user1);

        vm.prank(validator);
        shareToken.batchTransfers(debtors, creditors, amounts);

        assertEq(shareToken.balanceOf(user1), user1BalBefore - (100 * 1e18), "User1 balance should decrease");
    }

    // ==================== rBatchTransfers Error Path Tests ====================

    /**
     * @notice Test rBatchTransfers with selective rBalance updates
     */
    function testRBatchTransfersSelectiveRBalance() public {
        address[] memory debtors = new address[](3);
        address[] memory creditors = new address[](3);
        uint256[] memory amounts = new uint256[](3);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 50 * 1e18;

        debtors[1] = user2;
        creditors[1] = user3;
        amounts[1] = 30 * 1e18;

        debtors[2] = user3;
        creditors[2] = user1;
        amounts[2] = 20 * 1e18;

        uint256 user1RBalBefore = shareToken.rBalanceOf(user1);
        uint256 user2RBalBefore = shareToken.rBalanceOf(user2);
        uint256 user3RBalBefore = shareToken.rBalanceOf(user3);

        // Only flag bit 0 (user1) and bit 2 (user3)
        uint256 flags = (1 << 0) | (1 << 2);

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, flags);

        // User1 is debtor with flag set - rBalance should increase by net debit (50 - 20 = 30)
        assertEq(shareToken.rBalanceOf(user1), user1RBalBefore + 30 * 1e18, "User1 rBalance should increase");

        // User2 is not flagged - rBalance should not change
        assertEq(shareToken.rBalanceOf(user2), user2RBalBefore, "User2 rBalance should not change");

        // User3 is flagged - rBalance should increase by net debit (20 - 30 = -10, clamped to 0 decrease)
        assertEq(shareToken.rBalanceOf(user3), user3RBalBefore, "User3 rBalance should stay same (no net debit)");
    }

    /**
     * @notice Test rBatchTransfers with all flags set
     */
    function testRBatchTransfersAllFlagsSet() public {
        address[] memory debtors = new address[](2);
        address[] memory creditors = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 100 * 1e18;

        debtors[1] = user2;
        creditors[1] = user1;
        amounts[1] = 60 * 1e18;

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, type(uint256).max);

        // User1: -100 + 60 = -40 net debit
        assertEq(shareToken.rBalanceOf(user1), 40 * 1e18, "User1 net debit should be in rBalance");

        // User2: +100 - 60 = +40 net credit (rBalance clamped to 0)
        assertEq(shareToken.rBalanceOf(user2), 0, "User2 should have 0 rBalance");
    }

    /**
     * @notice Test rBatchTransfers with no flags set
     */
    function testRBatchTransfersNoFlags() public {
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 100 * 1e18;

        uint256 user1RBalBefore = shareToken.rBalanceOf(user1);

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, 0);

        // No flags set - rBalance should not change
        assertEq(shareToken.rBalanceOf(user1), user1RBalBefore, "rBalance should not change");
    }

    // ==================== adjustrBalance Error Path Tests ====================

    /**
     * @notice Test adjustrBalance with future timestamp reverts
     */
    function testAdjustrBalanceFutureTimestamp() public {
        uint256 futureTimestamp = block.timestamp + 1 hours;

        vm.prank(revenueAdmin);
        vm.expectRevert(WERC7575ShareToken.FutureTimestampNotAllowed.selector);
        shareToken.adjustrBalance(user1, futureTimestamp, 100 * 1e18, 110 * 1e18);
    }

    /**
     * @notice Test adjustrBalance with zero amount
     */
    function testAdjustrBalanceZeroAmount() public {
        uint256 timestamp = block.timestamp;

        // First create rBalance
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 100 * 1e18;

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, 1);

        // Try to adjust with zero amount - should revert
        vm.prank(revenueAdmin);
        vm.expectRevert(IERC7575Errors.ZeroAmount.selector);
        shareToken.adjustrBalance(user1, timestamp, 0, 100 * 1e18);
    }

    /**
     * @notice Test adjustrBalance with MaxReturnMultiplierExceeded
     */
    function testAdjustrBalanceMaxReturnMultiplierExceeded() public {
        uint256 timestamp = block.timestamp;

        // Create rBalance
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 100 * 1e18;

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, 1);

        // Try to adjust with return > 2x (likely exceeds MAX_RETURN_MULTIPLIER)
        vm.prank(revenueAdmin);
        vm.expectRevert(WERC7575ShareToken.MaxReturnMultiplierExceeded.selector);
        shareToken.adjustrBalance(user1, timestamp, 100 * 1e18, 300 * 1e18); // 3x return
    }

    /**
     * @notice Test adjustrBalance duplicate timestamp
     */
    function testAdjustrBalanceDuplicateTimestamp() public {
        uint256 timestamp = block.timestamp;

        // Create rBalance
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 100 * 1e18;

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, 1);

        // First adjustment
        vm.prank(revenueAdmin);
        shareToken.adjustrBalance(user1, timestamp, 100 * 1e18, 110 * 1e18);

        // Try same timestamp again
        vm.prank(revenueAdmin);
        vm.expectRevert(WERC7575ShareToken.RBalanceAdjustmentAlreadyApplied.selector);
        shareToken.adjustrBalance(user1, timestamp, 100 * 1e18, 110 * 1e18);
    }

    // ==================== cancelrBalanceAdjustment Tests ====================

    /**
     * @notice Test cancelrBalanceAdjustment non-existent adjustment
     */
    function testCancelrBalanceAdjustmentNotFound() public {
        uint256 timestamp = block.timestamp;

        vm.prank(revenueAdmin);
        vm.expectRevert(WERC7575ShareToken.NoRBalanceAdjustmentFound.selector);
        shareToken.cancelrBalanceAdjustment(user1, timestamp);
    }

    /**
     * @notice Test cancelrBalanceAdjustment successful cancellation
     */
    function testCancelrBalanceAdjustmentSuccess() public {
        uint256 timestamp = block.timestamp;

        // Create rBalance
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 100 * 1e18;

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, 1);

        uint256 rBalBefore = shareToken.rBalanceOf(user1);

        // Adjust
        vm.prank(revenueAdmin);
        shareToken.adjustrBalance(user1, timestamp, 100 * 1e18, 110 * 1e18);

        uint256 rBalAfterAdjust = shareToken.rBalanceOf(user1);
        assertEq(rBalAfterAdjust, 110 * 1e18, "rBalance should be adjusted");

        // Cancel
        vm.prank(revenueAdmin);
        shareToken.cancelrBalanceAdjustment(user1, timestamp);

        assertEq(shareToken.rBalanceOf(user1), rBalBefore, "rBalance should return to original");
    }

    // ==================== registerVault Error Path Tests ====================

    /**
     * @notice Test registerVault with AssetAlreadyRegistered
     */
    function testRegisterVaultAlreadyRegistered() public {
        vm.expectRevert(IERC7575Errors.AssetAlreadyRegistered.selector);
        shareToken.registerVault(address(token), address(vault)); // Already registered in setUp
    }

    /**
     * @notice Test registerVault exceeds max vaults
     */
    function testRegisterVaultMaxVaultsExceeded() public {
        // Register 9 more vaults (already have 1)
        for (uint256 i = 0; i < 9; i++) {
            ERC20Faucet newToken = new ERC20Faucet(string(abi.encodePacked("Token", i)), string(abi.encodePacked("TKN", i)), 10000 * 1e18);
            WERC7575Vault newVault = new WERC7575Vault(address(newToken), shareToken);
            shareToken.registerVault(address(newToken), address(newVault));
        }

        // Try to register 11th vault
        ERC20Faucet extraToken = new ERC20Faucet("Extra", "EXT", 10000 * 1e18);
        WERC7575Vault extraVault = new WERC7575Vault(address(extraToken), shareToken);

        vm.expectRevert(IERC7575Errors.MaxVaultsExceeded.selector);
        shareToken.registerVault(address(extraToken), address(extraVault));
    }

    // ==================== unregisterVault Tests ====================

    /**
     * @notice Test unregisterVault fails if vault has asset balance
     */
    function testUnregisterVaultWithAssetBalance() public {
        // Vault still holds assets (from the deposits), so unregister should fail
        vm.expectRevert(IERC7575Errors.CannotUnregisterVaultAssetBalance.selector);
        shareToken.unregisterVault(address(token));
    }

    // ==================== Transfer Tests ====================

    /**
     * @notice Test transfer reverts on KYC requirement
     */
    function testTransferKYCRequired() public {
        address nonKycUser = makeAddr("nonKycUser");

        vm.prank(user1);
        vm.expectRevert(WERC7575ShareToken.KycRequired.selector);
        shareToken.transfer(nonKycUser, 100 * 1e18);
    }

    /**
     * @notice Test transfer to self requires self-allowance (for valid case, must revert without permit)
     */
    function testTransferToSelfWithoutSelfAllowance() public {
        uint256 amount = 100 * 1e18;

        // Without setting self-allowance via permit, transfer should revert with ERC20InsufficientAllowance
        vm.prank(user1);
        vm.expectRevert();
        shareToken.transfer(user1, amount);
    }

    /**
     * @notice Test transferFrom reverts on KYC requirement
     */
    function testTransferFromKYCRequired() public {
        address nonKycUser = makeAddr("nonKycUser");

        vm.prank(user1);
        shareToken.approve(user2, 100 * 1e18);

        vm.prank(user2);
        vm.expectRevert(WERC7575ShareToken.KycRequired.selector);
        shareToken.transferFrom(user1, nonKycUser, 100 * 1e18);
    }

    // ==================== Permit Tests ====================

    /**
     * @notice Test permit with expired signature
     */
    function testPermitExpiredSignature() public {
        uint256 deadline = block.timestamp - 1; // Expired

        bytes32 domainSeparator = shareToken.DOMAIN_SEPARATOR();
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user1, user2, 100 * 1e18, shareToken.nonces(user1), deadline))
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256(abi.encodePacked(user1))), permitHash);

        vm.expectRevert(abi.encodeWithSelector(WERC7575ShareToken.ERC2612ExpiredSignature.selector, deadline));
        shareToken.permit(user1, user2, 100 * 1e18, deadline, v, r, s);
    }

    // ==================== Setter Tests ====================

    /**
     * @notice Test setKycAdmin with zero address
     */
    function testSetKycAdminZeroAddress() public {
        vm.expectRevert();
        shareToken.setKycAdmin(address(0));
    }

    /**
     * @notice Test setRevenueAdmin with zero address
     */
    function testSetRevenueAdminZeroAddress() public {
        vm.expectRevert();
        shareToken.setRevenueAdmin(address(0));
    }

    /**
     * @notice Test setValidator with zero address
     */
    function testSetValidatorZeroAddress() public {
        vm.expectRevert();
        shareToken.setValidator(address(0));
    }

    /**
     * @notice Test setKycVerified idempotency
     */
    function testSetKycVerifiedIdempotent() public {
        address testUser = makeAddr("testUser");

        vm.prank(validator);
        shareToken.setKycVerified(testUser, true);

        vm.prank(validator);
        shareToken.setKycVerified(testUser, true); // Set again

        assertTrue(shareToken.isKycVerified(testUser), "Should remain verified");
    }

    // ==================== Query Function Tests ====================

    /**
     * @notice Test rBalanceOf returns correct value
     */
    function testRBalanceOfQuery() public {
        uint256 rBal = shareToken.rBalanceOf(user1);
        assertEq(rBal, 0, "Initial rBalance should be 0");
    }

    /**
     * @notice Test balanceOf returns correct value
     */
    function testBalanceOfQuery() public {
        uint256 bal = shareToken.balanceOf(user1);
        assertEq(bal, INITIAL_BALANCE, "Balance should equal deposit amount");
    }

    /**
     * @notice Test getRegisteredAssets
     */
    function testGetRegisteredAssets() public {
        address[] memory assets = shareToken.getRegisteredAssets();
        assertEq(assets.length, 1, "Should have 1 registered asset");
        assertEq(assets[0], address(token), "Asset should be token");
    }

    /**
     * @notice Test getRegisteredVaults
     */
    function testGetRegisteredVaults() public {
        address[] memory vaults = shareToken.getRegisteredVaults();
        assertEq(vaults.length, 1, "Should have 1 registered vault");
        assertEq(vaults[0], address(vault), "Vault should match");
    }

    /**
     * @notice Test vault getter
     */
    function testVaultGetter() public {
        address vaultAddr = shareToken.vault(address(token));
        assertEq(vaultAddr, address(vault), "Vault address should match");
    }

    /**
     * @notice Test isVault
     */
    function testIsVault() public {
        assertTrue(shareToken.isVault(address(vault)), "Should be registered vault");
        assertFalse(shareToken.isVault(user1), "User should not be vault");
    }

    /**
     * @notice Test getVaultCount
     */
    function testGetVaultCount() public {
        uint256 count = shareToken.getVaultCount();
        assertEq(count, 1, "Should have 1 vault");
    }

    /**
     * @notice Test supportsInterface
     */
    function testSupportsInterface() public {
        assertTrue(shareToken.supportsInterface(0x01ffc9a7), "Should support ERC165");
    }
}
