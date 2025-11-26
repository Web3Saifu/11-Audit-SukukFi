# WERC7575 System - Use Case Context

## System Purpose

The WERC7575 smart contract system is the **blockchain settlement layer** within a **multi-tier telecom wholesale voice traffic settlement ecosystem**. It works in conjunction with off-chain platforms (COMMTRADE and WRAPX) and telecom OSS/BSS systems to enable efficient, transparent settlement of inter-carrier voice traffic transactions.

---

## Multi-Tier System Architecture

### Complete Ecosystem Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│           TELECOM WHOLESALE VOICE TRAFFIC SETTLEMENT ECOSYSTEM      │
└─────────────────────────────────────────────────────────────────────┘

TIER 1: Telecom OSS/BSS Systems (Carrier Operations)
┌────────────────────────────────────────────────────────────────────┐
│  Carrier A OSS/BSS  │  Carrier B OSS/BSS  │  Carrier C OSS/BSS     │
│  • Call routing     │  • Call routing     │  • Call routing        │
│  • CDR generation   │  • CDR generation   │  • CDR generation      │
│  • Rate management  │  • Rate management  │  • Rate management     │
└────────────┬───────────────────┬───────────────────┬───────────────┘
             │                   │                   │
             │    Push CDRs (Call Detail Records)    │
             ▼                   ▼                   ▼
┌────────────────────────────────────────────────────────────────────┐
│  TIER 2: COMMTRADE Platform (Off-Chain Smart Contract Engine)      │
├────────────────────────────────────────────────────────────────────┤
│  • Integrates with carrier OSS/BSS systems                         │
│  • Enforces rate exchange agreements                               │
│  • Manages call routing logic                                      │
│  • Accounting of all voice traffic transactions                    │
│  • Aggregates transactions per settlement period                   │
│  • Calculates net positions between carriers                       │
│  • Generates settlement instructions                               │
│  • Pushes individual settlement instructions to WRAPX              │
└────────────┬───────────────────────────────────────────────────────┘
             │
             │    Settlement Instructions (individual transactions)
             ▼
┌────────────────────────────────────────────────────────────────────┐
│  TIER 3: WRAPX Platform (Off-Chain Settlement Entity)              │
├────────────────────────────────────────────────────────────────────┤
│  • Receives settlement instructions from COMMTRADE                 │
│  • Validates settlement calculations                               │
│  • Optimizes transaction batching for gas efficiency               │
│  • Manages blockchain interaction                                  │
│  • Signs transactions as validator                                 │
│  • Pushes batch settlements to blockchain                          │
│  • Monitors blockchain confirmations                               │
│  • Handles settlement disputes                                     │
└────────────┬───────────────────────────────────────────────────────┘
             │
             │    Blockchain Transactions (batch transfers)
             ▼
┌────────────────────────────────────────────────────────────────────┐
│  TIER 4: Blockchain Settlement Layer (WERC7575 Smart Contracts)    │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  4A: On-Chain Settlement (WERC7575ShareToken + WERC7575Vault)      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  • Carrier wallets hold settlement balances                  │  │
│  │  • Permissionless deposits (carriers fund wallets 24/7)      │  │
│  │  • Batch settlement execution (WRAPX validator signature)    │  │
│  │  • Permission-required withdrawals (via WRAPX permit)        │  │
│  │  • Immutable settlement record on blockchain                 │  │
│  │  • Transparent audit trail                                   │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                    ▲                               │
│                                    │ Investment funding            │
│                                    │                               │
│  4B: Investment Layer (ShareTokenUpgradeable + Vault)              │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  • Investors deposit capital (async ERC-7540)                │  │
│  │  • Investment Manager deploys to settlement layer            │  │
│  │  • Funds carrier prepayments and working capital             │  │
│  │  • Earns yield from settlement activity                      │  │
│  │  • Investors redeem with profits                             │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## Layer-by-Layer Breakdown

### TIER 1: Telecom OSS/BSS Systems

**Components:** Carrier operational systems (legacy telecom infrastructure)

**Responsibilities:**
- **Call Routing**: Direct voice traffic between carriers
- **CDR Generation**: Create Call Detail Records for every call
  - Origin/destination numbers
  - Call duration
  - Timestamps
  - Quality metrics
- **Rate Management**: Apply agreed rates per destination/carrier
- **Real-Time Operations**: 24/7 voice traffic handling

