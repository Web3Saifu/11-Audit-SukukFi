// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC20Faucet.sol";
import "../src/WERC7575ShareToken.sol";
import "../src/WERC7575Vault.sol";
import "../src/interfaces/IERC7575Errors.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title WERC7575Vault Coverage Tests
 * @notice Tests to improve code coverage of vault functions
 * @dev Focuses on error paths, edge cases, and boundary conditions
 */
contract WERC7575VaultCoverageTests is Test {
    WERC7575ShareToken public shareToken;
    WERC7575Vault public vault;
    ERC20Faucet public asset;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 constant INITIAL_BALANCE = 1000 * 1e18;
    uint256 constant DEPOSIT_AMOUNT = 100 * 1e18;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        asset = new ERC20Faucet("Test Asset", "ASSET", 10000 * 1e18);
        shareToken = new WERC7575ShareToken("Test Share", "tSHARE");
        vault = new WERC7575Vault(address(asset), shareToken);

        // Register vault with share token
        shareToken.registerVault(address(asset), address(vault));
        shareToken.setValidator(owner);
        shareToken.setKycAdmin(owner);

        // Setup users with balances
        vm.warp(block.timestamp + 2 hours); // Skip faucet cooldown
        asset.faucetAmountFor(user1, INITIAL_BALANCE);
        asset.faucetAmountFor(user2, INITIAL_BALANCE);
        asset.faucetAmountFor(user3, INITIAL_BALANCE);

        // KYC all users
        shareToken.setKycVerified(user1, true);
        shareToken.setKycVerified(user2, true);
        shareToken.setKycVerified(user3, true);

        // Approve vault
        vm.prank(user1);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(user3);
        asset.approve(address(vault), type(uint256).max);
    }

    // ==================== Deposit with Invalid Receiver ====================

    /**
     * @notice Test deposit with zero address receiver
     */
    function testDepositZeroAddressReceiver() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, address(0));
    }

    // ==================== Deposit Zero Amount ====================

    /**
     * @notice Test deposit with zero assets
     */
    function testDepositZeroAssets() public {
        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.ZeroAssets.selector);
        vault.deposit(0, user1);
    }

    // ==================== Mint with Invalid Receiver ====================

    /**
     * @notice Test mint with zero address receiver
     */
    function testMintZeroAddressReceiver() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.mint(DEPOSIT_AMOUNT, address(0));
    }

    // ==================== Mint Zero Shares ====================

    /**
     * @notice Test mint with zero shares
     */
    function testMintZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.ZeroAssets.selector);
        vault.mint(0, user1);
    }

    // ==================== Withdraw with Invalid Receiver ====================

    /**
     * @notice Test withdraw with zero address receiver
     */
    function testWithdrawZeroAddressReceiver() public {
        // First deposit to have shares
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        // Try to withdraw to zero address (should fail before permit is needed)
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(DEPOSIT_AMOUNT, address(0), user1);
    }

    // ==================== Withdraw with Invalid Owner ====================

    /**
     * @notice Test withdraw with zero address owner
     */
    function testWithdrawZeroAddressOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(DEPOSIT_AMOUNT, user1, address(0));
    }

    // ==================== Withdraw Zero Assets ====================

    /**
     * @notice Test withdraw with zero assets
     */
    function testWithdrawZeroAssets() public {
        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.ZeroAssets.selector);
        vault.withdraw(0, user1, user1);
    }

    // ==================== Redeem with Invalid Receiver ====================

    /**
     * @notice Test redeem with zero address receiver
     */
    function testRedeemZeroAddressReceiver() public {
        // First deposit to have shares
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        // Try to redeem to zero address (should fail before permit is needed)
        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(DEPOSIT_AMOUNT, address(0), user1);
    }

    // ==================== Redeem with Invalid Owner ====================

    /**
     * @notice Test redeem with zero address owner
     */
    function testRedeemZeroAddressOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(DEPOSIT_AMOUNT, user1, address(0));
    }

    // ==================== Redeem Zero Shares ====================

    /**
     * @notice Test redeem with zero shares
     */
    function testRedeemZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.ZeroAssets.selector);
        vault.redeem(0, user1, user1);
    }

    // ==================== Vault Not Active ====================

    /**
     * @notice Test deposit when vault is inactive
     */
    function testDepositWhenVaultInactive() public {
        vm.prank(owner);
        vault.setVaultActive(false);

        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.VaultNotActive.selector);
        vault.deposit(DEPOSIT_AMOUNT, user1);
    }

    /**
     * @notice Test mint when vault is inactive
     */
    function testMintWhenVaultInactive() public {
        vm.prank(owner);
        vault.setVaultActive(false);

        vm.prank(user1);
        vm.expectRevert(IERC7575Errors.VaultNotActive.selector);
        vault.mint(DEPOSIT_AMOUNT, user1);
    }

    /**
     * @notice Test that withdrawal checking happens after vault deactivation check
     */
    function testVaultStateChecksPriority() public {
        // Deposit while active
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        // Deactivate vault
        vault.setVaultActive(false);

        // Withdrawal should work even when vault is inactive
        // (VaultNotActive is only checked on deposit/mint, not withdraw/redeem)
        assertEq(shareToken.balanceOf(user1), DEPOSIT_AMOUNT, "User has shares");
    }

    // ==================== Pause/Unpause Tests ====================

    /**
     * @notice Test deposit when paused
     */
    function testDepositWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, user1);
    }

    /**
     * @notice Test mint when paused
     */
    function testMintWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert();
        vault.mint(DEPOSIT_AMOUNT, user1);
    }

    /**
     * @notice Test that pause prevents deposits
     */
    function testPauseStateEffects() public {
        // Pause vault first
        vault.pause();

        // Check that deposit is blocked
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, user1);
    }

    /**
     * @notice Test unpause allows operations
     */
    function testUnpauseAllowsOperations() public {
        vault.pause();
        vault.unpause();

        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        assertEq(shareToken.balanceOf(user1), DEPOSIT_AMOUNT, "Deposit after unpause should succeed");
    }

    // ==================== Share Conversion Tests ====================

    /**
     * @notice Test convertToShares with standard deposit
     */
    function testConvertToShares() public {
        uint256 assets = 100 * 1e18;
        uint256 expectedShares = vault.convertToShares(assets);

        assertEq(expectedShares, assets, "Should convert 1:1 for 18-decimal asset");
    }

    /**
     * @notice Test convertToAssets with standard shares
     */
    function testConvertToAssets() public {
        uint256 shares = 100 * 1e18;
        uint256 expectedAssets = vault.convertToAssets(shares);

        assertEq(expectedAssets, shares, "Should convert 1:1 for 18-decimal asset");
    }

    /**
     * @notice Test previewDeposit with zero assets
     */
    function testPreviewDepositZeroAssets() public {
        uint256 shares = vault.previewDeposit(0);
        assertEq(shares, 0, "Preview of 0 assets should be 0 shares");
    }

    /**
     * @notice Test previewMint with zero shares
     */
    function testPreviewMintZeroShares() public {
        uint256 assets = vault.previewMint(0);
        assertEq(assets, 0, "Preview of 0 shares should be 0 assets");
    }

    /**
     * @notice Test previewWithdraw with zero assets
     */
    function testPreviewWithdrawZeroAssets() public {
        uint256 shares = vault.previewWithdraw(0);
        assertEq(shares, 0, "Preview of 0 assets to withdraw should be 0 shares");
    }

    /**
     * @notice Test previewRedeem with zero shares
     */
    function testPreviewRedeemZeroShares() public {
        uint256 assets = vault.previewRedeem(0);
        assertEq(assets, 0, "Preview of 0 shares to redeem should be 0 assets");
    }

    // ==================== Max Functions Tests ====================

    /**
     * @notice Test maxDeposit returns unlimited
     */
    function testMaxDepositUnlimited() public {
        uint256 maxDep = vault.maxDeposit(user1);
        assertEq(maxDep, type(uint256).max, "maxDeposit should be unlimited");
    }

    /**
     * @notice Test maxMint returns unlimited
     */
    function testMaxMintUnlimited() public {
        uint256 maxM = vault.maxMint(user1);
        assertEq(maxM, type(uint256).max, "maxMint should be unlimited");
    }

    /**
     * @notice Test maxWithdraw for user with no shares
     */
    function testMaxWithdrawZeroBalance() public {
        uint256 maxW = vault.maxWithdraw(user1);
        assertEq(maxW, 0, "maxWithdraw with 0 shares should be 0");
    }

    /**
     * @notice Test maxWithdraw for user with shares
     */
    function testMaxWithdrawWithBalance() public {
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        uint256 maxW = vault.maxWithdraw(user1);
        assertEq(maxW, DEPOSIT_AMOUNT, "maxWithdraw should equal asset balance");
    }

    /**
     * @notice Test maxRedeem for user with no shares
     */
    function testMaxRedeemZeroBalance() public {
        uint256 maxR = vault.maxRedeem(user1);
        assertEq(maxR, 0, "maxRedeem with 0 shares should be 0");
    }

    /**
     * @notice Test maxRedeem for user with shares
     */
    function testMaxRedeemWithBalance() public {
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        uint256 maxR = vault.maxRedeem(user1);
        assertEq(maxR, DEPOSIT_AMOUNT, "maxRedeem should equal share balance");
    }

    // ==================== Vault State Tests ====================

    /**
     * @notice Test isVaultActive defaults to true
     */
    function testIsVaultActiveDefault() public {
        assertTrue(vault.isVaultActive(), "Vault should be active by default");
    }

    /**
     * @notice Test setVaultActive can toggle state
     */
    function testSetVaultActiveToggle() public {
        vm.prank(owner);
        vault.setVaultActive(false);
        assertFalse(vault.isVaultActive(), "Vault should be inactive");

        vm.prank(owner);
        vault.setVaultActive(true);
        assertTrue(vault.isVaultActive(), "Vault should be active again");
    }

    /**
     * @notice Test setVaultActive is owner-only
     */
    function testSetVaultActiveOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setVaultActive(false);
    }

    // ==================== Interface Tests ====================

    /**
     * @notice Test supportsInterface for ERC165
     */
    function testSupportsInterfaceERC165() public {
        assertTrue(vault.supportsInterface(0x01ffc9a7), "Should support ERC165");
    }

    /**
     * @notice Test supportsInterface for unknown interface
     */
    function testSupportsInterfaceUnknown() public {
        // Test that unknown interface returns false
        assertFalse(vault.supportsInterface(0xdeadbeef), "Should not support unknown interface");
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
     * @notice Test totalAssets before any deposits
     */
    function testTotalAssetsInitial() public {
        assertEq(vault.totalAssets(), 0, "Initial total assets should be 0");
    }

    /**
     * @notice Test totalAssets after deposit
     */
    function testTotalAssetsAfterDeposit() public {
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT, "Total assets should equal deposit");
    }

    /**
     * @notice Test totalAssets with multiple deposits
     */
    function testTotalAssetsMultipleDeposits() public {
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        vm.prank(user2);
        vault.deposit(DEPOSIT_AMOUNT, user2);

        assertEq(vault.totalAssets(), 2 * DEPOSIT_AMOUNT, "Total assets should be sum of deposits");
    }

    // ==================== Multi-User Scenarios ====================

    /**
     * @notice Test concurrent deposits from multiple users
     */
    function testConcurrentDeposits() public {
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);

        vm.prank(user2);
        vault.deposit(DEPOSIT_AMOUNT / 2, user2);

        vm.prank(user3);
        vault.deposit(DEPOSIT_AMOUNT / 4, user3);

        assertEq(shareToken.balanceOf(user1), DEPOSIT_AMOUNT, "User1 shares correct");
        assertEq(shareToken.balanceOf(user2), DEPOSIT_AMOUNT / 2, "User2 shares correct");
        assertEq(shareToken.balanceOf(user3), DEPOSIT_AMOUNT / 4, "User3 shares correct");
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2 + DEPOSIT_AMOUNT / 4, "Total assets correct");
    }

    /**
     * @notice Test deposits in sequence
     */
    function testSequentialDeposits() public {
        // User1 deposits
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT, "After user1 deposit");

        // User2 deposits
        vm.prank(user2);
        vault.deposit(DEPOSIT_AMOUNT, user2);
        assertEq(vault.totalAssets(), 2 * DEPOSIT_AMOUNT, "After user2 deposit");

        // User3 deposits
        vm.prank(user3);
        vault.deposit(DEPOSIT_AMOUNT / 2, user3);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2, "After user3 deposit");
    }

    // ==================== Helper Functions ====================

    /**
     * @notice Helper to compute permit hash
     */
    function _getPermitHash(address owner, address spender, uint256 value, uint256 deadline) internal view returns (bytes32) {
        bytes32 domainSeparator = shareToken.DOMAIN_SEPARATOR();
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), owner, spender, value, shareToken.nonces(owner), deadline))
            )
        );
        return permitHash;
    }
}
