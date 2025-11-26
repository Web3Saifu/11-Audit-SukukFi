// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Faucet6} from "../src/ERC20Faucet6.sol";
import {WERC7575ShareToken} from "../src/WERC7575ShareToken.sol";
import {WERC7575Vault} from "../src/WERC7575Vault.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test, console} from "forge-std/Test.sol";

contract ERC20Faucet6DecimalsWERC7575Test is Test {
    WERC7575ShareToken public shareToken;
    WERC7575Vault public usdcVault;
    WERC7575Vault public usdtVault;
    ERC20Faucet6 public usdc;
    ERC20Faucet6 public usdt;

    address public owner;
    address public validator;
    uint256 public validatorPrivateKey;
    address public user;

    function setUp() public {
        owner = address(this);
        (validator, validatorPrivateKey) = makeAddrAndKey("validator");
        user = makeAddr("user");

        // Deploy 6-decimal stablecoins
        usdc = new ERC20Faucet6("USD Coin", "USDC", 1_000_000 * 10 ** 6);
        usdt = new ERC20Faucet6("Tether USD", "USDT", 1_000_000 * 10 ** 6);

        // Deploy shared 18-decimal share token
        shareToken = new WERC7575ShareToken("wUSD", "WUSD");

        // Deploy vaults for both assets and register them
        usdcVault = new WERC7575Vault(address(usdc), shareToken);
        usdtVault = new WERC7575Vault(address(usdt), shareToken);
        shareToken.registerVault(address(usdc), address(usdcVault));
        shareToken.registerVault(address(usdt), address(usdtVault));
        shareToken.setValidator(validator);
        shareToken.setKycAdmin(validator);
        shareToken.setRevenueAdmin(validator);

        // KYC user to allow mint/burn via vault (validator)
        vm.prank(validator);
        shareToken.setKycVerified(user, true);

        // Fund user with 6-decimal tokens from initial supply (avoid faucet cooldown)
        usdc.transfer(user, 10_000 * 10 ** 6);
        usdt.transfer(user, 10_000 * 10 ** 6);
    }

    function testDecimalsAndRegistration() public {
        assertEq(IERC20Metadata(address(usdc)).decimals(), 6);
        assertEq(IERC20Metadata(address(usdt)).decimals(), 6);
        assertEq(usdcVault.asset(), address(usdc));
        assertEq(usdtVault.asset(), address(usdt));
        // Registered in share token
        assertEq(shareToken.vault(address(usdc)), address(usdcVault));
        assertEq(shareToken.vault(address(usdt)), address(usdtVault));
    }

    function testDepositRedeemScaling_USDC6() public {
        uint256 depositAssets = 1 * 10 ** 6; // 1.0 USDC
        uint256 expectedShares = 1 * 10 ** 18; // scaling: 10^(18-6)

        // Approve and deposit
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(usdcVault), depositAssets);
        uint256 mintedShares = usdcVault.deposit(depositAssets, user);
        vm.stopPrank();

        assertEq(mintedShares, expectedShares, "shares mismatch for 6-dec asset");
        assertEq(shareToken.balanceOf(user), expectedShares);
        assertEq(usdcVault.totalAssets(), depositAssets);
        assertEq(usdcVault.previewDeposit(depositAssets), expectedShares);
        assertEq(usdcVault.previewRedeem(expectedShares), depositAssets);

        // Permit self-allowance via validator signature, then redeem
        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user, user, expectedShares, shareToken.nonces(user), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", shareToken.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorPrivateKey, digest);

        vm.startPrank(user);
        shareToken.permit(user, user, expectedShares, deadline, v, r, s);
        uint256 redeemedAssets = usdcVault.redeem(expectedShares, user, user);
        vm.stopPrank();

        assertEq(redeemedAssets, depositAssets, "assets mismatch on redeem for 6-dec asset");
        assertEq(shareToken.balanceOf(user), 0);
    }

    function testIndependentVaults_USDT6_and_USDC6() public {
        // Deposit 2 USDT in USDT vault and 3 USDC in USDC vault
        uint256 depositUSDT = 2 * 10 ** 6;
        uint256 depositUSDC = 3 * 10 ** 6;

        vm.startPrank(user);
        IERC20(address(usdt)).approve(address(usdtVault), depositUSDT);
        IERC20(address(usdc)).approve(address(usdcVault), depositUSDC);
        uint256 sharesUSDT = usdtVault.deposit(depositUSDT, user);
        uint256 sharesUSDC = usdcVault.deposit(depositUSDC, user);
        vm.stopPrank();

        assertEq(sharesUSDT, 2 * 10 ** 18);
        assertEq(sharesUSDC, 3 * 10 ** 18);
        assertEq(usdtVault.totalAssets(), depositUSDT);
        assertEq(usdcVault.totalAssets(), depositUSDC);
    }
}
