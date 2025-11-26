# WERC7575 Technical Architecture Documentation

## Table of Contents

1. [System Overview](#system-overview)
2. [Contract Architecture](#contract-architecture)
3. [Data Flow Diagrams](#data-flow-diagrams)
4. [Key Algorithms](#key-algorithms)
5. [Storage Layout](#storage-layout)
6. [Security Mechanisms](#security-mechanisms)
7. [Integration Guide](#integration-guide)

---

## System Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        WERC7575 SYSTEM                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐           ┌──────────────┐                    │
│  │  ShareToken  │◄─────────►│    Vault     │                    │
│  │ (WERC/Share  │           │ (WERC/Async) │                    │
│  │  Upgradeable)│           │ Upgradeable) │                    │
│  └──────────────┘           └──────────────┘                    │
│         │                           │                           │
│         │                           │                           │
│         │                           ▼                           │
│         │                  ┌──────────────┐                     │
│         │                  │  Investment  │                     │
│         └─────────────────►│    Vault     │                     │
│                            │  (External)  │                     │
│                            └──────────────┘                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

USER FLOW:
1. User deposits USDC → Vault
2. Vault mints shares → ShareToken
3. ShareToken receives shares
4. Investment Manager invests idle USDC → External Vault
5. External Vault mints WUSD shares → ShareToken
6. User earns yield on invested portion
```

### Component Relationships

```
ShareTokenUpgradeable (IUSD)
├── Manages: Asset → Vault registry
├── Coordinates: Investment Manager across all vaults
├── Holds: Shares from Investment Vaults
└── Provides: Unified 18-decimal share representation

ERC7575VaultUpgradeable (per asset: USDC, USDT, DAI)
├── Manages: Asset deposits/withdrawals
├── Implements: ERC-7540 async operations
├── Invests: Idle assets → Investment Vault
└── Mints/Burns: Shares via ShareTokenUpgradeable

Investment Vault (WERC7575Vault - External)
├── Accepts: Asset deposits from Vault
├── Mints: WUSD shares to ShareTokenUpgradeable
└── Generates: Yield for depositors
```

---

## Contract Architecture

### 1. WERC7575ShareToken (Non-Upgradeable)

**Inheritance:**
```solidity
WERC7575ShareToken is
    ERC20,           // Standard token functions
    IERC20Permit,    // Signature-based approvals
    EIP712,          // Structured data hashing
    Nonces,          // Replay protection
    ReentrancyGuard, // Reentrancy protection
    ERC165,          // Interface detection
    Pausable,        // Emergency pause
    IERC7575Errors   // Shared error interface
```

**Key State Variables:**
```solidity
// Line 126-132
mapping(address => bool) public isKycVerified;
mapping(address => uint256) private _balances;     // Standard balance
mapping(address => uint256) private _rBalances;   // Reserved/invested balance
mapping(address => mapping(uint256 => uint256[2])) private _rBalanceAdjustments;
EnumerableMap.AddressToAddressMap private _assetToVault;
mapping(address => address) private _vaultToAsset;
address private _validator;
```

**Architecture Decision: Why Split Balances?**

```solidity
// Standard balance: Available for withdrawal
_balances[user] = 1000 ether

// Reserved balance: Invested in external vaults (not yet returned)
_rBalances[user] = 500 ether

// Total balance: Both combined
totalBalance(user) = _balances[user] + _rBalances[user] = 1500 ether
```

**Purpose:**
- Track which assets are liquid vs. invested
- Enable settlement without disturbing investments
- Support yield distribution via rBalance adjustments
- Maintain ERC-20 compatibility for `balanceOf()`

---

### 2. ShareTokenUpgradeable (UUPS Upgradeable)

**Inheritance:**
```solidity
ShareTokenUpgradeable is
    ERC20Upgradeable,
    IERC20Permit,
    EIP712Upgradeable,
    NoncesUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ERC165,
    IERC7575MultiAsset,
    IERC7575Errors
```

**Storage Pattern (ERC-7201):**
```solidity
// Line 84-111
bytes32 private constant SHARE_TOKEN_STORAGE_SLOT =
    keccak256("erc7575.sharetoken.storage");

struct ShareTokenStorage {
    // Asset ↔ Vault mappings
    EnumerableMap.AddressToAddressMap assetToVault;
    mapping(address vault => address asset) vaultToAsset;

    // Operator approvals (ERC-7540)
    mapping(address controller => mapping(address operator => bool)) operators;

    // Centralized management
    address investmentShareToken;  // Target for yield generation
    address investmentManager;     // Controls fulfillment/investment
}

function _getShareTokenStorage() private pure returns (ShareTokenStorage storage $) {
    assembly {
        $.slot := SHARE_TOKEN_STORAGE_SLOT
    }
}
```

**Why ERC-7201 Namespaced Storage?**

Problem:
```solidity
// ❌ Traditional storage (collision risk)
contract V1 {
    uint256 value1;  // Slot 0
    uint256 value2;  // Slot 1
}

contract V2 is V1 {
    uint256 value3;  // Slot 2 - but what if V1 was upgraded and added value3?
}
```

Solution:
```solidity
// ✅ Namespaced storage (collision-free)
contract V1 {
    bytes32 constant SLOT = keccak256("myapp.storage.v1");
    struct Storage { uint256 value1; uint256 value2; }

    function _getStorage() private pure returns (Storage storage $) {
        assembly { $.slot := SLOT }
    }
}

contract V2 is V1 {
    bytes32 constant SLOT = keccak256("myapp.storage.v2");
    struct Storage { uint256 value3; }
    // No collision possible!
}
```

---

### 3. WERC7575Vault (Non-Upgradeable)

**Inheritance:**
```solidity
WERC7575Vault is
    Ownable,
    DecimalConstants,
    Pausable,
    SafeTokenTransfers,
    IERC7575Errors
```

**Key Mechanism: Decimal Normalization:**

```solidity
// Constructor (Line 82-100)
constructor(address asset_, address shareToken_) {
    _decimals = IERC20Metadata(asset_).decimals();  // e.g., 6 for USDC
    _offset = 10 ** (18 - _decimals);                // 10^12 for USDC
    _shareToken = shareToken_;
    _asset = asset_;
}

// Conversion: Assets → Shares (Line 251-253)
function convertToShares(uint256 assets) public view returns (uint256) {
    return assets * _offset;  // 1,000,000 USDC → 1e18 shares
}

// Conversion: Shares → Assets (Line 260-262)
function convertToAssets(uint256 shares) public view returns (uint256) {
    return shares / _offset;  // 1e18 shares → 1,000,000 USDC
}
```

**Example:**
```
USDC (6 decimals)
─────────────────
Deposit:  1,000,000 USDC (1e6)
Offset:   10^12
Shares:   1,000,000 * 10^12 = 1,000,000,000,000,000,000 (1e18)

Withdraw: 1,000,000,000,000,000,000 shares (1e18)
Offset:   10^12
Assets:   1e18 / 10^12 = 1,000,000 USDC (1e6)
```

**Why 18 Decimals for Shares?**
- ERC-7575 standard requirement
- DeFi compatibility (most protocols expect 18)
- Precision for cross-asset operations
- Simplified multi-asset accounting

---

### 4. ERC7575VaultUpgradeable (UUPS Upgradeable)

**Storage Pattern (ERC-7201):**
```solidity
// Line 96-123
bytes32 private constant VAULT_STORAGE_SLOT =
    keccak256("erc7575.vault.storage");

struct VaultStorage {
    // Core vault references
    address asset;
    address shareToken;

    // Decimal handling
    uint8 decimals;
    uint256 offset;

    // Investment integration
    address investmentVault;
    address investmentShareToken;
    address investmentManager;

    // Async request tracking
    uint256 totalPendingDeposit;
    uint256 totalClaimableDeposit;
    uint256 totalPendingRedeem;
    uint256 totalClaimableRedeem;
    mapping(address controller => Request) controllerToRequest;

    // Operator system
    mapping(address controller => mapping(address operator => bool)) operators;

    // Configuration
    bool isActive;
    uint256 minimumDepositAmount;
}
```

**Request Structure:**
```solidity
struct Request {
    uint256 pendingDepositRequest;    // Assets pending fulfillment
    uint256 claimableDepositRequest;  // Shares ready to claim
    uint256 pendingRedeemRequest;     // Shares pending fulfillment
    uint256 claimableRedeemRequest;   // Assets ready to claim
}
```

---

## 5. UUPS Upgrade Pattern Implementation

The system uses the Universal Upgradeable Proxy Standard (UUPS) pattern for the investment layer contract (ERC7575VaultUpgradeable) while the settlement layer (WERC7575Vault) remains non-upgradeable for stability.

### Proxy Architecture

**Bare Proxy (ERC1967Proxy):**
```
┌─────────────────────────────┐
│    ERC1967Proxy             │
├─────────────────────────────┤
│ Storage:                    │
│ - _IMPLEMENTATION_SLOT      │ ← Points to implementation address
│ - (all vault state)         │ ← Storage delegated to implementation
│                             │
│ Functions: NONE             │ ← Only delegation, no logic
│ Delegates all calls via     │
│ delegatecall()              │
└─────────────────────────────┘
```

**Implementation Contract (ERC7575VaultUpgradeable):**
```solidity
contract ERC7575VaultUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuard,
    // ... other interfaces
{
    // Upgrade functions ONLY in implementation
    function upgradeTo(address newImplementation) external onlyOwner {
        ERC1967Utils.upgradeToAndCall(newImplementation, "");
    }

    function upgradeToAndCall(address newImplementation, bytes calldata data)
        external payable onlyOwner
    {
        ERC1967Utils.upgradeToAndCall(newImplementation, data);
    }
}
```

### How UUPS Upgrades Work

**Step 1: Upgrade Initiation**
```
User calls: proxy.upgradeTo(newImplementation)
            ↓
ERC1967Proxy delegates to current implementation
            ↓
Current implementation's upgradeTo() executes
```

**Step 2: Implementation Slot Update**
```solidity
function upgradeTo(address newImplementation) external onlyOwner {
    // ERC1967Utils.upgradeToAndCall() performs:
    // 1. Validates newImplementation has upgradeTo function
    // 2. Updates _IMPLEMENTATION_SLOT in proxy storage
    //    _IMPLEMENTATION_SLOT = newImplementation
    // 3. Emits Upgraded(newImplementation) event
}
```

**Step 3: Storage Preservation**
```
Before Upgrade:
Proxy storage contains:
- All vault state (assets, shares, mappings, etc.)
- Points to Implementation V1

After Upgrade:
Proxy storage UNCHANGED:
- All vault state preserved
- Now points to Implementation V2
```

**Step 4: Subsequent Calls Use New Implementation**
```
User calls: proxy.someFunction()
            ↓
ERC1967Proxy reads _IMPLEMENTATION_SLOT
            ↓
Delegates to NEW implementation
            ↓
New implementation executes with original storage
```

### Access Control

**Only Owner Can Upgrade:**
```solidity
function upgradeTo(address newImplementation) external onlyOwner {
    ERC1967Utils.upgradeToAndCall(newImplementation, "");
}

function upgradeToAndCall(address newImplementation, bytes calldata data)
    external payable onlyOwner
{
    ERC1967Utils.upgradeToAndCall(newImplementation, data);
}
```

**Owner Management:**
- Uses `Ownable2StepUpgradeable` for two-step ownership transfer
- Prevents accidental owner lock-out
- Owner is the only address that can trigger upgrades
- **NO timelock** (intentional per KNOWN_ISSUES.md Section 5)

### Storage Safety

**ERC-7201 Namespaced Storage:**
```solidity
bytes32 private constant VAULT_STORAGE_SLOT =
    keccak256("erc7575.vault.storage");

struct VaultStorage {
    // All vault state packed here
    address asset;
    uint64 scalingFactor;
    bool isActive;
    // ... many more fields
}
```

**Why This Prevents Collisions:**
- Storage not at traditional slots (0, 1, 2, ...)
- Hash-based slot prevents accidental collision
- Inheritance doesn't interfere with state
- Safe to add parent classes in upgrades

**Gap Arrays for Future Expansion:**
```solidity
// At end of VaultStorage struct or separately:
uint256[50] __gap;  // Reserved for future storage variables
```
- Allows adding new state variables without shifting existing ones
- Protects against storage corruption in future upgrades
- Must NOT be removed or reordered in future versions

### Safe Upgrade Patterns

**✅ SAFE Upgrades:**
1. Adding new state variables at the END of structs
2. Adding new functions
3. Changing function implementation (not signature)
4. Adding new events
5. Modifying access control to be MORE restrictive

**❌ UNSAFE Upgrades (Will Corrupt Storage):**
1. Removing state variables
2. Changing order of state variables
3. Changing types of existing variables
4. Removing or reordering gap array slots
5. Changing parent contract order (affects storage layout)

### Why Settlement Layer is Non-Upgradeable

**WERC7575Vault (Settlement Layer) has NO upgrade capability:**
- Intentional for stability and regulatory certainty
- Carriers need guaranteed behavior
- Real-time settlements cannot change behavior
- High security: battle-tested code, no upgrade risk
- Regulatory approval tied to specific implementation

**If bug fixes needed:** Deploy new vault + migrate state (not zero-downtime, but guaranteed safety)

### Why Investment Layer is Upgradeable

**ERC7575VaultUpgradeable (Investment Layer) IS upgradeable:**
- Investment products evolve
- Regulatory requirements change
- Can add new features without affecting settlement layer
- Investor protection: can patch issues faster
- Operational flexibility: adapt to market conditions

---

## Data Flow Diagrams

### Deposit Flow (Async)

```
┌─────────┐
│  USER   │
└────┬────┘
     │ 1. requestDeposit(1000 USDC)
     ▼
┌────────────────┐
│  VaultUpgrade  │
├────────────────┤
│ Receives: 1000 │  Asset State Change:
│ USDC from user │  - User: -1000 USDC
│                │  - Vault: +1000 USDC
│ Updates:       │
│ pending += 1000│  Request State Change:
└────┬───────────┘  - pendingDepositRequest[user] += 1000
     │
     │ Time passes... (off-chain decision)
     │
     │ 2. fulfillDeposit(user, 1000 USDC) [Investment Manager]
     ▼
┌────────────────┐
│  VaultUpgrade  │
├────────────────┤
│ Calculates:    │  Request State Change:
│ shares = 1000  │  - pendingDepositRequest[user] -= 1000
│  * 10^12       │  - claimableDepositRequest[user] += 1e18
│  = 1e18        │
│                │  Share State Change:
│ Mints: 1e18    │  - Vault holds 1e18 shares for user
│ shares to      │  - ShareToken.totalSupply += 1e18
│ vault (held    │
│ for user)      │
└────┬───────────┘
     │
     │ 3. deposit(1000, user) [User claims]
     ▼
┌────────────────┐
│  VaultUpgrade  │
├────────────────┤
│ Transfers:     │  Request State Change:
│ 1e18 shares    │  - claimableDepositRequest[user] = 0
│ vault → user   │
│                │  Share State Change:
│                │  - User: +1e18 shares
│                │  - Vault: -1e18 shares
└────────────────┘
```

### Investment Flow

```
┌──────────────┐
│ Vault has:   │
│ 5000 USDC    │  Breakdown:
│              │  - pendingDeposit: 1000 USDC (reserved)
│ Reserved:    │  - claimableDeposit: 2000 USDC (reserved)
│ 3000 USDC    │  - pendingRedeem: 0
│              │  ────────────────────────────────
│ Available:   │  - Available: 2000 USDC (can invest)
│ 2000 USDC    │
└──────┬───────┘
       │ 1. investAssets(2000 USDC) [Investment Manager]
       ▼
┌──────────────┐
│ VaultUpgrade │  Asset State Change:
├──────────────┤  - Vault: -2000 USDC
│ Calls:       │  - Investment Vault: +2000 USDC
│ investment   │
│ Vault.deposit│  Share State Change:
│ (2000, share │  - ShareToken receives WUSD shares
│  Token)      │  - Amount: ~2000 WUSD (1:1 ratio)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ Investment   │  Share Accounting:
│ Vault (WUSD) │  - ShareToken now holds WUSD shares
├──────────────┤  - Represents invested USDC position
│ Mints WUSD   │  - Earns yield on behalf of users
│ to ShareToken│
│              │  User Impact:
│ Invests USDC │  - Users' IUSD shares unchanged
│ to generate  │  - Underlying value now earning yield
│ yield        │  - ShareToken owns the WUSD position
└──────────────┘
```

### Withdrawal from Investment

```
┌──────────────┐
│ User wants   │
│ to withdraw  │
│ 3000 USDC    │
└──────┬───────┘
       │ Investment Manager sees:
       │ - Vault liquid: 1000 USDC (insufficient)
       │ - Need to withdraw: 2000 USDC from investment
       │
       │ 1. withdrawFromInvestment(2000 USDC)
       ▼
┌──────────────┐
│ VaultUpgrade │  Calculates:
├──────────────┤  - ShareToken owns 2000 WUSD shares
│ Calls:       │  - Need to redeem for 2000 USDC
│ investment   │
│ Vault.redeem │  Share State Change:
│ (minShares,  │  - ShareToken: -2000 WUSD shares
│  thisVault,  │  - Investment Vault burns WUSD
│  ShareToken) │
└──────┬───────┘  Asset State Change:
       │           - Investment Vault: -2000 USDC
       │           - This Vault: +2000 USDC
       ▼
┌──────────────┐
│ Vault now    │  Now vault can fulfill the user's
│ has 3000 USDC│  withdrawal request
│ liquid       │
└──────────────┘
```

---

## Key Algorithms

### 1. Batch Transfer Netting Algorithm

**Purpose:** Process multiple transfers in a single transaction with O(n) complexity instead of O(n²).

**Algorithm:**
```solidity
// Line 628-807 (WERC7575ShareToken.sol)

Step 1: Validate inputs
─────────────────────────
if (debtors.length > MAX_BATCH_SIZE) revert ArrayTooLarge();
if (debtors.length != creditors.length) revert ArrayLengthMismatch();
if (creditors.length != amounts.length) revert ArrayLengthMismatch();

Step 2: Build accounts map (netting)
────────────────────────────────────
struct DebitAndCredit {
    address owner;
    uint256 debit;   // Total amount to deduct
    uint256 credit;  // Total amount to add
}

DebitAndCredit[] memory accounts = new DebitAndCredit[](batchSize * 2);
uint256 accountCount = 0;

for each (debtor[i], creditor[i], amount[i]):
    if debtor == creditor: continue  // Skip self-transfers

    // Find or create debtor entry
    debtorIndex = findOrCreate(debtor in accounts)
    accounts[debtorIndex].debit += amount

    // Find or create creditor entry
    creditorIndex = findOrCreate(creditor in accounts)
    accounts[creditorIndex].credit += amount

Step 3: Apply netted changes
─────────────────────────────
for each account in accounts:
    netAmount = account.debit - account.credit

    if netAmount > 0:  // Net debit (paying out)
        require(_balances[account.owner] >= netAmount)
        _balances[account.owner] -= netAmount
        _rBalances[account.owner] += netAmount

    else if netAmount < 0:  // Net credit (receiving)
        absAmount = -netAmount
        if _rBalances[account.owner] >= absAmount:
            _rBalances[account.owner] -= absAmount
        else:
            _rBalances[account.owner] = 0
        _balances[account.owner] += absAmount

Step 4: Emit events
───────────────────
for each (debtor[i], creditor[i], amount[i]):
    emit Transfer(debtor[i], creditor[i], amount[i])
```

**Example:**
```
Input Transfers:
────────────────
A → B: 100
A → C: 50
B → C: 30
C → A: 20
B → A: 10

Netting Process:
────────────────
Account A: debit = 150 (100+50), credit = 30 (20+10) → net -120 (pays out)
Account B: debit = 30, credit = 110 (100+10) → net +80 (receives)
Account C: debit = 20, credit = 80 (50+30) → net +60 (receives)

Final State Changes:
────────────────────
A: _balances -= 120, _rBalances += 120
B: _rBalances -= min(80, rBalance), _balances += 80
C: _rBalances -= min(60, rBalance), _balances += 60

Zero-Sum Property: -120 + 80 + 60 = 20 ❌ Wait, this doesn't sum to zero!

Correction: The net should be:
A sends: 150
A receives: 30
A net: -120 ✓

B sends: 30
B receives: 110
B net: +80 ✓

C sends: 20
C receives: 80
C net: +60 ✓

Total: -120 + 80 + 60 = +20 ❌

Actually, let me recalculate:
A→B: 100, A→C: 50 = A sends 150
C→A: 20, B→A: 10 = A receives 30
A net: -120 (sends more than receives)

B→C: 30 = B sends 30
A→B: 100 = B receives 100
B net: +70 (not +80, I made an error)

C sends: C→A: 20 = 20
C receives: A→C: 50, B→C: 30 = 80
C net: +60

Wait, let me redo this properly:

Transfers:
A → B: 100
A → C: 50
B → C: 30
C → A: 20
B → A: 10

For A:
  Debits (sending): A→B (100) + A→C (50) = 150
  Credits (receiving): C→A (20) + B→A (10) = 30
  Net: debit 150 - credit 30 = -120 (A loses 120)

For B:
  Debits (sending): B→C (30) + B→A (10) = 40
  Credits (receiving): A→B (100) = 100
  Net: debit 40 - credit 100 = +60 (B gains 60)

For C:
  Debits (sending): C→A (20) = 20
  Credits (receiving): A→C (50) + B→C (30) = 80
  Net: debit 20 - credit 80 = +60 (C gains 60)

Zero-sum check: -120 + 60 + 60 = 0 ✓
```

**Gas Savings:**
- Without netting: 5 transfers × 51k gas = 255k gas
- With netting: 3 net transfers × 51k + overhead = ~180k gas
- Savings: ~30% for this example

---

### 2. Reserved Asset Calculation

**Purpose:** Ensure sufficient liquidity for pending/claimable requests, prevent over-investment.

**Algorithm:**
```solidity
// Line 1083-1096 (ERC7575VaultUpgradeable.sol)

function _calculateReservedAssets() internal view returns (uint256 total) {
    total = $.totalPendingDeposit     // Assets received, shares not minted
          + $.totalClaimableDeposit   // Shares minted, assets not claimed (ERROR!)
          + $.totalPendingRedeem;     // Shares received, assets not released
}
```

**Wait, there's a bug here!** `totalClaimableDeposit` is in SHARES, not assets:

```solidity
// Line 352 (fulfillDeposit)
$.totalClaimableDeposit += shares;  // ← This is SHARES, not assets!

// But in _calculateReservedAssets:
total = $.totalPendingDeposit      // Assets ✓
      + $.totalClaimableDeposit    // SHARES ❌ (wrong unit!)
      + $.totalPendingRedeem;      // Shares ✓
```

**This is a potential vulnerability!** The reserved calculation mixes units.

Correct calculation should be:
```solidity
function _calculateReservedAssets() internal view returns (uint256 total) {
    total = $.totalPendingDeposit                           // Assets
          + _convertToAssets($.totalClaimableDeposit)       // Shares → Assets
          + _convertToAssets($.totalPendingRedeem);         // Shares → Assets
}
```

**Impact:**
- If `totalClaimableDeposit` is large, reserved assets overestimated
- Less assets available for investment (inefficiency, not security issue)
- If `totalClaimableDeposit` is small relative to offset, underestimated
- Could allow over-investment (security issue!)

**Example:**
```
Asset: USDC (6 decimals)
Offset: 10^12

Claimable Deposit: 1e18 shares (should reserve 1e6 USDC)
Current code: reserves 1e18 "assets" ← 1 trillion USDC! (wrong)
Correct code: reserves 1e6 USDC ✓
```

---

### 3. rBalance Adjustment Algorithm

**Purpose:** Update reserved balances to reflect investment returns without actual token transfers.

**Algorithm:**
```solidity
// Line 741-780 (WERC7575ShareToken.sol)

function adjustrBalance(
    address[] calldata accounts,
    uint256[] calldata amounti,  // Amount invested
    uint256[] calldata amountr,  // Amount returned
    uint256[] calldata ts        // Timestamp
) external onlyValidator nonReentrant {

    Step 1: Validate one-time application
    ──────────────────────────────────────
    bytes32 adjustmentHash = keccak256(abi.encode(accounts, amounti, amountr, ts));
    if (_rBalanceAdjustmentsApplied[adjustmentHash]) {
        revert RBalanceAdjustmentAlreadyApplied();
    }
    _rBalanceAdjustmentsApplied[adjustmentHash] = true;

    Step 2: Validate bounds
    ────────────────────────
    require(amounti > 0, "Investment must be positive");
    require(amountr <= amounti * MAX_RETURN_MULTIPLIER, "Return too large");
    require(ts <= block.timestamp, "No future timestamps");

    Step 3: Apply adjustments
    ──────────────────────────
    for each account:
        if amountr > amounti:  // Profit
            profit = amountr - amounti
            _rBalances[account] -= amounti    // Remove invested
            _balances[account] += amountr     // Add returned (principal + profit)

        else if amountr < amounti:  // Loss
            loss = amounti - amountr
            _rBalances[account] -= amounti    // Remove invested
            _balances[account] += amountr     // Add returned (principal - loss)

        else:  // Break even
            _rBalances[account] -= amounti
            _balances[account] += amounti

        // Store adjustment for potential cancellation
        _rBalanceAdjustments[account][ts] = [amounti, amountr];

    Step 4: Emit events
    ───────────────────
    emit RBalanceAdjustmentApplied(accounts, amounti, amountr, ts);
}
```

**Example Scenarios:**

```
Scenario 1: Profit
──────────────────
Initial: _balances[Alice] = 1000, _rBalances[Alice] = 500
Investment: amounti = 500 (all rBalance invested)
Return: amountr = 600 (20% profit)

Calculation:
  profit = 600 - 500 = 100
  _rBalances[Alice] -= 500 → 0
  _balances[Alice] += 600 → 1600

Final: _balances[Alice] = 1600, _rBalances[Alice] = 0
Total: 1600 (was 1500, gained 100) ✓

Scenario 2: Loss
────────────────
Initial: _balances[Alice] = 1000, _rBalances[Alice] = 500
Investment: amounti = 500
Return: amountr = 400 (20% loss)

Calculation:
  loss = 500 - 400 = 100
  _rBalances[Alice] -= 500 → 0
  _balances[Alice] += 400 → 1400

Final: _balances[Alice] = 1400, _rBalances[Alice] = 0
Total: 1400 (was 1500, lost 100) ✓

Scenario 3: Partial Investment
───────────────────────────────
Initial: _balances[Alice] = 1000, _rBalances[Alice] = 500
Investment: amounti = 300 (only 60% of rBalance)
Return: amountr = 360 (20% profit)

Calculation:
  profit = 360 - 300 = 60
  _rBalances[Alice] -= 300 → 200 (200 still invested elsewhere)
  _balances[Alice] += 360 → 1360

Final: _balances[Alice] = 1360, _rBalances[Alice] = 200
Total: 1560 (was 1500, gained 60) ✓
```

**Key Protections:**
1. `MAX_RETURN_MULTIPLIER = 2`: Prevents typos (e.g., accidentally returning 100x)
2. One-time application: Prevents double-counting returns
3. Timestamp validation: Prevents future-dated adjustments
4. Cancellation support: Can undo incorrect adjustments

---

## Storage Layout

### ShareTokenUpgradeable Storage

```
Storage Slot: keccak256("erc7575.sharetoken.storage")
─────────────────────────────────────────────────────

Offset  Size  Variable
─────────────────────────────────────────────────────
0x00    32    assetToVault._inner._positions (AddressToAddressMap)
0x01    32    assetToVault._inner._indexes
0x02    32    vaultToAsset (mapping)
0x03    32    operators (nested mapping)
0x04    20    investmentShareToken
0x05    20    investmentManager
```

### ERC7575VaultUpgradeable Storage

```
Storage Slot: keccak256("erc7575.vault.storage")
──────────────────────────────────────────────────

Offset  Size  Variable
──────────────────────────────────────────────────
0x00    20    asset
0x01    20    shareToken
0x02    1     decimals
0x03    32    offset
0x04    20    investmentVault
0x05    20    investmentShareToken
0x06    20    investmentManager
0x07    32    totalPendingDeposit
0x08    32    totalClaimableDeposit
0x09    32    totalPendingRedeem
0x0A    32    totalClaimableRedeem
0x0B    32    controllerToRequest (mapping)
0x0C    32    operators (nested mapping)
0x0D    1     isActive
0x0E    32    minimumDepositAmount
```

**Storage Gap Pattern:**
```solidity
// For future upgrades, contracts include gaps
uint256[50] private __gap;  // Reserve 50 slots for future variables
```

**Why?** If V2 adds new variables, they use the gap slots without shifting existing storage.

---

## Security Mechanisms

### 1. Reentrancy Protection

**Applied to:**
- All state-changing functions with external calls
- `batchTransfers()` - Complex multi-call operation
- `investAssets()` - External vault interaction
- `withdrawFromInvestment()` - External vault interaction

**Implementation:**
```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract WERC7575ShareToken is ReentrancyGuard {
    function batchTransfers(...) external onlyValidator nonReentrant {
        // Protected against reentrancy
    }
}
```

**Why Critical:**
```solidity
// Vulnerable pattern (if no ReentrancyGuard):
function withdraw() external {
    uint256 amount = balances[msg.sender];
    balances[msg.sender] = 0;

    (bool success,) = msg.sender.call{value: amount}("");
    // ↑ If msg.sender is malicious contract, could reenter before state updated
}

// Protected pattern:
function withdraw() external nonReentrant {
    uint256 amount = balances[msg.sender];
    balances[msg.sender] = 0;  // State updated BEFORE external call

    (bool success,) = msg.sender.call{value: amount}("");
    // ↑ Reentrancy blocked by nonReentrant modifier
}
```

---

### 2. Access Control Hierarchy

```
┌─────────────────────────────────────┐
│  TIER 1: Owner (Highest Privilege) │
├─────────────────────────────────────┤
│ - Vault registration                │
│ - Validator assignment              │
│ - Investment manager config         │
│ - Emergency pause                   │
│ - Contract upgrades                 │
└─────────────────────────────────────┘
            ↓ delegates to
┌─────────────────────────────────────┐
│  TIER 2: Validator (Medium Priv)   │
├─────────────────────────────────────┤
│ - KYC management                    │
│ - Batch transfers                   │
│ - rBalance adjustments              │
│ - Permit signatures                 │
└─────────────────────────────────────┘
            ↓ authorizes
┌─────────────────────────────────────┐
│  TIER 3: Investment Manager         │
├─────────────────────────────────────┤
│ - Fulfillment operations            │
│ - Investment decisions              │
│ - Asset movement                    │
└─────────────────────────────────────┘
            ↓ controls
┌─────────────────────────────────────┐
│  TIER 4: Vaults (Restricted)       │
├─────────────────────────────────────┤
│ - Token minting                     │
│ - Token burning                     │
│ - Allowance spending                │
└─────────────────────────────────────┘
            ↓ affects
┌─────────────────────────────────────┐
│  TIER 5: Users (Controlled Access) │
├─────────────────────────────────────┤
│ - Deposits (with KYC)               │
│ - Withdrawals (with KYC)            │
│ - Transfers (with permit + KYC)     │
└─────────────────────────────────────┘
```

**No Privilege Escalation Possible:**
- Users cannot become validators
- Validators cannot become owners
- Vaults cannot change their authorization
- Each tier is strictly separated

---

### 3. Input Validation

**Comprehensive validation at every entry point:**

```solidity
// Example: Batch transfers (Line 628-650)
function batchTransfers(...) external onlyValidator nonReentrant {
    // Array size validation
    if (debtors.length > MAX_BATCH_SIZE) revert ArrayTooLarge();

    // Array length consistency
    if (!(debtors.length == creditors.length &&
          creditors.length == amounts.length)) {
        revert ArrayLengthMismatch();
    }

    // Individual element validation in loop
    for (uint256 i = 0; i < batchSize; i++) {
        // Balance sufficiency checked before debit
        if (_balances[debtor] < amount) revert LowBalance();
        // ...
    }
}

// Example: Vault registration (Line 169-188)
function registerVault(address asset, address vaultAddress) external onlyOwner {
    // Zero address validation
    if (asset == address(0)) revert WrongAsset();
    if (vaultAddress == address(0)) revert WrongVaultAddress();

    // Duplicate prevention
    if ($.assetToVault.contains(asset)) revert AssetAlreadyRegistered();

    // Vault validation
    if (address(ERC7575VaultUpgradeable(vaultAddress).asset()) != asset) {
        revert AssetMismatch();
    }
    // ...
}
```

---

### 4. Signature Security (EIP-712)

**Domain Separator:**
```solidity
// Constructed in constructor
constructor(string memory name_, string memory symbol_)
    ERC20(name_, symbol_)
    EIP712(name_, "1")  // ← Domain separator with version
{
    // ...
}

// Domain separator includes:
// - Contract name
// - Version ("1")
// - Chain ID (automatically)
// - Contract address (automatically)
```

**Purpose:** Prevents signature replay attacks:
- **Cross-chain replay**: Different chain ID → different domain separator
- **Cross-contract replay**: Different address → different domain separator
- **Version replay**: Upgrade changes version → different domain separator

**Permit Implementation:**
```solidity
// Line 343-381
function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v, bytes32 r, bytes32 s
) public virtual {
    // Step 1: Check deadline
    if (block.timestamp > deadline) {
        revert ERC2612ExpiredSignature(deadline);
    }

    // Step 2: Consume nonce (prevents replay)
    uint256 nonce = _useNonce(owner);

    // Step 3: Construct EIP-712 hash
    bytes32 structHash = keccak256(
        abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            owner, spender, value, nonce, deadline
        )
    );
    bytes32 hash = _hashTypedDataV4(structHash);

    // Step 4: Recover signer
    address signer = ECDSA.recover(hash, v, r, s);

    // Step 5: Validate signer (with validator requirement for self-allowance)
    if (owner == spender) {
        // Self-allowance: validator must sign
        if (signer != _validator) revert ERC2612InvalidSigner(signer, owner);
    } else {
        // Regular allowance: owner must sign
        if (signer != owner) revert ERC2612InvalidSigner(signer, owner);
    }

    // Step 6: Set allowance
    _approve(owner, spender, value);
}
```

---

## Integration Guide

### For Protocol Integrators

**❌ STOP: Read This First**

WERC7575 is **NOT COMPATIBLE** with standard ERC-20 integrations. Review the following before proceeding:

### Pre-Integration Checklist

- [ ] Can you implement a custom permit flow?
- [ ] Can you verify all recipients via KYC?
- [ ] Can you accept fulfillment delays (async operations)?
- [ ] Can you handle non-standard transfer behavior?
- [ ] Do you have direct communication with validator?

If any answer is "NO", **DO NOT INTEGRATE**.

---

### Integration Pattern 1: Direct User Deposits

**Scenario:** User deposits USDC into your protocol, which then deposits into WERC7575 vault.

```solidity
// Step 1: User approves your protocol
IERC20(usdc).approve(yourProtocol, amount);

// Step 2: Your protocol receives USDC
IERC20(usdc).transferFrom(user, address(this), amount);

// Step 3: Your protocol approves vault
IERC20(usdc).approve(vault, amount);

// Step 4: Request deposit (async)
uint256 requestId = IVault(vault).requestDeposit(amount, user, address(this));

// Step 5: Wait for investment manager to fulfill
// (Off-chain monitoring required)

// Step 6: User claims shares
IVault(vault).deposit(amount, user);

// CRITICAL: User must be KYC-verified before Step 6!
```

---

### Integration Pattern 2: Protocol-Owned Position

**Scenario:** Your protocol maintains a position in WERC7575 on behalf of users.

```solidity
// Your protocol is the controller, users have claims against you

// Step 1: Request deposit
uint256 requestId = IVault(vault).requestDeposit(
    amount,
    address(this),  // ← Your protocol is the controller
    address(this)
);

// Step 2: After fulfillment, claim shares
uint256 shares = IVault(vault).deposit(amount, address(this));

// Step 3: Track user claims internally
userShares[user] += shares;

// CRITICAL: Your protocol must be KYC-verified!
```

---

### Integration Pattern 3: Operator Delegation

**Scenario:** Users delegate redemption authority to your protocol.

```solidity
// Step 1: User approves your protocol as operator
ShareToken(shareToken).setOperator(yourProtocol, true);

// Step 2: Your protocol can request redemption on user's behalf
IVault(vault).requestRedeem(
    shares,
    user,        // ← User is controller
    address(this) // ← Your protocol is owner (operator)
);

// Step 3: After fulfillment, claim assets
uint256 assets = IVault(vault).redeem(shares, user, user);
```

---

### Common Integration Pitfalls

**❌ Pitfall 1: Using standard `transfer()`**
```solidity
// This WILL FAIL without permit
ShareToken(shareToken).transfer(recipient, amount);
// Reverts: ERC20InsufficientAllowance (no self-allowance)
```

**✅ Correct: Use permit first**
```solidity
// Off-chain: Get validator signature
(v, r, s) = getValidatorSignature(owner, owner, amount, deadline);

// On-chain: Call permit, then transfer
ShareToken(shareToken).permit(owner, owner, amount, deadline, v, r, s);
ShareToken(shareToken).transfer(recipient, amount);
```

---

**❌ Pitfall 2: Assuming immediate execution**
```solidity
// This completes immediately in standard ERC-20
uint256 shares = vault.deposit(amount, receiver);

// WERC7575: This only REQUESTS, doesn't execute!
uint256 requestId = vault.requestDeposit(amount, receiver, msg.sender);
// User must wait for fulfillment!
```

**✅ Correct: Handle async flow**
```solidity
// Step 1: Request
uint256 requestId = vault.requestDeposit(amount, receiver, msg.sender);

// Step 2: Monitor off-chain for fulfillment
// (Check pendingDepositRequest and claimableDepositRequest)

// Step 3: Claim when ready
uint256 shares = vault.deposit(amount, receiver);
```

---

**❌ Pitfall 3: Forgetting KYC requirement**
```solidity
// Minting to non-KYC address
vault.requestDeposit(amount, nonKycUser, msg.sender);
// Later, when fulfilled:
vault.deposit(amount, nonKycUser);  // ← REVERTS: KycRequired
```

**✅ Correct: Ensure KYC first**
```solidity
// Off-chain: Ensure user is KYC-verified
require(shareToken.isKycVerified(user), "User not KYC verified");

// On-chain: Safe to deposit
vault.requestDeposit(amount, user, msg.sender);
```

---

### Testing Your Integration

**Minimum Test Suite:**

```solidity
// Test 1: Permit flow
function testIntegration_PermitFlow() public {
    // Get validator signature
    (uint8 v, bytes32 r, bytes32 s) = signPermit(validator, user, user, amount, deadline);

    // Call permit
    shareToken.permit(user, user, amount, deadline, v, r, s);

    // Verify allowance
    assertEq(shareToken.allowance(user, user), amount);
}

// Test 2: Async deposit flow
function testIntegration_AsyncDeposit() public {
    // Request deposit
    vm.prank(user);
    uint256 requestId = vault.requestDeposit(amount, user, user);

    // Fulfill as investment manager
    vm.prank(investmentManager);
    vault.fulfillDeposit(user, amount);

    // Claim shares
    vm.prank(user);
    uint256 shares = vault.deposit(amount, user);

    assertGt(shares, 0);
}

// Test 3: KYC requirement
function testIntegration_KycRequired() public {
    // Non-KYC user attempts deposit
    vm.prank(nonKycUser);
    vault.requestDeposit(amount, nonKycUser, nonKycUser);

    // Fulfill
    vm.prank(investmentManager);
    vault.fulfillDeposit(nonKycUser, amount);

    // Claim should revert
    vm.prank(nonKycUser);
    vm.expectRevert(abi.encodeWithSignature("KycRequired()"));
    vault.deposit(amount, nonKycUser);
}
```

---

## Conclusion

The WERC7575 system implements a sophisticated multi-asset vault architecture with:

1. **Regulatory Compliance**: KYC/AML enforcement at token level
2. **Yield Generation**: Automated investment of idle assets
3. **Async Operations**: ERC-7540 compliant request-fulfill-claim flow
4. **Multi-Asset Support**: Unified share token across different asset types
5. **Upgrade Capability**: UUPS proxy pattern for maintainability
6. **Centralized Management**: Owner, validator, and investment manager roles

**Key Technical Innovations:**
- Decimal normalization for cross-asset compatibility
- Batch transfer netting for gas efficiency
- Reserved balance tracking for investment safety
- ERC-7201 storage slots for upgrade safety

**Security Considerations:**
- Comprehensive access control
- Reentrancy protection
- Input validation
- Signature security (EIP-712)
- Storage collision prevention

**Integration Requirements:**
- Custom permit flow implementation
- KYC verification capability
- Async operation handling
- Non-standard ERC-20 behavior awareness

For questions or clarifications, please refer to the main documentation or contact the development team.

---

**Document Version:** 1.0
**Last Updated:** 2025-01-05
**Solidity Version:** ^0.8.30
**Framework:** Foundry
