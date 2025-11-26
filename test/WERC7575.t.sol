// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";
import {IERC7575} from "../src/interfaces/IERC7575.sol";

import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {IERC7575MultiAsset} from "../src/interfaces/IERC7575MultiAsset.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Test} from "forge-std/Test.sol";

contract WERC7575Test is Test {
    WERC7575Vault public vault;
    WERC7575ShareToken public shareToken;
    ERC20Faucet public token;

    // Events from WERC7575Vault
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    address public owner;
    address public validator;
    uint256 public validatorPrivateKey;
    address public user1;
    address public user2;

    uint256 constant TOTAL_SUPPLY = 10e9 * 1e18;
    uint256 constant AMOUNT = 100 * 1e18;

    function setUp() public {
        owner = address(this);
        (validator, validatorPrivateKey) = makeAddrAndKey("validator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy token
        token = new ERC20Faucet("USDT", "USDT", TOTAL_SUPPLY);

        // Deploy ShareToken first (ERC-7575 pattern)
        shareToken = new WERC7575ShareToken("wUSDT", "WUSDT");

        // Deploy ERC7575 vault with existing ShareToken
        vault = new WERC7575Vault(address(token), shareToken);

        // Register vault with ShareToken (owner operation)
        shareToken.registerVault(address(token), address(vault));

        // Set validator
        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);
        shareToken.setRevenueAdmin(validator);

        // KYC users for mint/burn via vault (validator)
        vm.prank(validator);
        shareToken.setKycVerified(user1, true);
        vm.prank(validator);
        shareToken.setKycVerified(user2, true);

        // Transfer tokens to users for testing
        assertTrue(token.transfer(user1, AMOUNT * 10));
        assertTrue(token.transfer(user2, AMOUNT * 10));
    }

    function testERC7575Interface() public {
        // Test ERC7575 interface support
        assertTrue(vault.supportsInterface(0x2f0a18c5)); // ERC7575 interface ID

        // Test core ERC7575 methods
        assertEq(vault.share(), address(shareToken));
        assertEq(vault.asset(), address(token));
        assertEq(shareToken.vault(address(token)), address(vault));
    }

    function testValidatorPermit() public {
        // Approve and deposit tokens for user1
        vm.startPrank(owner);
        token.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT, user1);
        vm.stopPrank();

        assertEq(shareToken.balanceOf(user1), AMOUNT);

        // User1 should not be able to transfer without permit
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, AMOUNT));
        bool success1 = shareToken.transfer(user2, AMOUNT);
        // Expected to fail - suppress warning
        success1;

        // Create permit signature
        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user1, user1, AMOUNT, shareToken.nonces(user1), deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPrivateKey, digest);

        // Use permit to approve transfer
        vm.prank(user1);
        shareToken.permit(user1, user1, AMOUNT, deadline, v, r, s);

        // Now user1 can transfer
        vm.prank(user1);
        assertTrue(shareToken.transfer(user2, AMOUNT));

        assertEq(shareToken.balanceOf(user1), 0);
        assertEq(shareToken.balanceOf(user2), AMOUNT);
        assertEq(shareToken.allowance(user1, user1), 0);
    }

    function testSelfPermitFails() public {
        // Generate random private key for user
        uint256 userPrivateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address userAddress = vm.addr(userPrivateKey);

        // Approve and deposit tokens for user
        vm.startPrank(owner);
        // KYC must be set by validator; stop prank then set
        vm.stopPrank();
        vm.prank(validator);
        shareToken.setKycVerified(userAddress, true);
        vm.startPrank(owner);
        token.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT, userAddress);
        vm.stopPrank();

        assertEq(shareToken.balanceOf(userAddress), AMOUNT);

        // User should not be able to transfer without permit
        vm.prank(userAddress);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, userAddress, 0, AMOUNT));
        bool success2 = shareToken.transfer(user2, AMOUNT);
        // Expected to fail - suppress warning
        success2;

        // Create permit signature with user's own private key
        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash = keccak256(
            abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), userAddress, userAddress, AMOUNT, shareToken.nonces(userAddress), deadline)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        // Self permit should fail (user signing for themselves)
        vm.prank(userAddress);
        vm.expectRevert();
        shareToken.permit(userAddress, userAddress, AMOUNT, deadline, v, r, s);

        // User still cannot transfer
        vm.prank(userAddress);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, userAddress, 0, AMOUNT));
        bool success3 = shareToken.transfer(user2, AMOUNT);
        // Expected to fail - suppress warning
        success3;
    }

    function testBatchTransfers() public {
        // Setup users with deposits
        address[] memory users = new address[](6);
        users[0] = user1;
        users[1] = user2;
        users[2] = makeAddr("user3");
        users[3] = makeAddr("user4");
        users[4] = makeAddr("user5");
        users[5] = makeAddr("user6");

        // Deposit to each user
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(validator);
            shareToken.setKycVerified(users[i], true);
            token.approve(address(vault), AMOUNT);
            vault.deposit(AMOUNT, users[i]);
            assertEq(shareToken.balanceOf(users[i]), AMOUNT);
        }

        // Prepare batch transfer arrays
        address[] memory debtors = new address[](6);
        address[] memory creditors = new address[](6);
        uint256[] memory amounts = new uint256[](6);

        // Circular transfers: user1 -> user2 -> user3 -> ... -> user6 -> user1
        for (uint256 i = 0; i < 5; i++) {
            debtors[i] = users[i];
            creditors[i] = users[i + 1];
            amounts[i] = AMOUNT;
        }
        debtors[5] = users[5];
        creditors[5] = users[0];
        amounts[5] = AMOUNT + AMOUNT; // Extra amount to test net effect

        // Execute batch transfers (validator-only)
        vm.prank(validator);
        shareToken.batchTransfers(debtors, creditors, amounts);

        // Verify final balances
        assertEq(shareToken.balanceOf(user1), AMOUNT * 2); // Net +1 AMOUNT
        assertEq(shareToken.balanceOf(users[1]), AMOUNT); // Net 0
        assertEq(shareToken.balanceOf(users[2]), AMOUNT); // Net 0
        assertEq(shareToken.balanceOf(users[3]), AMOUNT); // Net 0
        assertEq(shareToken.balanceOf(users[4]), AMOUNT); // Net 0
        assertEq(shareToken.balanceOf(users[5]), 0); // Net -1 AMOUNT

        // Check rBalance (restricted balance) - batchTransfers does NOT modify rBalance
        // Only rBatchTransfers modifies rBalance
        assertEq(shareToken.rBalanceOf(users[5]), 0);
    }

    function testRBalanceAdjustment() public {
        // Setup user with deposit
        token.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT, user1);

        // Create restricted balance through rBatchTransfers (with flags)
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = AMOUNT;

        // Use rBatchTransfers with flag to create rBalance
        vm.prank(validator);
        shareToken.rBatchTransfers(debtors, creditors, amounts, 1); // flag bit 0 set for user1

        // rBatchTransfers should have created rBalance
        assertEq(shareToken.balanceOf(user1), 0);
        assertEq(shareToken.rBalanceOf(user1), AMOUNT); // rBalance created by rBatchTransfers

        // Adjust rBalance
        uint256 timestamp = block.timestamp;
        uint256 amountInvested = AMOUNT;
        uint256 amountReceived = AMOUNT * 101 / 100; // 1% gain

        vm.prank(validator);
        shareToken.adjustrBalance(user1, timestamp, amountInvested, amountReceived);

        assertEq(shareToken.rBalanceOf(user1), AMOUNT * 101 / 100);

        // Cancel the adjustment
        vm.prank(validator);
        shareToken.cancelrBalanceAdjustment(user1, timestamp);

        assertEq(shareToken.rBalanceOf(user1), AMOUNT);
    }

    function testRBalanceAdjustmentReverts() public {
        uint256 timestamp = block.timestamp;

        // Should revert when trying to cancel non-existent adjustment
        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.NoRBalanceAdjustmentFound.selector);
        shareToken.cancelrBalanceAdjustment(user1, timestamp);

        // Apply adjustment
        vm.prank(validator);
        shareToken.adjustrBalance(user1, timestamp, 100, 110);

        // Should revert when trying to apply same timestamp again
        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.RBalanceAdjustmentAlreadyApplied.selector);
        shareToken.adjustrBalance(user1, timestamp, 100, 110);
    }

    function testOnlyOwnerModifiers() public {
        vm.prank(user1);
        vm.expectRevert(WERC7575ShareToken.OnlyKycAdmin.selector);
        shareToken.setKycVerified(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        shareToken.setValidator(user1);

        vm.prank(user1);
        vm.expectRevert(WERC7575ShareToken.OnlyValidator.selector);
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        shareToken.batchTransfers(debtors, creditors, amounts);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        shareToken.registerVault(address(token), address(vault));
    }

    function testOnlyValidatorModifiers() public {
        vm.prank(user1);
        vm.expectRevert(WERC7575ShareToken.OnlyRevenueAdmin.selector);
        shareToken.adjustrBalance(user1, block.timestamp, 100, 110);

        vm.prank(user1);
        vm.expectRevert(WERC7575ShareToken.OnlyRevenueAdmin.selector);
        shareToken.cancelrBalanceAdjustment(user1, block.timestamp);
    }

    function testKYCFunctionality() public {
        address newUser = makeAddr("kycTest");
        assertEq(shareToken.isKycVerified(newUser), false);

        vm.prank(validator);
        shareToken.setKycVerified(newUser, true);
        assertEq(shareToken.isKycVerified(newUser), true);

        vm.prank(validator);
        shareToken.setKycVerified(newUser, false);
        assertEq(shareToken.isKycVerified(newUser), false);
    }

    function testERC7575VaultFunctionality() public {
        uint256 depositAmount = 1000 * 1e18;

        // Test deposit
        token.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);

        assertEq(shares, depositAmount);
        assertEq(shareToken.balanceOf(user1), depositAmount);
        assertEq(vault.totalAssets(), depositAmount);

        // Test preview functions
        assertEq(vault.previewDeposit(depositAmount), depositAmount);
        assertEq(vault.previewMint(shares), depositAmount);
        assertEq(vault.previewWithdraw(depositAmount), shares);
        assertEq(vault.previewRedeem(shares), depositAmount);

        // Test max functions
        assertEq(vault.maxDeposit(user1), type(uint256).max);
        assertEq(vault.maxMint(user1), type(uint256).max);
        assertEq(vault.maxWithdraw(user1), depositAmount);
        assertEq(vault.maxRedeem(user1), depositAmount);

        // Test convert functions
        assertEq(vault.convertToShares(depositAmount), shares);
        assertEq(vault.convertToAssets(shares), depositAmount);
    }

    function testMultiAssetVaultFunctionality() public {
        // Test vault lookup
        assertEq(shareToken.vault(address(token)), address(vault));

        // Test adding new vault for different asset - create real contracts
        ERC20Faucet newAsset = new ERC20Faucet("New Asset", "NEW", 1000000 * 10 ** 18);
        WERC7575Vault newVault = new WERC7575Vault(address(newAsset), shareToken);

        // Should revert for non-owner
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        shareToken.registerVault(address(newAsset), address(newVault));

        // Owner should be able to add new vault
        vm.expectEmit(true, false, false, true);
        emit IERC7575MultiAsset.VaultUpdate(address(newAsset), address(newVault));
        shareToken.registerVault(address(newAsset), address(newVault));

        assertEq(shareToken.vault(address(newAsset)), address(newVault));
    }

    function testAddVault_ValidatesShareToken() public {
        // Create a different ShareToken
        WERC7575ShareToken otherShareToken = new WERC7575ShareToken("Other USD", "OTHER");

        // Create new asset and vault for the other ShareToken
        ERC20Faucet wrongAsset = new ERC20Faucet("Wrong Asset", "WRONG", 1000000 * 10 ** 18);
        WERC7575Vault wrongVault = new WERC7575Vault(address(wrongAsset), otherShareToken);

        // Try to add this vault to our ShareToken - should fail due to share token mismatch
        vm.expectRevert(IERC7575Errors.VaultShareMismatch.selector);
        shareToken.registerVault(address(wrongAsset), address(wrongVault));
    }

    function testMintFunction() public {
        uint256 sharesToMint = 500 * 1e18;
        uint256 expectedAssets = vault.previewMint(sharesToMint);

        token.approve(address(vault), expectedAssets);
        uint256 actualAssets = vault.mint(sharesToMint, user1);

        assertEq(actualAssets, expectedAssets);
        assertEq(shareToken.balanceOf(user1), sharesToMint);
        assertEq(vault.totalAssets(), actualAssets);
    }

    function testWithdrawAndRedeemRequireAllowance() public {
        uint256 depositAmount = 1000 * 1e18;

        // Give user1 tokens and let them deposit
        vm.startPrank(user1);
        token.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);

        // User should not be able to withdraw without allowance (already pranked)
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, depositAmount));
        vault.withdraw(depositAmount, user1, user1);

        // User should not be able to redeem without allowance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, shares));
        vault.redeem(shares, user1, user1);

        // Give user1 self-allowance through permit
        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user1, user1, shares, shareToken.nonces(user1), deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPrivateKey, digest);

        shareToken.permit(user1, user1, shares, deadline, v, r, s);

        // Now user1 can redeem
        uint256 assetsRedeemed = vault.redeem(shares, user1, user1);
        vm.stopPrank();

        assertEq(assetsRedeemed, depositAmount);
        assertEq(shareToken.balanceOf(user1), 0);
        assertEq(token.balanceOf(user1), AMOUNT * 10); // Back to original balance
    }

    function testShareTokenOnlyVaultMethods() public {
        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.mint(user1, AMOUNT);

        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.burn(user1, AMOUNT);
    }

    function testEvents() public {
        uint256 depositAmount = 100 * 1e18;

        // Test Deposit event
        token.approve(address(vault), depositAmount);

        vm.expectEmit(true, true, false, true);
        emit Deposit(address(this), user1, depositAmount, depositAmount);
        vault.deposit(depositAmount, user1);

        // Give user1 permission to redeem
        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user1, user1, depositAmount, shareToken.nonces(user1), deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPrivateKey, digest);

        vm.prank(user1);
        shareToken.permit(user1, user1, depositAmount, deadline, v, r, s);

        // Test Withdraw event
        vm.expectEmit(true, true, true, true);
        emit Withdraw(user1, user1, user1, depositAmount, depositAmount);

        vm.prank(user1);
        vault.redeem(depositAmount, user1, user1);
    }

    function testSetValidator_RejectsZeroAddress() public {
        // Try to set validator to zero address - should fail
        vm.prank(owner);
        vm.expectRevert(WERC7575ShareToken.ShareTokenZeroValidator.selector);
        shareToken.setValidator(address(0));
    }
}
