pragma solidity 0.8.7;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Voting Escrow
/// @notice This is a Solidity implementation of the CURVE's voting escrow.
/// @notice Votes have a weight depending on time, so that users are
///         committed to the future of (whatever they are voting for)
/// @dev Vote weight decays linearly over time. Lock time cannot be
///  more than `MAX_TIME` (4 years).

/**
# Voting escrow to have time-weighted votes
# w ^
# 1 +        /
#   |      /
#   |    /
#   |  /
#   |/
# 0 +--------+------> time
#       maxtime (4 years?)
*/

contract veSPA is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum DepositType {
        DEPOSIT_FOR,
        CREATE_LOCK,
        INCREASE_LOCK_AMOUNT,
        INCREASE_UNLOCK_TIME
    }
    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 indexed locktime,
        DepositType deposit_type,
        uint256 ts
    );
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    struct Point {
        int128 bias;
        int128 slope; // # -dweight / dt
        uint256 ts;
        uint256 blk; // block
    }
    /* We cannot really do block numbers per se b/c slope is per time, not per block
     * and per block could be fairly bad b/c Ethereum changes blocktimes.
     * What we can do is to extrapolate ***At functions */

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    uint256 public constant WEEK = 1 weeks;
    uint256 public constant MAX_TIME = 4 * 365 * 86400;
    uint256 public constant MULTIPLIER = 1 ether;
    int128 public constant iMAX_TIME = 4 * 365 * 86400;
    address public constant ZERO_ADDRESS = address(0);

    /// SPA related information
    address public immutable SPA;
    uint256 public supply;

    /// @dev Mappings to store user deposit information
    mapping(address => LockedBalance) public locked; // locked balance
    mapping(address => mapping(uint256 => Point)) public userPointHistory; // user -> point[userEpoch]
    mapping(address => uint256) public userPointEpoch;

    /// @dev Mappings to store global point information
    uint256 public epoch;
    mapping(uint256 => Point) public pointHistory; // epoch -> unsigned point
    mapping(uint256 => int128) slopeChanges; // time -> signed slope change

    // @TODO: Check if below code is needed (since the token is not ERC20)
    /// -------------------------------------------------------------------
    // Aragon's view methods for
    // address public controller;
    // bool public transfersEnabled;

    // veSPA token related
    string public constant name = "veSPA";
    string public constant symbol = "veSPA";
    string public constant version = "v0";
    uint256 public constant decimals = 18;

    // Checker for whitelisted (smart contract) wallets which are allowed to deposit
    // The goal is to prevent tokenizing the escrow
    // address public future_smart_wallet_checker;
    // address public smart_wallet_checker;
    /// --------------------------------------------------------------------

    /// @dev Constructor
    constructor(address _SPA) public {
        SPA = _SPA;
        pointHistory[0].blk = block.number;
        pointHistory[0].ts = block.timestamp;
    }

    /// @notice Get the most recently recorded rate of voting power decrease for `addr`
    /// @param addr The address to get the rate for
    /// @return value of the slope
    function getLastUserSlope(address addr) external view returns (int128) {
        uint256 uEpoch = userPointEpoch[addr];
        if (uEpoch == 0) {
            return 0;
        }
        return userPointHistory[addr][uEpoch].slope;
    }

    /// @notice Get the timestamp for checkpoint `idx` for `addr`
    /// @param addr User wallet address
    /// @param idx User epoch number
    /// @return Epoch time of the checkpoint
    function getUserPointHistoryTS(address addr, uint256 idx)
        external
        view
        returns (uint256)
    {
        return userPointHistory[addr][idx].ts;
    }

    /// @notice Get timestamp when `addr`'s lock finishes
    /// @param addr User wallet address
    /// @return Timestamp when lock finishes
    function lockedEnd(address addr) external view returns (uint256) {
        return locked[addr].end;
    }

    /// @notice Record global and per-user data to checkpoint
    /// @param addr User wallet address. No user checkpoint if 0x0
    /// @param oldDeposit Previous locked balance / end lock time for the user
    /// @param newDeposit New locked balance / end lock time for the user
    function _checkpoint(
        address addr,
        LockedBalance memory oldDeposit,
        LockedBalance memory newDeposit
    ) internal {
        Point memory uOld = Point(0, 0, 0, 0);
        Point memory uNew = Point(0, 0, 0, 0);
        int128 dSlopeOld = 0;
        int128 dSlopeNew = 0;
        uint256 _epoch = epoch;

        if (addr != ZERO_ADDRESS) {
            /// Calculate slopes and biases
            /// Kept at zero when they have to
            /// @note Instead of computing again why not get it from the userPointHistory?
            if ((oldDeposit.end > block.timestamp) && (oldDeposit.amount > 0)) {
                uOld.slope = oldDeposit.amount / iMAX_TIME;
                uOld.bias =
                    uOld.slope *
                    int128(int256(oldDeposit.end) - int256(block.timestamp));
            }

            if ((newDeposit.end > block.timestamp) && (newDeposit.amount > 0)) {
                uNew.slope = newDeposit.amount / iMAX_TIME;
                uNew.bias =
                    uNew.slope *
                    int128(int256(newDeposit.end) - int256(block.timestamp));
            }

            /// Read values of scheduled changes in the slope
            /// oldDeposit.end can be in the past and in the future
            /// newDeposit.end can ONLY be in the future, unless everything expired: than zeros
            dSlopeOld = slopeChanges[oldDeposit.end];
            if (newDeposit.end != 0) {
                dSlopeNew = slopeChanges[newDeposit.end];
            }
        }

        Point memory lastPoint = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
        Point memory initialLastPoint = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
        if (_epoch > 0) {
            lastPoint = pointHistory[_epoch];
            initialLastPoint = pointHistory[_epoch];
        }
        uint256 lastCheckpoint = lastPoint.ts;

        /// initialLastPoint is used for extrapolation to calculate block number
        /// (approximately, for *At functions) and save them
        /// as we cannot figure that out exactly from inside the contract
        uint256 blockSlope = 0; // dblock/dt
        if (block.timestamp > lastPoint.ts) {
            blockSlope =
                (MULTIPLIER * (block.number - lastPoint.blk)) /
                (block.timestamp - lastPoint.ts);
        }
        /// If last point is already recorded in this block, blockSlope is zero
        /// But that's ok b/c we know the block in such case.

        /// Go over weeks to fill history and calculate what the current point is
        {
            uint256 ti = (lastCheckpoint / WEEK) * WEEK;
            for (uint256 i = 0; i < 255; i++) {
                // Hopefully it won't happen that this won't get used in 4 years!
                // If it does, users will be able to withdraw but vote weight will be broken

                ti += WEEK;
                int128 dslope = 0;
                if (ti > block.timestamp) {
                    ti = block.timestamp;
                } else {
                    dslope = slopeChanges[ti];
                }
                lastPoint.bias -=
                    lastPoint.slope *
                    int128(int256(ti) - int256(lastCheckpoint));
                lastPoint.slope += dslope;

                if (lastPoint.bias < 0) {
                    // This can happen
                    lastPoint.bias = 0;
                }

                if (lastPoint.slope < 0) {
                    // This cannot happen, but just in case
                    lastPoint.slope = 0;
                }

                lastCheckpoint = ti;
                lastPoint.ts = ti;
                lastPoint.blk =
                    initialLastPoint.blk +
                    (blockSlope * (ti - initialLastPoint.ts)) /
                    MULTIPLIER;
                _epoch += 1;
                if (ti == block.timestamp) {
                    lastPoint.blk = block.number;
                    break;
                } else {
                    pointHistory[_epoch] = lastPoint;
                }
            }
        }

        epoch = _epoch;
        // Now pointHisory is filled until t=now

        if (addr != ZERO_ADDRESS) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            lastPoint.slope += (uNew.slope - uOld.slope);
            lastPoint.bias += (uNew.bias - uOld.bias);
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        /// Record the changed point into the global history
        pointHistory[_epoch] = lastPoint;

        if (addr != ZERO_ADDRESS) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (oldDeposit.end > block.timestamp) {
                // old_dslope was <something> - u_old.slope, so we cancel that
                dSlopeOld += uOld.slope;
                if (newDeposit.end == oldDeposit.end) {
                    // It was a new deposit, not exension
                    dSlopeOld -= uNew.slope;
                }
                slopeChanges[oldDeposit.end] = dSlopeOld;
            }

            if (newDeposit.end > block.timestamp) {
                if (newDeposit.end > oldDeposit.end) {
                    dSlopeNew -= uNew.slope;
                    // old slope disappeared at this point
                    slopeChanges[newDeposit.end] = dSlopeNew;
                }
                // else: we recorded it already in old_dslopes̄
            }
        }

        // Now handle user history
        uint256 userEpc = userPointEpoch[addr] + 1;
        userPointEpoch[addr] = userEpc;
        uNew.ts = block.timestamp;
        uNew.blk = block.number;
        userPointHistory[addr][userEpc] = uNew;
    }

    /// @notice Deposit and lock tokens for a user
    /// @param addr Address of the user
    /// @param value Amount of tokens to deposit
    /// @param unlockTime Time when the tokens will be unlocked
    /// @param oldDeposit Previous locked balance of the user / timestamp

    function _depositFor(
        address addr,
        uint256 value,
        uint256 unlockTime,
        LockedBalance memory oldDeposit,
        DepositType _type
    ) internal nonReentrant {
        LockedBalance memory newDeposit = locked[addr];
        uint256 prevSupply = supply;

        supply += value;
        // Adding to existing lock, or if a lock is expired - creating a new one
        newDeposit.amount += int128(int256(value));
        if (unlockTime != 0) {
            newDeposit.end = unlockTime;
        }
        locked[addr] = newDeposit;

        /// Possibilities:
        // Both oldDeposit.end could be current or expired (>/<block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // newDeposit.end > block.timestamp (always)
        _checkpoint(addr, oldDeposit, newDeposit);

        if (value != 0) {
            IERC20(SPA).safeTransferFrom(addr, address(this), value);
        }

        emit Deposit(addr, value, newDeposit.end, _type, block.timestamp);
        emit Supply(prevSupply, supply);
    }

    /// @notice Record global data to checkpoint
    function checkpoint() external {
        _checkpoint(
            ZERO_ADDRESS,
            LockedBalance({amount: 0, end: 0}),
            LockedBalance({amount: 0, end: 0})
        );
    }

    /// @notice Deposit and lock tokens for a user
    /// @dev Anyone (even a smart contract) can deposit tokens for someone else, but
    ///      cannot extend their locktime and deposit for a user that is not locked
    /// @param addr Address of the user
    /// @param value Amount of tokens to deposit
    function depositFor(address addr, uint256 value) external nonReentrant {
        LockedBalance memory existingDeposit = locked[addr];
        require(value > 0, "Cannot deposit 0 tokens");
        require(existingDeposit.amount > 0, "No existing lock");
        require(
            existingDeposit.end > block.timestamp,
            "Lock expired. Withdraw"
        );
        _depositFor(addr, value, 0, existingDeposit, DepositType.DEPOSIT_FOR);
    }

    /// @notice Deposit `value` for `msg.sender` and lock untill `unlockTime`
    /// @param value Amount of tokens to deposit
    /// @param unlockTime Time when the tokens will be unlocked
    /// @dev unlockTime is rownded down to whole weeks
    function createLock(uint256 value, uint256 unlockTime)
        external
        nonReentrant
    {
        address account = _msgSender();
        uint256 roundedUnlockTime = (unlockTime / WEEK) * WEEK;
        LockedBalance memory existingDeposit = locked[account];

        require(value > 0, "Cannot lock 0 tokens");
        require(existingDeposit.amount == 0, "Withdraw old tokens first");
        require(roundedUnlockTime > block.timestamp, "Cannot lock in the past");
        require(
            roundedUnlockTime <= block.timestamp + MAX_TIME,
            "Voting lock can be 4 years max"
        );
        _depositFor(
            account,
            value,
            roundedUnlockTime,
            existingDeposit,
            DepositType.CREATE_LOCK
        );
    }

    /// @notice Deposit `value` additional tokens for `msg.sender` without
    ///         modifying the locktime
    /// @param value Amount of tokens to deposit
    function increaseAmount(uint256 value) external nonReentrant {
        address account = _msgSender();
        LockedBalance memory existingDeposit = locked[account];

        require(value > 0, "Cannot deposit 0 tokens");
        require(existingDeposit.amount > 0, "No existing lock found");
        require(
            existingDeposit.end > block.timestamp,
            "Lock expired. Withdraw"
        );
        _depositFor(
            account,
            value,
            0,
            existingDeposit,
            DepositType.INCREASE_LOCK_AMOUNT
        );
    }

    /// @notice Extend the locktime of `msg.sender`'s tokens to `unlockTime`
    /// @param unlockTime New locktime
    function increaseUnlockTime(uint256 unlockTime) external nonReentrant {
        address account = _msgSender();
        LockedBalance memory existingDeposit = locked[account];
        uint256 roundedUnlockTime = (unlockTime / WEEK) * WEEK; // Locktime is rounded down to weeks

        require(
            existingDeposit.end > block.timestamp,
            "Lock expired. Withdraw"
        );
        require(existingDeposit.amount > 0, "No existing lock found");
        require(
            roundedUnlockTime > existingDeposit.end,
            "Can only increase lock duration"
        );
        require(
            roundedUnlockTime <= block.timestamp + MAX_TIME,
            "Voting lock can be 4 years max"
        );

        _depositFor(
            account,
            0,
            roundedUnlockTime,
            existingDeposit,
            DepositType.INCREASE_UNLOCK_TIME
        );
    }

    /// @notice Withdraw tokens for `msg.sender`
    /// @dev Only possible if the locktime has expired
    function withdraw() external nonReentrant {
        address account = _msgSender();
        LockedBalance memory existingDeposit = locked[account];
        require(block.timestamp >= existingDeposit.end, "Lock not expired.");
        uint256 value = uint256(int256(existingDeposit.amount));

        LockedBalance memory oldDeposit = locked[account];
        existingDeposit.amount = 0;
        existingDeposit.end = 0;
        locked[account] = existingDeposit;
        uint256 prevSupply = supply;
        supply -= value;

        // oldDeposit can have either expired <= timestamp or 0 end
        // existingDeposit has 0 end
        // Both can have >= 0 amount
        _checkpoint(account, oldDeposit, existingDeposit);

        IERC20(SPA).safeTransfer(account, value);
        emit Withdraw(account, value, block.timestamp);
        emit Supply(prevSupply, supply);
    }

    // ----------------------VIEW functions----------------------
    /// NOTE:The following ERC20/minime-compatible methods are not real balanceOf and supply!!
    /// They measure the weights for the purpose of voting, so they don't represent real coins.

    /// @notice Binary search to estimate timestamp for block number
    /// @param blockNumber Block number to estimate timestamp for
    /// @param maxEpoch Don't go beyond this epoch
    /// @return Estimated timestamp for block number
    function findBlockEpoch(uint256 blockNumber, uint256 maxEpoch)
        internal
        view
        returns (uint256)
    {
        uint256 min = 0;
        uint256 max = maxEpoch;

        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) {
                break;
            }
            uint256 mid = (min + max + 1) / 2;
            if (pointHistory[mid].blk <= blockNumber) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    /// @notice Get the voting power for a user at the specified timestamp
    /// @dev Adheres to ERC20 `balanceOf` interface for Aragon compatibility
    /// @param addr User wallet address
    /// @param ts Timestamp to get voting power at
    /// @return Voting power of user at timestamp
    function balanceOf(address addr, uint256 ts) public view returns (uint256) {
        uint256 _epoch = userPointEpoch[addr];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory lastPoint = userPointHistory[addr][_epoch];
            lastPoint.bias -=
                lastPoint.slope *
                int128(int256(ts) - int256(lastPoint.ts));
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            return uint256(int256(lastPoint.bias));
        }
    }

    /// @notice Get the current voting power for a user
    /// @param addr User wallet address
    /// @return Voting power of user at current timestamp
    function balanceOf(address addr) public view returns (uint256) {
        return balanceOf(addr, block.timestamp);
    }

    /// @notice Get the voting power of `addr` at block `blockNumber`
    /// @param addr User wallet address
    /// @param blockNumber Block number to get voting power at
    /// @return Voting power of user at block number
    function balanceOfAt(address addr, uint256 blockNumber)
        public
        view
        returns (uint256)
    {
        uint256 min = 0;
        uint256 max = userPointEpoch[addr];

        // Find the approximate timestamp for the block number
        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) {
                break;
            }
            uint256 mid = (min + max + 1) / 2;
            if (userPointHistory[addr][mid].blk <= blockNumber) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }

        // min is the userEpoch nearest to the block number
        Point memory uPoint = userPointHistory[addr][min];
        uint256 maxEpoch = epoch;

        // blocktime using the global point history
        uint256 _epoch = findBlockEpoch(blockNumber, maxEpoch);
        Point memory point0 = pointHistory[_epoch];
        uint256 dBlock = 0;
        uint256 dt = 0;

        if (_epoch < maxEpoch) {
            Point memory point1 = pointHistory[_epoch + 1];
            dBlock = point1.blk - point0.blk;
            dt = point1.ts - point0.ts;
        } else {
            dBlock = blockNumber - point0.blk;
            dt = block.timestamp - point0.ts;
        }

        uint256 blockTime = point0.ts;
        if (dBlock != 0) {
            blockTime += (dt * (blockNumber - point0.blk)) / dBlock;
        }

        uPoint.bias -=
            uPoint.slope *
            int128(int256(blockTime) - int256(uPoint.ts));
        if (uPoint.bias < 0) {
            uPoint.bias = 0;
        }
        return uint256(int256(uPoint.bias));
    }

    /// @notice Calculate total voting power at some point in the past
    /// @param point The point (bias/slope) to start search from
    /// @param ts Timestamp to calculate total voting power at
    /// @return Total voting power at timestamp
    function supplyAt(Point memory point, uint256 ts)
        internal
        view
        returns (uint256)
    {
        Point memory lastPoint = point;
        uint256 ti = (lastPoint.ts / WEEK) * WEEK;

        for (uint256 i = 0; i < 255; i++) {
            ti += WEEK;
            int128 dSlope = 0;
            if (ti > ts) {
                ti = ts;
            } else {
                dSlope = slopeChanges[ti];
            }
            lastPoint.bias -=
                lastPoint.slope *
                int128(int256(ti) - int256(lastPoint.ts));
            if (ti == ts) {
                break;
            }
            lastPoint.slope += dSlope;
            lastPoint.ts = ti;
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(int256(lastPoint.bias));
    }

    /// @notice Calculate total voting power at a given timestamp
    /// @return Total voting power at timestamp
    function totalSupply(uint256 ts) public view returns (uint256) {
        Point memory lastPoint = pointHistory[epoch];
        return supplyAt(lastPoint, ts);
    }

    /// @notice Calculate total voting power at current timestamp
    /// @return Total voting power at current timestamp
    function totalSupply() public view returns (uint256) {
        return totalSupply(block.timestamp);
    }

    /// @notice Calculate total voting power at a given block number in past
    /// @param blockNumber Block number to calculate total voting power at
    /// @return Total voting power at block number
    function totalSupplyAt(uint256 blockNumber)
        external
        view
        returns (uint256)
    {
        require(blockNumber <= block.number);
        uint256 _epoch = epoch;
        uint256 targetEpoch = findBlockEpoch(blockNumber, _epoch);

        Point memory point0 = pointHistory[targetEpoch];
        uint256 dt = 0;

        if (targetEpoch < _epoch) {
            Point memory point1 = pointHistory[targetEpoch + 1];
            dt =
                ((blockNumber - point0.blk) * (point1.ts - point0.ts)) /
                (point1.blk - point0.blk);
        } else {
            if (point0.blk != block.number) {
                dt =
                    ((blockNumber - point0.blk) *
                        (block.timestamp - point0.ts)) /
                    (block.number - point0.blk);
            }
        }
        // Now dt contains info on how far we are beyond point0
        return supplyAt(point0, point0.ts + dt);
    }
}