**Output:** CDRs (Call Detail Records) pushed to COMMTRADE

**Example:**
```
Carrier A routes call: +1-555-0100 → +44-20-7946-0958
Duration: 15 minutes
Rate: $0.02/minute
Cost: $0.30
CDR sent to COMMTRADE for accounting
```

---

### TIER 2: COMMTRADE Platform (Off-Chain Smart Contract Engine)

**Nature:** Off-chain platform with smart contract capabilities

**Responsibilities:**

**1. OSS/BSS Integration**
- Connects to multiple carrier OSS/BSS systems
- Ingests CDRs in real-time
- Normalizes data formats across carriers

**2. Rate Exchange Management**
- Enforces bilateral rate agreements
- Applies volume discounts
- Handles rate updates
- Manages currency conversions

**3. Call Routing Logic**
- Least cost routing (LCR)
- Quality-based routing
- Load balancing
- Failover management

**4. Transaction Accounting**
- Records every voice traffic transaction
- Applies agreed rates
- Calculates per-carrier balances
- Maintains detailed transaction history

**5. Settlement Preparation**
- Settlements are accounted for in quasi-real-time and pushed when they reached a defined amount or timer.
- Generates settlement instructions

**6. Data Push to WRAPX**
- Pushes individual settlement instructions (not batched)
- WRAPX receives individual transactions for batching and blockchain execution
- Provides transaction details for WRAPX validation and optimization

**Example Settlement Period:**
```
Week 1 Transactions (aggregated by COMMTRADE):
─────────────────────────────────────────────────
Carrier A → Carrier B: 1,000,000 minutes @ $0.02 = $20,000
Carrier B → Carrier C: 800,000 minutes @ $0.025 = $20,000
Carrier C → Carrier A: 500,000 minutes @ $0.03 = $15,000
Carrier A → Carrier C: 300,000 minutes @ $0.028 = $8,400
Carrier B → Carrier A: 600,000 minutes @ $0.022 = $13,200

COMMTRADE calculates net positions:
────────────────────────────────────
Carrier A: -$20,000 - $8,400 + $15,000 + $13,200 = -$200 (net payer)
Carrier B: +$20,000 - $20,000 - $13,200 = -$13,200 (net payer)
Carrier C: +$20,000 - $15,000 + $8,400 = +$13,400 (net receiver)

Individual settlement instructions sent to WRAPX:
──────────────────────────────────────────────────
Transaction 1: Transfer $200 from Carrier A to Carrier C
Transaction 2: Transfer $13,200 from Carrier B to Carrier C

(WRAPX will batch these into a single blockchain transaction)
```

---

### TIER 3: WRAPX Platform (Off-Chain Settlement Entity)

**Nature:** Off-chain settlement management platform

**Responsibilities:**

**1. Settlement Validation**
- Receives settlement instructions from COMMTRADE
- Validates calculations
- Checks for discrepancies
- Confirms carrier balances sufficient

**2. Batch Optimization**
- Receives individual settlement instructions from COMMTRADE
- Aggregates multiple instructions into optimized batches
- Optimizes for gas efficiency
- Groups similar operations
- Schedules blockchain transactions

**3. Blockchain Interaction**
- Acts as validator on WERC7575 contracts
- Signs batch settlement transactions
- Pushes `batchTransfers()` to blockchain
- Monitors transaction confirmations
- Handles failed transactions

**4. Permit Management**
- Controls withdrawal permissions
- Issues permit signatures for valid withdrawals
- Enforces withdrawal rules:
  - No outstanding settlement disputes
  - Regulatory compliance checks
  - Sufficient liquidity maintained
  - AML/KYC validation

**5. Dispute Resolution**
- Manages settlement disputes between carriers
- Holds withdrawals during investigations
- Coordinates with COMMTRADE for data verification
- Releases funds when disputes resolved

**6. Settlement Monitoring**
- Tracks all blockchain settlements
- Generates settlement reports
- Alerts on anomalies
- Maintains audit trail

