// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Owned} from "./Owned.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {ERC20} from "./ERC20.sol";
import {ExcludedFromFeeList} from "./ExcludedFromFeeList.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Helper} from "./Helper.sol";
import {BaseUSDT, USDT} from "./BaseUSDT.sol";
import {IReferral} from "./IReferral.sol";
import {IStaking} from "./IStaking.sol";

interface Ibuild {
    function depositDividend(uint256 amount) external;
}

interface IFeeSwap {
    function swapAndLiquify() external;
}

contract Rich is ExcludedFromFeeList, BaseUSDT, ERC20 {
    bool public presale;
    bool public buyState;

    uint40 public coldTime = 1 minutes;

    uint256 public AmountMarketingFee;
    uint256 public AmountLPFee;

    address public buildAddress;
    address public marketingAddress;
    address public gameAddress;
    address public feeSwapAddress; // swap Fee
    address public lpFeeAddress; // Lp Fee

    uint256 public swapAtAmount = 1 ether;

    mapping(address => bool) public _rewardList;

    mapping(address => uint256) public tOwnedU;
    mapping(address => uint40) public lastBuyTime;
    address public STAKING;
    Ibuild public build;
    IFeeSwap public feeSwap;

    event ree(address account);
    event SwapFailed(string reason);

    struct POOLUStatus {
        uint112 bal; // pool usdt reserve last time update
        uint40 t; // last update time
    }

    POOLUStatus public poolStatus;

    function setPresale() external onlyOwner {
        presale = true;
    }

    function updatePoolReserve(uint112 reserveU) private {
        poolStatus.t = uint40(block.timestamp);
        poolStatus.bal = reserveU;
    }

    function getReserveU() external view returns (uint112) {
        return poolStatus.bal;
    }

    function setColdTime(uint40 _coldTime) external onlyOwner {
        coldTime = _coldTime;
    }

    constructor(
        address _staking,
        address _buildAddr,
        address _marketingAddress,
        address _gameAddr
    ) Owned(msg.sender) ERC20("RICH", "RICH", 18, 21000000 ether) {
        allowance[address(this)][address(uniswapV2Router)] = type(uint256).max;
        IERC20(USDT).approve(address(uniswapV2Router), type(uint256).max);

        presale = true;
        poolStatus.t = uint40(block.timestamp);

        STAKING = _staking;
        marketingAddress = _marketingAddress;
        buildAddress = _buildAddr;
        gameAddress = _gameAddr;

        build = Ibuild(_buildAddr);

        excludeFromFee(msg.sender);
        excludeFromFee(address(this));
        excludeFromFee(_staking);
        excludeFromFee(_marketingAddress);
        excludeFromFee(_buildAddr);
        excludeFromFee(_gameAddr);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        require(isReward(sender) == 0, "isReward != 0 !");

        if (
            !inSwapAndLiquify &&
        sender != uniswapV2Pair &&
        recipient != uniswapV2Pair &&
        AmountLPFee >= swapAtAmount
        ) {
            swapFee();
        }

        uint112 reserveToken;
        uint112 reserveUSDT;

        if (msg.sender == address(uniswapV2Router)) {
            super._transfer(sender, recipient, amount);
            return;
        }

        bool involvePair = (sender == uniswapV2Pair || recipient == uniswapV2Pair);
        if (involvePair) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(uniswapV2Pair).getReserves();
            address token0 = IUniswapV2Pair(uniswapV2Pair).token0();

            if (token0 == address(this)) {
                reserveToken = r0;
                reserveUSDT  = r1;
            } else {
                reserveToken = r1;
                reserveUSDT  = r0;
            }

            updatePoolReserve(reserveUSDT);
        }


        if (
            inSwapAndLiquify ||
            _isExcludedFromFee[sender] ||
            _isExcludedFromFee[recipient]
        ) {
            super._transfer(sender, recipient, amount);
            return;
        }

        // require(
        //     !Helper.isContract(recipient) || uniswapV2Pair == recipient,
        //     "contract"
        // );


        if (uniswapV2Pair == sender) {
            require(presale, "pre");

        unchecked {
            if (!buyState) {
                if (reserveUSDT > 30000000 ether) {
                    buyState = true;
                }
                require(buyState, "buyState fail");
            }

            lastBuyTime[recipient] = uint40(block.timestamp);
            uint256 fee = (amount * 5) / 1000;
            super._transfer(sender, address(0xdead), fee);

            uint256 LPFee = (amount * 25) / 1000;
            AmountLPFee += LPFee;

            super._transfer(sender, feeSwapAddress, LPFee);
            super._transfer(sender, recipient, amount - fee - LPFee);
        }

        } else if (uniswapV2Pair == recipient) {
            require(presale, "pre");
            require(block.timestamp >= lastBuyTime[sender] + coldTime, "cold");
            require(amount <= (reserveToken * 20) / 100, "max cap sell"); //每次卖单最多只能卖池子的20%

            uint256 fee = (amount * 1) / 100;
            uint256 totalFee = fee * 3;

            super._transfer(sender, marketingAddress, fee); // market addr
            super._transfer(sender, buildAddress, fee); // build addr
            build.depositDividend(fee);
            super._transfer(sender, lpFeeAddress, fee); // Lp Fee

            super._transfer(sender, recipient, amount - totalFee);

        } else {
            // normal transfer
            super._transfer(sender, recipient, amount);
        }

    }

    function swapFee() internal lockTheSwap {
        AmountLPFee = 0;
        feeSwap.swapAndLiquify();
    }

    function _isAddLiquidity() private view returns (bool) {
        address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        (uint r0, uint r1,) = IUniswapV2Pair(uniswapV2Pair).getReserves();
        address usdtToken = token0 == address(this) ? IUniswapV2Pair(uniswapV2Pair).token1() : token0;
        uint balUsdt = IERC20(usdtToken).balanceOf(uniswapV2Pair);
        uint rUsdt = token0 == USDT ? r0 : r1;

        return balUsdt > rUsdt;
    }


    function recycle(uint256 amount) external returns (bool) {
        require(STAKING == msg.sender, "cycle");
        uint256 maxBurn = balanceOf[uniswapV2Pair] / 3;
        uint256 burn_maount = amount >= maxBurn ? maxBurn : amount;
        super._transfer(uniswapV2Pair, STAKING, burn_maount);
        IUniswapV2Pair(uniswapV2Pair).sync();
        return true;
    }

    function recycleGame(uint256 amount) external returns (bool) {
        require(gameAddress == msg.sender, "game");
        super._transfer(uniswapV2Pair, gameAddress, amount);
        IUniswapV2Pair(uniswapV2Pair).sync();
        return true;
    }

    function setMarketingAddress(address addr) external onlyOwner {
        marketingAddress = addr;
    }

    function setBuildAddress(address addr) external onlyOwner {
        buildAddress = addr;
        excludeFromFee(addr);
    }

    function setLpFeeAddress(address addr) external onlyOwner {
        lpFeeAddress = addr;
    }

    function setSwapFeeAddress(address addr) external onlyOwner {
        feeSwapAddress = addr;
        feeSwap = IFeeSwap(addr);
        excludeFromFee(addr);
    }

    function setStaking(address addr) external onlyOwner {
        STAKING = addr;
        excludeFromFee(addr);
    }

    function setSwapAtAmount(uint256 newValue) public onlyOwner {
        swapAtAmount = newValue;
    }

    function setGameAddress(address addr) external onlyOwner {
        gameAddress = addr;
        excludeFromFee(addr);
    }

    function multi_bclist(address[] calldata addresses, bool value)
    public
    onlyOwner
    {
        require(addresses.length < 201);
        for (uint256 i; i < addresses.length; ++i) {
            _rewardList[addresses[i]] = value;
        }
    }

    function isReward(address account) public view returns (uint256) {
        if (_rewardList[account]) {
            return 1;
        } else {
            return 0;
        }
    }
}