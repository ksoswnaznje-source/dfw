// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IStaking {
    function setTeamVirtuallyInvestValueCall(address _user, uint256 _value) external;
}


contract BuilderNodeSystem is ReentrancyGuard {
    address public owner;
    address public USDT;
    address public RICH;

    IStaking public staking;
    
    // 节点配置
    uint256 public TOKEN_REWARD = 2500e18;         // 送2500代币
    uint256 public constant BONUS_PERFORMANCE = 10000;   // 送1万虚拟业绩

    // 锁仓时间
    uint256 public constant LOCK_DURATION = 180 days;
    
    struct Node {
        bool isActive;
        uint256 lastDividendPoints;  // 上次领取时的累积分红点
        uint256 unclaimedDividends;  // 交易手续费未领取的分红
    }
    
    mapping(address => Node) public nodes;
    address[] public nodeHolders;
    
    uint256 public totalNodes;
    uint256 public dividendPool;

    uint256 public startTime;
    
    // 累积分红点数（每个节点的累积分红）
    uint256 public totalDividendPoints;
    
    // 避免小数运算
    uint256 constant PRECISION = 1e18;
    
    event DividendDeposited(uint256 amount, uint256 perNodeAmount);
    event DividendClaimed(address indexed holder, uint256 amount);

    event NodeLog(address user, uint256 amount, uint256 perNodeAmount);
    
    mapping(address => bool) public authorizedCallers;

    struct Prize {
        uint256 token;     // 获得数量
        uint256 claimed;    // 是否已领取
    }
    mapping(address => Prize[]) public prizes;

    mapping(address => uint256) public UserReward; // 总奖励 
    mapping(address => uint256) public UserClaimed; // 已邻取

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender] || msg.sender == owner, "Not authorized");
        _;
    }
    
    constructor(
        address _staking,
        address _rich
    ) {
        owner = msg.sender;
        staking = IStaking(_staking);
        RICH = _rich;
        authorizedCallers[msg.sender] = true;
    }


    // 管理员节点
    function nodeSys(address user) external onlyOwner {
        if (!nodes[user].isActive) {
            nodes[user].isActive = true;
            nodes[user].lastDividendPoints = totalDividendPoints;
            nodes[user].unclaimedDividends = 0;
            totalNodes++;
        }

        // REWARD
        prizes[user].push(
            Prize({
                token: TOKEN_REWARD,
                claimed: 0
            })
        );

        //总奖劢
        UserReward[user] += TOKEN_REWARD;

        // 赠送虚拟业绩（用于等级计算）
        // staking.setTeamVirtuallyInvestValueCall(user, BONUS_PERFORMANCE);
        emit NodeLog(user, prizes[user].length, TOKEN_REWARD);
    }
    
    
    /**
     * @notice 累积分红模型 / token swap add
     * @param amount 分红金额（已经是 wei 单位，1e18 精度）
     */
    function depositDividend(uint256 amount) external onlyAuthorized {
        require(amount > 0, "Zero amount");
        dividendPool += amount;
        
        // 如果有活跃节点，更新累积分红点数
        if (totalNodes > 0) {
            // 计算每个节点增加的分红点数
            // amount 已经是 1e18 精度，再乘 PRECISION 用于更高精度计算
            uint256 dividendPerNode = (amount * PRECISION) / totalNodes;
            totalDividendPoints += dividendPerNode;
            
            emit DividendDeposited(amount, amount / totalNodes);
        }
    }
    
    /**
     * @notice 计算用户未领取的分红
     * @param holder 持有者地址
     * @return 未领取的分红金额
     */
    function pendingDividends(address holder) public view returns (uint256) {
        Node memory node = nodes[holder];
        if (!node.isActive) {
            return 0;
        }
        
        // 计算自上次领取后累积的分红
        uint256 newDividendPoints = totalDividendPoints - node.lastDividendPoints;
        uint256 pending = (newDividendPoints / PRECISION) + node.unclaimedDividends;
        
        return pending;
    }
    
    /**
     * @notice 领取分红
     */
    function claimDividend() external nonReentrant {
        uint256 amount = pendingDividends(msg.sender);
        require(amount > 0, "No dividends to claim");
        require(dividendPool >= amount, "Insufficient dividend pool");
        
        // 更新状态
        nodes[msg.sender].lastDividendPoints = totalDividendPoints;
        nodes[msg.sender].unclaimedDividends = 0;
        dividendPool -= amount;
        
        // 转账
        require(IERC20(RICH).transfer(msg.sender, amount), "Transfer failed");
        emit DividendClaimed(msg.sender, amount);
    }
    
    function getPrizeCount(address user) external view returns (uint256) {
        return prizes[user].length;
    }

    // 赠送代币 - 释放
    function claimPrize() external nonReentrant {
        address user = msg.sender;        
        require(startTime > 0, "No startTime");
        require(UserClaimed[user] < UserReward[user], "Already claimed all");
        
        uint256 amount;
        uint256 elapsed = block.timestamp - startTime;
        
        if (elapsed >= LOCK_DURATION) {
            amount = UserReward[user] - UserClaimed[user];
        } else {
            UD60x18 reward = ud(UserReward[user]);
            UD60x18 t = ud(elapsed);
            UD60x18 duration = ud(LOCK_DURATION);
            UD60x18 releasedUD = reward.mul(t).div(duration);
            uint256 released = releasedUD.unwrap();

            amount = released - UserClaimed[user];
        }

        require(amount > 0, "No prize");
        UserClaimed[user] += amount;

        require(IERC20(RICH).transfer(user, amount), "RICH fail");
    }

    // 已释放量
    function getClaimPrize(address user) public view returns (uint256) {     
        uint256 rwd = UserReward[user];
        if (rwd == 0 || startTime == 0) {
            return 0;
        }

        uint256 amount;
        uint256 elapsed = block.timestamp - startTime;
        
        if (elapsed >= LOCK_DURATION) {
            amount = UserReward[user] - UserClaimed[user];

        } else {

            UD60x18 reward = ud(UserReward[user]);
            UD60x18 t = ud(elapsed);
            UD60x18 duration = ud(LOCK_DURATION);
            UD60x18 releasedUD = reward.mul(t).div(duration);

            // 转回 uint256（向下取整）
            uint256 released = releasedUD.unwrap();
            amount = released - UserClaimed[user];
        }

        return amount;
    }

    function getInfo() external view returns (
        uint256 reward,
        uint256 claimed,
        uint256 prize,
        uint256 fee
    ) {
        address user = msg.sender;
        return (UserReward[user], UserClaimed[user], getClaimPrize(user), pendingDividends(user));
    }

    function setStartTime(uint256 _time) external onlyOwner {
        require(startTime == 0, "time fail");
        startTime = _time;
    }

    function setRICH(address _token) external onlyOwner {
        RICH = _token;
    }

    function setUSDT(address _token) external onlyOwner {
        USDT = _token;
    }

    function setIStaking(address _addr) external onlyOwner {
        require(_addr != address(0), "Invalid address");
        staking = IStaking(_addr);
    }

    function withdraw(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(owner, amount), "Transfer failed");
    }
    
    /**
     * @notice 转移所有权
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }
    
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        authorizedCallers[caller] = status;
    }
}