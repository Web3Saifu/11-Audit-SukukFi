# Sponsorname audit details
- Total Prize Pool: XXX XXX USDC (Airtable: Total award pool)
    - HM awards: up to XXX XXX USDC (Airtable: HM (main) pool)
        - If no valid Highs or Mediums are found, the HM pool is $0 (🐺 C4 EM: adjust in case of tiered pools)
    - QA awards: XXX XXX USDC (Airtable: QA pool)
    - Judge awards: XXX XXX USDC (Airtable: Judge Fee)
    - Scout awards: $500 USDC (Airtable: Scout fee - but usually $500 USDC)
    - (this line can be removed if there is no mitigation) Mitigation Review: XXX XXX USDC
- [Read our guidelines for more details](https://docs.code4rena.com/competitions)
- Starts XXX XXX XX 20:00 UTC (ex. `Starts March 22, 2023 20:00 UTC`)
- Ends XXX XXX XX 20:00 UTC (ex. `Ends March 30, 2023 20:00 UTC`)

### ❗ Important notes for wardens
(🐺 C4 staff: delete the PoC requirement section if not applicable - i.e. for non-Solidity/EVM audits.)
1. A coded, runnable PoC is required for all High/Medium submissions to this audit. 
    - This repo includes a basic template to run the test suite.
    - PoCs must use the test suite provided in this repo.
    - Your submission will be marked as Insufficient if the POC is not runnable and working with the provided test suite.
    - Exception: PoC is optional (though recommended) for wardens with signal ≥ 0.68.
1. Judging phase risk adjustments (upgrades/downgrades):
    - High- or Medium-risk submissions downgraded by the judge to Low-risk (QA) will be ineligible for awards.
    - Upgrading a Low-risk finding from a QA report to a Medium- or High-risk finding is not supported.
    - As such, wardens are encouraged to select the appropriate risk level carefully during the submission phase.

## V12 findings (🐺 C4 staff: remove this section for non-Solidity/EVM audits)

[V12](https://v12.zellic.io/) is [Zellic](https://zellic.io)'s in-house AI auditing tool. It is the only autonomous Solidity auditor that [reliably finds Highs and Criticals](https://www.zellic.io/blog/introducing-v12/). All issues found by V12 will be judged as out of scope and ineligible for awards.

V12 findings will be posted in this section within the first two days of the competition.  

## Publicly known issues

_Anything included in this section is considered a publicly known issue and is therefore ineligible for awards._

## 🐺 C4: Begin Gist paste here (and delete this line)





# Scope

*See [scope.txt](https://github.com/code-423n4/2025-11-sukukfi/blob/main/scope.txt)*

### Files in scope


| File   | Logic Contracts | Interfaces | nSLOC | Purpose | Libraries used |
| ------ | --------------- | ---------- | ----- | -----   | ------------ |
| /src/DecimalConstants.sol | 1| **** | 5 | ||
| /src/ERC7575VaultUpgradeable.sol | 1| **** | 737 | |@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol<br>@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol<br>@openzeppelin/contracts/interfaces/draft-IERC6093.sol<br>@openzeppelin/contracts/utils/ReentrancyGuard.sol<br>@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol<br>@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol<br>@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol<br>@openzeppelin/contracts/utils/introspection/IERC165.sol<br>@openzeppelin/contracts/utils/math/Math.sol<br>@openzeppelin/contracts/utils/structs/EnumerableSet.sol|
| /src/SafeTokenTransfers.sol | 1| **** | 19 | |@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol<br>@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol|
| /src/ShareTokenUpgradeable.sol | 1| 2 | 243 | |@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol<br>@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol<br>@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol<br>@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol<br>@openzeppelin/contracts/interfaces/draft-IERC6093.sol<br>@openzeppelin/contracts/token/ERC20/IERC20.sol<br>@openzeppelin/contracts/utils/introspection/IERC165.sol<br>@openzeppelin/contracts/utils/math/Math.sol<br>@openzeppelin/contracts/utils/structs/EnumerableMap.sol|
| /src/WERC7575ShareToken.sol | 1| 1 | 514 | |@openzeppelin/contracts/token/ERC20/ERC20.sol<br>@openzeppelin/contracts/access/Ownable.sol<br>@openzeppelin/contracts/access/Ownable2Step.sol<br>@openzeppelin/contracts/interfaces/draft-IERC6093.sol<br>@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol<br>@openzeppelin/contracts/utils/Nonces.sol<br>@openzeppelin/contracts/utils/Pausable.sol<br>@openzeppelin/contracts/utils/ReentrancyGuard.sol<br>@openzeppelin/contracts/utils/cryptography/ECDSA.sol<br>@openzeppelin/contracts/utils/cryptography/EIP712.sol<br>@openzeppelin/contracts/utils/introspection/ERC165.sol<br>@openzeppelin/contracts/utils/structs/EnumerableMap.sol|
| /src/WERC7575Vault.sol | 1| **** | 152 | |@openzeppelin/contracts/access/Ownable.sol<br>@openzeppelin/contracts/access/Ownable2Step.sol<br>@openzeppelin/contracts/interfaces/draft-IERC6093.sol<br>@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol<br>@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol<br>@openzeppelin/contracts/utils/Pausable.sol<br>@openzeppelin/contracts/utils/ReentrancyGuard.sol<br>@openzeppelin/contracts/utils/introspection/ERC165.sol<br>@openzeppelin/contracts/utils/math/Math.sol|
| **Totals** | **6** | **3** | **1670** | | |

### Files out of scope

*See [out_of_scope.txt](https://github.com/code-423n4/2025-11-sukukfi/blob/main/out_of_scope.txt)*

| File         |
| ------------ |
| ./src/ERC20Faucet.sol |
| ./src/ERC20Faucet6.sol |
| ./src/interfaces/IERC7540.sol |
| ./src/interfaces/IERC7575.sol |
| ./src/interfaces/IERC7575Errors.sol |
| ./src/interfaces/IERC7575MultiAsset.sol |
| ./src/interfaces/IERC7887.sol |
| ./src/interfaces/IVaultMetrics.sol |
| ./test/AdditionalSecurityAndEdgeCases.t.sol |
| ./test/AdminRoleManagement.t.sol |
| ./test/ApprovalAndSignatureMechanisms.t.sol |
| ./test/AuditReproduction.t.sol |
| ./test/CompleteFlowWalkthrough.t.sol |
| ./test/ComprehensiveERC7540ERC7575Test.t.sol |
| ./test/ComprehensiveHelperFunctions.t.sol |
| ./test/ComprehensiveVault.t.sol |
| ./test/ERC20Faucet6DecimalsWERC7575.t.sol |
| ./test/ERC7540AsyncEdgeCases.t.sol |
| ./test/ERC7540ComplianceComplete.t.sol |
| ./test/ERC7540MaxFunctionsTest.t.sol |
| ./test/ERC7575MultiAsset.t.sol |
| ./test/ERC7575Security.t.sol |
| ./test/ERC7575Upgradeable.t.sol |
| ./test/ERC7575VaultUpgradeableCoverageTests.t.sol |
| ./test/ERC7887Compliance.t.sol |
| ./test/EdgeCases_AuthorizationPaths.t.sol |
| ./test/EdgeCases_ComputeRBalanceFlags.t.sol |
| ./test/EdgeCases_KYC.t.sol |
| ./test/EdgeCases_MinimumDepositBoundary.t.sol |
| ./test/EdgeCases_RBatchTransfers_Capping.t.sol |
| ./test/EdgeCases_VaultStateTransitions.t.sol |
| ./test/EdgeCases_ZeroAmounts.t.sol |
| ./test/ForkUpgradeNoCheat.t.sol |
| ./test/GetInvestedAssetsWithRBalance.t.sol |
| ./test/MaxFunctionsBehaviorTest.t.sol |
| ./test/MixedDecimalYieldAccuracy.t.sol |
| ./test/MockAsset.sol |
| ./test/MockAssetTest.sol |
| ./test/MultiStablecoinYieldScenarios.t.sol |
| ./test/MultiVaultEnumeration.t.sol |
| ./test/OffChainHelperFunctions.t.sol |
| ./test/OperatorInterfaceCompliance.t.sol |
| ./test/OperatorRedemptionTest.t.sol |
| ./test/OutstandingSharesValidation.t.sol |
| ./test/OverflowProtection.t.sol |
| ./test/PaginationEfficiencyTest.t.sol |
| ./test/PauseFunctionality.t.sol |
| ./test/PreAuditCriticalTests.t.sol |
| ./test/RegisterVaultInvestmentConfig.t.sol |
| ./test/ShareTokenCompliance.t.sol |
| ./test/ShareTokenSimpleTest.t.sol |
| ./test/ShareTokenUpgradeableCoverageTests.t.sol |
| ./test/SimpleUpgradeDemo.t.sol |
| ./test/TotalNormalizedAssetsTest.t.sol |
| ./test/TotalPendingRedeemAssetsTest.t.sol |
| ./test/VaultDeactivation.t.sol |
| ./test/WERC7575.t.sol |
| ./test/WERC7575Inflation.t.sol |
| ./test/WERC7575ShareTokenCoverageTests.t.sol |
| ./test/WERC7575VaultCoverageTests.t.sol |
| ./test/WorkingUpgradeDemo.t.sol |
| Totals: 61 |

