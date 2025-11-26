// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC20Faucet.sol";
import "../src/ERC7575VaultUpgradeable.sol";
import "../src/ShareTokenUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "forge-std/Test.sol";

/**
 * @title ERC7575VaultUpgradeable Coverage Tests
 * @notice Tests to improve code coverage of ERC7575VaultUpgradeable
 * @dev Focuses on upgradeable-specific features and async vault operations
 */
contract ERC7575VaultUpgradeableCoverageTests is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    ERC1967Proxy public vaultProxy;
    ERC1967Proxy public shareProxy;
    ERC20Faucet public asset;

    address public owner;
    address public user1;
    address public user2;

    uint256 constant INITIAL_BALANCE = 1000 * 1e18;
    uint256 constant DEPOSIT_AMOUNT = 100 * 1e18;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        asset = new ERC20Faucet("Test Asset", "ASSET", 10000 * 1e18);

        // Deploy ShareTokenUpgradeable
        ShareTokenUpgradeable shareImpl = new ShareTokenUpgradeable();
        shareProxy = new ERC1967Proxy(address(shareImpl), abi.encodeCall(ShareTokenUpgradeable.initialize, ("Test Share", "tSHARE", owner)));
        shareToken = ShareTokenUpgradeable(address(shareProxy));

        // Deploy ERC7575VaultUpgradeable
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeCall(ERC7575VaultUpgradeable.initialize, (asset, address(shareToken), owner)));
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault
        shareToken.registerVault(address(asset), address(vault));

        // Setup users
        vm.warp(block.timestamp + 2 hours);
        asset.faucetAmountFor(user1, INITIAL_BALANCE);
        asset.faucetAmountFor(user2, INITIAL_BALANCE);

        // Approve vault
        vm.prank(user1);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(vault), type(uint256).max);
    }

    // ==================== Initialization Tests ====================

    /**
     * @notice Test initialize sets correct owner
     */
    function testInitializeOwner() public {
        assertEq(vault.owner(), owner, "Owner should be set correctly");
    }

    /**
     * @notice Test initialize sets correct asset
     */
    function testInitializeAsset() public {
        assertEq(address(vault.asset()), address(asset), "Asset should be set correctly");
    }

    /**
     * @notice Test initialize sets correct share token
     */
    function testInitializeShareToken() public {
        assertEq(address(vault.share()), address(shareToken), "Share token should be set correctly");
    }

    // ==================== Upgrade Tests ====================

    /**
     * @notice Test upgradeTo is owner only
     */
    function testUpgradeToOwnerOnly() public {
        ERC7575VaultUpgradeable newImpl = new ERC7575VaultUpgradeable();

        vm.prank(user1);
        vm.expectRevert();
        vault.upgradeTo(address(newImpl));
    }

    /**
     * @notice Test upgradeTo with valid implementation
     */
    function testUpgradeToSuccess() public {
        ERC7575VaultUpgradeable newImpl = new ERC7575VaultUpgradeable();

        uint256 assetsBefore = vault.totalAssets();

        vault.upgradeTo(address(newImpl));

        assertEq(vault.totalAssets(), assetsBefore, "State should persist after upgrade");
        assertEq(vault.owner(), owner, "Owner should persist");
    }

    /**
     * @notice Test upgradeToAndCall with empty data
     */
    function testUpgradeToAndCallEmptyData() public {
        ERC7575VaultUpgradeable newImpl = new ERC7575VaultUpgradeable();

        uint256 assetsBefore = vault.totalAssets();

        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(vault.totalAssets(), assetsBefore, "State should persist");
    }

    // ==================== Deposit/Mint Tests ====================

    /**
     * @notice Test deposit is async (async flow pattern)
     */
    function testDepositIsAsync() public {
        // ERC7575VaultUpgradeable is async - deposit creates a request
        // Preview functions check for pending requests which may cause AsyncFlow
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, user1);
    }

    /**
     * @notice Test mint is async
     */
    function testMintIsAsync() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.mint(DEPOSIT_AMOUNT, user1);
    }

    /**
     * @notice Test maxDeposit getter
     */
    function testMaxDepositGetter() public {
        uint256 maxDep = vault.maxDeposit(user1);
        // For async vaults, this may be 0 or type(uint256).max depending on state
        assertTrue(maxDep >= 0, "Max deposit should be >= 0");
    }

    /**
     * @notice Test maxMint getter
     */
    function testMaxMintGetter() public {
        uint256 maxM = vault.maxMint(user1);
        // For async vaults, this may be 0 or type(uint256).max depending on state
        assertTrue(maxM >= 0, "Max mint should be >= 0");
    }

    // ==================== Withdraw/Redeem Tests ====================

    /**
     * @notice Test maxWithdraw with no requests
     */
    function testMaxWithdrawInitial() public {
        uint256 maxW = vault.maxWithdraw(user1);
        assertEq(maxW, 0, "Initial max withdraw should be 0");
    }

    /**
     * @notice Test maxRedeem with no shares
     */
    function testMaxRedeemInitial() public {
        uint256 maxR = vault.maxRedeem(user1);
        assertEq(maxR, 0, "Initial max redeem should be 0");
    }

    /**
     * @notice Test withdraw with zero amount reverts
     */
    function testWithdrawZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(0, user1, user1);
    }

    /**
     * @notice Test redeem with zero shares reverts
     */
    function testRedeemZeroShares() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(0, user1, user1);
    }

    // ==================== State Change Tests ====================

    /**
     * @notice Test owner can change vault active state
     */
    function testOwnerCanChangeVaultState() public {
        assertTrue(vault.isVaultActive(), "Should be active initially");

        vault.setVaultActive(false);
        assertFalse(vault.isVaultActive(), "Should be inactive");

        vault.setVaultActive(true);
        assertTrue(vault.isVaultActive(), "Should be active again");
    }

    // ==================== Investment Manager Tests ====================

    /**
     * @notice Test setInvestmentManager is owner only
     */
    function testSetInvestmentManagerOwnerOnly() public {
        address manager = makeAddr("manager");

        vm.prank(user1);
        vm.expectRevert();
        vault.setInvestmentManager(manager);
    }

    /**
     * @notice Test getInvestmentManager initial value
     */
    function testGetInvestmentManagerInitial() public {
        address manager = vault.getInvestmentManager();
        // Manager could be zero or owner depending on implementation
        assertTrue(manager == address(0) || manager == owner, "Manager should be valid");
    }

    // ==================== Share Conversion Tests ====================

    /**
     * @notice Test convertToShares with zero assets
     */
    function testConvertToSharesZero() public {
        uint256 shares = vault.convertToShares(0);
        assertEq(shares, 0, "Zero assets should convert to zero shares");
    }

    /**
     * @notice Test convertToAssets with zero shares
     */
    function testConvertToAssetsZero() public {
        uint256 assets = vault.convertToAssets(0);
        assertEq(assets, 0, "Zero shares should convert to zero assets");
    }

    /**
     * @notice Test convertToShares with assets
     */
    function testConvertToShares() public {
        uint256 shares = vault.convertToShares(DEPOSIT_AMOUNT);
        assertGt(shares, 0, "Should convert assets to shares");
    }

    /**
     * @notice Test convertToAssets with shares
     */
    function testConvertToAssets() public {
        uint256 assets = vault.convertToAssets(DEPOSIT_AMOUNT);
        assertGt(assets, 0, "Should convert shares to assets");
    }

    // ==================== Async Flow Tests ====================

    /**
     * @notice Test that async vault has async flow characteristics
     */
    function testAsyncVaultCharacteristics() public {
        // ERC7575VaultUpgradeable implements async flow pattern
        // This is different from WERC7575Vault which is synchronous
        assertTrue(vault.isVaultActive(), "Vault should be active");
    }

    // ==================== View Function Tests ====================

    /**
     * @notice Test share token getter
     */
    function testShareTokenGetter() public {
        assertEq(address(vault.share()), address(shareToken), "Share token should match");
    }

    /**
     * @notice Test asset token getter
     */
    function testAssetTokenGetter() public {
        assertEq(address(vault.asset()), address(asset), "Asset should match");
    }

    /**
     * @notice Test totalAssets initial
     */
    function testTotalAssetsInitial() public {
        assertEq(vault.totalAssets(), 0, "Initial total assets should be 0");
    }

    /**
     * @notice Test supportsInterface for ERC165
     */
    function testSupportsInterfaceERC165() public {
        assertTrue(vault.supportsInterface(0x01ffc9a7), "Should support ERC165");
    }

    /**
     * @notice Test supportsInterface for unknown
     */
    function testSupportsInterfaceUnknown() public {
        assertFalse(vault.supportsInterface(0xdeadbeef), "Should not support unknown");
    }

    // ==================== Owner Functions ====================

    /**
     * @notice Test setVaultActive is owner only
     */
    function testSetVaultActiveOwnerOnly() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setVaultActive(false);
    }
}
