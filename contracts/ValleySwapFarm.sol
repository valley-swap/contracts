// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './ValleySwapToken.sol';

contract ValleySwapFarm is Ownable, ReentrancyGuard {
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
        uint accVSPerStake;   // Accumulated VS per share, times 1e18. See below.
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

    event Add(uint indexed pid, IERC20 lpToken, uint allocPoint, uint16 depositFeeBP);
    event Set(uint indexed pid, uint allocPoint, uint16 depositFeeBP);
    event SetVsPerSecond(uint newVsPerSecond);
    event SetDevAddress(address indexed newDevAddress);
    event SetFeeAddress(address indexed newFeeAddress);
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

        emit Add(0, vs, reinvestAllocPoint, 0);
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(IERC20 lpToken, uint allocPoint, uint16 depositFeeBP, bool withUpdate, uint position) external onlyOwner {
        require(!tokens[lpToken], 'add: token already added');
        require(depositFeeBP <= 500, 'add: maximum deposit fee is 500 (5%)');

        // strictly check pool position for in case of mass initial adding
        require(poolInfo.length == position, 'add: position check failed');

        lpToken.balanceOf(address(this));

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

        emit Add(position, lpToken, allocPoint, depositFeeBP);
    }

    // Update the given pool's VS allocation point and deposit fee. Can only be called by the owner.
    function set(uint pid, uint allocPoint, uint16 depositFeeBP, bool withUpdate) external onlyOwner {
        require(depositFeeBP <= 500, 'set: maximum deposit fee is 500 (5%)');

        if (withUpdate) {
            massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint - poolInfo[pid].allocPoint + allocPoint;
        poolInfo[pid].allocPoint = allocPoint;
        poolInfo[pid].depositFeeBP = depositFeeBP;

        emit Set(pid, allocPoint, depositFeeBP);
    }

    function setVsPerSecond(uint newVsPerSecond, bool withUpdate) external onlyOwner {
        require(vsPerSecond <= 5 ether, 'setVsPerSecond: maximum vs per second is 5');

        if (withUpdate) {
            massUpdatePools();
        }

        vsPerSecond = newVsPerSecond;
        emit SetVsPerSecond(newVsPerSecond);
    }

    function setDevAddress(address newDevAddress) external {
        require(msg.sender == devAddress, 'setDevAddress: FORBIDDEN');
        require(newDevAddress != address(0), 'setDevAddress: new dev address cant be 0');
        devAddress = newDevAddress;
        emit SetDevAddress(newDevAddress);
    }

    function setFeeAddress(address newFeeAddress) external {
        require(msg.sender == feeAddress, 'setFeeAddress: FORBIDDEN');
        require(newFeeAddress != address(0), 'setDevAddress: new fee address cant be 0');
        feeAddress = newFeeAddress;
        emit SetFeeAddress(newFeeAddress);
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
          accVSPerStake += vsReward * 1e18 / pool.totalStake;
      }

      return user.amount * accVSPerStake / 1e18 - user.rewardDebt;
    }

    // Deposit LP tokens to MasterChef for VS allocation.
    function deposit(uint pid, uint amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        updatePool(pid);
        claim(pid);

        if (amount > 0) {
            uint balance = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);
            amount = pool.lpToken.balanceOf(address(this)) - balance;

            if (pool.depositFeeBP > 0){
                uint depositFee = amount * pool.depositFeeBP / 10000;
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                amount -= depositFee;
            }
            user.amount += amount;
            pool.totalStake += amount;

            emit Deposit(msg.sender, pid, amount);
        }

        user.rewardDebt = user.amount * pool.accVSPerStake / 1e18;
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint pid, uint amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        require(user.amount >= amount, 'withdraw: not good');

        updatePool(pid);
        claim(pid);

        if (amount > 0) {
            user.amount -= amount;
            pool.lpToken.safeTransfer(msg.sender, amount);
        }

        pool.totalStake -= amount;
        user.rewardDebt = user.amount * pool.accVSPerStake / 1e18;
        emit Withdraw(msg.sender, pid, amount);
    }

    function reinvest(uint pid) public nonReentrant {
        _reinvest(pid);
    }

    // Reinvest LP tokens to Reinvest Pool
    function _reinvest(uint pid) internal {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        updatePool(pid);

        uint toReinvest = pendingVS(pid, msg.sender);
        if (toReinvest == 0) {
            return;
        }

        if (pid != 0) {
          _reinvest(0);
          user.rewardDebt = user.amount * pool.accVSPerStake / 1e18;
        }

        PoolInfo storage rPool = poolInfo[0];
        UserInfo storage rUser = userInfo[0][msg.sender];

        rUser.amount += toReinvest;
        rPool.totalStake += toReinvest;
        rUser.rewardDebt = rUser.amount * rPool.accVSPerStake / 1e18;

        emit Reinvest(msg.sender, pid, toReinvest);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        uint amount = user.amount;
        pool.totalStake -= amount;
        user.amount = 0;
        user.rewardDebt = 0;

        pool.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount);
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

        pool.accVSPerStake += vsReward * 1e18 / pool.totalStake;
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
}
