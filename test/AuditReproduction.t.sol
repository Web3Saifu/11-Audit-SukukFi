// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";
import {MockAsset} from "./MockAsset.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

contract AuditReproductionTest is Test {
    ERC7575VaultUpgradeable public mainVault;
    ShareTokenUpgradeable public mainShareToken;
    ERC7575VaultUpgradeable public investmentVault;
    ShareTokenUpgradeable public investmentShareToken;
    MockAsset public asset;

    address public owner = address(this);
    address public user = address(0x1);
    address public investmentManager = address(0x2);

    function setUp() public {
        // Deploy Asset
        asset = new MockAsset();

        // Deploy Main ShareToken
        ShareTokenUpgradeable mainShareTokenImpl = new ShareTokenUpgradeable();
        ERC1967Proxy mainShareTokenProxy = new ERC1967Proxy(address(mainShareTokenImpl), abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Main Share", "MSH", owner));
        mainShareToken = ShareTokenUpgradeable(address(mainShareTokenProxy));

        // Deploy Investment ShareToken
        ShareTokenUpgradeable investmentShareTokenImpl = new ShareTokenUpgradeable();
        ERC1967Proxy investmentShareTokenProxy = new ERC1967Proxy(address(investmentShareTokenImpl), abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Invest Share", "ISH", owner));
        investmentShareToken = ShareTokenUpgradeable(address(investmentShareTokenProxy));

        // Deploy Main Vault
        ERC7575VaultUpgradeable mainVaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy mainVaultProxy = new ERC1967Proxy(address(mainVaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(mainShareToken), owner));
        mainVault = ERC7575VaultUpgradeable(address(mainVaultProxy));

        // Deploy Investment Vault
        ERC7575VaultUpgradeable investmentVaultImpl = new ERC7575VaultUpgradeable();
        ERC1967Proxy investmentVaultProxy =
            new ERC1967Proxy(address(investmentVaultImpl), abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(investmentShareToken), owner));
        investmentVault = ERC7575VaultUpgradeable(address(investmentVaultProxy));

        // Register Vaults
        mainShareToken.registerVault(address(asset), address(mainVault));
        investmentShareToken.registerVault(address(asset), address(investmentVault));

        // Configure Investment Manager
        mainShareToken.setInvestmentManager(investmentManager);
        investmentShareToken.setInvestmentManager(investmentManager);

        // Configure Investment ShareToken on Main ShareToken
        // mainShareToken.setInvestmentShareToken(address(investmentShareToken));

        // Mint assets to user and approve
        asset.mint(user, 10000e18);
        vm.prank(user);
        asset.approve(address(mainVault), type(uint256).max);
    }

    function testInvestmentYieldAccountingWithRBalance() public {
        // 1. Deploy WERC7575 Investment ShareToken
        WERC7575ShareToken wInvestmentShare = new WERC7575ShareToken("Inv Share", "INV");

        // 2. Deploy WERC7575 Investment Vault
        // WERC7575Vault requires asset and share token in constructor
        WERC7575Vault wInvestmentVault = new WERC7575Vault(address(asset), wInvestmentShare);

        // Register vault in share token
        wInvestmentShare.registerVault(address(asset), address(wInvestmentVault));

        // KYC Verify Main ShareToken so it can receive shares
        wInvestmentShare.setKycVerified(address(mainShareToken), true);

        // 3. Configure Main ShareToken to use WERC7575 as investment token
        mainShareToken.setInvestmentShareToken(address(wInvestmentShare));

        // 4. User deposits into Main Vault
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        mainVault.requestDeposit(depositAmount, user, user);
        vm.stopPrank();

        vm.startPrank(investmentManager);
        mainVault.fulfillDeposit(user, depositAmount);
        vm.stopPrank();

        vm.prank(user);
        mainVault.deposit(depositAmount, user);

        // 5. Simulate Investment
        // Since investAssets is broken for async vaults, we manually move assets and mint shares
        uint256 investAmount = 500e18;

        // Move assets from Main Vault to Investment Vault
        vm.prank(address(mainVault));
        asset.transfer(address(wInvestmentVault), investAmount);

        // Mint Investment Shares to Main ShareToken
        // WERC7575 minting is restricted to vaults.
        // But here we are simulating the investment vault minting shares to the main share token.
        // We can prank the investment vault.
        vm.prank(address(wInvestmentVault));
        wInvestmentShare.mint(address(mainShareToken), investAmount); // 1:1 mint

        // Verify initial state
        (uint256 supply, uint256 totalAssets) = mainShareToken.getCirculatingSupplyAndAssets();
        // Total Assets = 500 (remaining in Main Vault) + 500 (invested in WERC7575) = 1000
        assertEq(totalAssets, 1000e18, "Initial total assets should be 1000");

        // 6. Simulate Yield via rBalance
        // Revenue Admin (deployer of WERC7575) adjusts rBalance
        // Let's say we earned 100 tokens of yield.
        // We simulate this by transferring 100 tokens to the Investment Vault (backing the yield)
        // And increasing rBalance of the Main ShareToken.

        uint256 yieldAmount = 100e18;
        asset.mint(address(wInvestmentVault), yieldAmount); // Backing assets

        // Adjust rBalance
        // adjustrBalance(account, ts, amounti, amountr)
        // amounti = invested amount (500)
        // amountr = received amount (value now) (600)
        // diff = 100 (profit) -> added to rBalance

        // WERC7575 deployer is this contract (AuditReproductionTest)
        wInvestmentShare.adjustrBalance(address(mainShareToken), 1, investAmount, investAmount + yieldAmount);

        // 7. Verify Main ShareToken sees the yield
        (supply, totalAssets) = mainShareToken.getCirculatingSupplyAndAssets();

        // Total Assets should be:
        // 500 (Main Vault) + 500 (Investment Shares Balance) + 100 (Investment Shares rBalance) = 1100

        // console.log("Total Assets:", totalAssets);
        // console.log("Expected Assets:", 1100e18);

        assertEq(totalAssets, 1100e18, "Total assets should include rBalance yield");
    }

    function testInsolvencyWithTrappedRBalance() public {
        // 1. Setup WERC7575 Investment
        WERC7575ShareToken wInvestmentShare = new WERC7575ShareToken("Inv Share", "INV");
        WERC7575Vault wInvestmentVault = new WERC7575Vault(address(asset), wInvestmentShare);
        wInvestmentShare.registerVault(address(asset), address(wInvestmentVault));
        wInvestmentShare.setKycVerified(address(mainShareToken), true);
        mainShareToken.setInvestmentShareToken(address(wInvestmentShare));

        // 2. User deposits 1000 into Main Vault
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        mainVault.requestDeposit(depositAmount, user, user);
        vm.stopPrank();
        vm.startPrank(investmentManager);
        mainVault.fulfillDeposit(user, depositAmount);
        vm.stopPrank();
        vm.prank(user);
        mainVault.deposit(depositAmount, user);

        // 3. Invest ALL 1000 assets
        vm.prank(address(mainVault));
        asset.transfer(address(wInvestmentVault), depositAmount);
        vm.prank(address(wInvestmentVault));
        wInvestmentShare.mint(address(mainShareToken), depositAmount);

        // 4. Simulate 1000 Yield (100% return) via rBalance
        uint256 yieldAmount = 1000e18;
        asset.mint(address(wInvestmentVault), yieldAmount);
        wInvestmentShare.adjustrBalance(address(mainShareToken), 1, depositAmount, depositAmount + yieldAmount);

        // Fix Allowances using PERMIT (since approve(self) is blocked)
        // We need to be the validator to sign a self-permit.
        // 1. Set validator to a known key
        uint256 validatorPk = 0xA11CE;
        address validator = vm.addr(validatorPk);
        wInvestmentShare.setValidator(validator);

        // 2. Construct Permit
        uint256 nonce = wInvestmentShare.nonces(address(mainShareToken));
        uint256 deadline = block.timestamp + 1 days;

        // Domain Separator
        bytes32 domainSeparator = wInvestmentShare.DOMAIN_SEPARATOR();

        // Permit Typehash
        bytes32 PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                address(mainShareToken), // owner
                address(mainShareToken), // spender (SELF)
                type(uint256).max,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPk, digest);

        // 3. Execute Permit
        wInvestmentShare.permit(address(mainShareToken), address(mainShareToken), type(uint256).max, deadline, v, r, s);

        // Also approve MainVault to spend MainShareToken's investment shares
        // This is a normal approval (owner != spender), so we can just prune and approve.
        vm.prank(address(mainShareToken));
        wInvestmentShare.approve(address(mainVault), type(uint256).max);

        // 5. Check Main ShareToken NAV
        // Total Assets = 1000 (Invested) + 1000 (Yield) = 2000.
        // Supply = 1000.
        // Price = 2.0.
        (uint256 supply, uint256 totalAssets) = mainShareToken.getCirculatingSupplyAndAssets();
        assertEq(totalAssets, 2000e18);

        // 6. User requests redeem of ALL shares (1000 shares)
        // Expected value = 2000 assets.
        vm.startPrank(user);
        mainVault.requestRedeem(1000e18, user, user);
        vm.stopPrank();

        // 7. Manager fulfills redeem
        vm.startPrank(investmentManager);
        // This should succeed (accounting only)
        mainVault.fulfillRedeem(user, 1000e18);
        vm.stopPrank();

        // 8. Manager tries to withdraw assets from investment to cover the redemption
        // Needs 2000 assets.
        // Investment Vault has 2000 assets (1000 original + 1000 yield).
        // But ShareToken only has 1000 shares (balance) + 1000 rBalance.
        // withdrawFromInvestment tries to redeem shares.

        vm.startPrank(investmentManager);
        // Try to withdraw 2000 assets
        // This will NOT revert, but it will only withdraw 1000 assets (capped by maxShares)
        uint256 withdrawn = mainVault.withdrawFromInvestment(2000e18);
        console.log("Withdrawn Amount:", withdrawn);
        assertEq(withdrawn, 1000e18, "Should be capped at 1000 assets");
        vm.stopPrank();

        // 9. User tries to claim assets
        // Needs 2000 assets.
        // Vault has 1000 assets (withdrawn).
        // User claim should FAIL due to insufficient assets in vault.

        vm.startPrank(user);
        vm.expectRevert(); // Should revert due to insufficient assets in vault
        mainVault.redeem(1000e18, user, user);
        vm.stopPrank();
    }
}
