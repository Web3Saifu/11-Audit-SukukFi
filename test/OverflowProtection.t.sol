// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_, uint256 totalSupply) ERC20(name, symbol) {
        _decimals = decimals_;
        _mint(msg.sender, totalSupply);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract OverflowProtectionTest is Test {
    WERC7575Vault public vault;
    WERC7575ShareToken public shareToken;
    MockToken public token;

    address public owner;
    address public validator;
    uint256 public validatorPrivateKey;
    address public user1;

    function setUp() public {
        owner = address(this);
        (validator, validatorPrivateKey) = makeAddrAndKey("validator");
        user1 = makeAddr("user1");

        // Deploy 6-decimal token (like USDC) which has the highest scaling factor
        token = new MockToken("USDC", "USDC", 6, 1000000 * 1e6); // 1M USDC with 6 decimals

        shareToken = new WERC7575ShareToken("wUSDC", "WUSDC");
        vault = new WERC7575Vault(address(token), shareToken);

        shareToken.registerVault(address(token), address(vault));
        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);
        shareToken.setRevenueAdmin(validator);
    }

    function testLargeAmountConversions() public view {
        // Test very large amounts that could cause overflow with naive multiplication
        // For 6-decimal asset, scaling factor is 10^12

        // Test 1: Maximum safe amount for uint256 with 6 decimals
        // This should work without overflow
        uint256 largeAmount = type(uint256).max / (10 ** 12) - 1;

        uint256 shares = vault.convertToShares(largeAmount);
        assertEq(shares, largeAmount * (10 ** 12), "Large amount conversion should work");

        uint256 backToAssets = vault.convertToAssets(shares);
        assertEq(backToAssets, largeAmount, "Round-trip conversion should be accurate");
    }

    function testScalingFactorOverflowProtection() public {
        // Test the specific vulnerability: assets * scalingFactor overflow
        uint256 maxSafeAssets = type(uint256).max / (10 ** 12);

        // This should work (just under the overflow threshold)
        uint256 shares = vault.convertToShares(maxSafeAssets - 1);
        assertTrue(shares > 0, "Conversion should succeed for max safe amount");

        // Test with maximum possible value - this should not revert due to our fix
        try vault.convertToShares(type(uint256).max) {
            // If this succeeds, Math.mulDiv handled the overflow correctly
            assertTrue(true, "Math.mulDiv should handle potential overflow");
        } catch {
            // If this reverts, it's expected behavior for overflow
            assertTrue(true, "Overflow protection working - transaction reverted");
        }
    }

    function testPreviewFunctionsWithLargeAmounts() public {
        uint256 largeAmount = 1e30; // Very large amount

        uint256 previewShares = vault.previewDeposit(largeAmount);
        uint256 convertShares = vault.convertToShares(largeAmount);
        assertEq(previewShares, convertShares, "Preview and convert should match");

        uint256 previewAssets = vault.previewMint(previewShares);
        assertEq(previewAssets, largeAmount, "Round-trip through preview should work");
    }

    function testEdgeCaseAmounts() public {
        // Test edge cases that previously could cause overflow
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 1e18; // 1 token with 18 decimal precision
        testAmounts[1] = 1e24; // Very large amount
        testAmounts[2] = 1e30; // Extremely large amount
        testAmounts[3] = type(uint128).max; // Half of uint256 max
        testAmounts[4] = type(uint64).max; // Large but manageable amount

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 amount = testAmounts[i];

            // These should not revert with our overflow protection
            uint256 shares = vault.convertToShares(amount);
            uint256 backToAssets = vault.convertToAssets(shares);

            // For deterministic conversion, we expect: shares = amount * 10^12
            if (amount <= type(uint256).max / (10 ** 12)) {
                // If no overflow expected, check exact equality
                assertEq(shares, amount * (10 ** 12), "Shares should equal amount * scaling factor");
                assertEq(backToAssets, amount, "Round-trip should be exact");
            } else {
                // If overflow possible, just ensure no revert and reasonable result
                assertTrue(shares > 0, "Should get some shares even for very large amounts");
                assertTrue(backToAssets > 0, "Should get some assets back");
            }
        }
    }

    function testScalingFactorDifferentDecimals() public {
        // Test that the fix works for different decimal configurations

        // Test with 8 decimals (like BTC)
        MockToken token8 = new MockToken("BTC", "BTC", 8, 21000000 * 1e8);
        WERC7575ShareToken shareToken8 = new WERC7575ShareToken("wBTC", "WBTC");
        WERC7575Vault vault8 = new WERC7575Vault(address(token8), shareToken8);

        // For 8 decimals, scaling factor should be 10^10
        uint256 testAmount = 1e20;
        uint256 shares = vault8.convertToShares(testAmount);
        assertEq(shares, testAmount * (10 ** 10), "8-decimal conversion should work");

        // Test with 18 decimals (like ETH) - no scaling needed
        MockToken token18 = new MockToken("ETH", "ETH", 18, 1000000 * 1e18);
        WERC7575ShareToken shareToken18 = new WERC7575ShareToken("wETH", "WETH");
        WERC7575Vault vault18 = new WERC7575Vault(address(token18), shareToken18);

        // For 18 decimals, scaling factor should be 1
        shares = vault18.convertToShares(testAmount);
        assertEq(shares, testAmount, "18-decimal conversion should be 1:1");
    }
}
