// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";

/**
 * @title MultiStablecoinYieldScenarios
 * @dev Comprehensive test suite for multi-stablecoin vault system with yield scenarios
 */
contract MultiStablecoinYieldScenariosTest is Test {
    // Vault system contracts
    ShareTokenUpgradeable public shareToken;
    ERC7575VaultUpgradeable public usdcVault;
    ERC7575VaultUpgradeable public usdtVault;
    ERC7575VaultUpgradeable public daiVault;

    // Stablecoin contracts
    MockStablecoin public usdc; // 6 decimals
    MockStablecoin public usdt; // 6 decimals
    MockStablecoin public dai; // 18 decimals

    // Test users
    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public yieldGenerator = makeAddr("yieldGenerator");

    // Test amounts (normalized to respective decimals)
    uint256 constant USDC_AMOUNT = 10000 * 10 ** 6; // 10,000 USDC
    uint256 constant USDT_AMOUNT = 15000 * 10 ** 6; // 15,000 USDT
    uint256 constant DAI_AMOUNT = 20000 * 10 ** 18; // 20,000 DAI

    event YieldGenerated(address indexed vault, uint256 yieldAmount, uint256 newTotalAssets);
    event SharePriceUpdated(address indexed vault, uint256 newSharePrice);

    function setUp() public {
        // Deploy share token
        ShareTokenUpgradeable shareImpl = new ShareTokenUpgradeable();
        ERC1967Proxy shareProxy = new ERC1967Proxy(address(shareImpl), abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Multi-Stablecoin Vault Shares", "MSVS", owner));
        shareToken = ShareTokenUpgradeable(address(shareProxy));

        // Deploy stablecoins
        usdc = new MockStablecoin("USD Coin", "USDC", 6);
        usdt = new MockStablecoin("Tether USD", "USDT", 6);
        dai = new MockStablecoin("Dai Stablecoin", "DAI", 18);

        // Deploy vaults
        usdcVault = _deployVault(usdc, "USDC Vault", "vUSDC");
        usdtVault = _deployVault(usdt, "USDT Vault", "vUSDT");
        daiVault = _deployVault(dai, "DAI Vault", "vDAI");

        // Register vaults in share token
        shareToken.registerVault(address(usdc), address(usdcVault));
        shareToken.registerVault(address(usdt), address(usdtVault));
        shareToken.registerVault(address(dai), address(daiVault));

        // Mint tokens to users
        _mintTokensToUsers();

        console.log("=== Multi-Stablecoin Vault System Setup Complete ===");
        console.log("USDC Vault:", address(usdcVault));
        console.log("USDT Vault:", address(usdtVault));
        console.log("DAI Vault:", address(daiVault));
        console.log("Shared Token:", address(shareToken));
    }

    function _deployVault(MockStablecoin asset, string memory name, string memory symbol) internal returns (ERC7575VaultUpgradeable) {
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), owner));
        return ERC7575VaultUpgradeable(address(vaultProxy));
    }

    function _mintTokensToUsers() internal {
        // Mint generous amounts to users
        usdc.mint(alice, 1000000 * 10 ** 6); // 1M USDC
        usdc.mint(bob, 1000000 * 10 ** 6); // 1M USDC
        usdc.mint(charlie, 1000000 * 10 ** 6); // 1M USDC

        usdt.mint(alice, 1000000 * 10 ** 6); // 1M USDT
        usdt.mint(bob, 1000000 * 10 ** 6); // 1M USDT
        usdt.mint(charlie, 1000000 * 10 ** 6); // 1M USDT

        dai.mint(alice, 1000000 * 10 ** 18); // 1M DAI
        dai.mint(bob, 1000000 * 10 ** 18); // 1M DAI
        dai.mint(charlie, 1000000 * 10 ** 18); // 1M DAI

        // Mint to yield generator for creating yield
        usdc.mint(yieldGenerator, 10000000 * 10 ** 6); // 10M USDC
        usdt.mint(yieldGenerator, 10000000 * 10 ** 6); // 10M USDT
        dai.mint(yieldGenerator, 10000000 * 10 ** 18); // 10M DAI
    }

    // SCENARIO 1: Sequential deposits across different vaults
    function test_Scenario1_SequentialDepositsAcrossVaults() public {
        console.log("\n=== SCENARIO 1: Sequential Deposits Across Vaults ===");

        // Step 1: Alice deposits USDC
        console.log("Step 1: Alice deposits 10,000 USDC");
        _performCompleteDeposit(alice, usdcVault, usdc, USDC_AMOUNT);
        _logVaultStates("After Alice USDC deposit");

        // Step 2: Generate yield on USDC vault
        console.log("Step 2: Generate 5% yield on USDC vault");
        uint256 usdcYield = (USDC_AMOUNT * 5) / 100; // 5% yield
        _generateYield(usdcVault, usdc, usdcYield);
        _logVaultStates("After USDC yield generation");

        // Step 3: Bob deposits USDT
        console.log("Step 3: Bob deposits 15,000 USDT");
        _performCompleteDeposit(bob, usdtVault, usdt, USDT_AMOUNT);
        _logVaultStates("After Bob USDT deposit");

        // Step 4: Charlie deposits DAI
        console.log("Step 4: Charlie deposits 20,000 DAI");
        _performCompleteDeposit(charlie, daiVault, dai, DAI_AMOUNT);
        _logVaultStates("After Charlie DAI deposit");

        // Step 5: Generate yield across all vaults
        console.log("Step 5: Generate yield across all vaults");
        uint256 usdtYield = (USDT_AMOUNT * 3) / 100; // 3% yield
        uint256 daiYield = (DAI_AMOUNT * 7) / 100; // 7% yield

        _generateYield(usdcVault, usdc, (USDC_AMOUNT * 2) / 100); // Additional 2%
        _generateYield(usdtVault, usdt, usdtYield);
        _generateYield(daiVault, dai, daiYield);
        _logVaultStates("After yield generation on all vaults");

        // Verify share consistency
        _verifyShareConsistency("Scenario 1 Final");
    }

    // SCENARIO 2: Simultaneous deposits then differential yield
    function test_Scenario2_SimultaneousDepositsWithDifferentialYield() public {
        console.log("\n=== SCENARIO 2: Simultaneous Deposits with Differential Yield ===");

        // Step 1: All users deposit simultaneously
        console.log("Step 1: All users deposit simultaneously");
        _performCompleteDeposit(alice, usdcVault, usdc, USDC_AMOUNT);
        _performCompleteDeposit(bob, usdtVault, usdt, USDT_AMOUNT);
        _performCompleteDeposit(charlie, daiVault, dai, DAI_AMOUNT);
        _logVaultStates("After simultaneous deposits");

        // Step 2: Create differential yield scenarios
        console.log("Step 2: Create differential yield - USDC high, USDT medium, DAI low");
        _generateYield(usdcVault, usdc, (USDC_AMOUNT * 10) / 100); // 10% yield
        _generateYield(usdtVault, usdt, (USDT_AMOUNT * 5) / 100); // 5% yield
        _generateYield(daiVault, dai, (DAI_AMOUNT * 2) / 100); // 2% yield
        _logVaultStates("After differential yield");

        // Step 3: Second round of deposits to test yield impact on new deposits
        console.log("Step 3: Second round of deposits after yield");
        uint256 secondDepositAmount = USDC_AMOUNT / 2; // 5,000 USDC equivalent

        _performCompleteDeposit(alice, usdcVault, usdc, secondDepositAmount);
        _performCompleteDeposit(bob, usdtVault, usdt, secondDepositAmount);
        _performCompleteDeposit(charlie, daiVault, dai, secondDepositAmount * (10 ** 18 / 10 ** 6)); // Convert to DAI decimals
        _logVaultStates("After second round deposits");

        _verifyShareConsistency("Scenario 2 Final");
    }

    // SCENARIO 3: Cross-vault arbitrage and yield sharing
    function test_Scenario3_CrossVaultArbitrageAndYieldSharing() public {
        console.log("\n=== SCENARIO 3: Cross-Vault Arbitrage and Yield Sharing ===");

        // Step 1: Alice deposits across multiple vaults
        console.log("Step 1: Alice diversifies across all vaults");
        _performCompleteDeposit(alice, usdcVault, usdc, USDC_AMOUNT / 3);
        _performCompleteDeposit(alice, usdtVault, usdt, USDT_AMOUNT / 3);
        _performCompleteDeposit(alice, daiVault, dai, DAI_AMOUNT / 3);

        uint256 aliceSharesBefore = shareToken.balanceOf(alice);
        _logVaultStates("After Alice diversified deposits");

        // Step 2: Bob concentrates in one vault
        console.log("Step 2: Bob concentrates in USDT vault");
        _performCompleteDeposit(bob, usdtVault, usdt, USDT_AMOUNT);

        uint256 bobSharesBefore = shareToken.balanceOf(bob);
        _logVaultStates("After Bob concentrated deposit");

        // Step 3: Generate asymmetric yield
        console.log("Step 3: Generate asymmetric yield - DAI outperforms");
        _generateYield(usdcVault, usdc, (USDC_AMOUNT * 1) / 300); // ~0.33% on Alice's portion
        _generateYield(usdtVault, usdt, (USDT_AMOUNT * 2) / 100); // 2% on full amount
        _generateYield(daiVault, dai, (DAI_AMOUNT * 15) / 300); // ~5% on Alice's portion

        _logVaultStates("After asymmetric yield");

        // Step 4: Verify yield distribution is fair
        uint256 aliceSharesAfter = shareToken.balanceOf(alice);
        uint256 bobSharesAfter = shareToken.balanceOf(bob);

        console.log("Alice shares before:", aliceSharesBefore);
        console.log("Alice shares after:", aliceSharesAfter);
        console.log("Bob shares before:", bobSharesBefore);
        console.log("Bob shares after:", bobSharesAfter);

        // Alice and Bob should benefit proportionally from the shared yield
        assertTrue(aliceSharesAfter == aliceSharesBefore, "Alice shares should remain constant (she owns them)");
        assertTrue(bobSharesAfter == bobSharesBefore, "Bob shares should remain constant (he owns them)");

        // But the value of shares should have increased due to yield
        _verifyYieldImpactOnShares();
    }

    // SCENARIO 4: Stress test with rapid yield changes
    function test_Scenario4_StressTestRapidYieldChanges() public {
        console.log("\n=== SCENARIO 4: Stress Test with Rapid Yield Changes ===");

        // Initial deposits
        _performCompleteDeposit(alice, usdcVault, usdc, USDC_AMOUNT);
        _performCompleteDeposit(bob, usdtVault, usdt, USDT_AMOUNT);
        _performCompleteDeposit(charlie, daiVault, dai, DAI_AMOUNT);

        // Rapid yield generation cycles
        for (uint256 i = 0; i < 5; i++) {
            console.log("Yield cycle", i + 1);

            // Random yield amounts (1-3%)
            uint256 usdcYieldRate = 1 + (i % 3); // 1%, 2%, or 3%
            uint256 usdtYieldRate = 1 + ((i + 1) % 3);
            uint256 daiYieldRate = 1 + ((i + 2) % 3);

            _generateYield(usdcVault, usdc, (USDC_AMOUNT * usdcYieldRate) / 100);
            _generateYield(usdtVault, usdt, (USDT_AMOUNT * usdtYieldRate) / 100);
            _generateYield(daiVault, dai, (DAI_AMOUNT * daiYieldRate) / 100);

            if (i == 2) {
                // Mid-cycle deposits
                console.log("Mid-cycle deposits");
                _performCompleteDeposit(alice, daiVault, dai, DAI_AMOUNT / 4);
                _performCompleteDeposit(bob, usdcVault, usdc, USDC_AMOUNT / 4);
            }
        }

        _logVaultStates("After stress testing");
        _verifyShareConsistency("Scenario 4 Stress Test");
    }

    // SCENARIO 5: Large yield shock and recovery
    function test_Scenario5_LargeYieldShockAndRecovery() public {
        console.log("\n=== SCENARIO 5: Large Yield Shock and Recovery ===");

        // Initial balanced state
        _performCompleteDeposit(alice, usdcVault, usdc, USDC_AMOUNT);
        _performCompleteDeposit(bob, usdtVault, usdt, USDT_AMOUNT);
        _performCompleteDeposit(charlie, daiVault, dai, DAI_AMOUNT);

        (, uint256 initialTotalNormalized) = shareToken.getCirculatingSupplyAndAssets();
        console.log("Initial total normalized assets:", initialTotalNormalized);

        // Large yield shock (50% yield on DAI)
        console.log("Applying large yield shock - 50% yield on DAI vault");
        uint256 massiveYield = (DAI_AMOUNT * 50) / 100;
        _generateYield(daiVault, dai, massiveYield);

        (, uint256 afterShockNormalized) = shareToken.getCirculatingSupplyAndAssets();
        console.log("After shock normalized assets:", afterShockNormalized);

        // Verify the yield is properly reflected
        uint256 expectedIncrease = massiveYield; // DAI is already 18 decimals
        uint256 actualIncrease = afterShockNormalized - initialTotalNormalized;

        assertApproxEqRel(actualIncrease, expectedIncrease, 0.01e18, "Yield should be properly reflected");

        // New deposits after shock should get fair share prices
        console.log("New deposits after yield shock");
        _performCompleteDeposit(alice, daiVault, dai, DAI_AMOUNT / 10); // Small deposit

        _logVaultStates("After yield shock and new deposits");
        _verifyShareConsistency("Scenario 5 Yield Shock");
    }

    // Helper functions
    function _performCompleteDeposit(address user, ERC7575VaultUpgradeable vault, MockStablecoin asset, uint256 amount) internal {
        vm.startPrank(user);

        // Step 1: Request deposit
        asset.approve(address(vault), amount);
        uint256 requestId = vault.requestDeposit(amount, user, user);

        // Verify pending
        uint256 pending = vault.pendingDepositRequest(requestId, user);
        assertEq(pending, amount, "Pending amount should match requested");

        vm.stopPrank();

        // Step 2: Fulfill deposit (as vault owner)
        uint256 shares = vault.fulfillDeposit(user, amount);

        // Step 3: Claim deposit
        vm.startPrank(user);
        uint256 claimedShares = vault.deposit(amount, user, user);
        assertEq(claimedShares, shares, "Claimed shares should match fulfilled shares");
        vm.stopPrank();

        console.log("Completed deposit - amount:", amount, "shares:", shares);
    }

    function _generateYield(ERC7575VaultUpgradeable vault, MockStablecoin asset, uint256 yieldAmount) internal {
        // Transfer yield to vault to simulate yield generation
        vm.prank(yieldGenerator);
        require(asset.transfer(address(vault), yieldAmount), "Yield transfer failed");

        uint256 newTotalAssets = vault.totalAssets();
        emit YieldGenerated(address(vault), yieldAmount, newTotalAssets);

        console.log("Generated yield:", yieldAmount);
        console.log("New total assets:", newTotalAssets);
    }

    function _logVaultStates(string memory description) internal view {
        console.log("--- Vault States ---");
        console.log("Description:", description);

        (, uint256 totalNormalized) = shareToken.getCirculatingSupplyAndAssets();
        uint256 totalShares = shareToken.totalSupply();

        console.log("Total normalized assets:", totalNormalized);
        console.log("Total shares:", totalShares);

        if (totalShares > 0) {
            uint256 sharePrice = (totalNormalized * 1e18) / totalShares;
            console.log("Share price (18 decimals):", sharePrice);
        }

        console.log("USDC Vault assets:", usdcVault.totalAssets());
        console.log("USDT Vault assets:", usdtVault.totalAssets());
        console.log("DAI Vault assets:", daiVault.totalAssets());

        console.log("Alice shares:", shareToken.balanceOf(alice));
        console.log("Bob shares:", shareToken.balanceOf(bob));
        console.log("Charlie shares:", shareToken.balanceOf(charlie));
        console.log("---");
    }

    function _verifyShareConsistency(string memory scenarioName) internal view {
        console.log("=== Verifying Share Consistency ===");
        console.log("Scenario:", scenarioName);

        (, uint256 totalNormalized) = shareToken.getCirculatingSupplyAndAssets();
        uint256 totalShares = shareToken.totalSupply();

        // Verify individual vault contributions
        uint256 usdcNormalized = usdcVault.totalAssets() * usdcVault.getScalingFactor();
        uint256 usdtNormalized = usdtVault.totalAssets() * usdtVault.getScalingFactor();
        uint256 daiNormalized = daiVault.totalAssets() * daiVault.getScalingFactor();

        uint256 calculatedTotal = usdcNormalized + usdtNormalized + daiNormalized;

        console.log("USDC normalized:", usdcNormalized);
        console.log("USDT normalized:", usdtNormalized);
        console.log("DAI normalized:", daiNormalized);
        console.log("Calculated total:", calculatedTotal);
        console.log("ShareToken reported:", totalNormalized);

        assertEq(totalNormalized, calculatedTotal, "Total normalized assets should match sum of individual vaults");

        // Verify conversion consistency across vaults
        if (totalShares > 0) {
            uint256 testAmount = 1000;

            // Convert same normalized amount across different vaults - should give similar shares
            uint256 usdcShares = usdcVault.convertToShares(testAmount);
            uint256 usdtShares = usdtVault.convertToShares(testAmount);
            uint256 daiShares = daiVault.convertToShares(testAmount * (10 ** 18 / 10 ** 6));

            console.log("Conversion test - 1000 base units:");
            console.log("USDC shares:", usdcShares);
            console.log("USDT shares:", usdtShares);
            console.log("DAI shares (scaled):", daiShares);

            // Should be approximately equal (allowing for rounding)
            assertApproxEqRel(usdcShares, usdtShares, 0.01e18, "USDC/USDT conversion should be similar");
        }

        console.log("Share consistency verified successfully");
    }

    function _verifyYieldImpactOnShares() internal view {
        // Verify that yield increases the value of existing shares
        // rather than creating new shares
        (, uint256 totalNormalized) = shareToken.getCirculatingSupplyAndAssets();
        uint256 totalShares = shareToken.totalSupply();

        assertTrue(totalNormalized > 0, "Should have normalized assets");
        assertTrue(totalShares > 0, "Should have shares");

        // Share price should reflect accumulated yield
        uint256 sharePrice = (totalNormalized * 1e18) / totalShares;
        console.log("Current share price:", sharePrice);

        // Should be greater than 1.0 due to yield
        assertTrue(sharePrice > 1e18, "Share price should be > 1.0 due to yield");
    }
}

/**
 * @dev Mock stablecoin with configurable decimals
 */
contract MockStablecoin is ERC20 {
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
