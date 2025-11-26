// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC20Faucet.sol";
import "../src/WERC7575ShareToken.sol";
import "../src/WERC7575Vault.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title Admin Role Management Tests
 * @notice Comprehensive tests for KYC admin and Revenue admin role functions
 * @dev Tests setKycAdmin(), setRevenueAdmin(), and their getters
 */
contract AdminRoleManagementTest is Test {
    WERC7575ShareToken public shareToken;
    ERC20Faucet public token;
    WERC7575Vault public vault;

    address public currentKycAdmin;
    address public currentRevenueAdmin;
    address public newKycAdmin;
    address public newRevenueAdmin;
    address public thirdAdmin;

    event KycAdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event RevenueAdminChanged(address indexed previousAdmin, address indexed newAdmin);

    function setUp() public {
        currentKycAdmin = makeAddr("kycAdmin");
        currentRevenueAdmin = makeAddr("revenueAdmin");
        newKycAdmin = makeAddr("newKycAdmin");
        newRevenueAdmin = makeAddr("newRevenueAdmin");
        thirdAdmin = makeAddr("thirdAdmin");

        // Deploy token and share token
        token = new ERC20Faucet("Test Token", "TEST", 10000 * 1e18);
        shareToken = new WERC7575ShareToken("Test Share Token", "tSHARE");
        vault = new WERC7575Vault(address(token), shareToken);

        // Register vault
        shareToken.registerVault(address(token), address(vault));

        // Set initial admin roles
        shareToken.setKycAdmin(currentKycAdmin);
        shareToken.setRevenueAdmin(currentRevenueAdmin);
    }

    /**
     * @notice Test 1: setKycAdmin changes the KYC admin correctly
     */
    function testSetKycAdminChangesAdmin() public {
        vm.expectEmit(true, true, false, false);
        emit KycAdminChanged(currentKycAdmin, newKycAdmin);

        shareToken.setKycAdmin(newKycAdmin);

        assertEq(shareToken.getKycAdmin(), newKycAdmin, "KYC admin should be updated");
    }

    /**
     * @notice Test 2: setRevenueAdmin changes the revenue admin correctly
     */
    function testSetRevenueAdminChangesAdmin() public {
        vm.expectEmit(true, true, false, false);
        emit RevenueAdminChanged(currentRevenueAdmin, newRevenueAdmin);

        shareToken.setRevenueAdmin(newRevenueAdmin);

        assertEq(shareToken.getRevenueAdmin(), newRevenueAdmin, "Revenue admin should be updated");
    }

    /**
     * @notice Test 3: getKycAdmin returns correct initial value
     */
    function testGetKycAdminReturnsCorrectValue() public {
        assertEq(shareToken.getKycAdmin(), currentKycAdmin, "Initial KYC admin should be set");
    }

    /**
     * @notice Test 4: getRevenueAdmin returns correct initial value
     */
    function testGetRevenueAdminReturnsCorrectValue() public {
        assertEq(shareToken.getRevenueAdmin(), currentRevenueAdmin, "Initial Revenue admin should be set");
    }

    /**
     * @notice Test 5: setKycAdmin rejects zero address
     */
    function testSetKycAdminRejectsZeroAddress() public {
        vm.expectRevert();
        shareToken.setKycAdmin(address(0));
    }

    /**
     * @notice Test 6: setRevenueAdmin rejects zero address
     */
    function testSetRevenueAdminRejectsZeroAddress() public {
        vm.expectRevert();
        shareToken.setRevenueAdmin(address(0));
    }

    /**
     * @notice Test 7: Sequential KYC admin changes are all recorded
     */
    function testSequentialKycAdminChanges() public {
        // First change
        shareToken.setKycAdmin(newKycAdmin);
        assertEq(shareToken.getKycAdmin(), newKycAdmin, "First change should succeed");

        // Second change
        shareToken.setKycAdmin(thirdAdmin);
        assertEq(shareToken.getKycAdmin(), thirdAdmin, "Second change should succeed");

        // Third change back to original
        shareToken.setKycAdmin(currentKycAdmin);
        assertEq(shareToken.getKycAdmin(), currentKycAdmin, "Third change should succeed");
    }

    /**
     * @notice Test 8: Sequential revenue admin changes are all recorded
     */
    function testSequentialRevenueAdminChanges() public {
        // First change
        shareToken.setRevenueAdmin(newRevenueAdmin);
        assertEq(shareToken.getRevenueAdmin(), newRevenueAdmin, "First change should succeed");

        // Second change
        shareToken.setRevenueAdmin(thirdAdmin);
        assertEq(shareToken.getRevenueAdmin(), thirdAdmin, "Second change should succeed");

        // Third change back to original
        shareToken.setRevenueAdmin(currentRevenueAdmin);
        assertEq(shareToken.getRevenueAdmin(), currentRevenueAdmin, "Third change should succeed");
    }

    /**
     * @notice Test 9: Changing KYC admin does not affect revenue admin
     */
    function testChangingKycAdminDoesNotAffectRevenueAdmin() public {
        address originalRevenueAdmin = shareToken.getRevenueAdmin();

        shareToken.setKycAdmin(newKycAdmin);

        assertEq(shareToken.getRevenueAdmin(), originalRevenueAdmin, "Revenue admin should not change");
    }

    /**
     * @notice Test 10: Changing revenue admin does not affect KYC admin
     */
    function testChangingRevenueAdminDoesNotAffectKycAdmin() public {
        address originalKycAdmin = shareToken.getKycAdmin();

        shareToken.setRevenueAdmin(newRevenueAdmin);

        assertEq(shareToken.getKycAdmin(), originalKycAdmin, "KYC admin should not change");
    }

    /**
     * @notice Test 11: Setting KYC admin to same address (no-op)
     */
    function testSetKycAdminToSameAddress() public {
        address currentAdmin = shareToken.getKycAdmin();

        // This should succeed even if it's the same address
        shareToken.setKycAdmin(currentAdmin);

        assertEq(shareToken.getKycAdmin(), currentAdmin, "Admin should remain same");
    }

    /**
     * @notice Test 12: Setting revenue admin to same address (no-op)
     */
    function testSetRevenueAdminToSameAddress() public {
        address currentAdmin = shareToken.getRevenueAdmin();

        // This should succeed even if it's the same address
        shareToken.setRevenueAdmin(currentAdmin);

        assertEq(shareToken.getRevenueAdmin(), currentAdmin, "Admin should remain same");
    }

    /**
     * @notice Test 13: KYC admin and revenue admin can be the same address
     */
    function testKycAndRevenueAdminCanBeSame() public {
        address sameAdmin = makeAddr("sameAdmin");

        shareToken.setKycAdmin(sameAdmin);
        shareToken.setRevenueAdmin(sameAdmin);

        assertEq(shareToken.getKycAdmin(), sameAdmin, "KYC admin should be set");
        assertEq(shareToken.getRevenueAdmin(), sameAdmin, "Revenue admin should be set");
        assertEq(shareToken.getKycAdmin(), shareToken.getRevenueAdmin(), "Both admins should be same");
    }

    /**
     * @notice Test 14: Event emission contains correct previous admin
     */
    function testKycAdminEventContainsPreviousAdmin() public {
        address previousAdmin = shareToken.getKycAdmin();

        vm.expectEmit(true, true, false, false);
        emit KycAdminChanged(previousAdmin, newKycAdmin);

        shareToken.setKycAdmin(newKycAdmin);
    }

    /**
     * @notice Test 15: Event emission contains correct previous revenue admin
     */
    function testRevenueAdminEventContainsPreviousAdmin() public {
        address previousAdmin = shareToken.getRevenueAdmin();

        vm.expectEmit(true, true, false, false);
        emit RevenueAdminChanged(previousAdmin, newRevenueAdmin);

        shareToken.setRevenueAdmin(newRevenueAdmin);
    }

    /**
     * @notice Test 16: Multiple admins can be managed concurrently
     */
    function testMultipleAdminsConcurrentlyManaged() public {
        // Set different admins
        shareToken.setKycAdmin(newKycAdmin);
        shareToken.setRevenueAdmin(newRevenueAdmin);

        // Verify both are different and correct
        assertEq(shareToken.getKycAdmin(), newKycAdmin, "KYC admin correct");
        assertEq(shareToken.getRevenueAdmin(), newRevenueAdmin, "Revenue admin correct");
        assertNotEq(shareToken.getKycAdmin(), shareToken.getRevenueAdmin(), "Admins should be different");
    }

    /**
     * @notice Test 17: Admin role persists across vault operations
     */
    function testAdminPersistsAcrossVaultOperations() public {
        address originalKycAdmin = shareToken.getKycAdmin();
        address originalRevenueAdmin = shareToken.getRevenueAdmin();

        // Perform vault operation
        ERC20Faucet newToken = new ERC20Faucet("New Token", "NEW", 10000 * 1e18);
        WERC7575ShareToken newShareToken = new WERC7575ShareToken("New Share Token", "nSHARE");
        WERC7575Vault newVault = new WERC7575Vault(address(newToken), newShareToken);

        newShareToken.registerVault(address(newToken), address(newVault));

        // Original admins should not change
        assertEq(shareToken.getKycAdmin(), originalKycAdmin, "KYC admin should persist");
        assertEq(shareToken.getRevenueAdmin(), originalRevenueAdmin, "Revenue admin should persist");
    }

    /**
     * @notice Test 18: getKycAdmin returns address type
     */
    function testGetKycAdminReturnsAddressType() public {
        address admin = shareToken.getKycAdmin();
        assertTrue(admin != address(0), "Should return a valid address");
    }

    /**
     * @notice Test 19: getRevenueAdmin returns address type
     */
    function testGetRevenueAdminReturnsAddressType() public {
        address admin = shareToken.getRevenueAdmin();
        assertTrue(admin != address(0), "Should return a valid address");
    }

    /**
     * @notice Test 20: Admin setter accepts various valid addresses
     */
    function testAdminSettersAcceptVariousAddresses() public {
        address[] memory validAddresses = new address[](5);
        validAddresses[0] = address(0x1);
        validAddresses[1] = address(0x123);
        validAddresses[2] = address(0xABCD);
        validAddresses[3] = address(token);
        validAddresses[4] = address(vault);

        for (uint256 i = 0; i < validAddresses.length; i++) {
            shareToken.setKycAdmin(validAddresses[i]);
            assertEq(shareToken.getKycAdmin(), validAddresses[i], "Should accept various addresses for KYC");
        }
    }
}
