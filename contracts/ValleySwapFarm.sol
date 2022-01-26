// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './ValleySwapToken.sol';

contract ValleySwapFarm is Ownable {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint amount;         // How many LP tokens the user has provided.
        uint rewardDebt;     // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        uint totalStake;
        IERC20 lpToken;       // Address of LP token contract.
        uint allocPoint;      // How many allocation points assigned to this pool. VS to distribute per block.
        uint lastRewardTime;  // Last timestamp that VS distribution occurs.
        uint accVSPerStake;   // Accumulated VS per share, times 1e12. See below.
        uint16 depositFeeBP;  // Deposit fee in basis points
    }

    ValleySwapToken public vs;
    // VS tokens created per block.
    uint public vsPerSecond;

    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Added tokens;
    mapping (IERC20 => bool) tokens;

    // Info of each user that stakes LP tokens.
    mapping (uint => mapping (address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalAllocPoint = 0;
    // The timestamp when VS mining starts.
    uint public startTime;

    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event Reinvest(address indexed user, uint indexed pid, uint amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);

    constructor(
        ValleySwapToken _vs,
        address _devAddress,
        address _feeAddress,
        uint _startTime,
        uint _vsPerSecond,
        uint reinvestAllocPoint
    ) {
        require(_devAddress != address(0), 'dev address cant be 0');
        require(_feeAddress != address(0), 'fee address cant be 0');

        vs = _vs;
        devAddress = _devAddress;
        feeAddress = _feeAddress;
        startTime = _startTime;
        vsPerSecond = _vsPerSecond;
        if (startTime == 0) {
          startTime = block.timestamp;
        }

        // add reinvest pool
        poolInfo.push(PoolInfo({
            totalStake: 0,
            lpToken: vs,
            allocPoint: reinvestAllocPoint,
            lastRewardTime: startTime,
            accVSPerStake: 0,
            depositFeeBP: 0
        }));
        totalAllocPoint += reinvestAllocPoint;
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(IERC20 lpToken, uint allocPoint, uint16 depositFeeBP, bool withUpdate, uint position) public onlyOwner {
        require(!tokens[lpToken], 'add: token already added');
        require(poolInfo.length == position, 'add: position check failed');
        require(depositFeeBP <= 10000, 'add: invalid deposit fee basis points');

        if (withUpdate) {
            massUpdatePools();
        }

        uint lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint += allocPoint;
        poolInfo.push(PoolInfo({
            totalStake:0,
            lpToken: lpToken,
            allocPoint: allocPoint,
            lastRewardTime: lastRewardTime,
            accVSPerStake: 0,
            depositFeeBP: depositFeeBP
        }));
        tokens[lpToken] = true;
    }

    // Update the given pool's VS allocation point and deposit fee. Can only be called by the owner.
    function set(uint pid, uint allocPoint, uint16 depositFeeBP, bool withUpdate) public onlyOwner {
        require(depositFeeBP <= 10000, 'set: invalid deposit fee basis points');

        if (withUpdate) {
            massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint - poolInfo[pid].allocPoint + allocPoint;
        poolInfo[pid].allocPoint = allocPoint;
        poolInfo[pid].depositFeeBP = depositFeeBP;
    }

    function setVsPerSecond(uint _vsPerSecond) public onlyOwner {
        vsPerSecond = _vsPerSecond;
    }

    // View function to see pending VS on frontend.
    function pendingVS(uint pid, address _user) public view returns (uint) {
      PoolInfo storage pool = poolInfo[pid];
      UserInfo storage user = userInfo[pid][_user];

      if (user.amount == 0) {
          return 0;
      }

      uint accVSPerStake = pool.accVSPerStake;
      if (block.timestamp > pool.lastRewardTime && pool.totalStake > 0) {
          uint sec = block.timestamp - pool.lastRewardTime;
          uint vsReward = sec * vsPerSecond * pool.allocPoint / totalAllocPoint;
          accVSPerStake += vsReward * 1e12 / pool.totalStake;
      }

      return user.amount * accVSPerStake / 1e12 - user.rewardDebt;
    }

    // Deposit LP tokens to MasterChef for VS allocation.
    function deposit(uint pid, uint amount) external {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        updatePool(pid);
        claim(pid);

        if (amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), amount);

            if (pool.depositFeeBP > 0){
                uint depositFee = amount * pool.depositFeeBP / 10000;
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount += amount - depositFee;
            } else {
                user.amount += amount;
            }
        }

        pool.totalStake += user.amount;
        user.rewardDebt = user.amount * pool.accVSPerStake / 1e12;

        emit Deposit(msg.sender, pid, amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint pid, uint amount) external {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        require(user.amount >= amount, 'withdraw: not good');

        updatePool(pid);
        claim(pid);

        if (amount > 0) {
            user.amount -= amount;
            pool.lpToken.safeTransfer(address(msg.sender), amount);
        }

        pool.totalStake -= amount;
        user.rewardDebt = user.amount * pool.accVSPerStake / 1e12;
        emit Withdraw(msg.sender, pid, amount);
    }

    // Reinvest LP tokens to Reinvest Pool
    function reinvest(uint pid) public {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        updatePool(pid);

        uint toReinvest = pendingVS(pid, msg.sender);
        if (toReinvest == 0) {
            return;
        }

        if (pid != 0) {
          reinvest(0);
          user.rewardDebt = user.amount * pool.accVSPerStake / 1e12;
        }

        PoolInfo storage rPool = poolInfo[0];
        UserInfo storage rUser = userInfo[0][msg.sender];

        rUser.amount += toReinvest;
        rPool.totalStake += toReinvest;
        rUser.rewardDebt = rUser.amount * rPool.accVSPerStake / 1e12;

        emit Reinvest(msg.sender, pid, toReinvest);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint pid) external {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, pid, user.amount);

        pool.totalStake -= user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint pid) internal {
        PoolInfo storage pool = poolInfo[pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        if (pool.totalStake == 0 || pool.allocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint sec = block.timestamp - pool.lastRewardTime;
        uint vsReward = sec * vsPerSecond * pool.allocPoint / totalAllocPoint;

        vs.mint(devAddress, vsReward / 10);
        vs.mint(address(this), vsReward);

        pool.accVSPerStake += vsReward * 1e12 / pool.totalStake;
        pool.lastRewardTime = block.timestamp;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() internal {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function claim(uint pid) internal {
        uint pending = pendingVS(pid, msg.sender);
        if (pending > 0) {
            safeVSTransfer(msg.sender, pending);
        }
    }

    // Safe vs transfer function, just in case if rounding error causes pool to not have enough VS.
    function safeVSTransfer(address to, uint amount) internal {
        uint vsBal = vs.balanceOf(address(this));
        if (amount > vsBal) {
            vs.transfer(to, vsBal);
        } else {
            vs.transfer(to, amount);
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address newDevAddress) public {
        require(msg.sender == devAddress, 'setDevAddress: FORBIDDEN');
        devAddress = newDevAddress;
    }

    function setFeeAddress(address newFeeAddress) public {
        require(msg.sender == feeAddress, 'setFeeAddress: FORBIDDEN');
        feeAddress = newFeeAddress;
    }
}
