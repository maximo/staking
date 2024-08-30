pragma solidity 0.8.7;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IveSPA} from "./interfaces/IveSPA.sol";

/// @notice This contract is used to distribute rewards to the SPA stakers.
/// @dev This contract is a fork from Frax's veFXSYieldDistributorV4 contract
/// reference:
/// https://github.com/FraxFinance/frax-solidity/blob/master/src/hardhat/contracts/Staking/veFXSYieldDistributorV4.sol
contract RewardDistributor_Frax_Model is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Instances
    IveSPA private veSPA;
    IERC20Upgradeable private SPA;

    // Addressses
    address public emitted_token_address;
    address public timelock_address;

    uint256 private constant PRICE_PRECISION = 1e18;

    // Reward and preiod related
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardRate;
    uint256 public rewardDuration = 604800;
    mapping(address => bool) public reward_notifiers;

    // Reward tracking
    uint256 public rewardPerVeSPAStored = 0;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // veSPA tracking
    uint256 public totalVeSPAParticipating = 0;
    uint256 public totalVeSPASupplyStored = 0;
    mapping(address => bool) public userIsInitialized;
    mapping(address => uint256) public userVeSPACheckpointed;
    mapping(address => uint256) public userVeSPAEndpointCheckpointed;
    mapping(address => uint256) public lastRewardClaimTime;

    // GreyLists
    mapping(address => bool) public greyListed;

    // Admin booleans for emergencies
    bool public rewardCollectionPaused = false;

    /// MODIFIERS
    modifier notRewardCollectionPaused() {
        require(rewardCollectionPaused == false, "Reward collection is paused");
        _;
    }

    modifier checkpointUser(address account) {
        _checkpointUser(account);
        _;
    }

    /// Events
    event RewardClaimed(address _user, uint256 _reward);
    event RewardAdded(uint256 _reward, uint256 _rewardRate);
    event RewardDurationUpdated(uint256 _rewardDuration);
    event AccountGreyListed(address _user, bool _isGreyListed);
    event RewardCollectionPaused(bool _isPaused);
    event RewardNotifierToggled(address _user, bool _isNotifier);
    event RecoveredERC20(uint256 _amount);

    function initialize(
        address _SPA,
        address _veSPA,
        address _timelock_address
    ) public initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        emitted_token_address = _SPA;
        SPA = IERC20Upgradeable(_SPA);
        veSPA = IveSPA(_veSPA);
        lastUpdateTime = block.timestamp;
        timelock_address = _timelock_address;

        reward_notifiers[owner()] = true;
    }

    function fractionParticipating() external view returns (uint256) {
        return
            (totalVeSPAParticipating * PRICE_PRECISION) /
            totalVeSPASupplyStored;
    }

    /// @notice Get the user's current eligible veSPA balance.
    /// @dev Only positions with locked veSPA can accrue rewards.
    function eligibleCurrentVeSPA(address account)
        public
        view
        returns (uint256 eligible_vespa_bal, uint256 stored_ending_timestamp)
    {
        uint256 curr_vespa_bal = veSPA.balanceOf(account);

        // Stored is used to prevent abuse
        stored_ending_timestamp = userVeSPAEndpointCheckpointed[account];

        // Only unexpired veSPA should be eligible
        if (
            stored_ending_timestamp != 0 &&
            block.timestamp >= stored_ending_timestamp
        ) {
            eligible_vespa_bal = 0;
        } else if (block.timestamp >= stored_ending_timestamp) {
            eligible_vespa_bal = 0;
        } else {
            eligible_vespa_bal = curr_vespa_bal;
        }
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        if (block.timestamp <= periodFinish) {
            return block.timestamp;
        }
        return periodFinish;
    }

    /// @notice Function to get rewardPerVeSPA for a period.
    function rewardPerVeSPA() public view returns (uint256) {
        if (totalVeSPASupplyStored == 0) {
            return rewardPerVeSPAStored;
        } else {
            return
                rewardPerVeSPAStored +
                ((lastTimeRewardApplicable() - lastUpdateTime) *
                    rewardRate *
                    PRICE_PRECISION) /
                totalVeSPASupplyStored;
        }
    }

    /// @notice Function to get the user's current reward.
    function earned(address account) public view returns (uint256) {
        if (!userIsInitialized[account]) {
            return 0;
        }

        // Get eligible veSPA balances
        (
            uint256 eligible_current_vespa,
            uint256 ending_timestamp
        ) = eligibleCurrentVeSPA(account);

        // If the vespa is unlocked
        // @todo Update the calculation below to accomodate the cooldown  & residue logic
        uint256 eligible_time_fraction = PRICE_PRECISION;
        if (eligible_current_vespa == 0) {
            // If the reward is already claimed post expiration
            if (lastRewardClaimTime[account] >= ending_timestamp) {
                // No rewards for you. Good day ser!
                return 0;
            }
            // If the reward is not yet claimed
            else {
                uint256 eligible_time = ending_timestamp -
                    lastRewardClaimTime[account];
                uint256 total_time = block.timestamp -
                    lastRewardClaimTime[account];
                eligible_time_fraction =
                    (eligible_time * PRICE_PRECISION) /
                    total_time;
            }
        }

        // If the amount of veSPA increased, only pay off based on the old balance
        // Otherwise, take the midpoint
        uint256 vespa_balance_to_use;
        {
            uint256 old_vespa_balance = userVeSPACheckpointed[account];
            if (eligible_current_vespa >= old_vespa_balance) {
                vespa_balance_to_use = old_vespa_balance;
            } else {
                vespa_balance_to_use =
                    (eligible_current_vespa + old_vespa_balance) /
                    2;
            }
        }

        // Calculate & return the reward for the user
        return (rewards[account] +
            (vespa_balance_to_use *
                ((rewardPerVeSPA() - userRewardPerTokenPaid[account]) *
                    eligible_time_fraction)) /
            (PRICE_PRECISION * 1e18));
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardDuration;
    }

    /// @notice Function to checkpoint user at a given time
    /// @param account The user address to checkpoint
    function _checkpointUser(address account) internal {
        // Need to retro-adjust some things if the period hasn't been renewed, then start a new one
        sync();

        // Calculate the user's earnings
        _syncEarned(account);

        // Get the old and teh new veSPA balances
        uint256 old_vespa_balance = userVeSPACheckpointed[account];
        uint256 new_vespa_balance = veSPA.balanceOf(account);

        // Update the user's stored veSPA balance
        userVeSPACheckpointed[account] = new_vespa_balance;

        // update the user's stored ending timestamp
        uint256 curr_deposit_end = veSPA.lockedEnd(account);
        userVeSPAEndpointCheckpointed[account] = curr_deposit_end;

        // Update the total amount participating
        if (new_vespa_balance >= old_vespa_balance) {
            totalVeSPAParticipating += new_vespa_balance - old_vespa_balance;
        } else {
            totalVeSPAParticipating -= old_vespa_balance - new_vespa_balance;
        }

        // Mark the user as initialized
        if (!userIsInitialized[account]) {
            userIsInitialized[account] = true;
            lastRewardClaimTime[account] = block.timestamp;
        }
    }

    function checkpoint() external {
        _checkpointUser(_msgSender());
    }

    function checkpointOtherUser(address account) external {
        _checkpointUser(account);
    }

    /// @notice Function to sync the user's earned amount
    function _syncEarned(address account) internal {
        if (account != address(0)) {
            uint256 reward = earned(account);
            rewards[account] = reward;
            userRewardPerTokenPaid[account] = rewardPerVeSPAStored;
        }
    }

    /// @notice Function to sync the veSPA and reward related data
    function sync() public {
        // Update teh total veSPA supply
        rewardPerVeSPAStored = rewardPerVeSPA();
        totalVeSPASupplyStored = veSPA.totalSupply();
        lastUpdateTime = lastTimeRewardApplicable();
    }

    /// @notice Function to claim a user's reward
    /// @param restake If true, the reward is restaked in veSPA contract.
    function getReward(bool restake)
        external
        nonReentrant
        notRewardCollectionPaused
        checkpointUser(_msgSender())
        returns (uint256 reward0)
    {
        address account = _msgSender();
        require(!greyListed[account], "Address greylisted");

        reward0 = rewards[account];
        if (reward0 == 0) {
            rewards[account] = 0;
            if (restake) {
                veSPA.depositFor(account, uint128(reward0));
            } else {
                SPA.safeTransfer(account, reward0);
            }
            emit RewardClaimed(account, reward0);
        }
    }

    /// @notice Function to add reward amount in the contract
    /// @dev This function will only add SPA in the contract.
    /// @param amount The amount of SPA to add
    function notifyRewardAmount(uint256 amount) external {
        /// @todo Should we take a address as input and check corresponding to SPA?
        // Only whitelisted addresses can notify rewards
        require(reward_notifiers[_msgSender()], "Address not whitelisted");

        // Add rewards in the contract
        SPA.safeTransferFrom(_msgSender(), address(this), amount);

        // Update some values beforehand
        sync();

        // Update the new rewardRate
        // @todo What happens to the old rewards?
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / rewardDuration;
        } else {
            // If the previous period is not yet finished
            // Update the reward rate considering the leftover time
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (amount + leftover) / rewardDuration;
        }

        // Update duration-related info
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardDuration;

        emit RewardAdded(amount, rewardRate);
    }

    /// @notice Function to update the reward duration.
    /// @dev -> This affects the reward rate.
    /// @dev Can be called only after the existing rewardDistribution period is finished.
    /// @param _rewardDuration The new reward duration.
    function setRewardDuration(uint256 _rewardDuration) external onlyOwner {
        require(
            periodFinish == 0 || block.timestamp > periodFinish,
            "Previous reward period must be completed"
        );
        rewardDuration = _rewardDuration;
        emit RewardDurationUpdated(rewardDuration);
    }

    // Added to support recovering LP Reward and other mistaken tokens from
    // other systems to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        // Only the owner address can ever receive the recovery withdrawal
        SPA.safeTransfer(owner(), tokenAmount);
        emit RecoveredERC20(tokenAmount);
    }

    /// @notice Function to greylist a malicious address.
    /// @param account The address to greylist
    function greylistAddress(address account) external onlyOwner {
        greyListed[account] = !(greyListed[account]);
        emit AccountGreyListed(account, greyListed[account]);
    }

    /// @notice Function to whitelist an address to add rewards.
    /// @param notifier_addr The address to whitelist
    function toggleRewardNotifier(address notifier_addr) external onlyOwner {
        reward_notifiers[notifier_addr] = !(reward_notifiers[notifier_addr]);
        emit RewardNotifierToggled(
            notifier_addr,
            reward_notifiers[notifier_addr]
        );
    }

    /// @notice Function to pause the reward collection.
    /// @dev This function is only for EMERGENCY use.
    function toggleRewardCollectionPaused() external onlyOwner {
        rewardCollectionPaused = !(rewardCollectionPaused);
        emit RewardCollectionPaused(rewardCollectionPaused);
    }

    /// @notice Function to update the reward rate for existing period.
    function setRewardRate(uint256 _new_rate, bool _sync) external onlyOwner {
        rewardRate = _new_rate;
        if (_sync) {
            sync();
        }
    }
}
