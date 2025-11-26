// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IERC7575
 * @dev Interface of the ERC7575 "Multi-Asset ERC-4626 Vaults", as defined in
 *      https://eips.ethereum.org/EIPS/eip-7575
 *
 * This standard extends ERC-4626 to support multiple assets or entry points
 * for the same share token. It includes all ERC4626 functions plus the share() function.
 * Interface ID: 0x2f0a18c5
 */
interface IERC7575 {
    /**
     * @dev Emitted when a vault address is updated for a specific asset.
     * @param asset The asset token address
     * @param vault The vault address for this asset
     */
    event VaultUpdate(address indexed asset, address vault);

    /**
     * @dev Returns the address of the share token.
     * This is the token minted to represent ownership in the vault.
     * @return shareTokenAddress The address of the share token
     */
    function share() external view returns (address shareTokenAddress);

    // ERC4626 functions (inherited from IERC4626)
    function asset() external view returns (address assetTokenAddress);
    function totalAssets() external view returns (uint256 totalManagedAssets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function maxMint(address receiver) external view returns (uint256 maxShares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function maxRedeem(address owner) external view returns (uint256 maxShares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

/**
 * @title IERC7575Share
 * @dev Basic interface for share tokens in the ERC7575 ecosystem.
 * This covers the fundamental vault lookup functionality that all share tokens should implement.
 * Interface ID: 0x3749710f
 */
interface IERC7575Share {
    /**
     * @dev Returns the vault address for a specific asset.
     * Allows share tokens to point back to their vaults.
     * @param asset The asset token address
     * @return vault The vault address that handles this asset
     */
    function vault(address asset) external view returns (address vault);

    /**
     * @dev Returns all registered assets in the multi-asset system.
     * @return assets Array of all asset addresses that have registered vaults
     */
    function getRegisteredAssets() external view returns (address[] memory assets);

    /**
     * @dev Emitted when a vault address is updated for a specific asset.
     * @param asset The asset token address
     * @param vault The vault address for this asset
     */
    event VaultUpdate(address indexed asset, address vault);
}

/**
 * @title IERC7575ShareExtended
 * @dev Full interface for share tokens in the ERC7575 ecosystem with advanced features.
 * Extends the basic interface with optimization functions for upgradeable implementations.
 * Interface ID: 0x0a13f305
 */
interface IERC7575ShareExtended is IERC7575Share {
    /**
     * @dev Returns both circulating supply and total normalized assets in a single optimized call.
     * This is the preferred method for conversion calculations as it reduces gas usage.
     * @return circulatingSupply Total supply minus shares held by vaults for redemption claims
     * @return totalNormalizedAssets Total normalized assets (18 decimals) across all vaults
     */
    function getCirculatingSupplyAndAssets() external view returns (uint256 circulatingSupply, uint256 totalNormalizedAssets);
}
