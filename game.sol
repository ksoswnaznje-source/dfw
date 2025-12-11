// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {_USDT, _ROUTER} from "./Const.sol";

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";

interface VRFCoordinatorV2_5Interface {
    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata req
    ) external returns (uint256 requestId);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}


contract LotteryContract is VRFConsumerBaseV2Plus, ReentrancyGuard {
    // vrf data
    uint256 public lastRequestId;
    uint256 public seedResult;
    uint256 public preseedResult;

    uint256 public startTime;

    address public vrfCoordinator; // 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9
    bytes32 public keyHash = 0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;
    uint256 public subId = 102199748192999433460364503762462184980209636456515381243847376555940529902288;
    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;

    // 常量配置
    uint256 public constant TOTAL_KEYS_PER_ROUND = 800; // 8000 每轮总钥匙数
    uint256 public constant KEY_PRICE = 1e18; // 1 USDT
    uint256 public constant MAX_KEYS_PER_USER = 100; // 单用户上限
    uint256 public constant POOL_SPLIT_AMOUNT = 400e18; // 4000 USDT用于买币
    
    // 奖励配置
    uint256 public constant FIRST_PRIZE_COUNT = 8;
    uint256 public constant SECOND_PRIZE_COUNT = 24;
    uint256 public constant THIRD_PRIZE_COUNT = 300;
    
    // 锁仓时间
    uint256 public constant LOCK_DURATION = 3 * 365 days;
    
    // 代币地址
    address public RICH;

    address public owners;

    IUniswapV2Router02 public constant uniswapV2Router = IUniswapV2Router02(_ROUTER);
    
    // 轮次信息
    uint256 public currentRound;

    struct Round {
        uint256 totalKeysSold;
        uint256 tokenPrice; // 代币价格/数量
        bool drawn; // 是否已开奖
        bool winnersSet; // 是否已设置中奖名单
        mapping(address => uint256) userKeys; // 编号总数
        mapping(address => uint256) userWinCouts; // 中奖总数
        address[] keyHolders;
        mapping(uint256 => address) keyToOwner; // 钥匙编号到所有者的映射
        mapping(uint256 => bool) usedKeys; // 记录已中奖的钥匙编号
        uint256 drawnTime; // 开奖时间
        uint256[] firstPrizeKeys; // 一等奖中奖钥匙编号
        uint256[] secondPrizeKeys; // 二等奖中奖钥匙编号
        uint256[] thirdPrizeKeys; // 三等奖中奖钥匙编号
    }

    mapping(uint256 => mapping(address => uint256[])) public userKeysList; // roundId => user => keyIds
    mapping(uint256 => Round) public rounds;
    
    // 中奖信息
    struct Prize {
        uint16 count; // 获得的数量
        bool claimed; // 是否已领取
        bool discountUsed; // 是否使用了折扣购买
    }
    
    mapping(uint256 => mapping(address => Prize)) public firstPrizes; // round => user => prize
    mapping(uint256 => mapping(address => bool)) public prizesAddrs; // round
    mapping(uint256 => address[]) public prizesAddrsArr; // round

    mapping(uint256 => mapping(address => Prize)) public secondPrizes; // round => user => prize
    mapping(uint256 => mapping(address => Prize)) public thirdPrizes; // round => user => prize
    
    // 锁仓信息
    struct VestingInfo {
        bool setTotal; // 设置总数
        uint256 totalLocked;    // 总锁仓量（例如未中奖票数对应的 Token 数量）
        uint256 claimed;        // 已提取
    }

    // 用户 → 轮次 → 锁仓信息
    mapping(uint256 => mapping(address => VestingInfo)) public userVesting;

    mapping(uint256 => uint256) usdtWinSum; // 领取总USDT
    mapping(uint256 => uint256) tokenWinSum; // 领取总Token

    
    // 事件
    event KeysPurchased(uint256 indexed round, address indexed user, uint256 amount, uint256 keyStart, uint256 keyEnd);
    event LotteryDrawn(uint256 indexed round, uint256 tokenAAmount);
    event PrizeClaimed(uint256 indexed round, address indexed user, uint8 prizeType, uint256 amount);
    event DiscountPurchase(uint256 indexed round, address indexed user, uint256 usdtPaid, uint256 tokenReceived);
    event ClaimedPurchase(uint256 indexed round, address indexed user, uint256 tokenReceived);
    event TokensLocked(uint256 indexed round, address indexed user, uint256 amount);
    event TokensUnlocked(uint256 indexed round, address indexed user, uint256 amount);

    event SeedLog(uint256 RId);
    
    constructor(address _vrfCoordinator, address _rich, address _staking) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        RICH = _rich;
        owners = msg.sender;
        vrfCoordinator = _vrfCoordinator;
        currentRound = 1;

        authorizedCallers[_staking] = true;
        authorizedCallers[msg.sender] = true;

        IERC20(_USDT).approve(address(uniswapV2Router), type(uint256).max);
        IERC20(RICH).approve(address(uniswapV2Router), type(uint256).max);
    }
    
    modifier onlyOwners() {
        require(msg.sender == owners, "Not owner");
        _;
    }

    mapping(address => bool) public authorizedCallers;    
    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender] || msg.sender == owners, "Not authorized");
        _;
    }

    // 购买钥匙
    function buyKeys(uint256 amount) external nonReentrant {
        // require(amount > 0 && amount <= MAX_KEYS_PER_USER, "Invalid amount");
        
        Round storage round = rounds[currentRound];
        require(!round.drawn, "Round already drawn");
        require(round.totalKeysSold + amount <= TOTAL_KEYS_PER_ROUND, "Exceeds round limit");
        // require(round.userKeys[msg.sender] + amount <= MAX_KEYS_PER_USER, "Exceeds user limit");
        
        uint256 cost = amount * KEY_PRICE;
        require(IERC20(_USDT).transferFrom(msg.sender, address(this), cost), "Transfer failed");
        
        // 记录钥匙
        uint256 keyStart = round.totalKeysSold + 1;
        if (round.userKeys[msg.sender] == 0) {
            round.keyHolders.push(msg.sender);
        }
        
        for (uint256 i = 0; i < amount; i++) {
            uint256 keyId = keyStart + i;
            round.keyToOwner[keyId] = msg.sender;
            userKeysList[currentRound][msg.sender].push(keyId); // 记录用户的钥匙编号
        }
        
        round.userKeys[msg.sender] += amount;
        round.totalKeysSold += amount;
        
        emit KeysPurchased(currentRound, msg.sender, amount, keyStart, round.totalKeysSold);
        
        // 如果达到8000把，自动开奖
        if (round.totalKeysSold == TOTAL_KEYS_PER_ROUND) {
            swapAndLiquify(POOL_SPLIT_AMOUNT);
            
            // 1 price
            address[] memory path = new address[](2);
            path[0] = _USDT;
            path[1] = RICH;

            uint256[] memory amounts = uniswapV2Router.getAmountsOut(1e18, path);
            uint256 outToken = amounts[1];
            round.tokenPrice = outToken;

            reqVrfId(); // rand num
        }
    }
    
    function buyKeysk(uint256 amount, address user) external onlyAuthorized {
        require(amount > 0 && amount <= MAX_KEYS_PER_USER, "Invalid amount");
        
        Round storage round = rounds[currentRound];
        require(!round.drawn, "Round already drawn");
        require(round.totalKeysSold + amount <= TOTAL_KEYS_PER_ROUND, "Exceeds round limit");
        require(round.userKeys[user] + amount <= MAX_KEYS_PER_USER, "Exceeds user limit");
        
        // 记录钥匙
        uint256 keyStart = round.totalKeysSold + 1;
        if (round.userKeys[user] == 0) {
            round.keyHolders.push(user);
        }
        
        for (uint256 i = 0; i < amount; i++) {
            uint256 keyId = keyStart + i;
            round.keyToOwner[keyId] = user;
            userKeysList[currentRound][user].push(keyId); // 记录用户的钥匙编号
        }
        
        round.userKeys[user] += amount;
        round.totalKeysSold += amount;
        
        emit KeysPurchased(currentRound, user, amount, keyStart, round.totalKeysSold);
        
        // 如果达到8000把，自动开奖
        if (round.totalKeysSold == TOTAL_KEYS_PER_ROUND) {
            swapAndLiquify(POOL_SPLIT_AMOUNT);
            
            address[] memory path = new address[](2);
            path[0] = _USDT;
            path[1] = RICH;

            uint256[] memory amounts = uniswapV2Router.getAmountsOut(1e18, path);
            uint256 outToken = amounts[1];
            round.tokenPrice = outToken;

            reqVrfId(); // rand num
        }
    }

    function reqVrfId() internal {
        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient.RandomWordsRequest({
        keyHash: keyHash,
        subId: subId,
        requestConfirmations: requestConfirmations,
        callbackGasLimit: callbackGasLimit,
        numWords: numWords,
        extraArgs: VRFV2PlusClient._argsToBytes(
                VRFV2PlusClient.ExtraArgsV1({nativePayment: true}) // use native token
            )
        });

        lastRequestId = VRFCoordinatorV2_5Interface(vrfCoordinator).requestRandomWords(req);
    }
    
    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] calldata randomWords
    ) internal override {
        require(msg.sender == vrfCoordinator, "Only VRFCoordinator can fulfill");
        Round storage round = rounds[currentRound];
        require(!round.drawn, "Already drawn");
        require(round.totalKeysSold == TOTAL_KEYS_PER_ROUND, "Not enough keys sold");

        round.drawn = true;
        round.drawnTime = block.timestamp;

        seedResult = randomWords[0];
        emit SeedLog(currentRound);
    }

    // 开始下一轮
    function nextStart() external nonReentrant {
        Round storage round = rounds[currentRound];
        require(round.winnersSet, "Already winnersSet");

        // uint256 interval = currentRound < 100 ? 12 hours : 8 hours;
        uint256 interval = currentRound < 5 ? 2 minutes : 1 minutes;
        require(block.timestamp >= startTime + interval, "time fail");

        currentRound++;
        startTime = block.timestamp;
    }

    // 链上随机生成中奖名单
    function drawWinners(uint256 roundId) external {
        Round storage round = rounds[roundId];
        require(round.drawn, "Not drawn yet");
        require(!round.winnersSet, "Winners already set");
        require(round.totalKeysSold == TOTAL_KEYS_PER_ROUND, "Not all keys sold");

        require(preseedResult != seedResult, "seeds fail");
        uint256 randomSeed = seedResult;
        preseedResult = seedResult;
        
        // 一等奖抽取
        uint16 winFistCount;
        for (uint256 i = 0; i < FIRST_PRIZE_COUNT; i++) {
            uint256 winningKey = _getUniqueRandomKey(randomSeed, i, round.usedKeys);
            address winner = round.keyToOwner[winningKey];
            round.firstPrizeKeys.push(winningKey);

            winFistCount += 1;
            round.userWinCouts[winner] = winFistCount; // 中奖次数

            if (!prizesAddrs[roundId][winner]) {
                prizesAddrs[roundId][winner] = true; // 中奖地址
                prizesAddrsArr[roundId].push(winner);
            }
            
            
            firstPrizes[roundId][winner] = Prize({
                count: winFistCount,
                claimed: false,
                discountUsed: false
            });
        }
        
        // 二等奖抽取
        uint16 winSecCount;
        for (uint256 i = 0; i < SECOND_PRIZE_COUNT; i++) {
            uint256 winningKey = _getUniqueRandomKey(randomSeed, FIRST_PRIZE_COUNT + i, round.usedKeys);
            address winner = round.keyToOwner[winningKey];
            round.secondPrizeKeys.push(winningKey);

            winSecCount += 1;
            round.userWinCouts[winner] = winSecCount; // 中奖次数

            if (!prizesAddrs[roundId][winner]) {
                prizesAddrs[roundId][winner] = true; // 中奖地址
                prizesAddrsArr[roundId].push(winner);
            }
            
            secondPrizes[roundId][winner] = Prize({
                count: winSecCount,
                claimed: false,
                discountUsed: false
            });
        }
        
        // 三等奖抽取
        uint16 winThirdCount;
        for (uint256 i = 0; i < THIRD_PRIZE_COUNT; i++) {
            uint256 winningKey = _getUniqueRandomKey(randomSeed, FIRST_PRIZE_COUNT + SECOND_PRIZE_COUNT + i, round.usedKeys);
            address winner = round.keyToOwner[winningKey];
            round.thirdPrizeKeys.push(winningKey);

            winThirdCount += 1;
            round.userWinCouts[winner] = winThirdCount; // 中奖次数

            if (!prizesAddrs[roundId][winner]) {
                prizesAddrs[roundId][winner] = true; // 中奖地址
                prizesAddrsArr[roundId].push(winner);
            }
            
            thirdPrizes[roundId][winner] = Prize({
                count: winThirdCount,
                claimed: false,
                discountUsed: false
            });
        }
        
        round.winnersSet = true;
        startTime = block.timestamp;
    }
    
    // 获取唯一随机钥匙编号
    function _getUniqueRandomKey(
        uint256 seed,
        uint256 nonce,
        mapping(uint256 => bool) storage usedKeys
    ) internal returns (uint256) {
        uint256 attempts = 0;
        uint256 maxAttempts = 100;
        
        while (attempts < maxAttempts) {
            uint256 randomKey = (uint256(keccak256(abi.encodePacked(seed, nonce, attempts))) % TOTAL_KEYS_PER_ROUND) + 1;
            
            if (!usedKeys[randomKey]) {
                usedKeys[randomKey] = true;
                return randomKey;
            }
            attempts++;
        }
        
        revert("Failed to find unique key");
    }


    function setAppr() external onlyOwner {
        IERC20(_USDT).approve(address(uniswapV2Router), type(uint256).max);
        IERC20(RICH).approve(address(uniswapV2Router), type(uint256).max);
    }


    function setRich(address addr) external onlyOwner {
        RICH = addr;
    }

    function swapAndLiquify(uint256 tokens) internal {
        // IERC20 usdt = IERC20(_USDT);
        // uint256 half = tokens / 2;
        // uint256 otherHalf = tokens - half;

        uint256 half = tokens;
        uint256 otherHalf = tokens;
        uint256 initialBalance = IERC20(RICH).balanceOf(address(this));
        swapUsdtFroToken(half, address(this));

        uint256 newBalance = IERC20(RICH).balanceOf(address(this)) - initialBalance;
        addLiquidity(newBalance, otherHalf);
    }

    function swapUsdtFroToken(uint256 tokenAmount, address to) internal {
        unchecked {
            address[] memory path = new address[](2);
            path[0] = address(_USDT);
            path[1] = address(RICH);
            // make the swap
            uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp
                );
        }
    }

    function addLiquidity(uint256 tokenAmount, uint256 usdtAmount) internal {
        uniswapV2Router.addLiquidity(
            address(RICH),
            address(_USDT),
            tokenAmount,
            usdtAmount,
            0,
            0,
            address(0xdead),
            block.timestamp
        );
    }


    // 未中奖邻取
    function claimLocked(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];
        require(round.winnersSet, "Winners set");
        require(round.userKeys[msg.sender] > 0, "userKeys 0");

        VestingInfo storage v = userVesting[roundId][msg.sender];
       
        if (v.setTotal == false) {
            v.setTotal = true;

             // 计算未中奖的票数
            uint256 xkey = round.userKeys[msg.sender] - round.userWinCouts[msg.sender];
            UD60x18 priceUD = ud(round.tokenPrice);

            // 总 U 数量
            UD60x18 totalU = ud(xkey * 1e18);
            UD60x18 totalToken = totalU.div(priceUD);
            uint256 tokenAmount = totalToken.unwrap(); // 总token

            require(tokenAmount > 0, "totalToken 0");

            v.totalLocked = tokenAmount;
        }

        uint256 amount;
        uint256 elapsed = block.timestamp - round.drawnTime;

        UD60x18 totalUD = ud(v.totalLocked);      // 18 decimals
        UD60x18 elapsedUD = ud(elapsed);          // seconds as UD60
        UD60x18 durationUD = ud(LOCK_DURATION);   // seconds as UD60

        if (elapsed >= LOCK_DURATION) {
            // 全部可提
            amount = v.totalLocked - v.claimed;
        }else {
            // 已累计释放量
            UD60x18 releasedUD = totalUD.mul(elapsedUD).div(durationUD);
            uint256 released = releasedUD.unwrap();  // 18 decimals

            amount = released - v.claimed;
        }

        require(amount > 0, "Nothing to claim");
        v.claimed += amount;

        require(IERC20(RICH).transfer(msg.sender, amount), "RICH fail");
    }

    // 权益1
    function claimedFs(uint256 roundId) external nonReentrant {
        address[] memory arr = prizesAddrsArr[roundId];

        for (uint256 i = 0; i < arr.length; i++) {
            claimedPurchase(roundId, arr[i]);
        }
    }


    // 中奖权益
    function claimedPurchase(uint256 roundId, address user) internal {
        Prize storage prize1 = firstPrizes[roundId][user];
        Prize storage prize2 = secondPrizes[roundId][user];
        Prize storage prize3 = thirdPrizes[roundId][user];
        
        uint256 tokenAmount;
        uint256 price = rounds[roundId].tokenPrice; // 18 decimals
        UD60x18 priceUD = ud(price);
        uint256 totalUsdt;

        if (prize1.count > 0 && prize1.claimed == false) {
            prize1.claimed = true;
            totalUsdt += (100 * prize1.count);
        }
        
        if (prize2.count > 0 && prize2.claimed == false) {
            prize2.claimed = true;
            totalUsdt += (50 * prize2.count);
        }
        
        if (prize3.count > 0 && prize3.claimed == false) {
            prize3.claimed = true;
            totalUsdt += (5 * prize3.count);
        }
        
        
        // 总 U 数量
        UD60x18 totalU = ud(totalUsdt * 1e18);
        // 3500 U * outToken
        UD60x18 totalReward = totalU.div(priceUD);
        tokenAmount = totalReward.unwrap();
        
        require(tokenAmount > 0, "No prize");
        
        require(IERC20(RICH).transfer(user, tokenAmount), "Transfer failed");
        emit ClaimedPurchase(roundId, user, tokenAmount);
    }
    
    // 折扣购买 2
    function discountPurchase(uint256 roundId) external nonReentrant {
        Prize storage prize1 = firstPrizes[roundId][msg.sender];
        Prize storage prize2 = secondPrizes[roundId][msg.sender];
        Prize storage prize3 = thirdPrizes[roundId][msg.sender];
        
        uint256 usdtAmount;
        uint256 tokenAmount;

        uint256 totalUsdt;

        uint256 price = rounds[roundId].tokenPrice;
        UD60x18 priceUD = ud(price);

        if (prize1.count > 0 && prize1.discountUsed == false) {
            prize1.discountUsed = true;

            usdtAmount += (50 * prize1.count) * 1e18;
            // 100 USD worth of token
            totalUsdt += (100 * prize1.count);
        }
        
        if (prize2.count > 0 && prize2.discountUsed == false) {
            prize2.discountUsed = true;

            usdtAmount += (25 * prize2.count) * 1e18;
            totalUsdt += (50 * prize2.count);
        }
        
        if (prize3.count > 0 && prize3.discountUsed == false) {
            prize3.discountUsed = true;
            
            usdtAmount += (25 * prize3.count) * 1e17;
            totalUsdt += (5 * prize3.count);
        }
        
        UD60x18 totalU = ud(totalUsdt * 1e18);
        UD60x18 totalReward = totalU.div(priceUD);
        tokenAmount = totalReward.unwrap();

        require(usdtAmount > 0, "usdt No prize");

        // totalUsdt, totalToken.
        usdtWinSum[roundId] += usdtAmount;
        tokenWinSum[roundId] += tokenAmount;
        
        require(IERC20(_USDT).transferFrom(msg.sender, address(this), usdtAmount), "Transfer failed");
        require(IERC20(RICH).transfer(msg.sender, tokenAmount), "Transfer failed");
        
        emit DiscountPurchase(roundId, msg.sender, usdtAmount, tokenAmount);
    }

    function withdraw(address _token, address to, uint256 _amount) external onlyOwners {
        IERC20(_token).transfer(to, _amount);
    }


    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        authorizedCallers[caller] = status;
        // emit AuthorizedCallerUpdated(caller, status);
    }

    // 获取用户的所有钥匙编号
    function getUserKeysList(uint256 roundId, address user) external view returns (uint256[] memory) {
        return userKeysList[roundId][user];
    }
    
    // 获取一等奖中奖钥匙编号
    function getFirstPrizeKeys(uint256 roundId) external view returns (uint256[] memory) {
        return rounds[roundId].firstPrizeKeys;
    }
    
    // 获取二等奖中奖钥匙编号
    function getSecondPrizeKeys(uint256 roundId) external view returns (uint256[] memory) {
        return rounds[roundId].secondPrizeKeys;
    }
    
    // 获取三等奖中奖钥匙编号
    function getThirdPrizeKeys(uint256 roundId) external view returns (uint256[] memory) {
        return rounds[roundId].thirdPrizeKeys;
    }
    
    // 查询函数
    function getUserKeys(uint256 roundId, address user) external view returns (uint256) {
        return rounds[roundId].userKeys[user];
    }

    function getUserKeys(address user) external view returns (uint256) {
        return rounds[currentRound].userKeys[user];
    }
    
    function getRoundProgress() external view returns (uint256 sold, uint256 total) {
        return (rounds[currentRound].totalKeysSold, TOTAL_KEYS_PER_ROUND);
    }
    
    function getKeyOwner(uint256 roundId, uint256 keyId) external view returns (address) {
        return rounds[roundId].keyToOwner[keyId];
    }
}