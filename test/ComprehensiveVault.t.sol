// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";

import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockERC20 is ERC20 {
    uint8 private _customDecimals;

    constructor(string memory name, string memory symbol, uint8 decimals_, uint256 totalSupply) ERC20(name, symbol) {
        _customDecimals = decimals_;
        _mint(msg.sender, totalSupply);
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }
}

contract ComprehensiveVaultTest is Test {
    WERC7575Vault public vault;
    WERC7575ShareToken public shareToken;
    MockERC20 public token;

    address public owner;
    address public user1;
    address public user2;

    uint256 constant TOTAL_SUPPLY = 1e12 * 1e18; // Large supply for testing

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy ShareToken
        shareToken = new WERC7575ShareToken("Test Share", "TSHARE");

        // KYC common users to allow mint/burn during deposits in tests
        shareToken.setKycVerified(user1, true);
        shareToken.setKycVerified(user2, true);
    }

    function _deployVaultWithDecimals(uint8 decimals) internal returns (WERC7575Vault, MockERC20) {
        MockERC20 testToken = new MockERC20("TestToken", "TEST", decimals, TOTAL_SUPPLY);
        WERC7575Vault testVault = new WERC7575Vault(address(testToken), shareToken);
        shareToken.registerVault(address(testToken), address(testVault));

        // Transfer tokens to users
        assertTrue(testToken.transfer(user1, 1e9 * 10 ** decimals));
        assertTrue(testToken.transfer(user2, 1e9 * 10 ** decimals));

        return (testVault, testToken);
    }

    // Test constructor validations
    function testConstructorValidations() public {
        // Test valid asset decimals
        for (uint8 i = 6; i <= 18; i++) {
            MockERC20 validToken = new MockERC20("Valid", "VALID", i, 1000);
            WERC7575Vault validVault = new WERC7575Vault(address(validToken), shareToken);
            assertEq(validVault.asset(), address(validToken));
        }

        // Test invalid asset decimals (too low)
        MockERC20 invalidTokenLow = new MockERC20("Invalid", "INV", 5, 1000);
        vm.expectRevert(IERC7575Errors.UnsupportedAssetDecimals.selector);
        new WERC7575Vault(address(invalidTokenLow), shareToken);

        // Test invalid asset decimals (too high)
        MockERC20 invalidTokenHigh = new MockERC20("Invalid", "INV", 19, 1000);
        vm.expectRevert(IERC7575Errors.UnsupportedAssetDecimals.selector);
        new WERC7575Vault(address(invalidTokenHigh), shareToken);

        // Test zero address ShareToken
        MockERC20 testToken = new MockERC20("Valid", "VALID", 18, 1000);
        vm.expectRevert(IERC7575Errors.ZeroAddress.selector);
        new WERC7575Vault(address(testToken), WERC7575ShareToken(address(0)));
    }

    // Test ShareToken decimals enforcement
    function testShareTokenDecimalsEnforcement() public {
        // Create a mock ShareToken with wrong decimals
        MockERC20 wrongDecimalShareToken = new MockERC20("Wrong", "WRONG", 6, 1000);
        MockERC20 validAsset = new MockERC20("Asset", "ASSET", 18, 1000);

        // This should fail when we try to create the vault
        vm.expectRevert(IERC7575Errors.WrongDecimals.selector);
        new WERC7575Vault(address(validAsset), WERC7575ShareToken(address(wrongDecimalShareToken)));
    }

    // Test scaling factor calculations for different decimal combinations
    function testScalingFactorCalculations() public {
        uint8[5] memory testDecimals = [6, 8, 12, 16, 18];

        for (uint256 i = 0; i < testDecimals.length; i++) {
            (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(testDecimals[i]);

            uint256 testAmount = 1000 * 10 ** testDecimals[i]; // 1000 tokens
            uint256 expectedShares = testAmount * 10 ** (18 - testDecimals[i]); // Expected shares

            // Test convertToShares
            assertEq(testVault.convertToShares(testAmount), expectedShares, string(abi.encodePacked("convertToShares failed for ", vm.toString(testDecimals[i]), " decimals")));

            // Test convertToAssets (round trip)
            assertEq(testVault.convertToAssets(expectedShares), testAmount, string(abi.encodePacked("convertToAssets failed for ", vm.toString(testDecimals[i]), " decimals")));
        }
    }

    // Test preview functions with proper rounding
    function testPreviewFunctionsRounding() public {
        (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(6); // USDC-like

        uint256 assets = 1000000; // 1 USDC (6 decimals)
        uint256 shares = assets * 10 ** 12; // Expected shares (18 decimals)

        // previewDeposit uses Floor rounding (favors vault)
        assertEq(testVault.previewDeposit(assets), shares);

        // previewMint uses Ceil rounding (favors vault)
        assertEq(testVault.previewMint(shares), assets);

        // previewWithdraw uses Ceil rounding (favors vault)
        assertEq(testVault.previewWithdraw(assets), shares);

        // previewRedeem uses Floor rounding (favors vault)
        assertEq(testVault.previewRedeem(shares), assets);
    }

    // Test max functions
    function testMaxFunctions() public {
        (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(18);

        // maxDeposit should return max uint256
        assertEq(testVault.maxDeposit(user1), type(uint256).max);
        assertEq(testVault.maxDeposit(address(0)), type(uint256).max);

        // maxMint should return max uint256
        assertEq(testVault.maxMint(user1), type(uint256).max);
        assertEq(testVault.maxMint(address(0)), type(uint256).max);

        // Give user1 some shares first
        uint256 depositAmount = 1000 * 1e18;
        vm.startPrank(user1);
        testToken.approve(address(testVault), depositAmount);
        testVault.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 userShares = shareToken.balanceOf(user1);

        // maxWithdraw should return convertToAssets of user's balance
        assertEq(testVault.maxWithdraw(user1), testVault.convertToAssets(userShares));

        // maxRedeem should return user's share balance
        assertEq(testVault.maxRedeem(user1), userShares);

        // Empty user should return 0
        assertEq(testVault.maxWithdraw(user2), 0);
        assertEq(testVault.maxRedeem(user2), 0);
    }

    // Test deposit edge cases
    function testDepositEdgeCases() public {
        (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(6);

        // Test zero deposit
        vm.startPrank(user1);
        testToken.approve(address(testVault), 0);
        vm.expectRevert(IERC7575Errors.ZeroAssets.selector);
        testVault.deposit(0, user1);
        vm.stopPrank();

        // Test deposit to zero address
        vm.startPrank(user1);
        testToken.approve(address(testVault), 1000);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        testVault.deposit(1000, address(0));
        vm.stopPrank();

        // Test successful small deposit (1 unit)
        vm.startPrank(user1);
        testToken.approve(address(testVault), 1);
        uint256 shares = testVault.deposit(1, user1);
        assertEq(shares, 1 * 10 ** 12); // 1 * 10^(18-6)
        assertEq(shareToken.balanceOf(user1), 1 * 10 ** 12);
        vm.stopPrank();
    }

    // Test mint edge cases
    function testMintEdgeCases() public {
        (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(12);

        // Test zero mint (will revert with "Cannot deposit zero assets" since mint calls _deposit)
        vm.startPrank(user1);
        vm.expectRevert(IERC7575Errors.ZeroAssets.selector);
        testVault.mint(0, user1);
        vm.stopPrank();

        // Test mint to zero address
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        testVault.mint(1000, address(0));
        vm.stopPrank();

        // Test successful mint
        uint256 sharesToMint = 1000 * 1e18; // 1000 shares
        uint256 expectedAssets = sharesToMint / 10 ** 6; // 12 decimal asset needs 10^6 less

        vm.startPrank(user1);
        testToken.approve(address(testVault), expectedAssets);
        uint256 assetsUsed = testVault.mint(sharesToMint, user1);
        assertEq(assetsUsed, expectedAssets);
        assertEq(shareToken.balanceOf(user1), sharesToMint);
        vm.stopPrank();
    }

    // Test withdraw edge cases
    function testWithdrawEdgeCases() public {
        (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(18);

        // Setup: deposit first
        uint256 depositAmount = 1000 * 1e18;
        vm.startPrank(user1);
        testToken.approve(address(testVault), depositAmount);
        testVault.deposit(depositAmount, user1);
        vm.stopPrank();

        // Test zero withdraw
        vm.startPrank(user1);
        vm.expectRevert(IERC7575Errors.ZeroAssets.selector);
        testVault.withdraw(0, user1, user1);
        vm.stopPrank();

        // Test withdraw to zero address
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        testVault.withdraw(100, address(0), user1);
        vm.stopPrank();

        // Test withdraw from zero address owner
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        testVault.withdraw(100, user1, address(0));
        vm.stopPrank();

        // Test withdrawal without proper allowance should fail
        uint256 withdrawAmount = 100 * 1e18;

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user1, 0, withdrawAmount));
        testVault.withdraw(withdrawAmount, user1, user1);
        vm.stopPrank();
    }

    // Test totalAssets accuracy
    function testTotalAssetsAccuracy() public {
        (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(8);

        // Initially should be 0
        assertEq(testVault.totalAssets(), 0);

        // After deposits should equal vault balance
        uint256 deposit1 = 500 * 10 ** 8;
        uint256 deposit2 = 300 * 10 ** 8;

        vm.startPrank(user1);
        testToken.approve(address(testVault), deposit1);
        testVault.deposit(deposit1, user1);
        vm.stopPrank();

        assertEq(testVault.totalAssets(), deposit1);

        vm.startPrank(user2);
        testToken.approve(address(testVault), deposit2);
        testVault.deposit(deposit2, user2);
        vm.stopPrank();

        assertEq(testVault.totalAssets(), deposit1 + deposit2);
        assertEq(testVault.totalAssets(), testToken.balanceOf(address(testVault)));
    }

    // Test precision and round-trip conversion accuracy
    function testPrecisionAccuracy() public {
        uint8[4] memory testDecimals = [6, 8, 12, 18];

        for (uint256 i = 0; i < testDecimals.length; i++) {
            (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(testDecimals[i]);

            // Test various amounts for round-trip accuracy
            uint256[5] memory testAmounts = [
                1 * 10 ** testDecimals[i], // 1 token
                123456 * 10 ** testDecimals[i], // Random amount
                999999999 * 10 ** testDecimals[i], // Large amount
                1, // Minimum unit
                type(uint128).max / 10 ** 20 // Very large but safe
            ];

            for (uint256 j = 0; j < testAmounts.length; j++) {
                if (testAmounts[j] == 0) continue;

                uint256 assets = testAmounts[j];
                uint256 shares = testVault.convertToShares(assets);
                uint256 backToAssets = testVault.convertToAssets(shares);

                assertEq(backToAssets, assets, string(abi.encodePacked("Round-trip failed for ", vm.toString(testDecimals[i]), " decimals, amount ", vm.toString(assets))));
            }
        }
    }

    // Test multi-vault architecture
    function testMultiVaultArchitecture() public {
        // Create multiple assets with different decimals for purpose of the test,
        // assets will be equal to each other
        (WERC7575Vault vault1, MockERC20 token1) = _deployVaultWithDecimals(6); // USDC-like
        (WERC7575Vault vault2, MockERC20 token2) = _deployVaultWithDecimals(8); // WBTC-like
        (WERC7575Vault vault3, MockERC20 token3) = _deployVaultWithDecimals(18); // ETH-like

        // All should use the same ShareToken
        assertEq(vault1.share(), vault2.share());
        assertEq(vault2.share(), vault3.share());
        assertEq(vault3.share(), address(shareToken));

        // Test cross-vault operations
        uint256 amount1 = 1000 * 10 ** 6; // 1000 USDC
        uint256 amount2 = 1000 * 10 ** 8; // 1000 WBTC units
        uint256 amount3 = 1000 * 10 ** 18; // 1000 ETH

        // Deposit into all three vaults
        vm.startPrank(user1);
        token1.approve(address(vault1), amount1);
        uint256 shares1 = vault1.deposit(amount1, user1);

        token2.approve(address(vault2), amount2);
        uint256 shares2 = vault2.deposit(amount2, user1);

        token3.approve(address(vault3), amount3);
        uint256 shares3 = vault3.deposit(amount3, user1);
        vm.stopPrank();

        // User should have shares from all deposits in single ShareToken
        uint256 totalShares = shareToken.balanceOf(user1);
        assertEq(totalShares, shares1 + shares2 + shares3);

        // Verify scaling worked correctly
        assertEq(shares1, amount1 * 10 ** 12); // 6→18 decimals: *10^12
        assertEq(shares2, amount2 * 10 ** 10); // 8→18 decimals: *10^10
        assertEq(shares3, amount3 * 1); // 18→18 decimals: *1
    }

    // Test interface compliance
    function testInterfaceCompliance() public {
        (WERC7575Vault testVault,) = _deployVaultWithDecimals(18);

        // Test ERC7575 interface
        assertTrue(testVault.supportsInterface(0x2f0a18c5));

        // Test ERC165 interface
        assertTrue(testVault.supportsInterface(0x01ffc9a7));

        // Test unknown interface
        assertFalse(testVault.supportsInterface(0x12345678));
    }

    // Test gas usage optimization
    function testGasOptimizations() public {
        (WERC7575Vault testVault, MockERC20 testToken) = _deployVaultWithDecimals(6);

        uint256 testAmount = 1000 * 10 ** 6;

        // Test that precomputed scaling factor reduces gas
        uint256 gasBefore = gasleft();
        testVault.convertToShares(testAmount);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be relatively low since no computation needed
        assertTrue(gasUsed < 5000, "convertToShares using too much gas");

        gasBefore = gasleft();
        testVault.convertToAssets(testAmount * 10 ** 12);
        gasUsed = gasBefore - gasleft();

        assertTrue(gasUsed < 5000, "convertToAssets using too much gas");
    }
}