**Example WRAPX Operation:**
```
WRAPX receives individual instructions from COMMTRADE:
────────────────────────────────────────────────────────
Instruction 1: Transfer $500 from Carrier A to Carrier B
Instruction 2: Transfer $300 from Carrier B to Carrier C
Instruction 3: Transfer $400 from Carrier C to Carrier A
Instruction 4: Transfer $200 from Carrier D to Carrier E
... (50 total individual settlement instructions for 20 carriers)

WRAPX batches and optimizes:
────────────────────────────
• Aggregates all 50 individual instructions
• Applies netting algorithm
• Result: 12 net transfers (76% reduction)

WRAPX pushes single batch to blockchain:
──────────────────────────────────────────
batchTransfers(
    debtors:   [Carrier A, Carrier B, ...],
    creditors: [Carrier C, Carrier D, ...],
    amounts:   [200, 13200, ...]
)

Signed by: WRAPX validator private key
Gas cost: ~200k gas (vs. 1M+ gas if each instruction was separate blockchain tx)
```

---

### TIER 4A: On-Chain Settlement Layer (WERC7575)

### Purpose: Telecom Carrier Settlement Platform

**Primary Users:** Telecom carriers (wholesale voice traffic operators)

**Core Function:** Real-time settlement of inter-carrier voice traffic transactions

### Use Case Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    TELECOM SETTLEMENT FLOW                          │
└─────────────────────────────────────────────────────────────────────┘

Step 1: Carrier Onboarding
──────────────────────────
Carrier A (e.g., Verizon Wholesale) → KYC verification
Carrier B (e.g., AT&T Wholesale)   → KYC verification
Carrier C (e.g., T-Mobile Wholesale) → KYC verification

Each carrier gets:
• Wallet address on WERC7575ShareToken
• KYC verification from validator
• Telecom integration deployed (for settlement enforcement)

Step 2: Funding (Permissionless Deposit)
─────────────────────────────────────────
Carrier A deposits: 1,000,000 USDC
Carrier B deposits: 500,000 USDC
Carrier C deposits: 750,000 USDC

Deposits are PERMISSIONLESS (anyone KYC-verified can fund their wallet)
Reason: Carriers need to top up quickly to maintain service

Step 3: Voice Traffic & Settlement
───────────────────────────────────
Throughout the month:
• Carrier A routes 10M minutes through Carrier B's network → owes $500k
• Carrier B routes 8M minutes through Carrier C's network → owes $400k
• Carrier C routes 5M minutes through Carrier A's network → owes $250k

Settlement platform tracks all traffic via telecom integrations

Step 4: Batch Settlement Execution
───────────────────────────────────
Validator (settlement platform) calls:

batchTransfers(
    debtors:   [Carrier A, Carrier B, Carrier C],
    creditors: [Carrier B, Carrier C, Carrier A],
    amounts:   [500000, 400000, 250000]
)

Netting algorithm optimizes:
• Carrier A: -500k + 250k = -250k (net payer)
• Carrier B: +500k - 400k = +100k (net receiver)
• Carrier C: +400k - 250k = +150k (net receiver)

Only 3 state changes instead of complex multi-transfer cascade!

Step 5: Withdrawal (Permission Required)
─────────────────────────────────────────
Carrier B wants to withdraw 100k from their balance:

• Carrier B requests withdrawal from settlement platform (off-chain)
• Settlement platform validates request (e.g., no outstanding payments)
• Settlement platform issues permit signature:
  permit(Carrier B, Carrier B, 100k, deadline, v, r, s)
• Carrier B calls transfer() with permit → withdrawal succeeds

WHY PERMISSION REQUIRED?
• Prevents withdrawal during settlement disputes
• Ensures regulatory compliance (AML checks)
• Allows settlement platform to freeze fraudulent carriers
• Ensures carriers have sufficient liquidity for ongoing settlement obligations

**Technical Note on Permission Enforcement:**
The settlement platform (WRAPX) doesn't directly gate vault withdrawals. Instead:
1. Permission is enforced at the **ShareToken level** via self-allowance
2. WRAPX controls issuance of permit signatures that grant self-allowance
3. Transfer/withdrawal operations check that self-allowance exists before proceeding
4. This creates an indirect gating mechanism - no withdrawal possible without validator-approved permit

