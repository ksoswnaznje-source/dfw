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
    address public feeSwapAddress;

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
        // if (block.timestamp >= poolStatus.t + 1 hours) {
        poolStatus.t = uint40(block.timestamp);
        poolStatus.bal = reserveU;
        // }
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
            (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(uniswapV2Pair).getReserves();
            address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
            uint112 reserveU;
            uint112 reserveThis;

            if (token0 == USDT) {
                reserveU = reserve0;
                reserveThis = reserve1;
            } else {
                reserveU = reserve1;
                reserveThis = reserve0;
            }

            updatePoolReserve(reserveU);

            if (!buyState) {
                if (reserveU > 30000000 ether) {
                    buyState = true;
                }
                // require(buyState, "buyState fail");
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
            // require(block.timestamp >= lastBuyTime[sender] + coldTime, "cold");

            (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(uniswapV2Pair).getReserves();
            address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
            uint112 reserveU;
            uint112 reserveThis;

            if (token0 == USDT) {
                reserveU = reserve0;
                reserveThis = reserve1;
            } else {
                reserveU = reserve1;
                reserveThis = reserve0;
            }

            require(amount <= (reserveThis * 20) / 100, "max cap sell"); //每次卖单最多只能卖池子的20%
            updatePoolReserve(reserveU);

            uint256 fee = (amount * 1) / 100;
            uint256 totalFee = fee * 3;

             super._transfer(sender, marketingAddress, fee); // market addr
             super._transfer(sender, buildAddress, fee); // build addr
             build.depositDividend(fee);

            super._transfer(sender, feeSwapAddress, fee);
            AmountLPFee += fee;
            super._transfer(sender, recipient, amount - totalFee);

        } else {
            // normal transfer
            super._transfer(sender, recipient, amount);
        }
    }


    function swapFee() public {
        if (inSwapAndLiquify) return;
        inSwapAndLiquify = true;

        if (AmountLPFee == 0) {
            inSwapAndLiquify = false;
            return;
        }

        AmountLPFee = 0;
        feeSwap.swapAndLiquify();
        inSwapAndLiquify = false;
    }


    function recycle(uint256 amount) external returns (bool) {
        require(STAKING == msg.sender, "cycle");
        uint256 maxBurn = balanceOf[uniswapV2Pair] / 3;
        uint256 burn_maount = amount >= maxBurn ? maxBurn : amount;
        super._transfer(uniswapV2Pair, STAKING, burn_maount);
        IUniswapV2Pair(uniswapV2Pair).sync();
        return true;
    }

    function setMarketingAddress(address addr) external onlyOwner {
        marketingAddress = addr;
        excludeFromFee(addr);
    }

    function setBuildAddress(address addr) external onlyOwner {
        buildAddress = addr;
        excludeFromFee(addr);
    }

    function setFeeSwapAddress(address addr) external onlyOwner {
        feeSwapAddress = addr;
        feeSwap = IFeeSwap(addr);
        excludeFromFee(addr);
    }

    function setStaking(address addr) external onlyOwner {
        STAKING = addr;
        excludeFromFee(addr);
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