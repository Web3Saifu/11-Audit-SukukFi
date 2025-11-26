// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockAsset} from "./MockAsset.sol";
import {Test} from "forge-std/Test.sol";

contract MockAssetTest is Test {
    MockAsset public mockAsset;
    address public user = address(0x1);

    function setUp() public {
        mockAsset = new MockAsset();
    }

    function testName() public view {
        assertEq(mockAsset.name(), "Mock Asset");
    }

    function testSymbol() public view {
        assertEq(mockAsset.symbol(), "MOCK");
    }

    function testMint() public {
        uint256 amount = 1000e18;
        mockAsset.mint(user, amount);
        assertEq(mockAsset.balanceOf(user), amount);
    }

    function testTotalSupply() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 500e18;

        mockAsset.mint(user, amount1);
        mockAsset.mint(address(0x2), amount2);

        assertEq(mockAsset.totalSupply(), amount1 + amount2);
    }
}