This approach keeps the settlement vault simple and stable while the token layer controls access policy.
```

### Key Design Rationale: Settlement Layer

#### 1. Permissionless Deposits (with KYC)
```solidity
// Anyone can deposit IF they're KYC-verified
function deposit(uint256 assets, address receiver) external returns (uint256) {
    // No special permission needed
    // KYC check happens at mint() when shares are created
}
```

**Why?**
- Carriers need to top up wallets quickly (24/7 operation)
- No manual approval bottleneck
- KYC requirement ensures regulatory compliance
- Telecom integration already deployed = verified carrier

#### 2. Dual Authorization for Withdrawals

**A. Direct Transfer (owner withdraws their own funds)**
```solidity
function transfer(address to, uint256 value) public override {
    _spendAllowance(msg.sender, msg.sender, value); // ← Needs self-allowance permit!
    super.transfer(to, value);
}
```

**Why self-allowance required?**
- Settlement disputes must be resolved before withdrawal
- Prevents carriers from withdrawing during fraud investigation
- Regulatory compliance (AML checks on large withdrawals)
- Ensures sufficient liquidity for ongoing settlements
- Settlement platform controls withdrawal timing

**B. Third-Party Transfer (authorized party withdraws on owner's behalf)**
```solidity
function transferFrom(address from, address to, uint256 value) public override {
    _spendAllowance(from, from, value);        // ← Platform authorization (self-allowance)
    return super.transferFrom(from, to, value); // ← Owner delegation (caller allowance)
}
```

**Why BOTH allowances required?**

This is a **dual-authorization model**:

1. **Self-Allowance** (`allowance[from][from]`): Platform/validator permission
   - "Settlement platform permits this carrier to withdraw funds"
   - Set by: Validator via permit signature
   - Checks: No outstanding settlements, no disputes, compliance verified

2. **Caller Allowance** (`allowance[from][caller]`): Owner delegation
   - "Carrier delegates authority to this third party"
   - Set by: Carrier via standard `approve()`
   - Enables: Smart contract automation, authorized operators

**Real-World Example:**
```
Carrier A wants to use InvoicePaymentContract to auto-pay suppliers:

Step 1: Request platform permission
→ Carrier A requests withdrawal clearance from WRAPX
→ WRAPX verifies: no disputes, sufficient balance, compliance OK
→ WRAPX issues permit: allowance[CarrierA][CarrierA] = 1M USDC

Step 2: Delegate to smart contract
→ Carrier A: approve(InvoicePaymentContract, 500k USDC)
→ allowance[CarrierA][InvoicePaymentContract] = 500k

Step 3: Automated payment execution
→ InvoicePaymentContract calls: transferFrom(CarrierA, Supplier, 100k)
→ Checks platform authorization: allowance[CarrierA][CarrierA] ≥ 100k ✓
→ Checks owner delegation: allowance[CarrierA][Contract] ≥ 100k ✓
→ Payment succeeds, both allowances reduced by 100k
```

**Benefits:**
- Platform maintains oversight (prevents unauthorized withdrawals)
- Carrier retains control (can delegate to trusted parties)
- Smart contract integration possible (with platform approval)
- Granular control (different limits for platform vs. delegation)

#### 2a. Non-Standard ERC20 Behavior

The ShareToken deliberately deviates from standard ERC20 in several ways to enforce compliance and settlement safety:

**1. Self-Approval Blocked**
```solidity
function approve(address spender, uint256 value) public override {
    if (msg.sender == spender) revert ERC20InvalidSpender(msg.sender);
    super.approve(spender, value);
}
```
- Prevents users from creating their own self-allowance
- Forces validator/settlement platform to explicitly grant withdrawal permissions
- Ensures no withdrawal happens without platform approval

**2. Transfer Requires Self-Allowance**
```solidity
function transfer(address to, uint256 value) public override {
    _spendAllowance(msg.sender, msg.sender, value);  // Must have validator permit
    super.transfer(to, value);
}
```
- **Standard ERC20**: `transfer()` only requires you own the tokens
- **WERC7575**: `transfer()` also requires validator-issued self-allowance permit
- Enforces settlement safety: funds committed to pending settlements cannot be moved

**3. KYC Enforcement**
```solidity
function transfer(address to, uint256 value) public override {
    if (!isKycVerified[to]) revert KycRequired();
    // ... rest of transfer
}
```
- Recipients must be KYC-verified before receiving tokens
- Regulatory requirement for wholesale telecom settlements
- Prevents transfers to unverified addresses

**Integration Implications:**

| Scenario | Standard ERC20 | WERC7575 |
|----------|----------------|---------|
| User transfers tokens | Works without permission | Requires validator permit |
| Smart contract interaction | Can call `approve()` + `transferFrom()` | Must get validator permit for self-allowance |
| Wallet integration | MetaMask "Send" works | MetaMask fails (no permit mechanism) |
| DEX integration | Works directly | Cannot integrate (requires permits) |
| Standard approvals | Any address can approve themselves | Self-approval blocked |

**This is NOT compatible with standard DeFi tooling and is intentionally NOT designed to be.** The token enforces a compliance-first model suitable for commercial wholesale settlements, not permissionless DeFi.

#### 3. Batch Settlement Optimization
```solidity
function batchTransfers(
    address[] calldata debtors,
    address[] calldata creditors,
    uint256[] calldata amounts
) external onlyValidator nonReentrant returns (bool)
```

**Why?**
- **Gas Efficiency**: Thousands of inter-carrier transactions per month
- **Netting**: Carrier A owes B, B owes C, C owes A → optimize to single net transfer
- **Atomic Settlement**: All or nothing (prevents partial settlement)
- **Regulatory Audit Trail**: Single transaction for entire settlement period

**Example Optimization:**
```
Without netting: 1000 individual transfers = 51M gas
With netting:    200 net transfers = 10M gas
Savings:         80% gas reduction
```

#### 4. rBalance System for Investment Tracking
```solidity
// Tracks investment contract's funds: available vs. invested
_balances[investmentContract]  // Available for funding
_rBalances[investmentContract] // Invested in deals (not yet returned)
```

**Why?**
- **Investment Tracking**: Investment contract deploys capital into telecom deals
- **Yield Distribution**: When deals profitable, adjust rBalance to reflect returns
- **Liquidity Management**: Know how much available for new deals vs. locked in existing deals
- **Regulatory Reporting**: Separate liquid funds from invested capital

**Note:** Carriers do NOT have rBalance tracking. Only the investment contract (ShareTokenUpgradeable) uses rBalance to track its deployed capital and returns.

**Example:**
```
Investment contract (ShareTokenUpgradeable) has 1M USDC deposited in settlement layer:
• _balances[investmentContract] = 600k (available for funding new deals)
• _rBalances[investmentContract] = 400k (invested in deals, earning yield)

