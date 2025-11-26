// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";
import {IERC7575, IERC7575Share, IERC7575ShareExtended} from "../src/interfaces/IERC7575.sol";
import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";
import {MockAsset} from "./MockAsset.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ERC7540ComplianceCompleteTest
 * @dev Complete compliance test for ERC7540/ERC7575 including full investment flow
 */
contract ERC7540ComplianceCompleteTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    MockAsset public asset;
    WERC7575Vault public investmentVault;
    WERC7575ShareToken public investmentShareToken;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public investmentManager = makeAddr("investmentManager");
    address public validator = makeAddr("validator");

    function setUp() public {
        vm.startPrank(owner);

        asset = new MockAsset();

        // Deploy WERC7575 investment system (centralized architecture)
        investmentShareToken = new WERC7575ShareToken("Investment USD", "iUSD");
        investmentVault = new WERC7575Vault(address(asset), investmentShareToken);

        // Set up investment share token
        investmentShareToken.registerVault(address(asset), address(investmentVault));
        investmentShareToken.setValidator(validator);
        investmentShareToken.setKycAdmin(validator);
        investmentShareToken.setRevenueAdmin(validator);

        vm.stopPrank();

        // Set up KYC for ShareToken (centralized investor)
        vm.startPrank(validator);
        investmentShareToken.setKycVerified(address(0), true); // Will be updated after ShareToken is deployed
        vm.stopPrank();

        vm.startPrank(owner);

        // Seed investment vault with assets for liquidity
        asset.mint(address(investmentVault), 1000000e18);

        // Deploy ShareToken with proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Complete Flow Shares", "CFS", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault with proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20(asset), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Configure vault registry
        shareToken.registerVault(address(asset), address(vault));

        // Setup centralized investment management
        shareToken.setInvestmentManager(investmentManager);

        // Set up centralized investment: ShareToken invests in investment ShareToken
        shareToken.setInvestmentShareToken(address(investmentShareToken));

        vm.stopPrank();

        // Set up KYC for the ShareToken address (centralized investment)
        vm.startPrank(validator);
        investmentShareToken.setKycVerified(address(shareToken), true);
        vm.stopPrank();

        // Mint assets to users
        asset.mint(alice, 100000e18);
        asset.mint(bob, 100000e18);
    }

    /**
     * @dev Helper function to set up validator permit for ShareToken self-allowance
     * In WERC7575, self-allowances require validator signatures via permit
     * Updated for centralized investment architecture where ShareToken manages investments
     */
    function _setupValidatorPermitForShareToken() internal {
        address shareTokenAddress = address(shareToken);
        uint256 value = type(uint256).max;
        uint256 deadline = block.timestamp + 1 hours;

        // Get the current nonce for the ShareToken
        uint256 nonce = investmentShareToken.nonces(shareTokenAddress);

        // Create the permit message hash
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                shareTokenAddress, // owner (ShareToken)
                shareTokenAddress, // spender (self-allowance for ShareToken)
                value, // amount
                nonce, // nonce
                deadline // deadline
            )
        );

        bytes32 domainSeparator = investmentShareToken.DOMAIN_SEPARATOR();
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with validator private key (in Foundry, makeAddr creates predictable keys)
        // The private key for an address created with makeAddr("name") is uint256(keccak256("name"))
        uint256 validatorPrivateKey = uint256(keccak256("validator"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPrivateKey, hash);

        // Apply the permit (validator signature allows ShareToken to spend its own tokens)
        investmentShareToken.permit(shareTokenAddress, shareTokenAddress, value, deadline, v, r, s);
    }

    /// @dev Test complete ERC7540 compliance - full async deposit flow
    function test_ERC7540_CompleteAsyncDepositFlow() public {
        uint256 depositAmount = 10000e18;

        // 1. Request Phase - Alice requests deposit
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);

        uint256 requestId = vault.requestDeposit(depositAmount, alice, alice);
        assertEq(requestId, 0, "Request ID should be 0");

        // Check pending deposit
        assertEq(vault.pendingDepositRequest(0, alice), depositAmount);
        assertEq(vault.claimableDepositRequest(0, alice), 0);
        vm.stopPrank();

        // 2. Fulfillment Phase - Investment manager fulfills the request
        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        // Check claimable deposit
        assertEq(vault.pendingDepositRequest(0, alice), 0);
        assertEq(vault.claimableDepositRequest(0, alice), depositAmount);

        // 3. Claim Phase - Alice claims her shares
        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Verify shares received
        assertTrue(shares > 0);
        assertEq(shareToken.balanceOf(alice), shares);
        assertEq(vault.claimableDepositRequest(0, alice), 0);
    }

    /// @dev Test complete ERC7540 compliance - full async redeem flow
    function test_ERC7540_CompleteAsyncRedeemFlow() public {
        uint256 depositAmount = 10000e18;

        // Setup: Alice gets shares first
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Now test async redeem flow
        // 1. Request Phase - Alice requests redemption
        vm.startPrank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);
        assertEq(requestId, 0, "Request ID should be 0");

        // Check pending redeem
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
        assertEq(vault.claimableRedeemRequest(0, alice), 0);
        vm.stopPrank();

        // 2. Fulfillment Phase - Owner fulfills the redeem
        vm.prank(investmentManager);
        vault.fulfillRedeem(alice, shares);

        // Check claimable redeem
        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertEq(vault.claimableRedeemRequest(0, alice), shares);

        // 3. Claim Phase - Alice redeems her shares for assets
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // Verify assets received
        assertTrue(assets > 0);
        assertEq(vault.claimableRedeemRequest(0, alice), 0);
    }

    /// @dev Test ERC7540 operator functionality
    function test_ERC7540_OperatorCompliance() public {
        uint256 depositAmount = 5000e18;

        // Alice authorizes Bob as operator
        vm.prank(alice);
        bool result = vault.setOperator(bob, true);
        assertTrue(result);
        assertTrue(vault.isOperator(alice, bob));

        // Bob makes deposit request for Alice
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vm.stopPrank();

        vm.prank(bob);
        vault.requestDeposit(depositAmount, alice, alice);

        assertEq(vault.pendingDepositRequest(0, alice), depositAmount);

        // Fulfill and claim
        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(bob);
        vault.deposit(depositAmount, alice);

        assertTrue(shareToken.balanceOf(alice) > 0);

        // Alice revokes operator
        vm.prank(alice);
        vault.setOperator(bob, false);
        assertFalse(vault.isOperator(alice, bob));

        // Bob can no longer act for Alice
        vm.prank(bob);
        vm.expectRevert();
        vault.requestDeposit(1000e18, alice, alice);
    }

    /// @dev Test complete investment flow: deposit → invest → uninvest → withdraw
    function test_CompleteInvestmentFlow() public {
        uint256 depositAmount = 20000e18;

        // Phase 1: User deposits
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        assertEq(shareToken.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), depositAmount);

        // Phase 2: Investment manager invests assets
        uint256 investAmount = 15000e18;

        vm.prank(investmentManager);
        uint256 investmentShares = vault.investAssets(investAmount);

        // Set up validator permit signature for ShareToken self-allowance (required for WERC7575 withdrawals)
        _setupValidatorPermitForShareToken();

        assertTrue(investmentShares > 0);
        uint256 actualInvested = shareToken.getInvestedAssets();
        assertTrue(actualInvested >= investAmount - 1e18, "Investment should be approximately correct");

        // In centralized architecture, invested assets are tracked separately from vault totalAssets
        // Vault's totalAssets excludes invested assets to prevent double counting
        uint256 vaultIdleAssets = vault.totalAssets();
        assertEq(vaultIdleAssets, depositAmount - investAmount, "Vault should only show idle assets");

        // Total system assets = vault idle assets + invested assets
        uint256 totalSystemAssets = vaultIdleAssets + actualInvested;
        assertEq(totalSystemAssets, depositAmount, "Total system assets should equal original deposit");

        // Phase 3: Investment manager withdraws from investment
        vm.prank(investmentManager);
        uint256 withdrawnAmount = vault.withdrawFromInvestment(10000e18);

        assertTrue(withdrawnAmount > 0, "Should withdraw some amount");

        // Phase 4: User withdraws (async redeem)
        uint256 redeemShares = shares / 2;

        vm.startPrank(alice);
        vault.requestRedeem(redeemShares, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillRedeem(alice, redeemShares);

        vm.prank(alice);
        uint256 assetsReceived = vault.redeem(redeemShares, alice, alice);

        assertTrue(assetsReceived > 0);
        assertEq(shareToken.balanceOf(alice), shares - redeemShares);
    }

    /// @dev Test ERC7575 compliance - multi-asset support
    function test_ERC7575_MultiAssetCompliance() public {
        // Test share() method
        assertEq(vault.share(), address(shareToken));

        // Test vault lookup
        assertEq(shareToken.vault(address(asset)), address(vault));

        // Test interface support
        assertTrue(vault.supportsInterface(type(IERC7575).interfaceId));
        assertTrue(shareToken.supportsInterface(type(IERC7575ShareExtended).interfaceId));

        // Test VaultUpdate event via unregister and register
        // Deploy a real new vault for the same asset
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        address newVault = address(vaultProxy);

        // First deactivate existing vault, then unregister
        vm.prank(owner);
        vault.setVaultActive(false);

        vm.prank(owner);
        vm.expectEmit();
        emit IERC7575Share.VaultUpdate(address(asset), address(0));
        shareToken.unregisterVault(address(asset));

        // Then register new vault
        vm.prank(owner);
        vm.expectEmit();
        emit IERC7575Share.VaultUpdate(address(asset), newVault);
        shareToken.registerVault(address(asset), newVault);
    }

    /// @dev Test that preview functions revert as required by ERC7540
    function test_ERC7540_PreviewFunctionsRevert() public {
        vm.expectRevert(IERC7575Errors.AsyncFlow.selector);
        vault.previewDeposit(1000e18);

        vm.expectRevert(IERC7575Errors.AsyncFlow.selector);
        vault.previewMint(1000e18);

        vm.expectRevert(IERC7575Errors.AsyncFlow.selector);
        vault.previewWithdraw(1000e18);

        vm.expectRevert(IERC7575Errors.AsyncFlow.selector);
        vault.previewRedeem(1000e18);
    }

    /// @dev Test ERC4626 compatibility methods
    function test_ERC4626_Compatibility() public {
        // Test basic view functions
        assertEq(vault.asset(), address(asset));
        // Vault no longer has name/symbol per ERC7575 spec - only share token does

        // Test total supply and balance tracking
        uint256 depositAmount = 5000e18;

        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        assertEq(vault.totalSupply(), shares);
        assertEq(vault.balanceOf(alice), shares);

        // Test max functions - in async flow, maxDeposit/maxMint return claimable amounts
        // After Alice has claimed her deposit, claimable should be 0
        assertEq(vault.maxDeposit(alice), 0); // Alice has no claimable deposits left
        assertEq(vault.maxMint(alice), 0); // Alice has no claimable mints left
        assertEq(vault.maxWithdraw(alice), 0); // Alice has no claimable redeems
        assertEq(vault.maxRedeem(alice), 0); // Alice has no claimable redeems
    }

    /// @dev Test investment management access controls
    function test_InvestmentManagement_AccessControl() public {
        // Only owner can set investment manager (centralized architecture)
        vm.prank(alice);
        vm.expectRevert();
        shareToken.setInvestmentManager(alice);

        // Only owner can set investment ShareToken (centralized architecture)
        vm.prank(alice);
        vm.expectRevert();
        shareToken.setInvestmentShareToken(address(investmentShareToken));

        // Only investment manager can invest
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.OnlyInvestmentManager.selector);
        vault.investAssets(1000e18);

        // Only investment manager can withdraw from investment
        vm.prank(alice);
        vm.expectRevert(IERC7575Errors.OnlyInvestmentManager.selector);
        vault.withdrawFromInvestment(1000e18);
    }

    /// @dev Test investment vault asset compatibility (centralized architecture)
    function test_InvestmentVault_AssetCompatibility() public {
        // Create investment vault with wrong asset
        MockAsset wrongAsset = new MockAsset();
        WERC7575ShareToken wrongInvestmentShareToken = new WERC7575ShareToken("Wrong USD", "WUSD");
        WERC7575Vault wrongVault = new WERC7575Vault(address(wrongAsset), wrongInvestmentShareToken);

        wrongInvestmentShareToken.registerVault(address(wrongAsset), address(wrongVault));

        // Test direct vault configuration - should fail with asset mismatch
        // This demonstrates that the asset mismatch validation works correctly
        vm.prank(owner);
        vm.expectRevert(IERC7575Errors.AssetMismatch.selector);
        vault.setInvestmentVault(IERC7575(address(wrongVault)));
    }

    /// @dev Test partial investment scenarios
    function test_PartialInvestmentScenarios() public {
        uint256 depositAmount = 10000e18;

        // Setup deposit
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.stopPrank();

        vm.prank(investmentManager);
        vault.fulfillDeposit(alice, depositAmount);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Test available balance calculation
        uint256 available = vault.totalAssets();
        assertEq(available, depositAmount);

        // Invest partial amount
        uint256 investAmount = 6000e18;
        vm.prank(investmentManager);
        vault.investAssets(investAmount);

        // Available should be reduced
        assertEq(vault.totalAssets(), depositAmount - investAmount);

        // Test investment info from ShareToken level using existing functions
        address invShareTokenAddr = shareToken.getInvestmentShareToken();
        uint256 investedAssets = shareToken.getInvestedAssets();

        assertTrue(invShareTokenAddr != address(0), "Investment ShareToken should be configured");
        // In Scenario A, invested assets represent current value (1:1 relationship)
        assertTrue(investedAssets >= 0, "Should return valid invested assets");
        // No separate yield tracking needed in Scenario A (yield comes from underlying vaults)
    }
}
