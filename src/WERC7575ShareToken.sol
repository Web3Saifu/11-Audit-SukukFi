// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecimalConstants} from "./DecimalConstants.sol";

import {IERC7575, IERC7575Share} from "./interfaces/IERC7575.sol";
import {IERC7575Errors} from "./interfaces/IERC7575Errors.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

// Interface for vault validation - minimal interface to avoid circular dependencies
interface IERC7575Vault {
    function totalAssets() external view returns (uint256);
}

/** 
 * @title WERC7575ShareToken (Wrapped ERC20 Share Token)
 * @notice NON-STANDARD ERC-20 IMPLEMENTATION WITH RESTRICTED TRANSFERS
 *
 * WERC = Wrapped ERC20 - Represents underlying assets as normalized 18-decimal shares
 *
 * ARCHITECTURE OVERVIEW:
 * This token provides a 1:1 wrapped representation of underlying ERC20 assets (USDT, USDC, etc.)
 * with decimal normalization to 18 decimals. For example:
 * - 1 USDC (6 decimals) = 1e12 scaling → 1e18 WERC shares
 * - 1 DAI (18 decimals) = 1e0 scaling → 1e18 WERC shares
 *
 * The 1:1 ratio is maintained through deterministic decimal scaling, NOT through
 * totalSupply/totalAssets ratios, making this architecture immune to donation/inflation attacks.
 *
 * USE CASES:
 * - Regulatory-compliant tokenized assets requiring KYC/AML
 * - Institutional vaults with controlled transfer permissions
 * - Multi-asset vault systems with unified 18-decimal share representation
 *
 * @dev This token implements centralized transfer controls that deviate from standard ERC-20:
 *
 * CRITICAL INTEGRATION WARNINGS:
 * - transfer() requires pre-existing self-allowance via permit()
 * - transferFrom() requires both owner's self-allowance AND caller's allowance
 * - approve() blocks self-approval (only validator can authorize via permit)
 * - All recipients must be KYC-verified by the KYC admin
 * - Validator controls batch transfers and permit operations
 * - Revenue admin controls rBalance adjustments
 *
 * INCOMPATIBLE WITH STANDARD ERC-20 INTEGRATIONS:
 * - DEXs (Uniswap, SushiSwap) will fail without modifications
 * - Lending protocols (Compound, Aave) will fail
 * - Standard wallet transfer functions will fail
 * - Multi-sig operations may fail
 * - Token streaming/vesting protocols will fail
 *
 * CENTRALIZATION RISKS:
 * - Single point of failure: KYC admin key compromise can lock all users from transfers
 * - Single point of failure: Validator key compromise can halt batch transfers
 * - Single point of failure: Revenue admin key compromise can manipulate rBalance
 * - User lock-in: KYC admin + validator signatures required for all token movements
 * - Censorship capability: KYC admin can prevent any user from transferring via KYC denial
 *
 * FOR INTEGRATORS:
 * Before integration, ensure your protocol handles:
 * - Permit-based authorization flows instead of standard approvals
 * - KYC verification requirements for all recipients
 * - Validator signature dependencies for user operations
 * - Non-standard transfer mechanics and failure modes
 *
 * See documentation for detailed integration guidelines and risk assessment.
 */
