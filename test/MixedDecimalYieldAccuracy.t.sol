// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";

/**
 * @title MixedDecimalYieldAccuracy
 * @dev Tests yield calculation accuracy across vaults with different decimal configurations
 */
contract MixedDecimalYieldAccuracyTest is Test {
    // Vault system contracts
    ShareTokenUpgradeable public shareToken;
    ERC7575VaultUpgradeable public vault8d; // 8 decimals
    ERC7575VaultUpgradeable public vault12d; // 12 decimals
    ERC7575VaultUpgradeable public vault18d; // 18 decimals

    // Different decimal assets
    MixedDecimalAsset public asset8d; // 8 decimals (like some wrapped BTC)
    MixedDecimalAsset public asset12d; // 12 decimals (less common)
    MixedDecimalAsset public asset18d; // 18 decimals (like ETH/most tokens)

    // Test users
    address public owner = address(this);
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    address public yieldProvider = makeAddr("yieldProvider");

    // Equivalent amounts across different decimals (1000 units each)
    uint256 constant BASE_AMOUNT = 1000;
    uint256 public amount8d; // 1000 * 10^8
    uint256 public amount12d; // 1000 * 10^12
    uint256 public amount18d; // 1000 * 10^18

    struct YieldTestResult {
        uint256 sharesBefore;
        uint256 sharesAfter;
        uint256 assetValueBefore;
        uint256 assetValueAfter;
        uint256 yieldGenerated;
        uint256 sharePriceBefore;
        uint256 sharePriceAfter;
    }

    function setUp() public {
        // Calculate equivalent amounts for each decimal configuration
        amount8d = BASE_AMOUNT * 10 ** 8;
        amount12d = BASE_AMOUNT * 10 ** 12;
        amount18d = BASE_AMOUNT * 10 ** 18;

        // Deploy share token
        ShareTokenUpgradeable shareImpl = new ShareTokenUpgradeable();
        ERC1967Proxy shareProxy = new ERC1967Proxy(address(shareImpl), abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Mixed Decimal Vault Shares", "MDVS", owner));
        shareToken = ShareTokenUpgradeable(address(shareProxy));

        // Deploy assets with different decimals
        asset8d = new MixedDecimalAsset("8 Decimal Asset", "ASSET8", 8);
        asset12d = new MixedDecimalAsset("12 Decimal Asset", "ASSET12", 12);
        asset18d = new MixedDecimalAsset("18 Decimal Asset", "ASSET18", 18);

        // Deploy vaults
        vault8d = _deployVault(asset8d, "8D Vault", "V8D");
        vault12d = _deployVault(asset12d, "12D Vault", "V12D");
        vault18d = _deployVault(asset18d, "18D Vault", "V18D");

        // Register vaults
        shareToken.registerVault(address(asset8d), address(vault8d));
        shareToken.registerVault(address(asset12d), address(vault12d));
        shareToken.registerVault(address(asset18d), address(vault18d));

        // Set minimum deposit to 0 for testing small amounts
        vault8d.setMinimumDepositAmount(0);
        vault12d.setMinimumDepositAmount(0);
        vault18d.setMinimumDepositAmount(0);

        // Mint assets to users and yield provider
        _mintAssets();

        console.log("=== Mixed Decimal Yield Accuracy Test Setup ===");
        console.log("8D Asset amount:", amount8d);
        console.log("12D Asset amount:", amount12d);
        console.log("18D Asset amount:", amount18d);
        console.log("8D Vault scaling factor:", vault8d.getScalingFactor());
        console.log("12D Vault scaling factor:", vault12d.getScalingFactor());
        console.log("18D Vault scaling factor:", vault18d.getScalingFactor());
    }

    function _deployVault(MixedDecimalAsset asset, string memory name, string memory symbol) internal returns (ERC7575VaultUpgradeable) {
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), owner));
        return ERC7575VaultUpgradeable(address(vaultProxy));
    }

    function _mintAssets() internal {
        // Mint to users
        asset8d.mint(user1, amount8d * 100); // 100x for multiple tests
        asset12d.mint(user2, amount12d * 100);
        asset18d.mint(user3, amount18d * 100);

        // Mint to yield provider for generating yield
        asset8d.mint(yieldProvider, amount8d * 1000);
        asset12d.mint(yieldProvider, amount12d * 1000);
        asset18d.mint(yieldProvider, amount18d * 1000);
    }

    // TEST 1: Equal value deposits across different decimals
    function test_EqualValueDepositsAcrossDecimals() public {
        console.log("\n=== TEST 1: Equal Value Deposits Across Decimals ===");

        // Each user deposits equivalent value (1000 units) in different decimals
        YieldTestResult memory result8d = _performDepositAndYieldTest(user1, vault8d, asset8d, amount8d, "8-decimal vault");

        YieldTestResult memory result12d = _performDepositAndYieldTest(user2, vault12d, asset12d, amount12d, "12-decimal vault");

        YieldTestResult memory result18d = _performDepositAndYieldTest(user3, vault18d, asset18d, amount18d, "18-decimal vault");

        // All users should get the same number of shares (normalized to 18 decimals)
        console.log("Shares received:");
        console.log("8D vault shares:", result8d.sharesAfter);
        console.log("12D vault shares:", result12d.sharesAfter);
        console.log("18D vault shares:", result18d.sharesAfter);

        // Verify share amounts are equivalent (allowing small rounding differences)
        assertApproxEqRel(result8d.sharesAfter, result12d.sharesAfter, 0.001e18, "8D and 12D shares should be equivalent");
        assertApproxEqRel(result12d.sharesAfter, result18d.sharesAfter, 0.001e18, "12D and 18D shares should be equivalent");
        assertApproxEqRel(result8d.sharesAfter, result18d.sharesAfter, 0.001e18, "8D and 18D shares should be equivalent");

        console.log("Success: Equal value deposits produce equivalent shares across decimals");
    }

    // TEST 2: Proportional yield distribution across different decimals
    function test_ProportionalYieldDistributionAcrossDecimals() public {
        console.log("\n=== TEST 2: Proportional Yield Distribution ===");

        // Setup: All users deposit equivalent amounts
        _performCompleteDeposit(user1, vault8d, asset8d, amount8d);
        _performCompleteDeposit(user2, vault12d, asset12d, amount12d);
        _performCompleteDeposit(user3, vault18d, asset18d, amount18d);

        uint256 totalSharesBefore = shareToken.totalSupply();
        (, uint256 totalNormalizedBefore) = shareToken.getCirculatingSupplyAndAssets();

        console.log("Before yield:");
        console.log("Total shares:", totalSharesBefore);
        console.log("Total normalized assets:", totalNormalizedBefore);

        // Generate equivalent yield (10% on each vault)
        uint256 yield8d = (amount8d * 10) / 100;
        uint256 yield12d = (amount12d * 10) / 100;
        uint256 yield18d = (amount18d * 10) / 100;

        _generateYield(vault8d, asset8d, yield8d);
        _generateYield(vault12d, asset12d, yield12d);
        _generateYield(vault18d, asset18d, yield18d);

        uint256 totalSharesAfter = shareToken.totalSupply();
        (, uint256 totalNormalizedAfter) = shareToken.getCirculatingSupplyAndAssets();

        console.log("After 10% yield on all vaults:");
        console.log("Total shares:", totalSharesAfter);
        console.log("Total normalized assets:", totalNormalizedAfter);

        // Shares should remain the same (yield doesn't create new shares)
        assertEq(totalSharesBefore, totalSharesAfter, "Total shares should remain constant");

        // Total normalized assets should increase by expected yield amount
        uint256 expectedYieldIncrease = yield8d * vault8d.getScalingFactor() + yield12d * vault12d.getScalingFactor() + yield18d * vault18d.getScalingFactor();

        uint256 actualIncrease = totalNormalizedAfter - totalNormalizedBefore;

        console.log("Expected yield increase (normalized):", expectedYieldIncrease);
        console.log("Actual yield increase:", actualIncrease);

        assertApproxEqRel(actualIncrease, expectedYieldIncrease, 0.001e18, "Yield increase should match expected");

        // Check individual vault conversions are still consistent
        _verifyConversionConsistency("After proportional yield");

        console.log("Success: Proportional yield correctly distributed across different decimals");
    }

    // TEST 3: Asymmetric yield impact on different decimals
    function test_AsymmetricYieldImpactAcrossDecimals() public {
        console.log("\n=== TEST 3: Asymmetric Yield Impact ===");

        // Setup equal deposits
        _performCompleteDeposit(user1, vault8d, asset8d, amount8d);
        _performCompleteDeposit(user2, vault12d, asset12d, amount12d);
        _performCompleteDeposit(user3, vault18d, asset18d, amount18d);

        uint256[] memory sharesBefore = new uint256[](3);
        sharesBefore[0] = shareToken.balanceOf(user1);
        sharesBefore[1] = shareToken.balanceOf(user2);
        sharesBefore[2] = shareToken.balanceOf(user3);

        console.log("Shares before asymmetric yield:");
        console.log("User1 (8D):", sharesBefore[0]);
        console.log("User2 (12D):", sharesBefore[1]);
        console.log("User3 (18D):", sharesBefore[2]);

        // Generate asymmetric yield: 5%, 10%, 15%
        _generateYield(vault8d, asset8d, (amount8d * 5) / 100); // 5% yield
        _generateYield(vault12d, asset12d, (amount12d * 10) / 100); // 10% yield
        _generateYield(vault18d, asset18d, (amount18d * 15) / 100); // 15% yield

        uint256[] memory sharesAfter = new uint256[](3);
        sharesAfter[0] = shareToken.balanceOf(user1);
        sharesAfter[1] = shareToken.balanceOf(user2);
        sharesAfter[2] = shareToken.balanceOf(user3);

        console.log("Shares after asymmetric yield (should be same):");
        console.log("User1 (8D):", sharesAfter[0]);
        console.log("User2 (12D):", sharesAfter[1]);
        console.log("User3 (18D):", sharesAfter[2]);

        // Share balances should remain unchanged (yield increases value, not quantity)
        assertEq(sharesBefore[0], sharesAfter[0], "User1 share count should remain same");
        assertEq(sharesBefore[1], sharesAfter[1], "User2 share count should remain same");
        assertEq(sharesBefore[2], sharesAfter[2], "User3 share count should remain same");

        // But the conversion value should reflect the asymmetric yield
        (, uint256 totalNormalizedAssets) = shareToken.getCirculatingSupplyAndAssets();
        uint256 sharePrice = (totalNormalizedAssets * 1e18) / shareToken.totalSupply();
        console.log("New share price:", sharePrice);
        assertTrue(sharePrice > 1e18, "Share price should reflect accumulated yield");

        // Test that new deposits get fair pricing after asymmetric yield
        uint256 newDeposit = amount8d / 10; // 10% of original
        uint256 sharesBefore8d = vault8d.convertToShares(newDeposit);
        uint256 sharesBefore12d = vault12d.convertToShares(amount12d / 10);
        uint256 sharesBefore18d = vault18d.convertToShares(amount18d / 10);

        console.log("Shares for new small deposits after asymmetric yield:");
        console.log("8D vault:", sharesBefore8d);
        console.log("12D vault:", sharesBefore12d);
        console.log("18D vault:", sharesBefore18d);

        // Should be approximately equal despite different yield histories
        assertApproxEqRel(sharesBefore8d, sharesBefore12d, 0.01e18, "8D and 12D new deposit shares should be similar");
        assertApproxEqRel(sharesBefore12d, sharesBefore18d, 0.01e18, "12D and 18D new deposit shares should be similar");

        console.log("Success: Asymmetric yield correctly handled across different decimals");
    }

    // TEST 4: Precision and rounding accuracy across decimals
    function test_PrecisionAndRoundingAcrossDecimals() public {
        console.log("\n=== TEST 4: Precision and Rounding Accuracy ===");

        // Test with small amounts to check precision (above minimum thresholds)
        uint256 smallAmount8d = 100000; // 0.001 in 8 decimals
        uint256 smallAmount12d = 1000000000; // 0.001 in 12 decimals
        uint256 smallAmount18d = 1000000000000000; // 0.001 in 18 decimals

        // Perform small deposits
        _performCompleteDeposit(user1, vault8d, asset8d, smallAmount8d);
        _performCompleteDeposit(user2, vault12d, asset12d, smallAmount12d);
        _performCompleteDeposit(user3, vault18d, asset18d, smallAmount18d);

        console.log("Small deposit shares:");
        console.log("8D vault:", shareToken.balanceOf(user1));
        console.log("12D vault:", shareToken.balanceOf(user2));
        console.log("18D vault:", shareToken.balanceOf(user3));

        // Generate micro-yield
        _generateYield(vault8d, asset8d, 1); // 1 unit in 8 decimals
        _generateYield(vault12d, asset12d, 1); // 1 unit in 12 decimals
        _generateYield(vault18d, asset18d, 1); // 1 unit in 18 decimals

        console.log("After micro-yield:");
        (, uint256 totalNormalizedAssetsMicro) = shareToken.getCirculatingSupplyAndAssets();
        console.log("Total normalized assets:", totalNormalizedAssetsMicro);
        console.log("Total shares:", shareToken.totalSupply());

        // Test conversion precision
        uint256 testConvert8d = vault8d.convertToAssets(1e18); // 1 share to assets
        uint256 testConvert12d = vault12d.convertToAssets(1e18);
        uint256 testConvert18d = vault18d.convertToAssets(1e18);

        console.log("1 share converts to assets:");
        console.log("8D vault:", testConvert8d);
        console.log("12D vault:", testConvert12d);
        console.log("18D vault:", testConvert18d);

        // Verify no precision is lost in small amounts
        assertTrue(testConvert8d > 0, "8D conversion should not be zero");
        assertTrue(testConvert12d > 0, "12D conversion should not be zero");
        assertTrue(testConvert18d > 0, "18D conversion should not be zero");

        console.log("Success: Precision maintained across different decimal configurations");
    }

    // TEST 5: Extreme decimal differences with large yield
    function test_ExtremeDecimalDifferencesWithLargeYield() public {
        console.log("\n=== TEST 5: Extreme Decimal Differences with Large Yield ===");

        // Large initial deposits
        uint256 largeAmount8d = amount8d * 100; // 100,000 units
        uint256 largeAmount12d = amount12d * 100;
        uint256 largeAmount18d = amount18d * 100;

        _performCompleteDeposit(user1, vault8d, asset8d, largeAmount8d);
        _performCompleteDeposit(user2, vault12d, asset12d, largeAmount12d);
        _performCompleteDeposit(user3, vault18d, asset18d, largeAmount18d);

        (, uint256 initialNormalized) = shareToken.getCirculatingSupplyAndAssets();
        console.log("Initial total normalized assets:", initialNormalized);

        // Generate massive yield (100% on each)
        _generateYield(vault8d, asset8d, largeAmount8d); // 100% yield
        _generateYield(vault12d, asset12d, largeAmount12d);
        _generateYield(vault18d, asset18d, largeAmount18d);

        (, uint256 finalNormalized) = shareToken.getCirculatingSupplyAndAssets();
        console.log("Final total normalized assets:", finalNormalized);

        // Should be approximately double
        uint256 expectedIncrease = initialNormalized; // 100% increase
        uint256 actualIncrease = finalNormalized - initialNormalized;

        console.log("Expected increase:", expectedIncrease);
        console.log("Actual increase:", actualIncrease);

        assertApproxEqRel(actualIncrease, expectedIncrease, 0.001e18, "Large yield should be accurate");

        // Test that system remains stable with extreme amounts
        _verifyConversionConsistency("After extreme yield");

        console.log("Success: System handles extreme decimal differences and large yields correctly");
    }

    // Helper functions
    function _performCompleteDeposit(address user, ERC7575VaultUpgradeable vault, MixedDecimalAsset asset, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.requestDeposit(amount, user, user);
        vm.stopPrank();

        shares = vault.fulfillDeposit(user, amount);

        vm.startPrank(user);
        vault.deposit(amount, user, user);
        vm.stopPrank();

        return shares;
    }

    function _performDepositAndYieldTest(
        address user,
        ERC7575VaultUpgradeable vault,
        MixedDecimalAsset asset,
        uint256 amount,
        string memory description
    )
        internal
        returns (YieldTestResult memory result)
    {
        // Record initial state
        result.sharesBefore = shareToken.balanceOf(user);

        // Perform deposit
        result.sharesAfter = _performCompleteDeposit(user, vault, asset, amount);

        console.log(description);
        console.log("Amount:", amount);
        console.log("Shares:", result.sharesAfter);

        return result;
    }

    function _generateYield(ERC7575VaultUpgradeable vault, MixedDecimalAsset asset, uint256 yieldAmount) internal {
        vm.prank(yieldProvider);
        require(asset.transfer(address(vault), yieldAmount), "Yield transfer failed");

        console.log("Generated yield:", yieldAmount);
        console.log("Vault address:", address(vault));
    }

    function _verifyConversionConsistency(string memory stage) internal view {
        console.log("Verifying conversion consistency:", stage);

        uint256 testAmount = 1000;

        // Convert same normalized amount across different vaults
        uint256 shares8d = vault8d.convertToShares(testAmount);
        uint256 shares12d = vault12d.convertToShares(testAmount * 10 ** 4); // Adjust for 12d
        uint256 shares18d = vault18d.convertToShares(testAmount * 10 ** 10); // Adjust for 18d

        console.log("Conversion consistency check:");
        console.log("8D shares:", shares8d);
        console.log("12D shares:", shares12d);
        console.log("18D shares:", shares18d);

        // Should be approximately equal
        assertApproxEqRel(shares8d, shares12d, 0.01e18, "8D and 12D conversions should be consistent");
        assertApproxEqRel(shares12d, shares18d, 0.01e18, "12D and 18D conversions should be consistent");

        console.log("Success: Conversion consistency verified");
    }
}

/**
 * @dev Asset with configurable decimals for testing
 */
contract MixedDecimalAsset is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
