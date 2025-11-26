// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Interface for vault metrics to check pending requests and active users
interface IVaultMetrics {
    struct VaultMetrics {
        uint256 totalPendingDepositAssets;
        uint256 totalClaimableRedeemAssets;
        uint256 totalCancelDepositAssets; // ERC7887 cancelation assets
        uint64 scalingFactor;
        uint256 totalAssets;
        uint256 availableForInvestment;
        uint256 activeDepositRequestersCount;
        uint256 activeRedeemRequestersCount;
        bool isActive;
        address asset;
        address shareToken;
        address investmentManager;
        address investmentVault;
    }

    function getVaultMetrics() external view returns (VaultMetrics memory);
}
