// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IRICH} from "./Irich.sol";
import {IReferral} from "./IReferral.sol";
import {Owned} from "./Owned.sol";
import {_USDT, _ROUTER} from "./Const.sol";

interface IGame {
    function buyKeysk(uint256 amount, address user) external;
    function getUserKeys(address user) external view returns (uint256);
}

contract Staking is Owned, ReentrancyGuard {
    event Staked(
        address user,
        uint256 amount,
        uint256 index,
        uint256 stakeTime
    );

    event RewardPaid(
        address indexed user,
        uint256 reward,
        uint40 timestamp,
        uint256 index
    );

    struct UnStake {
        uint256 reward;
        uint256 stake_amount;
        uint8 day;
        uint256 bal_this;
        uint256 usdt_this;
        uint256 bal_now;
        uint256 usdt_now;
        uint256 amount_rich;
        uint256 amount_usdt;
        uint256 interset;
        uint256 buyFee;
        uint256 referral_fee;
        uint256 team_fee;
        address[] referrals;
    }

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event ReferralLog(address from, uint256 amount);
    event KeysLog(address from, uint256 amount);
    event FeeLog(uint256 from, uint256 amount);

    uint256[3] rates = [1000000034670200000,1000000069236900000,1000000138062200000];
    // uint256[3] stakeDays = [1 days,15 days,30 days];
    uint256[3] stakeDays = [1 minutes,3 minutes,6 minutes];

    IUniswapV2Router02 constant ROUTER = IUniswapV2Router02(_ROUTER);
    IERC20 constant USDT = IERC20(_USDT);

    IRICH public RICH;

    IReferral public REFERRAL;
    IGame public Game;

    uint256 public maxSlippageBps = 500; // 5%

    address public marketingAddress;
    address public gameAddress;

    uint8 public constant decimals = 18;
    string public constant name = "Computility";
    string public constant symbol = "Computility";

    uint256 public totalSupply;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public userIndex;

    mapping(address => Record[]) public userStakeRecord;

    uint256 public stakingStartTime;
    mapping(uint256 => uint256) public dailyStaked;

    mapping(address => uint40) public lastStakeDay;

    // 授权的调用者（如主质押合约）
    mapping(address => bool) public authorizedCallers;

    mapping(address => uint256) public userBuyFee;  // 每个用户累计 buyFee
    uint256 public totalBuyFee;                     // 全部用户 buyFee 总额

    uint8 immutable maxD = 30;

    RecordTT[] public t_supply;

    struct RecordTT {
        uint40 stakeTime;
        uint160 tamount;
    }

    struct Record {
        uint40 stakeTime;
        uint160 amount;
        bool status;
        uint8 stakeIndex;
    }

    modifier onlyEOA() {
        require(tx.origin == msg.sender, "EOA");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender] || msg.sender == owner, "Not authorized");
        _;
    }

    constructor(address REFERRAL_, address _gameAddr, address _mark) Owned(msg.sender) {
        REFERRAL = IReferral(REFERRAL_);
        gameAddress = _gameAddr;
        Game = IGame(_gameAddr);
        marketingAddress = _mark;

        USDT.approve(address(ROUTER), type(uint256).max);

        stakingStartTime = block.timestamp;
        authorizedCallers[msg.sender] = true;
    }


    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        authorizedCallers[caller] = status;
    }


    function setStartTime(uint256 _time) external onlyOwner {
        require(stakingStartTime == 0, "time fail");
        stakingStartTime = _time;
    }


    function dailyMaxLimit(uint256 dayIndex) public pure returns(uint256) {
        if (dayIndex >= 30) {
            return type(uint256).max;
        }
        return 50000 ether + (dayIndex * 5000 ether);
    }

    function currentDay() public view returns(uint256) {
        if (stakingStartTime == 0) {
            return 0;
        }

        return (block.timestamp - stakingStartTime) / 1 days;
    }

    function checkAndConsumeDailyLimit(uint256 _amount) internal {
        uint256 dayIndex = currentDay();
        uint256 limit = dailyMaxLimit(dayIndex);

        require(dailyStaked[dayIndex] + _amount <= limit, "Daily staking limit reached");

        dailyStaked[dayIndex] += _amount;
    }

    function setGame(address _addr) external onlyOwner {
        gameAddress = _addr;
        Game = IGame(_addr);
    }

    function setRICH(address _token) external onlyOwner {
        RICH = IRICH(_token);
        RICH.approve(address(ROUTER), type(uint256).max);
    }

    function setRef(address _addr) external onlyOwner {
        REFERRAL = IReferral(_addr);
    }


    function setMarketingAddress(address _account) external  onlyOwner{
        marketingAddress = _account;
    }

    function network1In() public view returns (uint256 value) {
        uint256 len = t_supply.length;
        if (len == 0) return 0;
        uint256 one_last_time = block.timestamp - 1 minutes;
        uint256 last_supply = totalSupply;
        //       |
        // t0 t1 | t2 t3 t4 t5
        //       |
        for (uint256 i = len - 1; i >= 0; i--) {
            RecordTT storage stake_tt = t_supply[i];
            if (one_last_time > stake_tt.stakeTime) {
                break;
            } else {
                last_supply = stake_tt.tamount;
            }
            if (i == 0) break;
        }
        return totalSupply - last_supply;
    }

    function maxStakeAmount() public view returns (uint256) {
        uint256 lastIn = network1In();
        uint112 reverseu = RICH.getReserveU();
        uint256 p1 = reverseu / 100;
        if (lastIn > p1) return 0;
        else return Math.min256(p1 - lastIn, 1000 ether);
    }

    function stake(uint160 _amount, uint256 amountOutMin,uint8 _stakeIndex) external onlyEOA {
        // require(_amount <= maxStakeAmount(), "<1000");
        require(_stakeIndex<=2,"<=2");

        uint40 today = uint40(block.timestamp / 1 days);
        // 每天只能质押一次
        // require(lastStakeDay[msg.sender] < today, "Already staked today");
        lastStakeDay[msg.sender] = today;

        // checkAndConsumeDailyLimit(_amount);

        swapAndAddLiquidity(_amount, amountOutMin);
        mint(msg.sender, _amount,_stakeIndex);
    }

    function stakeWithInviter(
        uint160 _amount,
        uint256 amountOutMin,
        uint8 _stakeIndex,
        address parent
    ) external onlyEOA {
        require(_amount <= maxStakeAmount(), "<1000");
        require(_stakeIndex<=2,"<=2");

        uint40 today = uint40(block.timestamp / 1 days);
    
        require(lastStakeDay[msg.sender] < today, "Already staked today");
        lastStakeDay[msg.sender] = today;

        checkAndConsumeDailyLimit(_amount);

        swapAndAddLiquidity(_amount, amountOutMin);
        address user = msg.sender;
        if (!REFERRAL.isBindReferral(user) && REFERRAL.isBindReferral(parent)) {
            REFERRAL.bindReferral(parent, user, 0);
        }
        mint(user, _amount,_stakeIndex);
    }

    function swapAndAddLiquidity(uint160 _amount, uint256 amountOutMin)
        private
    {
        USDT.transferFrom(msg.sender, address(this), _amount);

        address[] memory path = new address[](2);
        path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(RICH);
        uint256 balb = RICH.balanceOf(address(this));

        uint256[] memory quoted = ROUTER.getAmountsOut(_amount / 2, path);
        amountOutMin = (quoted[1] * (10_000 - maxSlippageBps)) / 10_000;

        // ROUTER.swapTokensForExactTokens(
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount / 2,
            amountOutMin,
            path,
            address(this),
            block.timestamp
        );
        uint256 bala = RICH.balanceOf(address(this));
        ROUTER.addLiquidity(
            address(USDT),
            address(RICH),
            _amount / 2,
            bala - balb,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0),
            block.timestamp
        );
    }

    function mint(address sender, uint160 _amount,uint8 _stakeIndex) private {
        require(REFERRAL.isBindReferral(sender),"!!bind");
        RecordTT memory tsy;
        tsy.stakeTime = uint40(block.timestamp);
        tsy.tamount = uint160(totalSupply);
        t_supply.push(tsy);

        Record memory order;
        order.stakeTime = uint40(block.timestamp);
        order.amount = _amount;
        order.status = false;
        order.stakeIndex = _stakeIndex;

        totalSupply += _amount;
        balances[sender] += _amount;
        Record[] storage cord = userStakeRecord[sender];
        uint256 stake_index = cord.length;
        cord.push(order);

        require(REFERRAL.addSubTeam(sender, _amount / 1e18), "add team fail."); // add team amout

        emit Transfer(address(0), sender, _amount);
        emit Staked(sender, _amount, stake_index, stakeDays[_stakeIndex]);
    }

    function balanceOf(address account)
        public
        view
        returns (uint256 balance)
    {
        Record[] storage cord = userStakeRecord[account];
        if (cord.length > 0) {
            for (uint256 i = cord.length - 1; i >= 0; i--) {
                Record storage user_record = cord[i];
                if (user_record.status == false) {
                    balance += caclItem(user_record);
                }
                // else {
                //     continue;
                // }
                if (i == 0) break;
            }
        }
    }


    function caclItem(Record storage user_record)
        private
        view
        returns (uint256 reward)
    {
        UD60x18 stake_amount = ud(user_record.amount);
        uint40 stake_time = user_record.stakeTime;
        uint40 stake_period = (uint40(block.timestamp) - stake_time);
        uint40 maxPeriod = uint40(stakeDays[user_record.stakeIndex]);
        
        stake_period = Math.min(stake_period, maxPeriod);

        if (stake_period == 0) reward = UD60x18.unwrap(stake_amount);
        else
            reward = UD60x18.unwrap(
                stake_amount.mul(ud(rates[user_record.stakeIndex]).powu(stake_period))
            );
    }

    function rewardOfSlot(address user, uint8 index)
        public
        view
        returns (uint256 reward)
    {
        Record storage user_record = userStakeRecord[user][index];
        return caclItem(user_record);
    }

    function stakeCount(address user) external view returns (uint256 count) {
        count = userStakeRecord[user].length;
    }


    function unstake(uint256 index) external onlyEOA returns (uint256) {
        UnStake memory v;
        (v.reward, v.stake_amount, v.day) = burn(index);

        v.bal_this = RICH.balanceOf(address(this));
        v.usdt_this = USDT.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = address(RICH);
        path[1] = address(USDT);

        ROUTER.swapTokensForExactTokens(
            v.reward,
            v.bal_this,
            path,
            address(this),
            block.timestamp
        );

        v.bal_now = RICH.balanceOf(address(this));
        v.usdt_now = USDT.balanceOf(address(this));

        v.amount_rich = v.bal_this - v.bal_now;
        v.amount_usdt = v.usdt_now - v.usdt_this;

        if (v.amount_usdt > v.stake_amount) {
            v.interset = v.amount_usdt - v.stake_amount;
        }

        emit FeeLog(v.amount_usdt, v.interset);

        if (v.day == 0) {
            v.buyFee = v.interset * 20 / 100;
        } else if (v.day == 1) {
            v.buyFee = v.interset * 15 / 100;
        } else if (v.day == 2) {
            v.buyFee = v.interset * 10 / 100;
        }

        userBuyFee[msg.sender] += v.buyFee;
        totalBuyFee += v.buyFee;
        emit KeysLog(msg.sender, v.buyFee);

        v.referral_fee = referralReward(msg.sender, v.interset);

        v.referrals = REFERRAL.getAncestors(msg.sender);

        require(REFERRAL.subSubTeam(msg.sender, v.stake_amount / 1e18), "subSubTeam fail");

        v.team_fee = teamReward(v.referrals, v.interset);

        USDT.transfer(
            msg.sender,
            v.amount_usdt - v.referral_fee - v.team_fee - v.buyFee
        );

        require(RICH.recycle(v.amount_rich), "recycle fail");

        return v.reward;
    }

    // 买key
    function buyKeys(uint256 keys) external nonReentrant {
        require(keys > 0, "keys fail");
        uint256 fee = userBuyFee[msg.sender];
        uint256 transferAmount = keys * 1e18;
        require(fee >= transferAmount, "keys fail");
        
        userBuyFee[msg.sender] -= transferAmount;
        require(totalBuyFee >= transferAmount, "Invalid total");
        totalBuyFee -= transferAmount;

        require(USDT.transfer(gameAddress, transferAmount), "usdt fail");

        uint256 keysBefore = Game.getUserKeys(msg.sender);
        Game.buyKeysk(keys, msg.sender);

        uint256 keysAfter = Game.getUserKeys(msg.sender);
        require(keysAfter == keysBefore + keys, "Keys not credited");
    }

    function burn(uint256 index)
        private
        returns (uint256 reward, uint256 amount, uint8 day)
    {
        address sender = msg.sender;
        Record[] storage cord = userStakeRecord[sender];
        Record storage user_record = cord[index];

        uint256 stakeTime = user_record.stakeTime;
        require(block.timestamp - stakeTime >= stakeDays[user_record.stakeIndex], "The time is not right");
        require(user_record.status == false, "alw");

        amount = user_record.amount;
        totalSupply -= amount;
        balances[sender] -= amount;
        emit Transfer(sender, address(0), amount);

        reward = caclItem(user_record);
        user_record.status = true;

        day = user_record.stakeIndex;

        userIndex[sender] = userIndex[sender] + 1;

        emit RewardPaid(sender, reward, uint40(block.timestamp), index);
    }

    function getTeamKpi(address _user) public view returns (uint256) {
        // return teamTotalInvestValue[_user] + teamVirtuallyInvestValue[_user];
        (uint256 bigAreaPerformance, uint256 smallAreaPerformance) = REFERRAL.getBigAndSmallArea(_user);
        return smallAreaPerformance;
    }

    function isPreacher(address user) public view returns (bool) {
        return balances[user] >= 100e18;
    }

    function referralReward(
        address _user,
        uint256 _interset
    ) private returns (uint256 fee) {
        fee = (_interset * 5) / 100;
        address up = REFERRAL.getReferral(_user);
        if (up != address(0) && isPreacher(up)) {
            USDT.transfer(up, fee);
            emit ReferralLog(up, fee);
        }else{
            USDT.transfer(marketingAddress, fee);
            emit ReferralLog(marketingAddress, fee);
        }

    }

    function teamReward(address[] memory referrals, uint256 _interset)
        private
        returns (uint256 fee)
    {
        address top_team;
        uint256 team_kpi;
        uint256 maxTeamRate = 20;
        uint256 spendRate = 0;
        fee = (_interset * maxTeamRate) / 100;

        for (uint256 i = 0; i < referrals.length; i++) {
            top_team = referrals[i];
            team_kpi = getTeamKpi(top_team);

            if (spendRate == 20) {
                break;
            }

            if (
                team_kpi >= 1000000 &&
                    maxTeamRate > spendRate &&
                    isPreacher(top_team)
            ) {
                USDT.transfer(
                    top_team,
                    (_interset * (maxTeamRate - spendRate)) / 100
                );
                spendRate = 20;
            }

            if (
                team_kpi >= 500000 &&
                    team_kpi < 1000000 &&
                    spendRate < 16 &&
                    isPreacher(top_team)
            ) {
                USDT.transfer(top_team, (_interset * (16 - spendRate)) / 100);
                spendRate = 16;
            }

            if (
                team_kpi >= 100000 &&
                    team_kpi < 500000 &&
                    spendRate < 12 &&
                    isPreacher(top_team)
            ) {
                USDT.transfer(top_team, (_interset * (12 - spendRate)) / 100);
                spendRate = 12;
            }

            if (
                team_kpi >= 50000 &&
                    team_kpi < 100000 &&
                    spendRate < 8 &&
                    isPreacher(top_team)
            ) {
                USDT.transfer(top_team, (_interset * (8 - spendRate)) / 100);
                spendRate = 8;
            }

            if (
                team_kpi >= 10000 &&
                    team_kpi < 50000 &&
                    spendRate < 4 &&
                    isPreacher(top_team)
            ) {
                USDT.transfer(top_team, (_interset * (4 - spendRate)) / 100);
                spendRate = 4;
            }
        }
        
        if (maxTeamRate > spendRate) {
            USDT.transfer(marketingAddress, fee - ((_interset * spendRate) / 100));
        }
    }

    function sync() external {
        uint256 w_bal = IERC20(USDT).balanceOf(address(this));
        address pair = RICH.uniswapV2Pair();
        IERC20(USDT).transfer(pair, w_bal - totalBuyFee);
        IUniswapV2Pair(pair).sync();
    }

    function getInfo() external view returns (
        uint256 total,
        uint256 token,
        uint256 tokens,
        uint256 max
    ) {
        address user = msg.sender;
        return (totalSupply, balances[user], balanceOf(user), maxStakeAmount());
    }

    function withdraw(address _token, address to, uint256 _amount)
        external
        onlyOwner
    {
        IERC20(_token).transfer(to, _amount);
    }

    function setUserBuyFee(address user, uint256 amount) external onlyOwner {
        userBuyFee[user] += amount;
    }

}

library Math {
    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint40 a, uint40 b) internal pure returns (uint40) {
        return a < b ? a : b;
    }

    function min256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}