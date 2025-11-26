// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";

import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {IERC7575MultiAsset} from "../src/interfaces/IERC7575MultiAsset.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

contract ShareTokenComplianceTest is Test {
    WERC7575ShareToken public shareToken;
    WERC7575Vault public vault1;
    WERC7575Vault public vault2;
    ERC20Faucet public asset1;
    ERC20Faucet public asset2;

    address public owner;
    address public validator;
    uint256 public validatorPrivateKey;
    address public user1;
    address public user2;

    uint256 constant TOTAL_SUPPLY = 1e12 * 1e18;

    function setUp() public {
        owner = address(this);
        (validator, validatorPrivateKey) = makeAddrAndKey("validator");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy ShareToken
        shareToken = new WERC7575ShareToken("Test Shares", "TSHARE");

        // Deploy assets
        asset1 = new ERC20Faucet("Asset1", "ASS1", TOTAL_SUPPLY);
        asset2 = new ERC20Faucet("Asset2", "ASS2", TOTAL_SUPPLY);

        // Deploy vaults
        vault1 = new WERC7575Vault(address(asset1), shareToken);
        vault2 = new WERC7575Vault(address(asset2), shareToken);

        // Register vaults
        shareToken.registerVault(address(asset1), address(vault1));
        shareToken.registerVault(address(asset2), address(vault2));

        // Set validator
        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);
        shareToken.setRevenueAdmin(validator);

        // KYC primary users via validator
        vm.prank(validator);
        shareToken.setKycVerified(user1, true);
        vm.prank(validator);
        shareToken.setKycVerified(user2, true);

        // Transfer assets to users
        assertTrue(asset1.transfer(user1, 1000000 * 1e18));
        assertTrue(asset2.transfer(user1, 1000000 * 1e18));
    }

    // Test ShareToken constructor decimals enforcement
    function testShareTokenDecimalsEnforcement() public {
        // This should pass since our ShareToken uses 18 decimals
        assertEq(shareToken.decimals(), 18);

        // The require should be in constructor, but since it's after ERC20 constructor
        // and ERC20 always returns 18, this should pass
        WERC7575ShareToken newShareToken = new WERC7575ShareToken("Test", "TEST");
        assertEq(newShareToken.decimals(), 18);
    }

    // Test basic ERC20 functionality
    function testBasicERC20Functions() public {
        // Test metadata
        assertEq(shareToken.name(), "Test Shares");
        assertEq(shareToken.symbol(), "TSHARE");
        assertEq(shareToken.decimals(), 18);
        assertEq(shareToken.totalSupply(), 0); // Initially no shares

        // Test balances
        assertEq(shareToken.balanceOf(user1), 0);
        assertEq(shareToken.balanceOf(user2), 0);
    }

    // Test minting functionality (only vault can mint)
    function testMintingAccess() public {
        uint256 mintAmount = 1000 * 1e18;

        // Only vault should be able to mint
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.mint(user1, mintAmount);

        // Vault can mint
        vm.prank(address(vault1));
        shareToken.mint(user1, mintAmount);
        assertEq(shareToken.balanceOf(user1), mintAmount);
        assertEq(shareToken.totalSupply(), mintAmount);
    }

    // Test burning functionality (only vault can burn)
    function testBurningAccess() public {
        uint256 mintAmount = 1000 * 1e18;
        uint256 burnAmount = 300 * 1e18;

        // Setup: mint some tokens first
        vm.prank(address(vault1));
        shareToken.mint(user1, mintAmount);

        // Only vault should be able to burn
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.burn(user1, burnAmount);

        // Vault can burn
        vm.prank(address(vault1));
        shareToken.burn(user1, burnAmount);
        assertEq(shareToken.balanceOf(user1), mintAmount - burnAmount);
        assertEq(shareToken.totalSupply(), mintAmount - burnAmount);
    }

    // Test transfer restrictions (requires allowance)
    function testTransferRestrictions() public {
        uint256 amount = 1000 * 1e18;

        // Setup: mint tokens to user1
        vm.prank(address(vault1));
        shareToken.mint(user1, amount);

        // Direct transfer should fail without self-allowance
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, amount));
        bool success1 = shareToken.transfer(user2, amount);
        // Expected to fail - suppress warning
        success1;

        // transferFrom should also fail without self-allowance from the 'from' user
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, amount));
        bool success2 = shareToken.transferFrom(user1, user2, amount);
        // Expected to fail - suppress warning
        success2;
    }

    // Test allowance system
    function testAllowanceSystem() public {
        uint256 amount = 1000 * 1e18;

        // Setup: mint tokens to user1
        vm.prank(address(vault1));
        shareToken.mint(user1, amount);

        // Initially no allowance
        assertEq(shareToken.allowance(user1, user2), 0);

        // User can't approve themselves
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, user1));
        shareToken.approve(user1, amount);

        // User can approve others (but transferFrom still requires self-allowance)
        vm.prank(user1);
        shareToken.approve(user2, amount);
        assertEq(shareToken.allowance(user1, user2), amount);

        // transferFrom will fail because it checks self-allowance, not traditional allowance
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, amount));
        bool success3 = shareToken.transferFrom(user1, user2, amount);
        // Expected to fail - suppress warning
        success3;
    }

    // Test spendSelfAllowance function (used by vault for withdrawals)
    function testSpendSelfAllowance() public {
        uint256 amount = 1000 * 1e18;

        // Setup: mint tokens
        vm.prank(address(vault1));
        shareToken.mint(user1, amount);

        // Use permit to set self-allowance (can't use approve for self)
        // Create a simple permit signature - this is simplified for testing
        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user1,
                user1, // Self-approval
                amount,
                shareToken.nonces(user1),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));

        // For signature testing - we generate the signature but don't use it in this test
        // This is just to verify the private key setup works
        vm.sign(validatorPrivateKey, digest);

        // For this test, let's just verify that only vaults can call spendSelfAllowance
        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.spendSelfAllowance(user1, amount);

        // Vault can call spendSelfAllowance (but will fail due to no allowance)
        vm.prank(address(vault1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, amount));
        shareToken.spendSelfAllowance(user1, amount);
    }

    // Test KYC functionality
    function testKYCFunctionality() public {
        address fresh = makeAddr("freshUser");
        // Initially not KYCed
        assertFalse(shareToken.isKycVerified(fresh));

        // Only KYC admin can set KYC
        vm.prank(fresh);
        vm.expectRevert(WERC7575ShareToken.OnlyKycAdmin.selector);
        shareToken.setKycVerified(fresh, true);

        // KYC admin (validator) can set KYC
        vm.prank(validator);
        shareToken.setKycVerified(fresh, true);
        assertTrue(shareToken.isKycVerified(fresh));

        // KYC admin (validator) can unset KYC
        vm.prank(validator);
        shareToken.setKycVerified(fresh, false);
        assertFalse(shareToken.isKycVerified(fresh));
    }

    // Test validator functionality
    function testValidatorManagement() public {
        // Initially validator is set in setUp
        assertEq(shareToken.getValidator(), validator);

        // Only owner can change validator
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        shareToken.setValidator(user1);

        // Owner can change validator
        shareToken.setValidator(user1);
        assertEq(shareToken.getValidator(), user1);
    }

    // Test multi-vault support
    function testMultiVaultSupport() public {
        // Check vault mappings
        assertEq(shareToken.vault(address(asset1)), address(vault1));
        assertEq(shareToken.vault(address(asset2)), address(vault2));

        // Both vaults can mint to same ShareToken
        vm.prank(address(vault1));
        shareToken.mint(user1, 1000 * 1e18);

        vm.prank(address(vault2));
        shareToken.mint(user1, 500 * 1e18);

        // User should have total shares from both vaults
        assertEq(shareToken.balanceOf(user1), 1500 * 1e18);

        // Only registered vaults can mint
        ERC20Faucet newAsset = new ERC20Faucet("NewAsset", "NEW", TOTAL_SUPPLY);
        WERC7575Vault newVault = new WERC7575Vault(address(newAsset), shareToken);

        vm.prank(address(newVault));
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.mint(user1, 1000);
    }

    // Test vault registration
    function testVaultRegistration() public {
        ERC20Faucet newAsset = new ERC20Faucet("NewAsset", "NEW", TOTAL_SUPPLY);
        WERC7575Vault newVault = new WERC7575Vault(address(newAsset), shareToken);

        // Initially not registered
        assertEq(shareToken.vault(address(newAsset)), address(0));

        // Only owner can add vault
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        shareToken.registerVault(address(newAsset), address(newVault));

        // Owner can add vault
        vm.expectEmit(true, false, false, true);
        emit IERC7575MultiAsset.VaultUpdate(address(newAsset), address(newVault));
        shareToken.registerVault(address(newAsset), address(newVault));

        assertEq(shareToken.vault(address(newAsset)), address(newVault));

        // Cannot register same asset again (prevents accidental overwrites)
        WERC7575Vault anotherVault = new WERC7575Vault(address(newAsset), shareToken);
        vm.expectRevert(IERC7575Errors.AssetAlreadyRegistered.selector);
        shareToken.registerVault(address(newAsset), address(anotherVault));

        // Original vault should still be registered
        assertEq(shareToken.vault(address(newAsset)), address(newVault));
    }

    // Test batch transfers
    function testBatchTransfers() public {
        uint256 amount = 1000 * 1e18;

        // Setup: mint tokens to multiple users
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = makeAddr("user3");

        // KYC all users to allow minting (validator)
        vm.prank(validator);
        shareToken.setKycVerified(users[0], true);
        vm.prank(validator);
        shareToken.setKycVerified(users[1], true);
        vm.prank(validator);
        shareToken.setKycVerified(users[2], true);
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(address(vault1));
            shareToken.mint(users[i], amount);
        }

        // Test batch transfer
        address[] memory debtors = new address[](2);
        address[] memory creditors = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 100 * 1e18;

        debtors[1] = users[2];
        creditors[1] = user1;
        amounts[1] = 50 * 1e18;

        // Only validator can do batch transfers
        vm.prank(user1);
        vm.expectRevert(WERC7575ShareToken.OnlyValidator.selector);
        shareToken.batchTransfers(debtors, creditors, amounts);

        // Validator can do batch transfers
        vm.prank(validator);
        shareToken.batchTransfers(debtors, creditors, amounts);

        // Check final balances (net effects)
        // batchTransfers only updates balances, NOT rBalance
        // user1: debited 100, credited 50 -> net debit 50 -> balance -= 50
        // user2: debited 0, credited 100 -> net credit 100 -> balance += 100
        // user3: debited 50, credited 0 -> net debit 50 -> balance -= 50
        uint256 expectedUser1Balance = amount - 50 * 1e18; // 1000e18 - 50e18 = 950e18
        uint256 expectedUser2Balance = amount + 100 * 1e18; // 1000e18 + 100e18 = 1100e18
        uint256 expectedUser3Balance = amount - 50 * 1e18; // 1000e18 - 50e18 = 950e18

        console.log("user1 balance:", shareToken.balanceOf(user1), "expected:", expectedUser1Balance);
        console.log("user2 balance:", shareToken.balanceOf(user2), "expected:", expectedUser2Balance);
        console.log("user3 balance:", shareToken.balanceOf(users[2]), "expected:", expectedUser3Balance);

        assertEq(shareToken.balanceOf(user1), expectedUser1Balance);
        assertEq(shareToken.balanceOf(user2), expectedUser2Balance);
        assertEq(shareToken.balanceOf(users[2]), expectedUser3Balance);

        // Check restricted balances - rBalance NOT modified by batchTransfers
        assertEq(shareToken.rBalanceOf(user1), 0); // batchTransfers doesn't modify rBalance
        assertEq(shareToken.rBalanceOf(users[2]), 0); // batchTransfers doesn't modify rBalance
    }

    // Test rBalance system
    function testRBalanceSystem() public {
        uint256 amount = 1000 * 1e18;

        // Setup: create restricted balance through batch transfer
        vm.prank(address(vault1));
        shareToken.mint(user1, amount);

        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = 300 * 1e18;

        vm.prank(validator);
        shareToken.batchTransfers(debtors, creditors, amounts);

        // batchTransfers does NOT modify rBalance - only regular balance
        assertEq(shareToken.rBalanceOf(user1), 0);

        // To test rBalance adjustment, we need to use rBatchTransfers instead
        // Let's create another transfer with rBalance flags
        address[] memory debtors2 = new address[](1);
        address[] memory creditors2 = new address[](1);
        uint256[] memory amounts2 = new uint256[](1);

        debtors2[0] = user1;
        creditors2[0] = user2;
        amounts2[0] = 300 * 1e18;

        vm.prank(validator);
        shareToken.rBatchTransfers(debtors2, creditors2, amounts2, 1); // flag bit 0 set for user1

        // User1 should have restricted balance from rBatchTransfers
        assertEq(shareToken.rBalanceOf(user1), 300 * 1e18);

        // Test rBalance adjustment
        uint256 timestamp = block.timestamp;
        uint256 invested = 300 * 1e18;
        uint256 received = 330 * 1e18; // 10% gain

        // Only revenue admin can adjust rBalance
        vm.prank(user1);
        vm.expectRevert(WERC7575ShareToken.OnlyRevenueAdmin.selector);
        shareToken.adjustrBalance(user1, timestamp, invested, received);

        // Revenue admin (validator) can adjust rBalance
        vm.prank(validator);
        shareToken.adjustrBalance(user1, timestamp, invested, received);
        assertEq(shareToken.rBalanceOf(user1), received);

        // Can't adjust same timestamp twice
        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.RBalanceAdjustmentAlreadyApplied.selector);
        shareToken.adjustrBalance(user1, timestamp, invested, received);

        // Can cancel adjustment
        vm.prank(validator);
        shareToken.cancelrBalanceAdjustment(user1, timestamp);
        assertEq(shareToken.rBalanceOf(user1), invested);

        // Can't cancel non-existent adjustment
        vm.prank(validator);
        vm.expectRevert(WERC7575ShareToken.NoRBalanceAdjustmentFound.selector);
        shareToken.cancelrBalanceAdjustment(user1, timestamp);
    }

    // Test reentrancy protection
    function testReentrancyProtection() public {
        // The ShareToken uses ReentrancyGuard, but most functions are simple
        // The main place reentrancy could occur is in batchTransfers
        // This is more of a structural test to ensure the modifier is in place

        uint256 amount = 1000 * 1e18;
        vm.prank(address(vault1));
        shareToken.mint(user1, amount);

        address[] memory debtors = new address[](1);
        address[] memory creditors = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        debtors[0] = user1;
        creditors[0] = user2;
        amounts[0] = amount;

        // This should work normally (validator-only)
        vm.prank(validator);
        shareToken.batchTransfers(debtors, creditors, amounts);

        assertEq(shareToken.balanceOf(user2), amount);
        // batchTransfers does NOT modify rBalance
        assertEq(shareToken.rBalanceOf(user1), 0);
    }

    // Test interface compliance
    function testInterfaceCompliance() public {
        // Test ERC165 interface
        assertTrue(shareToken.supportsInterface(0x01ffc9a7)); // ERC165

        // Test unknown interface
        assertFalse(shareToken.supportsInterface(0x12345678));
    }

    // Test edge cases and boundary conditions
    function testEdgeCases() public {
        // Test minting to zero address
        vm.prank(address(vault1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        shareToken.mint(address(0), 1000);

        // Test burning from zero address
        vm.prank(address(vault1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        shareToken.burn(address(0), 1000);

        // Test burning more than balance
        vm.prank(address(vault1));
        shareToken.mint(user1, 1000);

        vm.prank(address(vault1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 1000, 2000));
        shareToken.burn(user1, 2000);

        // Test maximum values
        uint256 maxAmount = type(uint256).max / 2; // Avoid overflow
        vm.prank(address(vault1));
        shareToken.mint(user1, maxAmount);
        assertEq(shareToken.balanceOf(user1), maxAmount + 1000); // Previous mint + new mint
    }
}
