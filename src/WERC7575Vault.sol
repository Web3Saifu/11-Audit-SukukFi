// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {DecimalConstants} from "./DecimalConstants.sol";
import {SafeTokenTransfers} from "./SafeTokenTransfers.sol";
import {WERC7575ShareToken} from "./WERC7575ShareToken.sol";
import {IERC7575} from "./interfaces/IERC7575.sol";
import {IERC7575Errors} from "./interfaces/IERC7575Errors.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**_asset = real money
_shareToken = system receipt token
_scalingFactor = math bridge
_isActive = emergency switch


1. previewDeposit(100)
   → convert assets → shares

2. safeTransferFrom(user → vault, 100 USDC)

3. shareToken.mint(user, shares)

4. emit Deposit event



Assets go INTO vault
Shares go TO user
*/


contract WERC7575Vault is IERC7575, ERC165, ReentrancyGuard, Ownable2Step, Pausable, IERC7575Errors {
    using SafeERC20 for IERC20Metadata;

    /**
     * @dev Emitted when assets are deposited into the vault
     * @param sender The address that initiated the deposit
     * @param owner The address that received the shares
     * @param assets The amount of assets deposited
     * @param shares The amount of shares minted
     */
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /**
     * @dev Emitted when assets are withdrawn from the vault
     * @param sender The address that initiated the withdrawal
     * @param receiver The address that received the assets
     * @param owner The address that owned the shares
     * @param assets The amount of assets withdrawn
     * @param shares The amount of shares burned
     */
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    event VaultActiveStateChanged(bool indexed isActive);

    address private _asset; // 20 bytes//_asset → always points to USDC contract
    uint64 private _scalingFactor; // 8 bytes//converts
    bool private _isActive; // 1 byte - packs with _asset and _scalingFactor in same slot
    WERC7575ShareToken private _shareToken;  //@audit-info _shareToken is the ERC20 “receipt token” contract that represents ownership of the vault.

    /**
     * @dev Initializes a synchronous ERC4626 vault for the multi-asset system (ERC7575 compliant)
     *
     * Creates a simple, synchronous vault that enables immediate deposit/redeem operations
     * for a single asset. Integrates with the shared ShareToken to participate in the
     * multi-asset vault ecosystem.
     *
     * VAULT ARCHITECTURE:
     * - Synchronous operations: deposits and redeems are immediate
     * - Single asset per vault (paired asset-vault relationship)
     * - Shares minted/burned directly (no async requests)
     * - Integrates with multi-asset ShareToken
     * - Can be paused by owner for emergency situations
     *
     * SPECIFICATION COMPLIANCE:
     * - ERC7575: Multi-asset vault standard
     * - ERC4626: Complete tokenized vault functionality
     * - Decimal normalization: 6-18 decimals for assets, 18 for shares
     *
     * INITIALIZATION:
     * After deployment, the owner must:
     * 1. Call shareToken.registerVault(asset, vault_address)
     * 2. Set vault as active if needed (defaults to active)
     *
     * VALIDATION:
     * - Asset must be valid ERC20 with 6-18 decimals
     * - ShareToken must be valid ERC20 with 18 decimals
     * - ShareToken address must not be zero
     * - Scaling factor must fit in uint64
     *
     * @param asset_ The underlying ERC20 asset token (e.g., USDC, USDT)
     * @param shareToken_ The ERC7575 share token for multi-asset vault system
     *
     * @custom:throws ZeroAddress If shareToken_ is zero address
     * @custom:throws UnsupportedAssetDecimals If asset decimals are not 6-18
     * @custom:throws WrongDecimals If shareToken decimals are not 18
     * @custom:throws AssetDecimalsFailed If asset.decimals() call fails
     * @custom:throws ScalingFactorTooLarge If scaling factor exceeds uint64 max
     */
    constructor(address asset_, WERC7575ShareToken shareToken_) Ownable(msg.sender) {
        // Validate asset compatibility
        uint8 assetDecimals;
        try IERC20Metadata(asset_).decimals() returns (uint8 decimals) {//USDC returns → 6
            if (decimals < DecimalConstants.MIN_ASSET_DECIMALS || decimals > DecimalConstants.SHARE_TOKEN_DECIMALS) {
                revert UnsupportedAssetDecimals();
            }
            assetDecimals = decimals;//Store verified decimals for later use in scaling factor calculation
        } catch {
            revert AssetDecimalsFailed();
        }
        // Validate share token compatibility and enforce 18 decimals
        if (address(shareToken_) == address(0)) revert ZeroAddress();
        if (shareToken_.decimals() != DecimalConstants.SHARE_TOKEN_DECIMALS) {//shares are always in 18-decimal precision system
            revert WrongDecimals();
        }

        // Precompute scaling factor: 10^(18 - assetDecimals)
        // Max scaling factor is 10^12 (for 6 decimals) which fits in uint64
        uint256 scalingFactor = 10 ** (DecimalConstants.SHARE_TOKEN_DECIMALS - assetDecimals);
        if (scalingFactor > type(uint64).max) revert ScalingFactorTooLarge();

        _asset = asset_;
        _scalingFactor = uint64(scalingFactor);//“how to convert USDC → shares”
        _isActive = true; // Vault is active by default    vault is OPEN immediately after deployment
        _shareToken = shareToken_;

        // Note: Owner must separately call shareToken.registerVault(asset, vault) after deployment
    }

    /**
     * @dev Pause all vault operations. Only callable by owner.
     * Used for emergency situations to halt deposits, withdrawals, mints, and redeems.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause all vault operations. Only callable by owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Sets the vault active state (only owner)
     * @param _active True to activate, false to deactivate
     */
    function setVaultActive(bool _active) external onlyOwner {
        _isActive = _active;
        emit VaultActiveStateChanged(_active);
    }

    /**
     * @dev Returns whether the vault is active and accepting deposits
     * @return True if vault is active
     */
    function isVaultActive() external view returns (bool) {
        return _isActive;
    }

    /**
     * @dev Returns true if this contract implements the interface defined by interfaceId
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return bool True if the contract implements interfaceId
     * //If someone asks:
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {//This function checks whether the contract supports a specific interface (ERC-165 standard).         If someone asks:“Do you support ERC7575?”
        return interfaceId == type(IERC7575).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns the address of the share token contract
     * @return address The ERC7575 share token address
     */
    function share() external view returns (address) {//“Which token represents ownership of this vault?”
        return address(_shareToken);
    }

    /**
     * @dev Returns the address of the underlying asset token
     * @return address The ERC20 asset token address
     */
    function asset() external view returns (address) {//_asset = USDC contract address
        return _asset;
    }

    /**
     * @dev Returns the total amount of underlying assets held by the vault
     * @return uint256 Total assets held in the vault
     */
    function totalAssets() public view returns (uint256) {//Returns how much real USDC is inside the vault right now.
        return IERC20Metadata(_asset).balanceOf(address(this));
    }

    /**
     * @dev Converts asset amount to equivalent share amount
     * @param assets Amount of assets to convert
     * @return uint256 Equivalent amount of shares
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @dev Converts share amount to equivalent asset amount
     * @param shares Amount of shares to convert
     * @return uint256 Equivalent amount of assets
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @dev Converts assets to shares using decimal normalization for stablecoins
     * @param assets Amount of assets to convert
     * @return shares Amount of shares equivalent to assets
     *
     * Formula: shares = assets * 10^(18 - assetDecimals)
     *
     * For stablecoins with no yield:
     * - Share decimals: enforced to be 18 in ShareToken constructor
     * - Asset decimals: varies (6 for USDC, 18 for DAI, etc.)
     * - This provides 1:1 value conversion with decimal normalization
     * - No first depositor attack possible since conversion is deterministic
     * - No manipulation possible since no dependency on totalSupply or totalAssets
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {//Shares = Assets × scalingFactor,,  Floor, // round down  Ceil // round up
        // ShareToken always has 18 decimals, assetDecimals ∈ [6, 18]
        // shares = assets * _scalingFactor where _scalingFactor = 10^(18 - assetDecimals)
        // Use Math.mulDiv to prevent overflow on large amounts
        return Math.mulDiv(assets, uint256(_scalingFactor), 1, rounding);//scalingFactor   = 10^12
    }

    /**
     * @dev Converts shares to assets using decimal normalization for stablecoins
     * @param shares Amount of shares to convert
     * @param rounding Rounding direction (Floor = favor vault, Ceil = favor user)
     * @return assets Amount of assets equivalent to shares
     *
     * Formula: assets = shares * 10^(assetDecimals) / 10^(shareDecimals)
     *
     * For stablecoins with no yield:
     * - Share decimals: queried from share token (typically 18)
     * - Asset decimals: varies (6 for USDC, 18 for DAI, etc.)
     * - This provides 1:1 value conversion with decimal normalization
     * - No first depositor attack possible since conversion is deterministic
     * - No manipulation possible since no dependency on totalSupply or totalAssets
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        // ShareToken always has 18 decimals, assetDecimals ∈ [6, 18]
        // When _scalingFactor == 1 (assetDecimals == 18): assets = shares
        // When _scalingFactor > 1 (assetDecimals < 18): assets = shares / _scalingFactor
        if (_scalingFactor == 1) {
            return shares;
        } else {
            return Math.mulDiv(shares, 1, uint256(_scalingFactor), rounding);
        }
    }

    /**
     * @dev Preview shares received for depositing assets
     * Uses Floor rounding to give slightly fewer shares to user (favors vault)
     */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @dev Preview assets needed to mint shares
     * Uses Ceil rounding to require slightly more assets from user (favors vault)
     */
    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /**
     * @dev Preview shares needed to withdraw assets
     * Uses Ceil rounding to require slightly more shares from user (favors vault)
     */
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /**
     * @dev Preview assets received for redeeming shares
     * Uses Floor rounding to give slightly fewer assets to user (favors vault)
     */
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @dev Returns the maximum amount of assets that can be deposited
     * @return uint256 Maximum deposit amount (unlimited)
     *
     * Note: Receiver parameter is unused as there are no deposit limits
     */
    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev Returns the maximum amount of shares that can be minted
     * @return uint256 Maximum mint amount (unlimited)
     *
     * Note: Receiver parameter is unused as there are no mint limits
     */
    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev Returns the maximum amount of assets that can be withdrawn by owner
     * @param owner The address that owns the shares
     * @return uint256 Maximum withdrawal amount based on share balance
     */
    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(_shareToken.balanceOf(owner), Math.Rounding.Floor);
    }

    /**
     * @dev Returns the maximum amount of shares that can be redeemed by owner
     * @param owner The address that owns the shares
     * @return uint256 Maximum redeem amount (owner's full share balance)
     */
    function maxRedeem(address owner) public view returns (uint256) {
        return _shareToken.balanceOf(owner);
    }

    /**
     * @dev Internal function to handle deposit/mint logic
     * @param assets Amount of assets to transfer
     * @param shares Amount of shares to mint
     * @param receiver Address to receive shares
     */
    function _deposit(uint256 assets, uint256 shares, address receiver) internal {//👉 This function takes USDC from user and gives them shares   msg.sender and receiver can be same OR different
        if (!_isActive) revert VaultNotActive();
        if (receiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(address(0));
        }
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();

        SafeTokenTransfers.safeTransferFrom(_asset, msg.sender, address(this), assets);//👉 Move USDC from user → vault    Alice → Vault: 100 USDC

        _shareToken.mint(receiver, shares);//Alice gets 100 shares
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev Deposits exact amount of assets and receives corresponding shares (ERC4626 compliant)
     *
     * Synchronous deposit operation: immediately mints shares and transfers assets.
     * Simple one-step process without async state management.
     *
     * OPERATION:
     * - Previews share amount for the deposit
     * - Transfers assets from caller to vault
     * - Mints shares to receiver
     *
     * SECURITY:
     * - Reentrancy protected
     * - Paused state check
     * - Vault must be active
     * - Zero address validation
     *
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the minted shares
     *
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) public nonReentrant whenNotPaused returns (uint256 shares) {
        shares = previewDeposit(assets);
        _deposit(assets, shares, receiver);
    }

    /**
     * @dev Mints exact amount of shares by depositing necessary assets (ERC4626 compliant)
     *
     * Synchronous mint operation: caller specifies desired shares, assets calculated.
     * Transfers required assets and immediately mints specified shares.
     *
     * OPERATION:
     * - Previews asset amount needed for shares
     * - Transfers required assets from caller
     * - Mints exact shares to receiver
     *
     * USE CASE:
     * - When you want exactly X shares (not Y assets)
     * - May require more assets due to rounding
     *
     * @param shares Amount of shares to mint (exact)
     * @param receiver Address to receive the minted shares
     *
     * @return assets Amount of assets required for the mint
     */
    function mint(uint256 shares, address receiver) public nonReentrant whenNotPaused returns (uint256 assets) {
        assets = previewMint(shares);
        _deposit(assets, shares, receiver);
    }

    /**
     * @dev Internal function to handle withdraw/redeem logic
     * @param assets Amount of assets to transfer
     * @param shares Amount of shares to burn
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     */
    function _withdraw(uint256 assets, uint256 shares, address receiver, address owner) internal {
        if (receiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(address(0));
        }
        if (owner == address(0)) {
            revert IERC20Errors.ERC20InvalidSender(address(0));
        }
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();

        _shareToken.spendSelfAllowance(owner, shares);//Only owner OR approved spender can burn shares
        _shareToken.burn(owner, shares);//"User is exiting the vault"
        SafeTokenTransfers.safeTransfer(_asset, receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);//_asset = stored token addressm.,,receiver gets the money ,,The vault sends tokens (_asset like USDC) to receiver
    }

    /**
     * @dev Withdraws exact amount of assets from vault by burning shares (ERC4626 compliant)
     *
     * Synchronous withdrawal operation: caller specifies assets, shares calculated.
     * Burns required shares and immediately transfers assets to receiver.
     *
     * OPERATION:
     * - Previews share amount needed for assets
     * - Burns required shares from owner
     * - Transfers exact assets to receiver
     *
     * AUTHORIZATION:
     * - msg.sender must be owner OR have allowance for the shares
     * - Allows delegation to withdrawal operators
     *
     * @param assets Amount of assets to withdraw (exact)
     * @param receiver Address to receive the assets
     * @param owner Address that owns the shares to be burned
     *
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant whenNotPaused returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(assets, shares, receiver, owner);
    }

    /**
     * @dev Redeems exact amount of shares for assets (ERC4626 compliant)
     *
     * Synchronous redemption operation: caller specifies shares, assets calculated.
     * Burns exact shares and transfers corresponding assets to receiver.
     *
     * OPERATION:
     * - Previews asset amount for shares
     * - Burns exact shares from owner
     * - Transfers corresponding assets to receiver
     *
     * AUTHORIZATION:
     * - msg.sender must be owner OR have allowance for the shares
     * - Allows delegation to redemption operators
     *
     * USE CASE:
     * - When you want to burn exactly X shares (not Y assets)
     * - Receives at least minimum due to rounding down
     *
     * @param shares Amount of shares to redeem (exact)
     * @param receiver Address to receive the assets
     * @param owner Address that owns the shares to be burned
     *
     * @return assets Amount of assets withdrawn
     */
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant whenNotPaused returns (uint256 assets) {
        assets = previewRedeem(shares);
        _withdraw(assets, shares, receiver, owner);
    }
}