When deal returns 20% profit:
• adjustrBalance(investmentContract, 400k invested, 480k returned)
• _balances[investmentContract] = 600k (unchanged - still available)
• _rBalances[investmentContract] = 480k (increased from 400k)
• Investment contract earned 80k profit (480k - 400k)
```

---

## TIER 2: Investment Layer (Upgradeable)

### Purpose: Investment Capital for Telecom Deals

**Primary Users:** Investors (not telecom carriers)

**Core Function:** Collect investment capital and deploy it into settlement contract to fund telecom traffic deals

### Use Case Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    INVESTMENT FLOW                                  │
└─────────────────────────────────────────────────────────────────────┘

Step 1: Investor Onboarding
────────────────────────────
Investor deposits USDC → ERC7575VaultUpgradeable

Request → Fulfill → Claim (ERC-7540 async flow)
• Request: Investor transfers USDC to vault
• Fulfill: Investment Manager converts to shares (when ready)
• Claim: Investor receives IUSD shares

Step 2: Investment Deployment
──────────────────────────────
Investment Manager takes vault's idle USDC and invests:

investAssets(amount) → deposits into WERC7575Vault (Settlement Layer)

WERC7575Vault mints WUSD shares to ShareTokenUpgradeable

ShareTokenUpgradeable holds WUSD shares on behalf of investors

Step 3: Telecom Deal Funding
─────────────────────────────
Investment capital in Settlement Layer used for:
• Funding carrier prepayments
• Working capital for voice traffic deals
• Margin for settlement float
• Emergency liquidity reserves

Step 4: Yield Generation
────────────────────────
Telecom deals generate profit:
• Settlement fees from carriers
• Voice traffic margins
• Interest on prepayments

Settlement platform adjusts rBalance:
adjustrBalance(ShareTokenUpgradeable, invested, returned)

Step 5: Investor Redemption
────────────────────────────
Investor wants to exit:

• Request redemption of IUSD shares
• Investment Manager withdraws from Settlement Layer
• Investor receives USDC + profit
```

### Key Design Rationale: Investment Layer

#### 1. Async Operations (ERC-7540)
```solidity
// Request → Fulfill → Claim
function requestDeposit(uint256 assets, address controller, address owner)
function fulfillDeposit(address controller, uint256 assets)
function deposit(uint256 assets, address receiver)
```