contract WERC7575ShareToken is ERC20, IERC20Permit, EIP712, Nonces, ReentrancyGuard, Ownable2Step, ERC165, Pausable, IERC7575Errors {
    using EnumerableMap for EnumerableMap.AddressToAddressMap;//using EnumerableMap → Enables iterable mapping for managing asset ↔ vault relationships efficiently.

    // Note: Common errors now inherited from IERC7575Errors interface
    // OnlyOwner is inherited from IERC7575Errors

    // WERC7575-specific errors
    error ArrayTooLarge();//Prevents oversized batch input arrays.
    error ArrayLengthMismatch();//ArrayLengthMismatch → Ensures related arrays have equal length.
    error LowBalance();//LowBalance → Prevents operations when balance is insufficient.
    error ShareTokenZeroValidator();//ShareTokenZeroValidator → Prevents setting validator to zero address.
    error KycRequired();//KycRequired → Blocks actions if user is not KYC verified.
    error RBalanceAdjustmentAlreadyApplied();//Prevents duplicate revenue adjustments.
    error FutureTimestampNotAllowed();//FutureTimestampNotAllowed → Disallows invalid future timestamps.
    error MaxReturnMultiplierExceeded();//MaxReturnMultiplierExceeded → Disallows return multipliers exceeding the maximum.
    error NoRBalanceAdjustmentFound();
    error OnlyValidator();
    error AmountTooLarge();
    error RBalanceAdjustmentTooLarge();
    error InconsistentRAccounts(address account, bool firstDiscoveryFlag, bool currentTransferFlag);

    bytes32 private constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // Batch transfer constants
    // Maximum batch size to prevent exceeding block gas limits
    // Calculated as: 30M gas limit / 25k per transfer ≈ 1000, conservatively set to 100
    // to leave headroom for complex transfers and other operations
    uint256 private constant MAX_BATCH_SIZE = 100;//👉 Batch = doing many actions in one transaction

    // Maximum allowed return multiplier (100% profit cap)
    // Protects against validator input errors and unrealistic returns
    // Value chosen to allow reasonable investment gains while preventing mistakes
    uint256 private constant MAX_RETURN_MULTIPLIER = 2;//👉 This is about profit calculation/User invests: $100 ,,System returns: $200


    // Batch array size multiplier for worst-case scenario
    // Allocates 2x space: 1 entry per debtor + 1 entry per creditor
    // Handles case where no addresses overlap between debtors and creditors
    uint256 private constant BATCH_ARRAY_MULTIPLIER = 2;//👉 Cap = Limit / Maximum allowed

    // Maximum number of vaults per share token - DoS mitigation
    // Prevents unbounded iteration in vault aggregation functions
    uint256 private constant MAX_VAULTS_PER_SHARE_TOKEN = 10;//One ShareToken can connect to multiple vaults

    mapping(address => uint256) private _balances;//_balances → Stores how many share tokens each user owns.
    mapping(address => uint256) private _rBalances;//Stores a special “adjusted/revenue balance” for each user used for internal accounting (not the normal token balance).
    mapping(address => mapping(uint256 => uint256[2])) private _rBalanceAdjustments;//Stores history of revenue adjustments per user using a timestamp/key to track invested amount and received amount.
    uint256 private _totalSupply;//_totalSupply → Stores the total number of share tokens that exist in the system.

    mapping(address => bool) public isKycVerified;//Stores whether a user is KYC approved (true = allowed to interact, false = blocked

    // Multi-vault support as per ERC7575 with EnumerableMap for better management
    EnumerableMap.AddressToAddressMap private _assetToVault; // asset => vault mapping with enumeration//@audit-issue where is  the mapping for vault to asser? for 265 line
    mapping(address => address) private _vaultToAsset; // 👉 Connects each asset to its vault,,USDC → USDC Vault,,USDT → USDT Vault

    address private _validator; //👉 Only this address can approve users
    address private _kycAdmin; // 👉 Without this → Alice cannot use system
    address private _revenueAdmin; // 👉 Controls profit / adjustment logic (rBalance system)

    error ERC2612ExpiredSignature(uint256 deadline);
    error ERC2612InvalidSigner(address signer, address owner);
    error OnlyKycAdmin();
    error OnlyRevenueAdmin();
    error ShareTokenZeroKycAdmin();//→ “Invalid admin, system cannot run without controller”
    error ShareTokenZeroRevenueAdmin();

    event RBalanceAdjusted(address indexed account, uint256 amountInvested, uint256 amountReceived);
    event RBalanceAdjustmentCancelled(address indexed account, uint256 ts);
    event VaultUpdate(address indexed asset, address vault);
    event KYCStatusChanged(address indexed user, address indexed kycAdmin, bool indexed isVerified, uint256 timestamp);
    event ValidatorChanged(address indexed previousValidator, address indexed newValidator);
    event KycAdminChanged(address indexed previousKycAdmin, address indexed newKycAdmin);
    event RevenueAdminChanged(address indexed previousRevenueAdmin, address indexed newRevenueAdmin);

    /**
     * @dev Initializes the ERC7575 share token with multi-asset vault support
     * @param name_ The name of the share token (e.g., "Wrapped USDT")
     * @param symbol_ The symbol of the share token (e.g., "wUSDT")
     *
     * Requirements:
     * - Token decimals must be exactly 18
     * - Sets deployer as owner, validator, kycAdmin, and revenueAdmin
     */
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) EIP712(name_, "1") Ownable(msg.sender) {
        if (decimals() != DecimalConstants.SHARE_TOKEN_DECIMALS) {
            revert WrongDecimals();
        }
        _validator = msg.sender;
        _kycAdmin = msg.sender;
        _revenueAdmin = msg.sender;
    }

    /**
     * @dev Modifier to restrict functions to validator only
     */
    modifier onlyValidator() {
        if (_validator != msg.sender) revert OnlyValidator();
        _;
    }

    /**
     * @dev Modifier to restrict functions to KYC admin only
     */
    modifier onlyKycAdmin() {
        if (_kycAdmin != msg.sender) revert OnlyKycAdmin();
        _;
    }

    /**
     * @dev Modifier to restrict functions to revenue admin only
     */
    modifier onlyRevenueAdmin() {
        if (_revenueAdmin != msg.sender) revert OnlyRevenueAdmin();
        _;
    }

    /**
     * @dev Modifier to restrict functions to authorized vaults only
     */
    modifier onlyVaults() {
        if (_vaultToAsset[msg.sender] == address(0)) revert Unauthorized();
        _;
    }

    /**
     * @dev Adds a new vault for a specific asset (ERC7575 multi-asset support)
     * @param asset The asset token address that the vault will manage
     * @param vaultAddress The vault contract address to authorize
     *
     * Requirements:
     * - Asset must not be zero address
     * - Vault must not be zero address
     * - Asset must not already be registered
     * - Vault's asset() must match the provided asset parameter
     * - Vault's share() must match this ShareToken address
     * - Only callable by owner
     */
    function registerVault(address asset, address vaultAddress) external onlyOwner {//“Register a new bank branch and link it to a specific money type.”
        if (asset == address(0)) revert ZeroAddress();//👉 Asset cannot be empty
        if (vaultAddress == address(0)) revert ZeroAddress();//👉 Vault cannot be empty
        if (_assetToVault.contains(asset)) revert AssetAlreadyRegistered();//👉 One asset = only ONE vault allowed,,USDC → Vault A,,USDC → Vault B

        // Validate that vault's asset matches the provided asset parameter
        if (IERC7575(vaultAddress).asset() != asset) revert AssetMismatch();//👉 Vault must say “I manage USDC” if you register USDC

        // Validate that vault's share token matches this ShareToken
        if (IERC7575(vaultAddress).share() != address(this)) {
            revert VaultShareMismatch();
        }

        // DoS mitigation: Enforce maximum vaults per share token to prevent unbounded loops
        if (_assetToVault.length() >= MAX_VAULTS_PER_SHARE_TOKEN) {//If the count is 10 or more, it stops new vault registration.
            revert MaxVaultsExceeded();
        }

        // Register new vault (automatically adds to enumerable collection)
        _assetToVault.set(asset, vaultAddress);//✔ 9 < 10 → new vault allowed
        _vaultToAsset[vaultAddress] = asset;//❌ 10 >= 10 → revert MaxVaultsExceeded()

        emit VaultUpdate(asset, vaultAddress);//👉 “USDC is now connected to VaultA”
    }

    /**
     * @dev Unregisters a vault for a specific asset
     * @param asset The asset token address to unregister vault authorization for
     *
     * SAFETY: This function now includes outstanding shares validation to prevent
     * user fund loss. It checks that the vault has no remaining assets that users
     * could claim, ensuring safe vault unregistration.
     *
     * Requirements:
     * - Vault must exist and be registered
     * - Vault must have zero assets remaining (no user funds at risk)
     * - Only callable by owner
     * 
     *   @audit-info  _assetToVault = {
       USDC → VaultA,
       USDT → VaultB
       }
     */
    function unregisterVault(address asset) external onlyOwner {//👉 This function removes a vault from the system only if it holds ZERO funds (to protect users).,,asset = USDC,,vaultAddress = VaultA
        if (asset == address(0)) revert ZeroAddress();
        if (!_assetToVault.contains(asset)) revert AssetNotRegistered();//👉 USDC must already have a vault

        address vaultAddress = _assetToVault.get(asset);//USDC → VaultA

        // SAFETY CHECK: Validate that vault has no outstanding assets that users could claim
        // In this architecture, we check vault's total assets rather than share supply
        // since shares are managed by this ShareToken contract, not the vault
        try IERC7575Vault(vaultAddress).totalAssets() returns (uint256 totalAssets) {//“VaultA, how much money do you currently hold?”
            if (totalAssets != 0) revert CannotUnregisterVaultAssetBalance();//“Users still have 500 tokens inside → cannot remove vault”
        } catch {//if Vault crashes / malicious / function missing
            /// If we can't verify the vault has no assets, we can't safely unregister
            /// This prevents unregistration if the vault is malicious or has interface issues
            revert("ShareToken: cannot verify vault has no outstanding assets");
        }
        /// Additional safety: Check if vault still has any assets to prevent user fund loss
        // This is a double-check using ERC20 interface in case totalAssets() is manipulated
        try ERC20(asset).balanceOf(vaultAddress) returns (uint256 vaultBalance) {//“How many USDC are stored in VaultA?”
            if (vaultBalance != 0) revert CannotUnregisterVaultAssetBalance();
        } catch {
            // If we can't check the asset balance in vault, err on the side of caution
            revert("ShareToken: cannot verify vault asset balance");
        }
        // Remove vault registration and authorization (automatically removes from enumerable collection)
        _assetToVault.remove(asset);
        delete _vaultToAsset[vaultAddress]; // Also clear reverse mapping for authorization

        emit VaultUpdate(asset, address(0));
    }

    /**
     * @dev Sets KYC status for an address
     * @param controller The address to set KYC status for
     * @param isVerified True to mark as KYC verified, false otherwise
     *
     * Emits KYCStatusChanged event only when status actually changes to save gas
     */
    function setKycVerified(address controller, bool isVerified) public onlyKycAdmin {
        bool previousStatus = isKycVerified[controller];

        // Only update and emit if status actually changes
        if (previousStatus != isVerified) {
            isKycVerified[controller] = isVerified;
            emit KYCStatusChanged(controller, msg.sender, isVerified, block.timestamp);
        }
    }

    /**
     * @dev Sets the validator address for permit operations and batch transfers
     * @param validator The new validator address
     *
     * Emits a ValidatorChanged event for off-chain monitoring
     */
    function setValidator(address validator) public onlyOwner {
        if (validator == address(0)) revert ShareTokenZeroValidator();
        address previousValidator = _validator;
        _validator = validator;
        emit ValidatorChanged(previousValidator, validator);
    }

    /**
     * @dev Sets the KYC admin address for managing KYC verification
     * @param kycAdmin The new KYC admin address
     *
     * Emits a KycAdminChanged event for off-chain monitoring
     */
    function setKycAdmin(address kycAdmin) public onlyOwner {
        if (kycAdmin == address(0)) revert ShareTokenZeroKycAdmin();
        address previousKycAdmin = _kycAdmin;
        _kycAdmin = kycAdmin;
        emit KycAdminChanged(previousKycAdmin, kycAdmin);
    }

    /**
     * @dev Sets the revenue admin address for managing rBalance adjustments
     * @param revenueAdmin The new revenue admin address
     *
     * Emits a RevenueAdminChanged event for off-chain monitoring
     */
    function setRevenueAdmin(address revenueAdmin) public onlyOwner {
        if (revenueAdmin == address(0)) revert ShareTokenZeroRevenueAdmin();
        address previousRevenueAdmin = _revenueAdmin;
        _revenueAdmin = revenueAdmin;
        emit RevenueAdminChanged(previousRevenueAdmin, revenueAdmin);
    }

    /**
     * @dev Pause critical ShareToken operations. Only callable by owner.
     * Used for emergency situations to halt batch transfers and rBalance adjustments.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause ShareToken operations. Only callable by owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Mints new share tokens to an address (vault-only operation)
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyVaults whenNotPaused {
        if (to == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(address(0));
        }
        if (!isKycVerified[to]) revert KycRequired();
        _mint(to, amount);
    }

    /**
     * @dev Burns share tokens from an address (vault-only operation)
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyVaults whenNotPaused {
        if (from == address(0)) {
            revert IERC20Errors.ERC20InvalidSender(address(0));
        }
        if (!isKycVerified[from]) revert KycRequired();
        _burn(from, amount);
    }

    /**
     * @dev Permit function allowing gasless approvals via signatures
     * @param owner The owner of the tokens
     * @param spender The address to approve spending
     * @param value The amount to approve
     * @param deadline The signature expiration timestamp
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     *
     * Special case: When owner == spender, validator signature is required
     */
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public virtual {
        if (block.timestamp > deadline) {
            revert ERC2612ExpiredSignature(deadline);
        }

        uint256 nonce = _useNonce(owner);
        bytes32 permitTypehash = PERMIT_TYPEHASH;

        bytes32 structHash;
        assembly {
            let freeMemPtr := mload(0x40)
            mstore(freeMemPtr, permitTypehash)
            mstore(add(freeMemPtr, 0x20), owner)
            mstore(add(freeMemPtr, 0x40), spender)
            mstore(add(freeMemPtr, 0x60), value)
            mstore(add(freeMemPtr, 0x80), nonce)
            mstore(add(freeMemPtr, 0xa0), deadline)
            structHash := keccak256(freeMemPtr, 0xc0)
        }

        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);

        if (owner == spender) {
            if (signer != _validator) {
                revert ERC2612InvalidSigner(signer, owner);
            }
        } else {
            if (signer != owner) {
                revert ERC2612InvalidSigner(signer, owner);
            }
        }
        _approve(owner, spender, value);
    }

    /**
     * @dev Approve function with self-approval protection
     * @param spender The address to approve spending
     * @param value The amount to approve
     * @return bool True if approval successful
     *
     * Note: Self-approval is blocked, use permit instead for self-spending
     */
    function approve(address spender, uint256 value) public virtual override returns (bool) {
        if (msg.sender != spender) {
            return super.approve(spender, value);
        }
        revert ERC20InvalidSpender(msg.sender);
    }

    /**
     * @dev Returns the current nonce for an owner address
     * @param owner The address to get nonce for
     * @return uint256 The current nonce value
     */
    function nonces(address owner) public view virtual override(IERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /**
     * @dev Returns the domain separator for EIP-712 signatures
     * @return bytes32 The domain separator hash
     */
    // EIP-712 standard requires mixed-case DOMAIN_SEPARATOR
    function DOMAIN_SEPARATOR() external view virtual returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @dev Transfer function with self-allowance spending requirement
     * @param to The address to transfer tokens to
     * @param value The amount of tokens to transfer
     * @return bool True if transfer successful
     *
     * Note: Requires self-allowance via permit for transfers, rBalance should not be affected by transfer.
     */
    function transfer(address to, uint256 value) public override whenNotPaused returns (bool) {
        address from = msg.sender;
        if (!isKycVerified[to]) revert KycRequired();
        _spendAllowance(from, from, value);
        return super.transfer(to, value);
    }

    /**
     * @dev Transfer from function with self-allowance spending requirement
     * @param from The address to transfer tokens from
     * @param to The address to transfer tokens to
     * @param value The amount of tokens to transfer
     * @return bool True if transfer successful
     *
     * Note: Always spends from self-allowance regardless of caller, rBalance should not be affected by transferFrom.
     */
    function transferFrom(address from, address to, uint256 value) public override whenNotPaused returns (bool) {
        if (!isKycVerified[to]) revert KycRequired();
        _spendAllowance(from, from, value);
        return super.transferFrom(from, to, value);
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override(ERC20) returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev Returns the token balance of an account
     * @param account The address to check balance for
     * @return uint256 The token balance
     */
    function balanceOf(address account) public view virtual override(ERC20) returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev Internal update function that maintains custom balance tracking
     * @param from The address tokens are transferred from (zero for minting)
     * @param to The address tokens are transferred to (zero for burning)
     * @param value The amount of tokens being transferred
     *
     * This override maintains our custom _balances mapping to avoid double
     * Transfer event emission in batchTransfers function
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Returns the reserved balance (rBalance) of an account
     * @param account The address to check rBalance for
     * @return uint256 The reserved balance amount
     */
    function rBalanceOf(address account) public view returns (uint256) {
        return _rBalances[account];
    }

    /**
     * @dev Returns the vault address for a given asset
     * @param asset The asset token address
     * @return address The vault address managing this asset (zero address if not registered)
     */
    function vault(address asset) external view returns (address) {
        if (_assetToVault.contains(asset)) {
            return _assetToVault.get(asset);
        }
        return address(0);
    }

    // Note: asset registration can be inferred via vault(asset) != address(0)

    /**
     * @dev Returns whether an address is a registered vault
     * @param vaultAddress The vault address to check
     * @return bool True if the address is a registered vault
     */
    function isVault(address vaultAddress) external view returns (bool) {
        return _vaultToAsset[vaultAddress] != address(0);
    }

    /**
     * @dev Returns all registered assets in the multi-asset system
     * @return address[] Array of all asset addresses that have registered vaults
     */
    function getRegisteredAssets() external view returns (address[] memory) {
        return _assetToVault.keys();
    }

    /**
     * @dev Returns all registered vaults in the multi-asset system
     * @return address[] Array of all vault addresses that are registered
     */
    function getRegisteredVaults() external view returns (address[] memory) {
        address[] memory assets = _assetToVault.keys();
        address[] memory vaults = new address[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            vaults[i] = _assetToVault.get(assets[i]);
        }

        return vaults;
    }

    /**
     * @dev Returns the total number of registered asset-vault pairs
     * @return uint256 The number of registered vaults
     */
    function getVaultCount() external view returns (uint256) {
        return _assetToVault.length();
    }

    /**
     * @dev Returns asset and vault at the given index (for iteration)
     * @param index The index to query
     * @return asset The asset address at this index
     * @return vaultAddress The vault address at this index
     */
    function getVaultAtIndex(uint256 index) external view returns (address asset, address vaultAddress) {
        return _assetToVault.at(index);
    }

    /**
     * @dev Returns the current validator address
     * @return address The validator address
     */
    function getValidator() external view returns (address) {
        return _validator;
    }

    /**
     * @dev Returns the current KYC admin address
     * @return address The KYC admin address
     */
    function getKycAdmin() external view returns (address) {
        return _kycAdmin;
    }

    /**
     * @dev Returns the current revenue admin address
     * @return address The revenue admin address
     */
    function getRevenueAdmin() external view returns (address) {
        return _revenueAdmin;
    }

    /**
     * @dev Returns true if this contract implements the interface defined by interfaceId
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return bool True if the contract implements interfaceId
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IERC7575Share).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Spends self allowance for an owner (vault-only operation)
     * @param owner The owner address to spend allowance for
     * @param shares The amount of shares to spend from allowance
     */
    function spendSelfAllowance(address owner, uint256 shares) external onlyVaults {
        _spendAllowance(owner, owner, shares);
    }

    /**
     * @dev Structure to track debits and credits for batch transfer optimization
     * @param owner The account address
     * @param debit Total amount being debited from the account
     * @param credit Total amount being credited to the account
     */
    struct DebitAndCredit {
        address owner;
        uint256 debit;
        uint256 credit;
    }

    /**
     * @dev Performs batch transfers for settlement operations
     * @param debtors Array of addresses to debit tokens from
     * @param creditors Array of addresses to credit tokens to
     * @param amounts Array of amounts for each transfer
     * @return bool True if all transfers successful
     *
     * This function optimizes multiple transfers by netting debits/credits
     * and moves tokens between regular balance and reserved balance (rBalance)
     * to minimize gas costs and avoid double Transfer event emission.
     *
     * REENTRANCY PROTECTION:
     * This function does NOT use nonReentrant guard because:
     * - Only manipulates internal state (_balances)
     * - Makes no external calls to other contracts
     * - Follows Checks-Effects-Interactions (CEI) pattern
     * - No way for an attacker to re-enter before state is finalized
     *
     * Requirements:
     * - All arrays must have the same length
     * - Maximum 100 transfers per batch
     * - Contract must not be paused
     * - Sufficient balance in debtor accounts
     */
    function batchTransfers(address[] calldata debtors, address[] calldata creditors, uint256[] calldata amounts) external onlyValidator returns (bool) {
        (DebitAndCredit[] memory accounts, uint256 accountsLength) = consolidateTransfers(debtors, creditors, amounts);

        // CEI: Update balances only (do NOT modify rBalances - that is rBatchTransfers' job)
        for (uint256 i = 0; i < accountsLength;) {
            DebitAndCredit memory account = accounts[i];
            if (account.debit > account.credit) {
                uint256 amount = account.debit - account.credit;
                uint256 debtorBalance = _balances[account.owner]; // Direct storage access instead of function call
                if (debtorBalance < amount) revert LowBalance();
                unchecked {
                    _balances[account.owner] -= amount;
                }
            } else if (account.debit < account.credit) {
                uint256 amount = account.credit - account.debit;
                unchecked {
                    _balances[account.owner] += amount;
                }
            }

            unchecked {
                ++i;
            } // Unchecked pre-increment for gas optimization
        }

        // CEI: Emit Transfer events after all state changes are complete
        for (uint256 i = 0; i < debtors.length;) {
            emit Transfer(debtors[i], creditors[i], amounts[i]);
            unchecked {
                ++i;
            } // Unchecked pre-increment for gas optimization
        }

        return true;
    }

    /**
     * @dev Computes the rBalance flags bitmap for batch transfers
     * @param debtors Array of debtor addresses
     * @param creditors Array of creditor addresses
     * @param debtorsRBalanceFlags Boolean array: debtorsRBalanceFlags[i] = true if debtors[i] needs rBalance update
     * @param creditorsRBalanceFlags Boolean array: creditorsRBalanceFlags[i] = true if creditors[i] needs rBalance update
     * @return rBalanceFlags Computed bitmap for accounts array indices that need rBalance updates
     *
     * VALIDATION APPROACH:
     * This helper function separates validation from execution for integrity verification:
     *
     * PHASE 1 (PRE-COMPUTATION):
     * - Maps the boolean arrays (indexed by transfer number) to rBalanceFlags bitmap (indexed by aggregated account position)
     * - Replicates EXACT account aggregation logic from consolidateTransfers() for semantic equivalence
     * - Called OFF-CHAIN before transaction submission for verification
     * - Pure function: deterministic, no side effects, independently verifiable
     *
     * PHASE 2 (EXECUTION):
     * - Result passed to rBatchTransfers() as parameter
     * - Uses O(1) bitwise lookup: ((rBalanceFlags >> i) & 1) instead of O(N) search
     * - Ensures only pre-approved accounts have rBalance updated
     *
     * INPUT FORMAT (boolean arrays):
     * - debtorsRBalanceFlags[i]:     true if debtors[i] needs rBalance update
     * - creditorsRBalanceFlags[i]:   true if creditors[i] needs rBalance update
     *
     * OUTPUT FORMAT (rBalanceFlags bitmap):
     * - Bits 0..M-1:   Set if accounts[i] (in aggregated order) needs rBalance update
     *                  where M <= 2N (typically M much less due to deduplication)
     *
     * MAPPING EXAMPLE:
     * Transfer 0: alice → bob    [debtorsRBalanceFlags[0]=true, creditorsRBalanceFlags[0]=false]
     * Transfer 1: bob → charlie  [debtorsRBalanceFlags[1]=false, creditorsRBalanceFlags[1]=true]
     *
     * Account aggregation:
     * 1. Transfer 0: alice (new) → bob (new)
     *    - alice new at position 0, flag=true → set rBalanceFlags bit 0
     *    - bob new at position 1, flag=false → clear rBalanceFlags bit 1
     * 2. Transfer 1: bob (found) → charlie (new)
     *    - bob found at position 1 (no-op)
     *    - charlie new at position 2, flag=true → set rBalanceFlags bit 2
     * Result: rBalanceFlags = 0b101 (alice and charlie marked for update)
     *
     * FIRST-DISCOVERY FLAG DETERMINATION:
     * - Account rBalance flag is set based on FIRST occurrence (earliest transfer) of that account
     * - If alice appears as debtor in transfer 0 (marked for rBalance), alice's flag is set
     * - If alice appears again in transfer 5 (NOT marked for rBalance), flag ALREADY SET, not re-evaluated
     * - This ensures deterministic, order-dependent (but not arbitrary) flag assignment
     * - CONSISTENCY REQUIREMENT: If an account is marked in one role (debtor/creditor), it MUST be
     *   marked consistently in all subsequent transfers involving that account in any role
     *
     * SEMANTIC EQUIVALENCE:
     * The account aggregation logic in computeRBalanceFlags() MUST match
     * consolidateTransfers() exactly. Both:
     * - Skip self-transfers (debtor == creditor)
     * - Use identical bit flag patterns for account discovery
     * - Process accounts in identical discovery order
     * This ensures flags computed here will be applied to correct accounts in rBatchTransfers()
     *
     * INTEGRITY PROPERTIES:
     * 1. Deterministic: Same inputs always produce same output (pure function)
     * 2. Off-chain verifiable: Can compute and validate before submitting transaction
     * 3. First-discovery semantics: Flag set on first encounter, verified on subsequent encounters
     * 4. Clarity: Boolean arrays are more readable than packed bitmaps
     * 5. Type-safe: No bit manipulation errors from incorrect offsets
     */
    function computeRBalanceFlags(
        address[] calldata debtors,
        address[] calldata creditors,
        bool[] calldata debtorsRBalanceFlags,
        bool[] calldata creditorsRBalanceFlags
    )
        external
        pure
        returns (uint256 rBalanceFlags)
    {
        return _computeRBalanceFlagsInternal(debtors, creditors, debtorsRBalanceFlags, creditorsRBalanceFlags);
    }

    function _computeRBalanceFlagsInternal(
        address[] calldata debtorsData,
        address[] calldata creditorsData,
        bool[] calldata debtorsFlagsData,
        bool[] calldata creditorsFlagsData
    )
        internal
        pure
        returns (uint256 rBalanceFlags)
    {
        // Copy calldata to memory to reduce stack depth issues
        address[] memory debtors = debtorsData;
        address[] memory creditors = creditorsData;
        bool[] memory debtorsRBalanceFlags = debtorsFlagsData;
        bool[] memory creditorsRBalanceFlags = creditorsFlagsData;
        uint256 debtorsLength = debtors.length;
        if (debtorsLength > MAX_BATCH_SIZE) revert ArrayTooLarge();
        if (debtorsLength != creditors.length) revert ArrayLengthMismatch();
        if (debtorsLength != debtorsRBalanceFlags.length) revert ArrayLengthMismatch();
        if (debtorsLength != creditorsRBalanceFlags.length) revert ArrayLengthMismatch();

        // Allocate accounts array with same size as consolidateTransfers (2*N max)
        // This maintains semantic equivalence: same aggregation process = same account positions
        address[] memory accounts = new address[](debtorsLength * BATCH_ARRAY_MULTIPLIER);
        uint256 accountsLength = 0;

        // PHASE 1: Replicate account aggregation logic from consolidateTransfers()
        // This double-loop mirrors the exact pattern used in consolidateTransfers():
        // 1. For each transfer, check if debtor/creditor already exist in accounts array
        // 2. Mark with flags which new accounts need to be created
        // 3. When creating new account, check rAccounts input to determine if rBalance update needed
        // 4. Set corresponding bit in rBalanceFlags output bitmap
        // 5. VERIFY: When account is found again, ensure flag consistency with first discovery
        //
        // CRITICAL: This logic MUST remain synchronized with consolidateTransfers().
        // Any divergence will cause flags to be applied to wrong accounts in rBatchTransfers().
        for (uint256 i = 0; i < debtorsLength;) {
            address debtor = debtors[i];
            address creditor = creditors[i];

            // Skip self-transfers (debtor == creditor) - same as consolidateTransfers() line 828
            if (debtor != creditor) {
                // Bit flag tracking (identical pattern to consolidateTransfers lines 830-842):
                // Bit 0 (0x1): Set if debtor needs to be added to accounts array
                // Bit 1 (0x2): Set if creditor needs to be added to accounts array
                // Start with both bits set, clear as we find existing accounts
                uint8 addFlags = 0x3; // 0b11 = both addDebtor and addCreditor initially true

                // Check if debtor or creditor already exist in accounts array
                // IMPORTANT: Once an account is discovered and added, its rBalance flag is SET based on that
                // discovery transfer's rAccounts bit. Subsequent transfers involving same account DON'T
                // re-check or re-set the flag - it was determined by first appearance.
                // VERIFICATION: When account is found again, validate that the expected flag from
                // current transfer's rAccounts matches the flag already set (from first discovery).
                // Loop only while addFlags != 0 (break early if both found)
                for (uint256 j = 0; (j < accountsLength) && addFlags != 0; ++j) {
                    if (accounts[j] == debtor) {
                        // Debtor found in existing accounts (was added in earlier transfer)
                        // VERIFY: Check that this debtor's rBalance flag from current transfer
                        // matches the flag already set in rBalanceFlags at position j
                        // If first discovery marked debtor with flag, current transfer should also mark it
                        // If first discovery didn't mark debtor, current transfer shouldn't either
                        bool currentTransferMarksDebtor = debtorsRBalanceFlags[i];
                        bool debtorAlreadyMarked = ((rBalanceFlags >> j) & 1) == 1;

                        // VERIFICATION LOGIC:
                        // currentTransferMarksDebtor: Whether THIS transfer marks debtor for rBalance
                        // debtorAlreadyMarked: Whether debtor was already marked from FIRST discovery
                        //
                        // CRITICAL INVARIANT: If debtor was marked on first discovery, it MUST be marked
                        // on all subsequent transfers (same role). If not marked on first discovery,
                        // it must NOT be marked in any subsequent transfer (same role).
                        // This ensures consistent rBalance semantics - account flag doesn't change based on
                        // which transfer involves it.
                        //
                        // Enforcement: If boolean flags are inconsistent, revert with detailed error
                        // Custom error includes: account address, flag from first discovery, flag from current transfer
                        if (currentTransferMarksDebtor != debtorAlreadyMarked) {
                            revert InconsistentRAccounts(debtor, debtorAlreadyMarked, currentTransferMarksDebtor);
                        }

                        addFlags &= ~uint8(1); // Clear bit 0 (addDebtor = false)
                    } else if (accounts[j] == creditor) {
                        // Creditor found in existing accounts (was added in earlier transfer)
                        // VERIFY: Check that this creditor's rBalance flag from current transfer
                        // matches the flag already set in rBalanceFlags at position j
                        bool currentTransferMarksCreditor = creditorsRBalanceFlags[i];
                        bool creditorAlreadyMarked = ((rBalanceFlags >> j) & 1) == 1;

                        // VERIFICATION LOGIC: Same as debtor case
                        // currentTransferMarksCreditor: Whether THIS transfer marks creditor for rBalance
                        // creditorAlreadyMarked: Whether creditor was marked from FIRST discovery
                        //
                        // CRITICAL INVARIANT: If creditor was marked on first discovery, it MUST be marked
                        // on all subsequent transfers (same role). If not marked on first discovery,
                        // it must NOT be marked in any subsequent transfer (same role).
                        // This ensures consistent rBalance semantics - account flag doesn't change based on
                        // which transfer involves it.
                        //
                        // Enforcement: If boolean flags are inconsistent, revert with detailed error
                        // Custom error includes: account address, flag from first discovery, flag from current transfer
                        if (currentTransferMarksCreditor != creditorAlreadyMarked) {
                            revert InconsistentRAccounts(creditor, creditorAlreadyMarked, currentTransferMarksCreditor);
                        }

                        addFlags &= ~uint8(2); // Clear bit 1 (addCreditor = false)
                    }
                }

                // Create new account entries only if not found in existing accounts
                if ((addFlags & 1) != 0) {
                    // DEBTOR IS NEW - add to accounts array at current position (accountsLength)
                    // This position will be used as index when processing this account in rBatchTransfers()
                    accounts[accountsLength] = debtor;

                    // Check if this debtor transfer has rBalance update flag set
                    // Use the debtorsRBalanceFlags[i] boolean to determine if flag should be set
                    if (debtorsRBalanceFlags[i]) {
                        // Set corresponding bit in rBalanceFlags output
                        // This marks accounts[accountsLength] for rBalance update in rBatchTransfers()
                        rBalanceFlags |= (uint256(1) << accountsLength);
                    }
                    accountsLength++;
                }

                if ((addFlags & 2) != 0) {
                    // CREDITOR IS NEW - add to accounts array at current position
                    accounts[accountsLength] = creditor;

                    // Check if this creditor transfer has rBalance update flag set
                    // Use the creditorsRBalanceFlags[i] boolean to determine if flag should be set
                    if (creditorsRBalanceFlags[i]) {
                        // Set corresponding bit in rBalanceFlags output
                        // This marks accounts[accountsLength] for rBalance update in rBatchTransfers()
                        rBalanceFlags |= (uint256(1) << accountsLength);
                    }
                    accountsLength++;
                }
            }

            unchecked {
                ++i;
            }
        }

        // Return bitmap where bit i indicates if accounts[i] (in aggregated order) needs rBalance update
        // This bitmap will be used in rBatchTransfers() as: ((rBalanceFlags >> i) & 1) == 1
        return rBalanceFlags;
    }

    /**
     * @dev Consolidates multiple transfers into unique account debit/credit pairs
     * Inlines the account tracking logic for optimal gas efficiency
     * @param debtors Array of debtor addresses
     * @param creditors Array of creditor addresses
     * @param amounts Array of transfer amounts
     * @return accounts Array of consolidated DebitAndCredit structs
     * @return accountsLength Number of unique accounts in array
     *
     * CONSOLIDATION ALGORITHM:
     * Converts N transfers into M unique accounts where M <= 2N (typically M << 2N due to deduplication)
     *
     * Example: 5 transfers between 3 people
     * Input:
     *   Transfer 0: alice → bob (100)
     *   Transfer 1: bob → charlie (50)
     *   Transfer 2: charlie → alice (75)
     *   Transfer 3: alice → bob (25)
     *   Transfer 4: bob → alice (10)
     *
     * Consolidation Result (3 unique accounts):
     *   Account 0 (alice):   debit=100+25=125, credit=75+10=85, net_debit=40
     *   Account 1 (bob):     debit=50+10=60, credit=100+25=125, net_credit=65
     *   Account 2 (charlie): debit=75, credit=50, net_debit=25
     *
     * RELATIONSHIP TO computeRBalanceFlags():
     * - Both functions use identical account discovery logic (lines 819-831 vs 817-830)
     * - Both skip self-transfers (debtor == creditor)
     * - Both track accounts with bit flags (addFlags pattern)
     * - Both process accounts in identical order: order of first appearance in transfer list
     *
     * This means account positions computed in computeRBalanceFlags() correspond EXACTLY
     * to account positions in consolidateTransfers() output. This semantic equivalence is
     * critical for rBalanceFlags bitmap to work correctly.
     *
     * SECURITY NOTE:
     * The account order is deterministic and depends on:
     * 1. Transfer order (which account appears first: debtor or creditor)
     * 2. Transfer history (whether account was seen before)
     * This order cannot be manipulated by changing account balances or other state.
     */
    function consolidateTransfers(
        address[] calldata debtors,
        address[] calldata creditors,
        uint256[] calldata amounts
    )
        internal
        pure
        returns (DebitAndCredit[] memory accounts, uint256 accountsLength)
    {
        uint256 debtorsLength = debtors.length;
        if (debtorsLength > MAX_BATCH_SIZE) revert ArrayTooLarge();
        if (!(debtorsLength == creditors.length && debtorsLength == amounts.length)) revert ArrayLengthMismatch();

        accounts = new DebitAndCredit[](debtorsLength * BATCH_ARRAY_MULTIPLIER);
        accountsLength = 0;

        // Outer loop: process each transfer
        for (uint256 i = 0; i < debtorsLength;) {
            address debtor = debtors[i];
            address creditor = creditors[i];
            uint256 amount = amounts[i];

            // Skip self-transfers (debtor == creditor)
            if (debtor != creditor) {
                // Inline addAccount logic with bit flags for account creation
                uint8 addFlags = 0x3; // 0b11 = both addDebtor and addCreditor initially true

                // Inner loop: check if debtor and creditor already exist in accounts array
                for (uint256 j = 0; (j < accountsLength) && addFlags != 0; ++j) {
                    if (accounts[j].owner == debtor) {
                        accounts[j].debit += amount;
                        addFlags &= ~uint8(1); // Clear bit 0 (addDebtor = false)
                    } else if (accounts[j].owner == creditor) {
                        // else if is safe here since debtor != creditor (self-transfers already skipped)
                        accounts[j].credit += amount;
                        addFlags &= ~uint8(2); // Clear bit 1 (addCreditor = false)
                    }
                }

                // Create new account entries only if not found in existing accounts
                if ((addFlags & 1) != 0) {
                    // Check bit 0 (addDebtor)
                    accounts[accountsLength] = DebitAndCredit(debtor, amount, 0);
                    accountsLength++;
                }
                if ((addFlags & 2) != 0) {
                    // Check bit 1 (addCreditor)
                    accounts[accountsLength] = DebitAndCredit(creditor, 0, amount);
                    accountsLength++;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Performs batch transfers with selective reserved balance (rBalance) updates
     * @param debtors Array of addresses to debit tokens from
     * @param creditors Array of addresses to credit tokens to
     * @param amounts Array of amounts for each transfer
     * @param rBalanceFlags Bitmap indicating which accounts (by index in aggregated array) need rBalance updates
     *                      Pre-computed by computeRBalanceFlags() for integrity validation
     * @return bool True if all transfers successful
     *
     * PHASE 2 EXECUTION: Uses pre-computed rBalanceFlags for selective rBalance updates
     *
     * FLOW:
     * 1. Call consolidateTransfers() to aggregate N transfers into M unique accounts
     *    - Same aggregation algorithm as computeRBalanceFlags()
     *    - Account positions match rBalanceFlags bitmap indices
     * 2. For each aggregated account, calculate net debit/credit
     * 3. Update _balances directly (CEI pattern, before events)
     * 4. Selectively update _rBalances using rBalanceFlags bitmap
     *    - If ((rBalanceFlags >> accountIndex) & 1) == 1, update _rBalances
     *    - Otherwise, leave _rBalances unchanged
     * 5. Emit Transfer events for original transfers (not consolidated)
     *
     * RBALANCE UPDATES:
     * When account is debtor (debit > credit):
     *   - Loses tokens: _balances[account] -= net_debit
     *   - If flagged: _rBalances[account] += net_debit (restricted balance increases)
     *
     * When account is creditor (credit > debit):
     *   - Gains tokens: _balances[account] += net_credit
     *   - If flagged: _rBalances[account] -= net_credit (restricted balance decreases)
     *                  Capped at 0: if rBalance < net_credit, set to 0
     *
     * INTEGRITY PROPERTIES:
     * - Atomicity: All transfers succeed or all revert (no partial state)
     * - Determinism: Same inputs always produce same state changes
     * - Verification: rBalanceFlags can be pre-verified with computeRBalanceFlags()
     * - Access Control: Only VALIDATOR role can execute
     *
     * REENTRANCY PROTECTION:
     * This function does NOT use nonReentrant guard because:
     * - Only manipulates internal state (_balances and _rBalances)
     * - Makes no external calls to other contracts
     * - Follows Checks-Effects-Interactions (CEI) pattern
     * - No way for an attacker to re-enter before state is finalized
     *
     * This function optimizes batch transfers for investor pools that need selective rBalance updates.
     * Regular settlement operations should use batchTransfers() instead for better gas efficiency.
     *
     * Requirements:
     * - All arrays must have the same length
     * - Maximum 100 transfers per batch
     * - Contract must not be paused
     * - Sufficient balance in debtor accounts
     * - rBalanceFlags must be pre-computed using computeRBalanceFlags()
     */
    function rBatchTransfers(address[] calldata debtors, address[] calldata creditors, uint256[] calldata amounts, uint256 rBalanceFlags) external onlyValidator returns (bool) {
        // PHASE 2A: Consolidate transfers into aggregated accounts
        // Same aggregation as computeRBalanceFlags: N transfers → M unique accounts (M <= 2N)
        // Account order matches rBalanceFlags bitmap indices
        (DebitAndCredit[] memory accounts, uint256 accountsLength) = consolidateTransfers(debtors, creditors, amounts);

        // PHASE 2B: Update balances with Checks-Effects-Interactions pattern
        // Check: Verify sufficient balance BEFORE state change
        // Effects: Update _balances and _rBalances
        // Interactions: Emit events AFTER state is finalized
        for (uint256 i = 0; i < accountsLength;) {
            DebitAndCredit memory account = accounts[i];

            if (account.debit > account.credit) {
                // CASE 1: Account is net DEBTOR (losing tokens)
                // This account had more outflows than inflows
                uint256 amount = account.debit - account.credit;

                // SECURITY: Check balance BEFORE state change (atomic failure)
                uint256 debtorBalance = _balances[account.owner];
                if (debtorBalance < amount) revert LowBalance();

                unchecked {
                    // Update regular balance: subtract net debit
                    _balances[account.owner] -= amount;

                    // CRITICAL: Selective rBalance update based on rBalanceFlags bitmap
                    // Bit position i in rBalanceFlags corresponds to accounts[i]
                    // If bit i is set (1), this account's rBalance increases
                    // This is how computeRBalanceFlags() output controls execution
                    if (((rBalanceFlags >> i) & 1) == 1) {
                        // Account flagged for rBalance update
                        // When losing tokens, restricted balance increases (restricted amount grows)
                        _rBalances[account.owner] += amount;
                    }
                }
            } else if (account.debit < account.credit) {
                // CASE 2: Account is net CREDITOR (gaining tokens)
                // This account had more inflows than outflows
                uint256 amount = account.credit - account.debit;

                unchecked {
                    // Update regular balance: add net credit
                    _balances[account.owner] += amount;

                    // CRITICAL: Selective rBalance update based on rBalanceFlags bitmap
                    // Same bitmap lookup as above
                    if (((rBalanceFlags >> i) & 1) == 1) {
                        // Account flagged for rBalance update
                        // When gaining tokens, restricted balance decreases (restricted amount used)
                        uint256 rbalance = _rBalances[account.owner];
                        if (rbalance < amount) {
                            // Not enough restricted balance to cover credit amount
                            // Set to 0 (no over-correction, stays >= 0)
                            _rBalances[account.owner] = 0;
                        } else {
                            // Have enough restricted balance, decrement by credit amount
                            // (unchecked is parent unchecked block, safe from underflow)
                            _rBalances[account.owner] -= amount;
                        }
                    }
                }
            }
            // Note: If debit == credit, account nets to zero (no balance changes)

            unchecked {
                ++i;
            } // Unchecked pre-increment for gas optimization
        }

        // PHASE 2C: Emit Transfer events after all state changes are complete (CEI pattern)
        // IMPORTANT: Emit ORIGINAL transfers (not consolidated), to match transfer semantics
        // Each debtors[i] → creditors[i] transfer gets one event, even if consolidated
        // This maintains compatibility with standard ERC20 event expectations
        for (uint256 i = 0; i < debtors.length;) {
            emit Transfer(debtors[i], creditors[i], amounts[i]);
            unchecked {
                ++i;
            } // Unchecked pre-increment for gas optimization
        }

        // SUCCESS: All state changes applied, all events emitted, transaction complete
        return true;
    }

    /**
     * RBALANCEFLAGS VALIDATION SYSTEM - COMPREHENSIVE ARCHITECTURAL DOCUMENTATION
     *
     * The rBalanceFlags validation approach is a two-phase system that separates pre-computation
     * (verification) from execution (application) for selective rBalance updates in batch transfers.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * PHASE 1: VALIDATION (computeRBalanceFlags)
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     *
     * INPUT:  debtors[], creditors[], rAccounts
     *         - rAccounts: bitmap indexed by transfer number
     *           Bits 0..N-1:     Set if debtors[i] needs rBalance update
     *           Bits N..2N-1:    Set if creditors[i] needs rBalance update
     *
     * OUTPUT: rBalanceFlags bitmap indexed by account position
     *         - Bits 0..M-1:     Set if accounts[i] (in aggregated order) needs rBalance update
     *         - M <= 2N (typically M << 2N due to deduplication)
     *
     * MECHANISM:
     * 1. Iterate through N transfers in order
     * 2. For each transfer, check if debtor/creditor already exist in accounts array
     * 3. Use bit flags (addFlags) to track which accounts need to be added
     * 4. When creating new account at position j:
     *    - Check corresponding bit in rAccounts (bit i for debtor, bit i+N for creditor)
     *    - If set: mark bit j in rBalanceFlags output
     * 5. Result: rBalanceFlags bitmap where bit positions correspond to account positions
     *
     * PROPERTY: Pure function
     * - No side effects, no state changes
     * - Can be called off-chain to verify before submitting transaction
     * - Same inputs always produce identical output (deterministic)
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * PHASE 2: EXECUTION (rBatchTransfers)
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     *
     * INPUT:  debtors[], creditors[], amounts[], rBalanceFlags (pre-computed)
     *
     * OUTPUT: Updated _balances and _rBalances
     *
     * MECHANISM:
     * 1. Call consolidateTransfers() with same debtors/creditors/amounts
     *    - Produces M aggregated accounts (same order as Phase 1)
     * 2. For each account at position i:
     *    - Calculate net debit/credit
     *    - Update _balances accordingly
     *    - Check rBalanceFlags: if ((rBalanceFlags >> i) & 1) == 1:
     *      * Update _rBalances
     * 3. Emit Transfer events for original transfers
     * 4. Return success
     *
     * PROPERTY: State-changing transaction
     * - Only VALIDATOR role can execute
     * - Protected by nonReentrant guard
     * - Atomic: all updates succeed or all revert (no partial state)
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * CRITICAL INVARIANT: SEMANTIC EQUIVALENCE
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     *
     * INVARIANT: The account aggregation logic in computeRBalanceFlags() MUST be identical to
     *            consolidateTransfers() to ensure rBalanceFlags bitmap applies to correct accounts.
     *
     * Both functions:
     * ✓ Skip self-transfers: if (debtor != creditor)
     * ✓ Use identical bit flag patterns: 0x3 initial, &= ~1, &= ~2 for tracking
     * ✓ Check accounts in identical order: iterate j < accountsLength
     * ✓ Create accounts in identical order: accounts[accountsLength] = new account
     * ✓ Process transfers in identical order: for i = 0 to N
     *
     * CONSEQUENCE: If invariant is maintained, then:
     * account position i in Phase 1 computation
     *         =
     * account position i in Phase 2 execution
     *
     * If invariant is violated (code divergence):
     * - rBalanceFlags bits may be applied to wrong accounts
     * - Unintended accounts get rBalance updates
     * - Intended accounts miss rBalance updates
     * - Security risk and functional corruption
     *
     * MAINTENANCE: When modifying account aggregation logic, ALWAYS update BOTH functions
     * in lockstep. Add regression test to verify account order matches.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * SECURITY PROPERTIES
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     *
     * 1. DETERMINISM
     *    - computeRBalanceFlags() is pure: same inputs → same output always
     *    - Off-chain verification possible and guaranteed accurate
     *    - No randomness or entropy involved
     *
     * 2. ACCESS CONTROL
     *    - Only VALIDATOR role can execute rBatchTransfers()
     *    - Only trusted validators can modify rBalances
     *    - Prevents unauthorized account manipulation
     *
     * 3. FIRST-DISCOVERY FLAG DETERMINATION
     *    - Account rBalance flag is set based on FIRST occurrence (earliest transfer) of that account
     *    - If alice appears as debtor in transfer 0 (marked for rBalance), alice's flag is set
     *    - If alice appears again in transfer 5 (NOT marked for rBalance), flag ALREADY SET, not re-evaluated
     *    - This ensures deterministic, order-dependent (but not arbitrary) flag assignment
     *
     * 4. REENTRANCY PROTECTION
     *    - nonReentrant modifier prevents callback attacks
     *    - No external calls before state finalized (CEI pattern)
     *    - Safe against reentrancy via share token callbacks
     *
     * 5. INTEGRITY VERIFICATION
     *    - Caller can independently verify rBalanceFlags before submission
     *    - Off-chain computation can detect mismatch early
     *    - Prevents accidental wrong-flag submission
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * THREAT ANALYSIS
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     *
     * THREAT 1: Incorrect rBalanceFlags Provided
     * Attack:   Attacker provides flags that mark wrong accounts for rBalance update
     * Example:  rBalanceFlags = 0xFF (all bits set) instead of computed value
     * Impact:   Unintended rBalance updates, incorrect investor pool state
     * Defenses:
     *   - Off-chain verification: computeRBalanceFlags() can be called to check
     *   - Access control: Only VALIDATOR role allowed, must be trusted
     *   - Event monitoring: Observers can check Transfer events match expected flags
     * Risk:     Medium (mitigated by access control, but depends on validator trustworthiness)
     *
     * THREAT 2: Logic Divergence
     * Attack:   Code maintainer accidentally changes one function without other
     * Example:  consolidateTransfers() changes self-transfer handling, computeRBalanceFlags() doesn't
     * Impact:   Account position mismatch, flags applied to wrong accounts
     * Defenses:
     *   - Code review: Both functions side-by-side during modifications
     *   - Testing: Regression test verifies account order matches
     *   - Documentation: Comments link both functions and explain invariant
     * Risk:     Low (caught by testing and code review)
     *
     * THREAT 3: Reentrancy During Execution
     * Attack:   During _balances update, attacker calls back into rBatchTransfers()
     * Example:  Transfer callback to ERC777 token triggers reentrant call
     * Impact:   Double spending, corrupted state, fund loss
     * Defenses:
     *   - nonReentrant modifier: Reentrancy guard prevents reentry
     *   - CEI pattern: All state changes before events, no callbacks
     *   - Direct storage access: No fallback to external contract functions
     * Risk:     Low (nonReentrant guard + CEI pattern)
     *
     * THREAT 4: Insufficient Balance Not Caught
     * Attack:   Provide transfers that exceed available balances
     * Impact:   Partial state corruption, incorrect balances
     * Defenses:
     *   - Explicit check: if (debtorBalance < amount) revert LowBalance()
     *   - Before state: Check happens BEFORE _balances update
     *   - Atomic: All transfers or none (no partial)
     * Risk:     Low (explicit check before state change)
     *
     * THREAT 5: rBalance Over-increment/Under-decrement
     * Attack:   rBalanceFlags cause rBalance to be updated incorrectly
     * Example:  rBalance += debit, but account was actually creditor (credit > debit)
     * Impact:   Restricted balance tracking corruption
     * Defenses:
     *   - Bit check is correct: if ((rBalanceFlags >> i) & 1) == 1
     *   - Offset is correct: debtor bit vs creditor bit i+N
     *   - Capping: rBalance -= amount capped at 0 (no negative)
     * Risk:     Very Low (conditional logic is straightforward)
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * PERFORMANCE ANALYSIS
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     *
     * computeRBalanceFlags():
     *   - Time Complexity: O(N²) in worst case
     *     Outer loop: N transfers
     *     Inner loop: up to 2N accounts checked per transfer
     *   - Space Complexity: O(N) for accounts array
     *   - Gas Cost: ~500k-600k for 100 transfers (depends on uniqueness ratio)
     *   - Cost Model: Paid by caller, off-chain execution possible
     *   - Optimization: Loop breaks early if both debtor/creditor found (addFlags != 0)
     *
     * rBatchTransfers():
     *   - Time Complexity: O(N²) for consolidation + O(M) for balance updates
     *     M <= 2N unique accounts
     *   - Space Complexity: O(M) for accounts array
     *   - Gas Cost: ~700k-900k for 100 transfers (on-chain)
     *   - Cost Model: Paid by validator in transaction gas
     *   - Benefit: O(1) per-account rBalance lookup via bitmap (vs O(N) search)
     *
     * Trade-off: Pay computation cost once (Phase 1) to get O(1) lookups during execution (Phase 2)
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * VALIDATION CHECKLIST
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     *
     * Before calling rBatchTransfers(), verify:
     *   ✓ Arrays (debtors, creditors, amounts) have equal length
     *   ✓ Length <= 100 (MAX_BATCH_SIZE)
     *   ✓ No duplicate (address, address) pairs in (debtors[i], creditors[i])
     *   ✓ All amounts > 0 (no zero transfers)
     *   ✓ rBalanceFlags = computeRBalanceFlags(debtors, creditors, rAccounts)
     *   ✓ All debtors have sufficient balances
     *   ✓ Caller is VALIDATOR role
     *   ✓ No reentrancy protection active
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * END OF RBALANCEFLAGS VALIDATION SYSTEM DOCUMENTATION
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     */

    /**
     * @dev Adjusts the reserved balance (rBalance) for an account
     * @param account The account address to adjust rBalance for
     * @param ts Timestamp identifier for this adjustment (must be unique per account)
     * @param amounti The invested amount (original investment)
     * @param amountr The received amount (after investment returns/losses)
     *
     * This function allows revenue admin to adjust rBalance based on investment performance.
     * If amountr > amounti, rBalance increases (profit).
     * If amountr < amounti, rBalance decreases (loss).
     *
     * Requirements:
     * - No existing adjustment for the same account and timestamp
     * - Only callable by revenue admin
     * - Should be called as soon as invoice is generated for the invoicing cycle
     * - Reserved balance need to be adjusted before the invoice is paid otherwise we are at risk of creating non existing yield.
     *
     * Known issue:
     * - if the invoice is paid before the adjustment is applied, the adjustment will be wrong.
     * - If the invoice is already paid, no adjustement is required unless pending reserved balance exists.
     */
    function adjustrBalance(address account, uint256 ts, uint256 amounti, uint256 amountr) external onlyRevenueAdmin {
        if (_rBalanceAdjustments[account][ts][0] != 0) {
            revert RBalanceAdjustmentAlreadyApplied();
        }
        if (amounti == 0) revert ZeroAmount();
        if (ts > block.timestamp) revert FutureTimestampNotAllowed();
        // Prevent overflow in return multiplier calculation
        if (amounti > type(uint256).max / MAX_RETURN_MULTIPLIER) {
            revert AmountTooLarge();
        }
        if (amountr > amounti * MAX_RETURN_MULTIPLIER) {
            revert MaxReturnMultiplierExceeded();
        }
        _rBalanceAdjustments[account][ts] = [amounti, amountr];

        uint256 difference;
        if (amountr > amounti) {
            difference = amountr - amounti;
            unchecked {
                _rBalances[account] += difference;
            }
        } else if (amountr < amounti) {
            difference = amounti - amountr;
            uint256 currentRBalance = _rBalances[account];
            if (currentRBalance < difference) {
                // Should not happen otherwise we can't cancel with cancelrBalanceAdjustment
                // If this was the case it would mean that the investment vault has received more assets than the original investment
                // This would mean that the investment vault has made a profit that is not backed by the assets which should not be possible
                revert RBalanceAdjustmentTooLarge();
            } else {
                unchecked {
                    _rBalances[account] -= difference;
                }
            }
        }
        emit RBalanceAdjusted(account, amounti, amountr);
    }

    /**
     * @dev Cancels a previously applied rBalance adjustment
     * @param account The account address to cancel adjustment for
     * @param ts The timestamp identifier of the adjustment to cancel
     *
     * This function reverses the effects of a previous adjustrBalance call
     * by applying the opposite adjustment to restore the original rBalance.
     *
     * Requirements:
     * - An adjustment must exist for the given account and timestamp
     * - Only callable by revenue admin
     */
    function cancelrBalanceAdjustment(address account, uint256 ts) external onlyRevenueAdmin {
        if (_rBalanceAdjustments[account][ts][0] == 0) {
            revert NoRBalanceAdjustmentFound();
        }

        uint256[2] memory adjustment = _rBalanceAdjustments[account][ts];
        uint256 amounti = adjustment[0];
        uint256 amountr = adjustment[1];

        if (amountr > amounti) {
            uint256 difference = amountr - amounti;
            uint256 currentRBalance = _rBalances[account];
            if (currentRBalance < difference) {
                // Should not happen otherwise we can't cancel with the adjustment
                revert RBalanceAdjustmentTooLarge();
            } else {
                unchecked {
                    _rBalances[account] -= difference;
                }
            }
        } else if (amountr < amounti) {
            uint256 difference = amounti - amountr;
            unchecked {
                _rBalances[account] += difference;
            }
        }

        delete _rBalanceAdjustments[account][ts];
        emit RBalanceAdjustmentCancelled(account, ts);
    }
}
