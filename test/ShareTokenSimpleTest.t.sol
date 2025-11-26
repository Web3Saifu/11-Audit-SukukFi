// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet6} from "../src/ERC20Faucet6.sol";
import {ERC7575VaultUpgradeable} from "../src/ERC7575VaultUpgradeable.sol";
import {ShareTokenUpgradeable} from "../src/ShareTokenUpgradeable.sol";
import {IERC7575Errors} from "../src/interfaces/IERC7575Errors.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

contract ShareTokenSimpleTest is Test {
    ShareTokenUpgradeable shareToken;
    ERC20Faucet6 asset1;
    ERC20Faucet6 asset2;
    ERC7575VaultUpgradeable vault1;
    ERC7575VaultUpgradeable vault2;

    function setUp() public {
        // Deploy ShareToken implementation and proxy
        ShareTokenUpgradeable impl = new ShareTokenUpgradeable();
        bytes memory initData = abi.encodeWithSelector(ShareTokenUpgradeable.initialize.selector, "Test Shares", "TST", address(this));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        shareToken = ShareTokenUpgradeable(address(proxy));

        // Deploy test assets
        asset1 = new ERC20Faucet6("Asset 1", "A1", 1000000 * 1e6);
        asset2 = new ERC20Faucet6("Asset 2", "A2", 1000000 * 1e6);

        // Deploy real vault contracts
        vault1 = _deployVault(address(asset1));
        vault2 = _deployVault(address(asset2));
    }

    function _deployVault(address asset) internal returns (ERC7575VaultUpgradeable) {
        ERC7575VaultUpgradeable vaultImpl = new ERC7575VaultUpgradeable();
        bytes memory vaultInitData = abi.encodeWithSelector(ERC7575VaultUpgradeable.initialize.selector, IERC20Metadata(asset), address(shareToken), address(this));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        return ERC7575VaultUpgradeable(address(vaultProxy));
    }

    function test_RegisterVault() public {
        // Register vault1 for asset1
        shareToken.registerVault(address(asset1), address(vault1));

        // Check registration
        assertEq(shareToken.vault(address(asset1)), address(vault1));
        assertTrue(shareToken.isVault(address(vault1)));

        // Check vault can mint/burn (modifier works)
        vm.prank(address(vault1));
        shareToken.mint(address(this), 100);
        assertEq(shareToken.balanceOf(address(this)), 100);
    }

    function test_PreventDuplicateRegistration() public {
        // Register vault1 for asset1
        shareToken.registerVault(address(asset1), address(vault1));

        // Deploy another vault for the same asset1 to test duplicate registration
        ERC7575VaultUpgradeable anotherVault1 = _deployVault(address(asset1));

        // Try to register another vault for same asset1 - should fail
        vm.expectRevert(IERC7575Errors.AssetAlreadyRegistered.selector);
        shareToken.registerVault(address(asset1), address(anotherVault1));
    }

    function test_UnauthorizedVaultCannotMint() public {
        // Try to mint from unregistered vault - should fail
        vm.prank(address(vault1));
        vm.expectRevert(IERC7575Errors.Unauthorized.selector);
        shareToken.mint(address(this), 100);
    }
}