**Why?**
- **Capital Efficiency**: Batch investments when deals available
- **Liquidity Management**: Don't need instant execution
- **Professional Management**: Investment Manager decides timing
- **Risk Management**: Can delay during high volatility

#### 2. Investment into Settlement Contract
```solidity
function investAssets(uint256 amount) external returns (uint256 shares) {
    // Deposit into WERC7575Vault (Settlement Layer)
    shares = IERC7575($.investmentVault).deposit(amount, $.shareToken);
}
```

**Why?**
- **Direct Exposure**: Investors get yield from actual telecom settlements
- **Transparent**: Investment goes directly into operational contract
- **Measurable**: Can track WUSD shares representing settlement position
- **Liquid**: Can withdraw from settlement (with permission) when needed

#### 3. Upgradeable Architecture
```solidity
contract ERC7575VaultUpgradeable is UUPSUpgradeable, OwnableUpgradeable
```

**Why?**
- **Regulatory Adaptation**: Investment products may need compliance updates
- **Feature Additions**: Can add new investment strategies
- **Bug Fixes**: Can patch issues without redeploying
- **Different Standards**: Settlement layer is battle-tested, investment layer evolves

---

## System Interaction: Two Layers Working Together

### Capital Flow

```
INVESTORS                    INVESTMENT LAYER              SETTLEMENT LAYER              CARRIERS
   │                              │                              │                          │
   │ 1. Deposit USDC              │                              │                          │
   ├─────────────────────────────►│                              │                          │
   │                              │                              │                          │
   │                              │ 2. Invest USDC               │                          │
   │                              ├─────────────────────────────►│                          │
   │                              │                              │                          │
   │                              │    (WUSD shares to           │                          │
   │                              │◄─────ShareToken)             │                          │
   │                              │                              │                          │
   │                              │                              │ 3. Fund telecom deals    │
   │                              │                              ├─────────────────────────►│
   │                              │                              │                          │
   │                              │                              │ 4. Settlements & fees    │
   │                              │                              │◄─────────────────────────┤
   │                              │                              │                          │
   │                              │ 5. Yield generated           │                          │
   │                              │    (rBalance adjustments)    │                          │
   │                              │◄─────────────────────────────┤                          │
   │                              │                              │                          │
   │ 6. Redeem + profit           │                              │                          │
   │◄─────────────────────────────┤                              │                          │
   │                              │                              │                          │
```

### Yield Generation Mechanism

**Settlement Layer generates profit from:**
1. **Settlement Fees**: Carriers pay fee per settlement
2. **Voice Traffic Margins**: Buy/sell voice minutes
3. **Prepayment Interest**: Carriers prepay for volume discounts
4. **Liquidity Services**: Premium for instant settlement

**Profit Distribution:**
1. Settlement platform calculates returns per period
2. Calls `adjustrBalance()` on ShareTokenUpgradeable's position
3. ShareTokenUpgradeable's WUSD shares increase in value
4. IUSD share price increases proportionally
5. Investors can redeem IUSD for more USDC than deposited

### Example: End-to-End Flow

```
Month 1:
────────
• Investor deposits 100k USDC → receives 100k IUSD shares
• Investment Manager invests 100k USDC → Settlement Layer
• Settlement Layer mints 100k WUSD shares → ShareTokenUpgradeable
• Investment used to fund Carrier A's traffic deals

Month 2:
────────
• Settlement activity generates 10k profit
• Settlement platform adjusts: adjustrBalance(ShareToken, 100k, 110k)
• ShareTokenUpgradeable now has 110k value in Settlement Layer
• IUSD share price: 110k / 100k = 1.10 USDC per IUSD

Month 3:
────────
• Investor redeems 100k IUSD shares
• Investment Manager withdraws 110k USDC from Settlement Layer
• Investor receives 110k USDC
• Profit: 10k USDC (10% return)
```

---

## Why Two Separate Systems?

### Separation of Concerns

| Aspect | Settlement Layer | Investment Layer |
|--------|------------------|------------------|
| **Users** | Telecom carriers | Investors |
| **Purpose** | Operational settlement | Capital deployment |
| **Deposits** | Permissionless (with KYC) | Async (managed) |
| **Withdrawals** | Permission required | Managed by IM |
| **Architecture** | Non-upgradeable (stable) | Upgradeable (flexible) |
| **Standards** | ERC-4626, ERC-7575, ERC-7540 | ERC-4626, ERC-7575, ERC-7540, ERC-7887 |
| **Gas Priority** | Critical (frequent) | Less critical (batched) |
| **Audit Status** | Battle-tested | Evolving |

