// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";

import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

contract PauseFunctionalityTest is Test {
    WERC7575Vault public vault;
    WERC7575ShareToken public shareToken;
    ERC20Faucet public token;

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

        // Deploy vault
        vault = new WERC7575Vault(address(token), shareToken);

        // Register vault with ShareToken (owner operation)
        shareToken.registerVault(address(token), address(vault));

        // Set validator
        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);
        shareToken.setRevenueAdmin(validator);

        // KYC users who receive shares (validator)
        vm.prank(validator);
        shareToken.setKycVerified(user1, true);
        vm.prank(validator);
        shareToken.setKycVerified(user2, true);

        // Transfer tokens to users for testing
        assertTrue(token.transfer(user1, AMOUNT * 10));
        assertTrue(token.transfer(user2, AMOUNT * 10));

        // Setup initial deposits
        token.approve(address(vault), AMOUNT * 5);
        vault.deposit(AMOUNT, user1);
        vault.deposit(AMOUNT, user2);
    }

    function testVaultPauseUnpause() public {
        // Initially not paused
        assertFalse(vault.paused(), "Vault should not be paused initially");

        // Owner can pause
        vault.pause();
        assertTrue(vault.paused(), "Vault should be paused after pause()");

        // Owner can unpause
        vault.unpause();
        assertFalse(vault.paused(), "Vault should not be paused after unpause()");
    }

    function testShareTokenPauseUnpause() public {
        // Initially not paused
        assertFalse(shareToken.paused(), "ShareToken should not be paused initially");

        // Owner can pause
        shareToken.pause();
        assertTrue(shareToken.paused(), "ShareToken should be paused after pause()");

        // Owner can unpause
        shareToken.unpause();
        assertFalse(shareToken.paused(), "ShareToken should not be paused after unpause()");
    }

    function testOnlyOwnerCanPause() public {
        // Non-owner cannot pause vault
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        vault.pause();

        // Non-owner cannot pause shareToken
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        shareToken.pause();

        // Non-owner cannot unpause
        vault.pause();
        shareToken.pause();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        vault.unpause();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        shareToken.unpause();
    }

    function testVaultDepositPausedReverts() public {
        vault.pause();

        vm.startPrank(user1);
        token.approve(address(vault), AMOUNT);

        vm.expectRevert();
        vault.deposit(AMOUNT, user1);

        vm.stopPrank();
    }

    function testVaultMintPausedReverts() public {
        vault.pause();

        vm.startPrank(user1);
        token.approve(address(vault), AMOUNT);

        vm.expectRevert();
        vault.mint(AMOUNT, user1);

        vm.stopPrank();
    }

    function testVaultWithdrawPausedReverts() public {
        vault.pause();

        // Create permit signature for user1 to withdraw their own shares
        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user1, user1, AMOUNT, shareToken.nonces(user1), deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPrivateKey, digest);

        vm.startPrank(user1);
        shareToken.permit(user1, user1, AMOUNT, deadline, v, r, s);

        vm.expectRevert();
        vault.withdraw(AMOUNT, user1, user1);

        vm.stopPrank();
    }

    function testVaultRedeemPausedReverts() public {
        vault.pause();

        // Create permit signature for user1 to redeem their own shares
        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user1, user1, AMOUNT, shareToken.nonces(user1), deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPrivateKey, digest);

        vm.startPrank(user1);
        shareToken.permit(user1, user1, AMOUNT, deadline, v, r, s);

        vm.expectRevert();
        vault.redeem(AMOUNT, user1, user1);

        vm.stopPrank();
    }

    function testShareTokenBatchTransfersAllowedWhenPaused() public {
        shareToken.pause();

        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = AMOUNT / 2;

        vm.prank(validator);
        bool success = shareToken.batchTransfers(debtors, creditors, amounts);
        assertTrue(success, "BatchTransfers should be allowed by validator while paused");
    }

    function testOwnerFunctionsWorkWhenPaused() public {
        shareToken.pause();

        // Validator should be able to adjust rBalance even when paused
        uint256 timestamp = block.timestamp;
        vm.prank(validator);
        shareToken.adjustrBalance(user1, timestamp, 100 * 1e18, 110 * 1e18);

        // Verify the adjustment worked
        assertEq(shareToken.rBalanceOf(user1), 10 * 1e18, "rBalance adjustment should work when paused");

        // Validator should be able to cancel rBalance adjustment even when paused
        vm.prank(validator);
        shareToken.cancelrBalanceAdjustment(user1, timestamp);

        // Verify the cancellation worked
        assertEq(shareToken.rBalanceOf(user1), 0, "rBalance adjustment cancellation should work when paused");

        // Validator should be able to set KYC even when paused
        vm.prank(validator);
        shareToken.setKycVerified(user1, true);
        assertTrue(shareToken.isKycVerified(user1), "setKycVerified (validator) should work when paused");

        // Owner should be able to set validator even when paused
        address newValidator = makeAddr("newValidator");
        shareToken.setValidator(newValidator);
        assertEq(shareToken.getValidator(), newValidator, "setValidator should work when paused");
    }

    function testVaultOperationsWorkAfterUnpause() public {
        // Pause and then unpause
        vault.pause();
        vault.unpause();

        // Normal operations should work after unpause
        vm.startPrank(user1);
        token.approve(address(vault), AMOUNT);
        uint256 shares = vault.deposit(AMOUNT, user1);
        assertTrue(shares > 0, "Deposit should work after unpause");
        vm.stopPrank();
    }

    function testShareTokenOperationsWorkAfterUnpause() public {
        // Pause and then unpause
        shareToken.pause();
        shareToken.unpause();

        // BatchTransfers should work after unpause
        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = AMOUNT / 2;

        vm.prank(validator);
        bool success = shareToken.batchTransfers(debtors, creditors, amounts);
        assertTrue(success, "BatchTransfers should work after unpause");
    }

    function testPauseEmitsEvents() public {
        // Test vault pause events
        vm.expectEmit(true, true, true, true);
        emit Paused(owner);
        vault.pause();

        vm.expectEmit(true, true, true, true);
        emit Unpaused(owner);
        vault.unpause();

        // Test shareToken pause events
        vm.expectEmit(true, true, true, true);
        emit Paused(owner);
        shareToken.pause();

        vm.expectEmit(true, true, true, true);
        emit Unpaused(owner);
        shareToken.unpause();
    }

    // Events from OpenZeppelin Pausable
    event Paused(address account);
    event Unpaused(address account);
}
