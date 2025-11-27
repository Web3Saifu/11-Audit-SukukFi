# SukukFi audit details
- Total Prize Pool: $40,000 in USDC
    - HM awards: up to $34,560 in USDC
      - If no valid Highs or Mediums are found, the HM pool is $0
    - QA awards: $1,440 in USDC
    - Judge awards: $3,500 in USDC
    - Scout awards: $500 in USDC 
- [Read our guidelines for more details](https://docs.code4rena.com/competitions)
- Starts November 26, 2025 20:00 UTC 
- Ends December 5, 2025 20:00 UTC 

### ❗ Important notes for wardens
1. A coded, runnable PoC is required for all High/Medium submissions to this audit. 
    - This repo includes a basic template to run the test suite.
    - PoCs must use the test suite provided in this repo.
    - Your submission will be marked as Insufficient if the POC is not runnable and working with the provided test suite.
    - Exception: PoC is optional (though recommended) for wardens with signal ≥ 0.68.
1. Judging phase risk adjustments (upgrades/downgrades):
    - High- or Medium-risk submissions downgraded by the judge to Low-risk (QA) will be ineligible for awards.
    - Upgrading a Low-risk finding from a QA report to a Medium- or High-risk finding is not supported.
    - As such, wardens are encouraged to select the appropriate risk level carefully during the submission phase.

## V12 findings

[V12](https://v12.zellic.io/) is [Zellic](https://zellic.io)'s in-house AI auditing tool. It is the only autonomous Solidity auditor that [reliably finds Highs and Criticals](https://www.zellic.io/blog/introducing-v12/). All issues found by V12 will be judged as out of scope and ineligible for awards.

[V12 findings can be viewed here.](https://github.com/code-423n4/2025-11-sukukfi/blob/main/2025_11_sukukfi_v12.md)

## Publicly known issues

_Anything included in this section is considered a publicly known issue and is therefore ineligible for awards._

A comprehensive [`KNOWN_ISSUES.md` file](https://github.com/code-423n4/2025-11-sukukfi/blob/main/KNOWN_ISSUES.md) is present in the repository that contains all known issues of the system.

# Overview

The WERC7575 smart contract system is the **blockchain settlement layer** within a **multi-tier telecom wholesale voice traffic settlement ecosystem**. It works in conjunction with off-chain platforms (COMMTRADE and WRAPX) and telecom OSS/BSS systems to enable efficient, transparent settlement of inter-carrier voice traffic transactions.

## Links

- **Previous audits:**  No previous audit reports.
- **Documentation:** https://drive.google.com/file/d/11xlNDudf-mihAWq6V6PNF5ArdTbswm4r/view
- **Website:** https://sukuk.fi
- **X/Twitter:** https://x.com/sukukfi

---

# Scope

### Files in scope


| File   | nSLOC |
| ------ | ----- |
|[src/DecimalConstants.sol](https://github.com/code-423n4/2025-11-sukukfi/blob/main/src/DecimalConstants.sol)| 5 |
|[src/ERC7575VaultUpgradeable.sol](https://github.com/code-423n4/2025-11-sukukfi/blob/main/src/ERC7575VaultUpgradeable.sol)| 737 |
|[src/SafeTokenTransfers.sol](https://github.com/code-423n4/2025-11-sukukfi/blob/main/src/SafeTokenTransfers.sol)| 19 |
|[src/ShareTokenUpgradeable.sol](https://github.com/code-423n4/2025-11-sukukfi/blob/main/src/ShareTokenUpgradeable.sol)| 243 |
|[src/WERC7575ShareToken.sol](https://github.com/code-423n4/2025-11-sukukfi/blob/main/src/WERC7575ShareToken.sol)| 514 |
|[src/WERC7575Vault.sol](https://github.com/code-423n4/2025-11-sukukfi/blob/main/src/WERC7575Vault.sol)| 152 |
|**Totals**| **1670** |

*For a machine-readable version, see [scope.txt](https://github.com/code-423n4/2025-11-sukukfi/blob/main/scope.txt)*

### Files out of scope

| File         |
| ------------ |
|[src/ERC20Faucet.sol](https://github.com/code-423n4/2025-11-sukukfi/blob/main/src/ERC20Faucet.sol)|
|[src/ERC20Faucet6.sol](https://github.com/code-423n4/2025-11-sukukfi/blob/main/src/ERC20Faucet6.sol)|
|[src/interfaces/\*\*.\*\*](https://github.com/code-423n4/2025-11-sukukfi/tree/main/src/interfaces)|
|[test/\*\*.\*\*](https://github.com/code-423n4/2025-11-sukukfi/tree/main/test)|
| Totals: 61 |

*For a machine-readable version, see [out_of_scope.txt](https://github.com/code-423n4/2025-11-sukukfi/blob/main/out_of_scope.txt)*

# Additional context

## Areas of concern (where to focus for bugs)
  1. Batch Settlement Netting (WERC7575ShareToken.batchTransfers) - Validator-controlled, complex netting logic, zero-sum invariant validation, potential for state corruption
  2. Role Access Control - Five distinct roles (Owner, Validator, KYC Admin, Revenue Admin, Investment Manager) with independent permissions; risk of single-point-of-failure key compromise
  3. Reentrancy in Async Flows - External calls in deposit/redeem/investment functions with nonReentrant guards; validate CEI pattern throughout
  4. Dual Allowance Model - Non-standard ERC20 requiring self-allowance + caller allowance; validate both checks are enforced in transfer/transferFrom
  5. Reserved Asset Accounting - Ensure pending/claimable/invested assets are correctly calculated and don't overlap; verify investment layer can't over-allocate
  6. Async State Transitions - Request→Fulfill→Claim flow with cancelations; validate no state-skipping, double-claiming, or permanent blocking
  7. Permit Signature Validation - EIP-712 replay protection, nonce tracking, chain ID inclusion; validate validator signature authenticity
  8. Upgrade Safety - ERC-7201 namespaced storage, gap arrays, no storage reordering; validate upgrade pattern prevents storage collision

## Main invariants

### Settlement Layer

  1. sum(balances) == totalSupply - Token supply conservation
  2. batchTransfers: sum(balance changes) == 0 - Zero-sum settlement
  3. transfer requires self-allowance[user] - Permit enforcement
  4. transferFrom requires both allowances - Dual authorization
  5. Only KYC-verified addresses can receive/hold shares
  6. assetToVault[asset] ↔ vaultToAsset[vault] - One-to-one mapping
  7. Only registered vaults can mint/burn

### Investment Layer

  8. Deposit/Redeem: Pending → Claimable → Claimed (no skipping)
  9. investedAssets + reservedAssets ≤ totalAssets - Reserved protection
  10. convertToShares(convertToAssets(x)) ≈ x - Rounding accuracy

### Global 

  11. No role escalation - access control boundaries enforced
  12. No fund theft - no double-claims, no reentrancy, no bypass


## All trusted roles in the protocol

The roles of the system are as follows:

- Owners
- Validators
- KYC Administrators
- Revenue Administrators
- Investment Managers 

Their privileges are documented in the known issues section of the contest.

## Running tests

### Prerequisites

The repository utilizes the `foundry` (`forge`) toolkit to compile its contracts, and contains several dependencies through `foundry` that will be automatically installed whenever a `forge` command is issued.

The compilation instructions were evaluated with the following toolkit versions:

- forge: `1.4.4-stable`

### Building

The traditional `forge` build command will install the relevant dependencies and build the project:

```sh
forge build
```

### Tests

The following command can be issued to execute all tests within the repository:

```sh
forge test
```

### Submission PoCs

The scope of the audit contest involves multiple EIP-7575 style contracts of varying complexity.

Wardens are instructed to utilize the respective test suite of the project to illustrate the vulnerabilities they identify, should they be constrained to a single file. A `AuditReproductionTest` also exists in the test suite that contains a comprehensive deployment that wardens can utilize.

If a custom configuration is desired, wardens are advised to create their own PoC file that should be executable within the `test` subfolder of this contest.

All PoCs must adhere to the following guidelines:

- The PoC should execute successfully
- The PoC must not mock any contract-initiated calls
- The PoC must not utilize any mock contracts in place of actual in-scope implementations

## Miscellaneous

Employees of SukukFi and employees' family members are ineligible to participate in this audit.

Code4rena's rules cannot be overridden by the contents of this README. In case of doubt, please check with C4 staff.

