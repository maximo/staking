pragma solidity 0.8.7;
//@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@//
//@@@@@@@@&    (@@@@@@@@@@@@@    /@@@@@@@@@//
//@@@@@@          /@@@@@@@          /@@@@@@//
//@@@@@            (@@@@@            (@@@@@//
//@@@@@(            @@@@@(           &@@@@@//
//@@@@@@@           &@@@@@@         @@@@@@@//
//@@@@@@@@@@@@@@%    /@@@@@@@@@@@@@@@@@@@@@//
//@@@@@@@@@@@@@@@@@@@   @@@@@@@@@@@@@@@@@@@//
//@@@@@@@@@@@@@@@@@@@@@      (&@@@@@@@@@@@@//
//@@@@@@#         @@@@@@#           @@@@@@@//
//@@@@@/           %@@@@@            %@@@@@//
//@@@@@            #@@@@@            %@@@@@//
//@@@@@@          #@@@@@@@/         #@@@@@@//
//@@@@@@@@@&/ (@@@@@@@@@@@@@@&/ (&@@@@@@@@@//
//@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@//
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IveSPA} from "./interfaces/IveSPA.sol";

contract RewardDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    // @TODO: Replace the EMERGENCY_RETURN with an appropriate one.
    // @dev EMERGENCY_RETURN is set as accounts[0].
    address public EMERGENCY_RETURN =
        0x66aB6D9362d4F35596279692F0251Db635165871;
    uint256 public constant WEEK = 7 days;
    uint256 public constant REWARD_CHECKPOINT_DEADLINE = 1 days;
    uint256 public startTime; // Start time for reward distribution
    uint256 public lastRewardCheckpointTime; // Last time when reward was checkpointed
    address public veSPA;
    address public SPA;
    uint256 public lastRewardBalance; // Last reward balance of the contract

    mapping(uint256 => uint256) public rewardsPerWeek; // Reward distributed per week
    mapping(address => uint256) public timeCursorOf; // Timestamp of last user checkpoint
    mapping(address => uint256) public userEpochOf; // Store the veSPA user epoch
    mapping(uint256 => uint256) public veSPASupply; // Store the veSPA supply per week
    bool public canCheckpointReward; // Checkpoint reward flag
    bool isKilled;

    event Claimed(
        address indexed _recipient,
        uint256 _amount,
        uint256 _claimEpoch,
        uint256 _maxEpoch
    );
    event RewardsCheckpointed(uint256 _ts, uint256 _amount);
    event CheckpointAllowed(bool _allowed);
    event Killed();
    event RecoveredERC20(address _token, uint256 _amount);

    constructor(
        address _SPA,
        address _veSPA,
        uint256 _startTime
    ) public {
        uint256 t = (_startTime / WEEK) * WEEK;
        // All time initialization is rounded to the week
        startTime = t; // Decides the start time for reward distibution
        lastRewardCheckpointTime = t; //reward checkpoint timestamp
        SPA = _SPA;
        veSPA = _veSPA;
    }

    /// @notice Checkpoint reward
    /// @dev Checkpoint rewards for 20 weeks at a time
    function _checkpointReward() internal {
        uint256 tokenBalance = IERC20(SPA).balanceOf(address(this));
        uint256 toDistribute = tokenBalance - lastRewardBalance;
        lastRewardBalance = tokenBalance;

        uint256 t = lastRewardCheckpointTime;
        // Store the period of the last checkpoint
        uint256 sinceLast = block.timestamp - t;
        lastRewardCheckpointTime = block.timestamp;
        uint256 thisWeek = (t / WEEK) * WEEK;
        uint256 nextWeek = 0;

        for (uint256 i = 0; i < 20; i++) {
            nextWeek = thisWeek + WEEK;
            veSPASupply[thisWeek] = IveSPA(veSPA).totalSupply(thisWeek);
            // Calculate share for the ongoing week
            if (block.timestamp < nextWeek) {
                if (sinceLast == 0 && block.timestamp == t) {
                    rewardsPerWeek[thisWeek] += toDistribute;
                } else {
                    // In case of a gap in time of the distribution
                    // Reward is divided across the remainder of the week
                    rewardsPerWeek[thisWeek] +=
                        (toDistribute * (block.timestamp - t)) /
                        sinceLast;
                }
                break;
                // Calculate share for all the past weeks
            } else {
                if (sinceLast == 0 && nextWeek == t) {
                    rewardsPerWeek[thisWeek] += toDistribute;
                } else {
                    rewardsPerWeek[thisWeek] +=
                        (toDistribute * (nextWeek - t)) /
                        sinceLast;
                }
            }
            t = nextWeek;
            thisWeek = nextWeek;
        }

        emit RewardsCheckpointed(block.timestamp, toDistribute);
    }

    /// @notice Update the reward checkpoint
    /// @dev Calculates the total number of tokens to be distributed in a given week.
    ///     During setup for the initial distribution this function is only callable
    ///     by the contract owner. Beyond initial distro, it can be enabled for anyone
    ///     to call.
    function checkpointReward() external {
        require(
            _msgSender() == owner() ||
                (canCheckpointReward &&
                    block.timestamp >
                    (lastRewardCheckpointTime + REWARD_CHECKPOINT_DEADLINE)),
            "Checkpointing not allowed"
        );
        _checkpointReward();
    }

    /// @notice Function to enable / disable checkpointing of tokens
    /// @dev To be called by the owner only
    function toggleAllowCheckpointReward() external onlyOwner {
        canCheckpointReward = !canCheckpointReward;
        emit CheckpointAllowed(canCheckpointReward);
    }

    /// @notice Get the nearest user epoch for a given timestamp
    /// @param addr The address of the user
    /// @param ts The timestamp
    /// @param maxEpoch The maximum possible epoch for the user.
    function _findUserTimestampEpoch(
        address addr,
        uint256 ts,
        uint256 maxEpoch
    ) public view returns (uint256) {
        uint256 min = 0;
        uint256 max = maxEpoch;

        // Binary search
        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) {
                break;
            }
            uint256 mid = (min + max + 1) / 2;
            if (IveSPA(veSPA).getUserPointHistoryTS(addr, mid) <= ts) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    /// @notice Function to get the total rewards for the user.
    /// @param addr The address of the user
    /// @param _lastRewardCheckpointTime The last reward checkpoint
    /// @return UserEpoch, MaxUserEpoch, WeekCursor of User, TotalRewards, updateUserRewardInfo
    function _computeRewards(address addr, uint256 _lastRewardCheckpointTime)
        internal
        view
        returns (
            uint256, // UserEpoch
            uint256, // MaxUserEpoch
            uint256, // WeekCursor
            uint256, // TotalRewards
            bool // updateUserRewardInfo
        )
    {
        uint256 userEpoch = 0;
        uint256 toDistrbute = 0;

        // Get the user's max epoch
        uint256 maxUserEpoch = IveSPA(veSPA).userPointEpoch(addr);
        // Get the user's reward time cursor.
        uint256 weekCursor = timeCursorOf[addr];
        // If maxUserEpoch is 0, the user has not staked
        if (maxUserEpoch == 0) {
            return (userEpoch, maxUserEpoch, weekCursor, toDistrbute, false);
        }

        if (weekCursor == 0) {
            // If cursor is 0, we need to find the starting cursor for user.
            userEpoch = _findUserTimestampEpoch(addr, startTime, maxUserEpoch);
        } else {
            userEpoch = userEpochOf[addr]; //TODO: ???
        }

        if (userEpoch == 0) {
            userEpoch = 1; //TODO: ??
        }
        // Get the user deposit timestamp
        uint256 userPointTs = IveSPA(veSPA).getUserPointHistoryTS(
            addr,
            userEpoch
        );
        // Compute the initial week cursor for the user for claiming the reward.
        if (weekCursor == 0) {
            weekCursor = ((userPointTs + WEEK - 1) / WEEK) * WEEK; //round up to next Thursday
        }
        if (weekCursor > _lastRewardCheckpointTime) {
            return (userEpoch, maxUserEpoch, weekCursor, toDistrbute, false);
        }
        // If the week cursor is less than the reward start time
        // Update it to the reward start time.
        if (weekCursor < startTime) {
            weekCursor = startTime;
        }

        // Iterate over the weeks
        // Can iterate only for 50 weeks at a time //TODO: can at most claim rewards for 50 week
        for (uint256 i = 0; i < 50; i++) {
            // Users can't claim the reward for the ongoing week.
            if (weekCursor >= _lastRewardCheckpointTime) {
                break;
            }

            // Traverse through the user's veSPA checkpoints.
            if (weekCursor >= userPointTs && userEpoch <= maxUserEpoch) {
                userEpoch += 1;
                if (userEpoch > maxUserEpoch) {
                    userPointTs = 0;
                } else {
                    userPointTs = IveSPA(veSPA).getUserPointHistoryTS(
                        addr,
                        userEpoch
                    );
                }
            } else {
                // Get the week's balance for the user
                uint256 balance = IveSPA(veSPA).balanceOf(addr, weekCursor);
                if (balance == 0 && userEpoch > maxUserEpoch) {
                    break;
                }
                if (balance > 0) {
                    // Compute the user's share for the week.
                    toDistrbute +=
                        (balance * rewardsPerWeek[weekCursor]) /
                        veSPASupply[weekCursor];
                }

                weekCursor += WEEK;
            }
        }

        return (userEpoch, maxUserEpoch, weekCursor, toDistrbute, true);
    }

    /// @notice Helper function to get the user earnings at a given timestamp.
    /// @param addr The address of the user
    /// @param _lastRewardCheckpointTime The timestamp of the last checkpointed reward
    function _claim(address addr, uint256 _lastRewardCheckpointTime)
        internal
        returns (uint256)
    {
        (
            uint256 userEpoch,
            uint256 maxUserEpoch,
            uint256 weekCursor,
            uint256 toDistrbute,
            bool updateUserRewardInfo
        ) = _computeRewards(addr, _lastRewardCheckpointTime);
        require(updateUserRewardInfo, "No rewards to claim");
        // Update the user's Epoch data
        if (userEpoch - 1 <= maxUserEpoch) {
            userEpochOf[addr] = userEpoch - 1; //TODO: what are you doing here?
        } else {
            userEpochOf[addr] = maxUserEpoch;
        }
        // update time cursor for the user
        timeCursorOf[addr] = weekCursor;

        emit Claimed(addr, toDistrbute, userEpoch, maxUserEpoch);

        return toDistrbute;
    }

    /// @notice Function to get the user earnings at a given timestamp.
    /// @param addr The address of the user
    /// @dev This function gets only for 50 days worth of rewards.
    /// @return total rewards earned by user, lastRewardCollectionTime, rewardsTill
    /// @dev lastRewardCollectionTime, rewardsTill are in terms of WEEK Cursor.
    function computeRewards(address addr)
        external
        view
        returns (
            uint256, // total rewards earned by user
            uint256, // lastRewardCollectionTime
            uint256 // rewardsTill
        )
    {
        uint256 _lastRewardCheckpointTime = lastRewardCheckpointTime;
        // Compute the rounded last token time
        _lastRewardCheckpointTime = (_lastRewardCheckpointTime / WEEK) * WEEK;
        (, , uint256 rewardsTill, uint256 totalRewards, ) = _computeRewards(
            addr,
            _lastRewardCheckpointTime
        );
        uint256 lastRewardCollectionTime = timeCursorOf[addr];
        if (lastRewardCollectionTime == 0) {
            lastRewardCollectionTime = startTime;
        }
        return (totalRewards, lastRewardCollectionTime, rewardsTill);
    }

    /// @notice Claim fees for the address
    /// @dev Each call to claim look at a maximum of 50 user veCRV points.
    ///      For accounts with many veCRV related actions, this function
    ///      may need to be called more than once to claim all available
    ///      fees. In the `Claimed` event that fires, if `claim_epoch` is
    ///      less than `max_epoch`, the account may claim again.
    /// @param addr The address of the user
    /// @return The amount of tokens claimed
    function claim(address addr, bool restake)
        public
        nonReentrant
        returns (uint256)
    {
        require(!isKilled);

        // Get the last token time
        uint256 _lastRewardCheckpointTime = lastRewardCheckpointTime;
        if (
            canCheckpointReward &&
            (block.timestamp >
                _lastRewardCheckpointTime + REWARD_CHECKPOINT_DEADLINE)
        ) {
            // Checkpoint the rewards till the current week
            _checkpointReward();
            _lastRewardCheckpointTime = block.timestamp;
        }

        // Compute the rounded last token time
        _lastRewardCheckpointTime = (_lastRewardCheckpointTime / WEEK) * WEEK; //TODO: check if it must be last Thursday? If so, is it ensured?

        // Calculate the entitled reward amount for the user
        uint256 amount = _claim(addr, _lastRewardCheckpointTime);
        if (amount > 0) {
            lastRewardBalance -= amount; //TODO: 1. why use lastRewardBalance to track reward balance? 2. is here the only place to update "lastRewardBalance"?
            if (restake) {
                // If restake == True, add the rewards to user's deposit
                IERC20(SPA).approve(veSPA, amount);
                IveSPA(veSPA).depositFor(addr, uint128(amount));
            } else {
                IERC20(SPA).safeTransfer(addr, amount);
            }
        }

        return amount;
    }

    function claim(bool restake) external returns (uint256) {
        return claim(_msgSender(), restake);
    }

    /// @notice Function to add rewards in the contract for distribution
    /// @param value The amount of SPA to add
    /// @dev This function is only for sending in SPA.
    function addRewards(uint256 value) external {
        require(!isKilled);
        require(value > 0, "Reward amount must be > 0");
        IERC20(SPA).safeTransferFrom(_msgSender(), address(this), value);

        if (
            canCheckpointReward &&
            (block.timestamp >
                lastRewardCheckpointTime + REWARD_CHECKPOINT_DEADLINE)
        ) {
            _checkpointReward();
        }
    }

    /*****************************
     *  Emergency Control
     ******************************/

    /// @notice Function to kill the contract.
    /// @dev Killing transfers the entire SPA balance to the emergency return address
    ///      and blocks the ability to claim or addRewards.
    /// @dev The contract can't be unkilled.
    function killMe() external onlyOwner {
        require(!isKilled);
        isKilled = true;
        IERC20(SPA).safeTransfer(
            EMERGENCY_RETURN,
            IERC20(SPA).balanceOf(address(this))
        );
        emit Killed();
    }

    /// @notice Recover ERC20 tokens from this contract
    /// @dev Tokens are sent to the emergency return address
    /// @param _coin token address
    function recoverERC20(address _coin) external onlyOwner {
        // Only the owner address can ever receive the recovery withdrawal
        require(_coin != SPA, "Can't recover SPA tokens");
        uint256 amount = IERC20(_coin).balanceOf(address(this));
        IERC20(_coin).safeTransfer(EMERGENCY_RETURN, amount);
        emit RecoveredERC20(_coin, amount);
    }
}
