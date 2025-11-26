// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet} from "../src/ERC20Faucet.sol";
import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, console} from "forge-std/Test.sol";

/**
 * @title PaginationEfficiencyTest
 * @dev Test to compare gas efficiency between old and new pagination approaches
 */
contract PaginationEfficiencyTest is Test {
    ERC7575VaultUpgradeable public vault;
    ShareTokenUpgradeable public shareToken;
    ERC20Faucet public asset;

    address[] public users;
    uint256 constant NUM_USERS = 100; // Test with 100 active requesters

    function setUp() public {
        // Deploy asset
        asset = new ERC20Faucet("TestToken", "TEST", 1000000 * 1e18);

        // Deploy ShareToken implementation and proxy
        ShareTokenUpgradeable shareTokenImpl = new ShareTokenUpgradeable();
        bytes memory shareTokenData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Test Shares", "TST", address(this));
        ERC1967Proxy shareTokenProxy = new ERC1967Proxy(address(shareTokenImpl), shareTokenData);
        shareToken = ShareTokenUpgradeable(address(shareTokenProxy));

        // Deploy Vault implementation and proxy
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, asset, address(shareToken), address(this));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultData);
        vault = ERC7575VaultUpgradeable(address(vaultProxy));

        // Register vault
        shareToken.registerVault(address(asset), address(vault));

        // Create users and deposit requests
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = address(uint160(1000 + i));
            users.push(user);

            // Give user tokens and make deposit request
            vm.warp(block.timestamp + 2 hours);
            asset.faucetAmountFor(user, 10000e18);

            vm.startPrank(user);
            asset.approve(address(vault), 1000e18);
            vault.requestDeposit(1000e18, user, user);
            vm.stopPrank();
        }

        console.log("Setup complete with", NUM_USERS, "active deposit requesters");
    }

    /// @dev Test gas efficiency of OLD approach (2 RPC calls)
    function test_OldApproach_TwoCallsRequired() public view {
        uint256 gasStart = gasleft();

        // Call 1: Get addresses using paginated controller status and extract addresses
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statusResult, uint256 total, bool hasMore) = vault.getDepositControllerStatusBatchPaginated(0, 50);

        address[] memory addresses = new address[](statusResult.length);
        for (uint256 i = 0; i < statusResult.length; i++) {
            addresses[i] = statusResult[i].controller;
        }

        uint256 gasAfterCall1 = gasleft();

        // Call 2: Get status using controller status function (simulates old approach)
        ERC7575VaultUpgradeable.ControllerStatus[] memory statuses = vault.getControllerStatusBatch(addresses);

        uint256 gasAfterCall2 = gasleft();

        uint256 call1Gas = gasStart - gasAfterCall1;
        uint256 call2Gas = gasAfterCall1 - gasAfterCall2;
        uint256 totalGas = gasStart - gasAfterCall2;

        console.log("=== OLD APPROACH (2 RPC Calls) ===");
        console.log("Call 1 gas (get addresses):", call1Gas);
        console.log("Call 2 gas (get status):", call2Gas);
        console.log("Total gas:", totalGas);
        console.log("Addresses returned:", addresses.length);
        console.log("Statuses returned:", statuses.length);
        console.log("");
    }

    /// @dev Test gas efficiency of NEW approach (1 RPC call)
    function test_NewApproach_SingleCallRequired() public view {
        uint256 gasStart = gasleft();

        // Single call: Get status directly
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses, uint256 total, bool hasMore) = vault.getDepositControllerStatusBatchPaginated(0, 50);

        uint256 gasAfterCall = gasleft();
        uint256 totalGas = gasStart - gasAfterCall;

        console.log("=== NEW APPROACH (1 RPC Call) ===");
        console.log("Single call gas:", totalGas);
        console.log("Statuses returned:", statuses.length);
        console.log("Total active requesters:", total);
        console.log("Has more:", hasMore);
        console.log("");
    }

    /// @dev Combined test to show efficiency comparison
    function test_EfficiencyComparison() public view {
        console.log("=== EFFICIENCY COMPARISON ===");

        // OLD APPROACH (2 calls) - simulated using new functions
        uint256 gasStart1 = gasleft();
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statusResult1,,) = vault.getDepositControllerStatusBatchPaginated(0, 50);

        address[] memory addresses = new address[](statusResult1.length);
        for (uint256 i = 0; i < statusResult1.length; i++) {
            addresses[i] = statusResult1[i].controller;
        }
        uint256 gasAfter1 = gasleft();
        ERC7575VaultUpgradeable.ControllerStatus[] memory statuses1 = vault.getControllerStatusBatch(addresses);
        uint256 gasAfter2 = gasleft();

        uint256 oldTotalGas = gasStart1 - gasAfter2;

        // NEW APPROACH
        uint256 gasStart3 = gasleft();
        (ERC7575VaultUpgradeable.ControllerStatus[] memory statuses2,,) = vault.getDepositControllerStatusBatchPaginated(0, 50);
        uint256 gasAfter3 = gasleft();

        uint256 newTotalGas = gasStart3 - gasAfter3;

        console.log("Old approach (2 calls):", oldTotalGas, "gas");
        console.log("New approach (1 call): ", newTotalGas, "gas");

        if (oldTotalGas > newTotalGas) {
            uint256 savings = oldTotalGas - newTotalGas;
            uint256 savingsPercent = (savings * 100) / oldTotalGas;
            console.log("Gas savings:", savings, "gas");
            console.log("Savings percent:", savingsPercent, "%");
        } else {
            console.log("No gas savings detected");
        }

        // Verify results are identical
        require(statuses1.length == statuses2.length, "Different result lengths");
        for (uint256 i = 0; i < statuses1.length; i++) {
            require(statuses1[i].controller == statuses2[i].controller, "Different controller");
            // Check controller status fields
            require(statuses1[i].pendingDepositAssets == statuses2[i].pendingDepositAssets, "Different pendingDepositAssets");
            require(statuses1[i].pendingRedeemShares == statuses2[i].pendingRedeemShares, "Different pendingRedeemShares");
        }
        console.log("Both approaches return identical results");
    }
}
