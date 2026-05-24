// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ReferralManager
 * @notice Stores wallet-level referrers and claimable referral fees.
 */
contract ReferralManager is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    address public guardian;
    address public manager;
    address public defaultReferrer;
    uint16 public referralShareBps;
    uint16 public copyReferralShareBps;

    mapping(address => address) public referrers;
    mapping(address => uint256) public referrerUserCount;
    mapping(address => uint256) public referralBalances;

    enum FeeType {
        Open,
        Collect,
        CollateralAdd,
        ChangeRange,
        Exit,
        Compound,
        CollateralRemove,
        MovePool
    }

    event GuardianUpdated(address indexed guardian);
    event ManagerUpdated(address indexed manager);
    event DefaultReferrerUpdated(address indexed defaultReferrer);
    event ReferralShareBpsUpdated(uint16 referralShareBps);
    event CopyReferralShareBpsUpdated(uint16 copyReferralShareBps);
    event ReferrerSet(address indexed user, address indexed referrer);
    event ReferrerUserCountUpdated(address indexed referrer, uint256 userCount);
    event ReferralFeeAccrued(
        address indexed referrer,
        address indexed user,
        bytes32 indexed key,
        uint256 grossUSDC,
        uint256 referralFee,
        uint256 netUSDC,
        FeeType feeType
    );
    event ReferralFeesClaimed(address indexed referrer, uint256 amount);

    error ZeroAddress();
    error NotGuardian();
    error NotManager();
    error ZeroAmount();
    error FeeTooHigh();
    error InvalidReferrer();
    error OwnershipRenounceDisabled();

    constructor(address usdc_, address owner_) Ownable(owner_) {
        if (usdc_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        USDC = IERC20(usdc_);
        referralShareBps = 2_000;
        copyReferralShareBps = 5_000;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }

    function setManager(address manager_) external onlyOwner {
        if (manager_ == address(0)) revert ZeroAddress();
        if (manager_ == defaultReferrer) revert InvalidReferrer();
        manager = manager_;
        emit ManagerUpdated(manager_);
    }

    function setDefaultReferrer(address defaultReferrer_) external onlyOwner {
        if (!_validReferrer(address(0), defaultReferrer_)) revert InvalidReferrer();
        defaultReferrer = defaultReferrer_;
        emit DefaultReferrerUpdated(defaultReferrer_);
    }

    function setReferralShareBps(uint16 referralShareBps_) external onlyOwner {
        if (referralShareBps_ > 10_000) revert FeeTooHigh();
        referralShareBps = referralShareBps_;
        emit ReferralShareBpsUpdated(referralShareBps_);
    }

    function setCopyReferralShareBps(uint16 copyReferralShareBps_) external onlyOwner {
        if (copyReferralShareBps_ > 10_000) revert FeeTooHigh();
        copyReferralShareBps = copyReferralShareBps_;
        emit CopyReferralShareBpsUpdated(copyReferralShareBps_);
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenounceDisabled();
    }

    function storeReferrer(address user, address candidate)
        external
        onlyManager
        whenNotPaused
        returns (address referrer)
    {
        referrer = _storeReferrer(user, candidate);
    }

    function storedReferrer(address user) external view returns (address referrer) {
        referrer = referrers[user];
    }

    function creditReferralFee(
        address referrer,
        address user,
        bytes32 key,
        uint256 grossUSDC,
        uint256 referralFee,
        uint256 netUSDC,
        uint8 feeType
    ) external onlyManager whenNotPaused {
        if (referrer == address(0)) revert InvalidReferrer();

        if (referralFee > 0) {
            referralBalances[referrer] += referralFee;
            emit ReferralFeeAccrued(referrer, user, key, grossUSDC, referralFee, netUSDC, FeeType(feeType));
        }
    }

    function claimReferralFees(uint256 amount) external nonReentrant returns (uint256) {
        if (amount == 0) revert ZeroAmount();

        uint256 balance = referralBalances[msg.sender];
        if (amount > balance) revert ZeroAmount();

        referralBalances[msg.sender] = balance - amount;
        USDC.safeTransfer(msg.sender, amount);

        emit ReferralFeesClaimed(msg.sender, amount);
        return amount;
    }

    function _storeReferrer(address user, address candidate) internal returns (address referrer) {
        if (user == address(0)) revert ZeroAddress();

        referrer = referrers[user];
        if (referrer != address(0)) return referrer;

        referrer = _resolveCandidate(user, candidate);
        referrers[user] = referrer;
        referrerUserCount[referrer] += 1;
        emit ReferrerSet(user, referrer);
        emit ReferrerUserCountUpdated(referrer, referrerUserCount[referrer]);
    }

    function _resolveCandidate(address user, address candidate) internal view returns (address referrer) {
        if (_validReferrer(user, candidate)) return candidate;
        referrer = defaultReferrer;
        if (!_validReferrer(user, referrer)) revert InvalidReferrer();
    }

    function _validReferrer(address user, address referrer) internal view returns (bool) {
        if (referrer == address(0)) return false;
        if (user != address(0) && referrer == user) return false;
        if (referrer == address(this) || referrer == manager) return false;
        return true;
    }

}
