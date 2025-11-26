// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";

import {IERC7540Operator} from "../src/interfaces/IERC7540.sol";
import {MockAsset} from "./MockAsset.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Test} from "forge-std/Test.sol";

contract OperatorInterfaceComplianceTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    MockAsset public asset;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        vm.startPrank(owner);

        asset = new MockAsset();

        // Deploy ShareToken with proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenInitData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Test Shares", "TST", owner);
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenInitData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault with proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(address(asset)), address(shareToken), owner);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault with share token
        shareToken.registerVault(address(asset), address(vault));

        vm.stopPrank();
    }

    /// @dev Test that ShareToken implements IERC7540Operator interface
    function test_ShareToken_ImplementsIERC7540Operator() public view {
        // Test ERC165 interface detection
        assertTrue(shareToken.supportsInterface(type(IERC7540Operator).interfaceId), "ShareToken should support IERC7540Operator");

        // Test can be cast to IERC7540Operator
        IERC7540Operator operatorInterface = IERC7540Operator(address(shareToken));

        // Interface should be valid (no revert on casting)
        assertEq(address(operatorInterface), address(shareToken), "Interface casting should work");
    }

    /// @dev Test that Vault implements IERC7540Operator interface
    function test_Vault_ImplementsIERC7540Operator() public view {
        // Test ERC165 interface detection
        assertTrue(vault.supportsInterface(type(IERC7540Operator).interfaceId), "Vault should support IERC7540Operator");

        // Test can be cast to IERC7540Operator
        IERC7540Operator operatorInterface = IERC7540Operator(address(vault));

        // Interface should be valid (no revert on casting)
        assertEq(address(operatorInterface), address(vault), "Interface casting should work");
    }

    /// @dev Test that operator functions work correctly through both interfaces
    function test_OperatorFunctions_WorkThroughBothInterfaces() public {
        vm.startPrank(alice);

        // Set operator through ShareToken interface
        IERC7540Operator shareTokenOperator = IERC7540Operator(address(shareToken));
        assertTrue(shareTokenOperator.setOperator(bob, true), "setOperator should return true");

        // Check operator status through ShareToken interface
        assertTrue(shareTokenOperator.isOperator(alice, bob), "Bob should be operator for Alice via ShareToken");

        // Check operator status through Vault interface
        IERC7540Operator vaultOperator = IERC7540Operator(address(vault));
        assertTrue(vaultOperator.isOperator(alice, bob), "Bob should be operator for Alice via Vault");

        // Set operator through Vault interface
        assertTrue(vaultOperator.setOperator(bob, false), "setOperator via vault should return true");

        // Check operator status is updated in both interfaces
        assertFalse(shareTokenOperator.isOperator(alice, bob), "Bob should no longer be operator via ShareToken");
        assertFalse(vaultOperator.isOperator(alice, bob), "Bob should no longer be operator via Vault");

        vm.stopPrank();
    }

    /// @dev Test that ShareToken is the centralized storage point
    function test_ShareToken_IsCentralizedStoragePoint() public {
        vm.startPrank(alice);

        // Set operator through ShareToken directly
        shareToken.setOperator(bob, true);

        // Should be visible through vault's operator interface
        assertTrue(vault.isOperator(alice, bob), "Operator set via ShareToken should be visible through Vault");

        // Set operator through vault interface
        vault.setOperator(bob, false);

        // Should be updated in ShareToken's storage
        assertFalse(shareToken.isOperator(alice, bob), "Operator change via Vault should update ShareToken storage");

        vm.stopPrank();
    }

    /// @dev Test that events are emitted correctly from both interfaces
    function test_OperatorSet_EventsEmittedCorrectly() public {
        vm.startPrank(alice);

        // Expect event from ShareToken
        vm.expectEmit(true, true, true, true);
        emit IERC7540Operator.OperatorSet(alice, bob, true);
        shareToken.setOperator(bob, true);

        // Expect events from both ShareToken and Vault when setting via Vault
        // (Vault delegates to ShareToken, so ShareToken emits, then Vault emits its own)
        vm.expectEmit(true, true, true, true);
        emit IERC7540Operator.OperatorSet(alice, bob, false);
        vm.expectEmit(true, true, true, true);
        emit IERC7540Operator.OperatorSet(alice, bob, false);
        vault.setOperator(bob, false);

        vm.stopPrank();
    }
}