*Note: The Settlement Layer's ShareToken (WERC7575ShareToken) additionally implements ERC-2612 (permit) for signature-based approvals.*

### Why Settlement is Non-Upgradeable

**Stability is Critical:**
- Handles millions in carrier funds
- Real-time settlements cannot fail
- Carriers need certainty of behavior
- Battle-tested code = lower risk
- Regulatory approval = hard to change

### Why Investment is Upgradeable

**Flexibility is Valuable:**
- Investment products evolve
- Regulatory requirements change
- Can add new features (e.g., different yield strategies)
- Bug fixes without affecting carriers
- Can adapt to market conditions

---

## Centralization Rationale in Context

### Settlement Layer Centralization

**Why WRAPX (Validator) Controls Withdrawals:**
```
Real-world scenario:
─────────────────────
Carrier A withdraws 1M USDC
BUT they have 500k outstanding settlement with Carrier B
PROBLEM: Carrier B cannot settle now!

Solution: WRAPX permit system
────────────────────────────────────
Carrier A requests withdrawal → WRAPX checks via COMMTRADE:
  ✓ No outstanding disputes (COMMTRADE confirms)
  ✓ No pending settlements (COMMTRADE confirms)
  ✓ Regulatory compliance (KYC status current)
  ✗ Large withdrawal → manual review

Only after approval → WRAPX issues permit signature → withdrawal succeeds
```

**Why Batch Settlements by WRAPX (Validator):**
```
Without batching (direct OSS/BSS → blockchain):
───────────────────────────────────────────────
1000 carriers × 100 transactions each = 100,000 individual blockchain transfers
Cost: Prohibitively expensive in gas
Risk: Some transfers fail = inconsistent state
No optimization possible

With multi-tier architecture (OSS/BSS → COMMTRADE → WRAPX → blockchain):
─────────────────────────────────────────────────────────────────────────
TIER 1 (OSS/BSS): Generates CDRs for all voice traffic
TIER 2 (COMMTRADE):
  • Aggregates CDRs
  • Calculates net positions
  • Sends individual settlement instructions to WRAPX
TIER 3 (WRAPX):
  • Receives individual settlement instructions from COMMTRADE
  • Batches multiple instructions together
  • Optimizes with netting algorithm
  • Pushes single atomic batch to blockchain
TIER 4 (Blockchain): Executes batched settlement

Result: 100,000 CDRs → 5,000 settlement instructions → 200 batched blockchain txs
Cost: 95% gas savings
Risk: All-or-nothing = consistent state
Benefit: COMMTRADE handles complex rate logic, WRAPX optimizes blockchain efficiency
```

**Why KYC Required:**
```
Regulatory requirement:
──────────────────────
Telecom settlements = financial services
Multi-jurisdiction carriers = AML compliance
Large transaction volumes = monitoring required
Fraudulent carriers = industry risk

Solution: KYC before wallet creation
────────────────────────────────────
Every carrier verified before COMMTRADE integration
Telecom OSS/BSS integration = identity verification
WRAPX maintains KYC status
Ongoing monitoring via COMMTRADE suspicious activity detection
```

**Why Multi-Tier Architecture (OSS/BSS → COMMTRADE → WRAPX → Blockchain):**
```
Single-tier approach problems:
──────────────────────────────
❌ Every CDR becomes a blockchain transaction = cost prohibitive
❌ Rate logic on-chain = complex, expensive, hard to update
❌ OSS/BSS systems can't directly interact with blockchain
❌ No optimization layer for gas efficiency
❌ Dispute resolution requires on-chain arbitration

Multi-tier benefits:
────────────────────
✅ TIER 1 (OSS/BSS): Legacy systems work as-is, no blockchain knowledge needed
✅ TIER 2 (COMMTRADE):
   • Complex rate logic off-chain, flexible, updateable
   • Aggregates CDRs and calculates net positions
   • Sends individual settlement instructions (not batches)
✅ TIER 3 (WRAPX):
   • Receives individual instructions from COMMTRADE
   • Batches instructions for blockchain efficiency
   • Gas optimization through netting algorithm
   • Dispute handling and permit management
✅ TIER 4 (Blockchain): Immutable settlement record, transparent, auditable

Cost efficiency:
───────────────
1M CDRs/month → COMMTRADE aggregates and sends instructions →
WRAPX batches into ~ X blockchain tx/day = 30X blockchain txs/month
Without tiers: 1M blockchain txs/month (33,333x/X more expensive!)
```

