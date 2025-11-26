// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../src/ERC20Faucet.sol";
import "../src/WERC7575ShareToken.sol";
import "../src/WERC7575Vault.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title Multi-Vault Enumeration Tests
 * @notice Comprehensive tests for vault enumeration functions and MAX_VAULTS limits
 * @dev Tests getRegisteredAssets(), getRegisteredVaults(), getVaultCount(), getVaultAtIndex(), isVault()
 */
contract MultiVaultEnumerationTest is Test {
    WERC7575ShareToken public shareToken;
    ERC20Faucet[] public tokens;
    WERC7575Vault[] public vaults;

    uint256 constant MAX_VAULTS = 10;

    function setUp() public {
        shareToken = new WERC7575ShareToken("Multi-Vault Share Token", "mvSHARE");
        tokens = new ERC20Faucet[](MAX_VAULTS + 5); // Extra for testing max limit
        vaults = new WERC7575Vault[](MAX_VAULTS + 5);

        // Deploy tokens and vaults
        for (uint256 i = 0; i < MAX_VAULTS + 5; i++) {
            tokens[i] = new ERC20Faucet(string(abi.encodePacked("Token", i)), string(abi.encodePacked("TOK", i)), 10000 * 1e18);
            vaults[i] = new WERC7575Vault(address(tokens[i]), shareToken);
        }
    }

    /**
     * @notice Test 1: Initial state has no vaults
     */
    function testInitialStateHasNoVaults() public {
        assertEq(shareToken.getVaultCount(), 0, "Initial vault count should be 0");

        address[] memory assets = shareToken.getRegisteredAssets();
        assertEq(assets.length, 0, "Initial assets array should be empty");

        address[] memory registeredVaults = shareToken.getRegisteredVaults();
        assertEq(registeredVaults.length, 0, "Initial vaults array should be empty");
    }

    /**
     * @notice Test 2: Register single vault
     */
    function testRegisterSingleVault() public {
        shareToken.registerVault(address(tokens[0]), address(vaults[0]));

        assertEq(shareToken.getVaultCount(), 1, "Vault count should be 1");
        assertTrue(shareToken.isVault(address(vaults[0])), "Vault should be registered");

        address[] memory assets = shareToken.getRegisteredAssets();
        assertEq(assets.length, 1, "Assets array should have 1 element");
        assertEq(assets[0], address(tokens[0]), "Asset should be tokens[0]");
    }

    /**
     * @notice Test 3: Register multiple vaults in sequence
     */
    function testRegisterMultipleVaults() public {
        for (uint256 i = 0; i < 5; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        assertEq(shareToken.getVaultCount(), 5, "Vault count should be 5");

        address[] memory assets = shareToken.getRegisteredAssets();
        assertEq(assets.length, 5, "Assets array should have 5 elements");

        for (uint256 i = 0; i < 5; i++) {
            assertTrue(shareToken.isVault(address(vaults[i])), "Vault should be registered");
        }
    }

    /**
     * @notice Test 4: Register maximum allowed vaults (10)
     */
    function testRegisterMaximumVaults() public {
        for (uint256 i = 0; i < MAX_VAULTS; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        assertEq(shareToken.getVaultCount(), MAX_VAULTS, "Vault count should equal MAX_VAULTS");

        address[] memory assets = shareToken.getRegisteredAssets();
        assertEq(assets.length, MAX_VAULTS, "Assets array should have MAX_VAULTS elements");
    }

    /**
     * @notice Test 5: Reject registration beyond maximum vaults
     */
    function testRejectVaultRegistrationBeyondMax() public {
        // Register MAX_VAULTS
        for (uint256 i = 0; i < MAX_VAULTS; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        // Try to register 11th vault - should revert
        vm.expectRevert();
        shareToken.registerVault(address(tokens[MAX_VAULTS]), address(vaults[MAX_VAULTS]));
    }

    /**
     * @notice Test 6: getVaultAtIndex retrieves correct vault
     */
    function testGetVaultAtIndexRetrievesCorrectVault() public {
        for (uint256 i = 0; i < 5; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        address[] memory registeredVaults = shareToken.getRegisteredVaults();
        assertEq(registeredVaults.length, 5, "Should have 5 vaults");

        for (uint256 i = 0; i < 5; i++) {
            assertEq(registeredVaults[i], address(vaults[i]), "Vault at index should match");
        }
    }

    /**
     * @notice Test 7: isVault returns false for unregistered vault
     */
    function testIsVaultReturnsFalseForUnregistered() public {
        shareToken.registerVault(address(tokens[0]), address(vaults[0]));

        assertTrue(shareToken.isVault(address(vaults[0])), "Registered vault should return true");
        assertFalse(shareToken.isVault(address(vaults[1])), "Unregistered vault should return false");
        assertFalse(shareToken.isVault(address(0)), "Zero address should return false");
    }

    /**
     * @notice Test 8: Unregister vault removes it from enumeration
     */
    function testUnregisterVaultRemovesFromEnumeration() public {
        // Register 3 vaults
        for (uint256 i = 0; i < 3; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        assertEq(shareToken.getVaultCount(), 3, "Should have 3 vaults");

        // Unregister vault[1]
        shareToken.unregisterVault(address(tokens[1]));

        assertEq(shareToken.getVaultCount(), 2, "Should have 2 vaults after unregister");
        assertFalse(shareToken.isVault(address(vaults[1])), "Unregistered vault should return false");

        // Verify remaining vaults are still there
        assertTrue(shareToken.isVault(address(vaults[0])), "Vault 0 should still exist");
        assertTrue(shareToken.isVault(address(vaults[2])), "Vault 2 should still exist");
    }

    /**
     * @notice Test 9: After unregister, can register new vault
     */
    function testAfterUnregisterCanRegisterNewVault() public {
        // Register vaults at max
        for (uint256 i = 0; i < MAX_VAULTS; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        // Unregister one
        shareToken.unregisterVault(address(tokens[0]));
        assertEq(shareToken.getVaultCount(), MAX_VAULTS - 1, "Should have MAX_VAULTS - 1");

        // Register a new one (should succeed)
        shareToken.registerVault(address(tokens[MAX_VAULTS]), address(vaults[MAX_VAULTS]));
        assertEq(shareToken.getVaultCount(), MAX_VAULTS, "Should be back to MAX_VAULTS");
    }

    /**
     * @notice Test 10: getRegisteredAssets returns correct order
     */
    function testGetRegisteredAssetsReturnsCorrectOrder() public {
        for (uint256 i = 0; i < 3; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        address[] memory assets = shareToken.getRegisteredAssets();
        assertEq(assets.length, 3, "Should have 3 assets");

        for (uint256 i = 0; i < 3; i++) {
            assertEq(assets[i], address(tokens[i]), "Assets should be in order");
        }
    }

    /**
     * @notice Test 11: getRegisteredVaults returns correct order
     */
    function testGetRegisteredVaultsReturnsCorrectOrder() public {
        for (uint256 i = 0; i < 3; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        address[] memory registeredVaults = shareToken.getRegisteredVaults();
        assertEq(registeredVaults.length, 3, "Should have 3 vaults");

        for (uint256 i = 0; i < 3; i++) {
            assertEq(registeredVaults[i], address(vaults[i]), "Vaults should be in order");
        }
    }

    /**
     * @notice Test 12: vault() getter returns correct vault for asset
     */
    function testVaultGetterReturnsCorrectVault() public {
        for (uint256 i = 0; i < 3; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        for (uint256 i = 0; i < 3; i++) {
            assertEq(shareToken.vault(address(tokens[i])), address(vaults[i]), "Should return correct vault");
        }
    }

    /**
     * @notice Test 13: vault() getter returns zero for unregistered asset
     */
    function testVaultGetterReturnsZeroForUnregistered() public {
        shareToken.registerVault(address(tokens[0]), address(vaults[0]));

        assertEq(shareToken.vault(address(tokens[1])), address(0), "Should return zero for unregistered asset");
    }

    /**
     * @notice Test 14: Enumeration consistency after unregister in middle
     */
    function testEnumerationConsistencyAfterMiddleUnregister() public {
        for (uint256 i = 0; i < 5; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        // Unregister middle vault
        shareToken.unregisterVault(address(tokens[2]));

        address[] memory registeredVaults = shareToken.getRegisteredVaults();
        assertEq(registeredVaults.length, 4, "Should have 4 vaults");

        // Verify correct vaults remain (note: unregister uses swap-and-pop)
        assertTrue(shareToken.isVault(address(vaults[0])), "Vault 0 should exist");
        assertTrue(shareToken.isVault(address(vaults[1])), "Vault 1 should exist");
        assertFalse(shareToken.isVault(address(vaults[2])), "Vault 2 should not exist");
        assertTrue(shareToken.isVault(address(vaults[3])), "Vault 3 should exist");
        assertTrue(shareToken.isVault(address(vaults[4])), "Vault 4 should exist");
    }

    /**
     * @notice Test 15: Multiple unregisters reduce count correctly
     */
    function testMultipleUnregistersReduceCount() public {
        for (uint256 i = 0; i < 5; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        shareToken.unregisterVault(address(tokens[0]));
        assertEq(shareToken.getVaultCount(), 4, "Count should be 4");

        shareToken.unregisterVault(address(tokens[1]));
        assertEq(shareToken.getVaultCount(), 3, "Count should be 3");

        shareToken.unregisterVault(address(tokens[2]));
        assertEq(shareToken.getVaultCount(), 2, "Count should be 2");
    }

    /**
     * @notice Test 16: Unregister then re-register same vault
     */
    function testUnregisterThenReregisterSameVault() public {
        shareToken.registerVault(address(tokens[0]), address(vaults[0]));
        assertTrue(shareToken.isVault(address(vaults[0])), "Should be registered");

        shareToken.unregisterVault(address(tokens[0]));
        assertFalse(shareToken.isVault(address(vaults[0])), "Should be unregistered");

        // Re-register
        shareToken.registerVault(address(tokens[0]), address(vaults[0]));
        assertTrue(shareToken.isVault(address(vaults[0])), "Should be registered again");
    }

    /**
     * @notice Test 17: getVaultCount is consistent with array length
     */
    function testVaultCountConsistentWithArrayLength() public {
        for (uint256 i = 0; i < 7; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));

            address[] memory registeredVaults = shareToken.getRegisteredVaults();
            assertEq(shareToken.getVaultCount(), registeredVaults.length, "Count should match array length");
        }
    }

    /**
     * @notice Test 18: Large enumeration (10 vaults) maintains order
     */
    function testLargeEnumerationMaintainsOrder() public {
        for (uint256 i = 0; i < MAX_VAULTS; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        address[] memory registeredVaults = shareToken.getRegisteredVaults();
        address[] memory registeredAssets = shareToken.getRegisteredAssets();

        for (uint256 i = 0; i < MAX_VAULTS; i++) {
            assertEq(registeredVaults[i], address(vaults[i]), "Vault order should match");
            assertEq(registeredAssets[i], address(tokens[i]), "Asset order should match");
        }
    }

    /**
     * @notice Test 19: isVault works correctly at boundary (MAX_VAULTS - 1)
     */
    function testIsVaultAtMaxVaultsBoundary() public {
        // Register MAX_VAULTS - 1
        for (uint256 i = 0; i < MAX_VAULTS - 1; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        // All should be registered
        for (uint256 i = 0; i < MAX_VAULTS - 1; i++) {
            assertTrue(shareToken.isVault(address(vaults[i])), "Vault should be registered");
        }

        // Next one should not be
        assertFalse(shareToken.isVault(address(vaults[MAX_VAULTS - 1])), "Next vault should not be registered");
    }

    /**
     * @notice Test 20: Empty enumeration after removing all vaults
     */
    function testEmptyEnumerationAfterRemovingAll() public {
        for (uint256 i = 0; i < 3; i++) {
            shareToken.registerVault(address(tokens[i]), address(vaults[i]));
        }

        for (uint256 i = 0; i < 3; i++) {
            shareToken.unregisterVault(address(tokens[i]));
        }

        assertEq(shareToken.getVaultCount(), 0, "Count should be 0");

        address[] memory registeredVaults = shareToken.getRegisteredVaults();
        assertEq(registeredVaults.length, 0, "Vaults array should be empty");

        address[] memory assets = shareToken.getRegisteredAssets();
        assertEq(assets.length, 0, "Assets array should be empty");
    }
}