### Investment Layer Centralization

**Why Investment Manager Controls Fulfillment:**
```
Capital efficiency scenario:
───────────────────────────
100 investors deposit throughout the month
Each wants immediate shares
BUT only deploy capital when large deal available

Solution: Async fulfillment
───────────────────────────
Investors request deposits (assets secured)
Investment Manager waits for optimal deal
Fulfills all deposits together when deal ready
Capital efficiency: 100% deployed vs. 20% idle
```

**Why Investment Manager Controls Timing:**
```
Risk management scenario:
────────────────────────
High volatility period in telecom markets
Investor requests redemption
BUT withdrawing now = selling at loss

Solution: Managed redemption
────────────────────────────
Investment Manager delays fulfillment
Waits for markets to stabilize
Fulfills when profitable exit available
Protects investor returns
```

---

## Security Considerations in Context

### Settlement Layer Security Priorities

**Critical Invariants:**
1. **Zero-Sum Settlements**: Batch transfers never create/destroy value
2. **Liquidity Protection**: Can't invest reserved settlement funds
3. **Withdrawal Safety**: Permit system prevents unauthorized exits
4. **Atomic Settlements**: All transfers succeed or all revert

**Attack Vectors to Consider:**
- Manipulating batch netting for profit
- Withdrawing during settlement to cause failure
- Double-spending settlement obligations
- rBalance manipulation to fake profits

### Investment Layer Security Priorities

**Critical Invariants:**
1. **Reserved Asset Protection**: Investment can't touch pending/claimable funds
2. **Share Accounting**: IUSD supply matches underlying WUSD position
3. **Fulfillment Accuracy**: Pending → claimable conversions correct
4. **Investment Safety**: Can't over-invest beyond available balance

**Attack Vectors to Consider:**
- Manipulating reserved asset calculation to over-invest
- Exploiting async flow for double-claims
- Front-running fulfillment operations
- Storage corruption during upgrades

---

## Integration Notes for Auditors

### Understanding Context is Critical

**Common Misconception:**
> "Why can't users withdraw freely? This is centralized censorship!"

**Reality:**
This is a **settlement platform** for **commercial counterparties**, not a consumer wallet.

Analogous to:
- **Banking**: Can't withdraw during fraud investigation
- **Escrow**: Can't withdraw without counterparty release
- **Clearing House**: Can't exit during settlement period

**Proper Audit Question:**
> "Can withdrawal permission be abused to steal funds?"
> "Are there safeguards against validator refusing legitimate withdrawals?"

### What Makes This Different from DeFi

| DeFi Standard | WERC7575 Settlement |
|---------------|---------------------|
| Permissionless access | KYC required (regulatory) |
| Instant withdrawals | Permission required (settlement safety) |
| No operator control | Validator controls (operational necessity) |
| Code is law | Code + legal agreements |
| Trust-minimized | Trust professional operators |

**This is NOT a bug, it's the business model.**

---

## Conclusion

The WERC7575 system implements:

1. **Settlement Layer**: Operational platform for telecom carrier settlements
   - Permissionless deposits (operational necessity)
   - Permission-required withdrawals (settlement safety)
   - Batch settlement optimization (cost efficiency)
   - Non-upgradeable architecture (stability)

2. **Investment Layer**: Capital deployment into settlement operations
   - Async operations (capital efficiency)
   - Professional management (risk management)
   - Upgradeable architecture (regulatory flexibility)
   - Yield generation from telecom settlements

**Both architectures are centralized BY DESIGN for legitimate business reasons**, not due to oversight or lack of sophistication.

Auditors should focus on:
- Security vulnerabilities within the intended design
- Business logic correctness
- Standards compliance
- Upgrade safety

NOT:
- The centralization itself
- Comparison to DeFi ideals
- Philosophical objections

---

**Document Version:** 1.0
**Last Updated:** 2025-01-05
**Context:** Telecom Wholesale Voice Traffic Settlement + Investment Platform
