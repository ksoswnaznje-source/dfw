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

            // super._transfer(sender, marketingAddress, fee); // market addr
            // super._transfer(sender, buildAddress, fee); // build addr
            // build.depositDividend(fee);

            super._transfer(sender, feeSwapAddress, fee);
            AmountLPFee += fee;
            super._transfer(sender, recipient, amount - totalFee);

            // if (AmountLPFee >= swapAtAmount && !inSwapAndLiquify) {
            //     feeSwap.swapAndLiquify();
            //     AmountLPFee = 0;
            // }

            if (shouldSwapFee()) {
                swapFee();
            }
        
        } else {
            // normal transfer
            super._transfer(sender, recipient, amount);

        }
    }

    function shouldSwapFee() internal view returns (bool) {
        return AmountLPFee >= swapAtAmount && !inSwapAndLiquify;
    }


    function swapFee() internal lockTheSwap {
        if (AmountLPFee > 0) {
            try feeSwap.swapAndLiquify() {
                AmountLPFee = 0;
            } catch Error(string memory reason) {
                // 记录错误原因
                emit SwapFailed(reason);
            } catch {
                // 其他错误
                emit SwapFailed("Unknown error");
            }
        }
    }

    // function swapAndLiquify(uint256 tokens) internal lockTheSwap {
    //     IERC20 usdt = IERC20(USDT);
    //     uint256 half = tokens / 2;
    //     uint256 otherHalf = tokens - half;
    //     uint256 initialBalance = usdt.balanceOf(address(this));
    //     swapTokenForUsdt(half, address(distributor));

    //     // usdt.transferFrom(
    //     //     address(distributor),
    //     //     address(this),
    //     //     usdt.balanceOf(address(distributor))
    //     // );

    //     // uint256 newBalance = usdt.balanceOf(address(this)) - initialBalance;
    //     // addLiquidity(otherHalf, newBalance);
    // }
    
    
    // function swapAndLiquifys() external lockTheSwap {
    //     uint256 tokens = balanceOf[address(this)];
    //     IERC20 usdt = IERC20(USDT);
    //     uint256 half = tokens / 2;
    //     uint256 otherHalf = tokens - half;
    //     uint256 initialBalance = usdt.balanceOf(address(this));
    //     swapTokenForUsdt(half, address(distributor));

    //     usdt.transferFrom(
    //         address(distributor),
    //         address(this),
    //         usdt.balanceOf(address(distributor))
    //     );

    //     uint256 newBalance = usdt.balanceOf(address(this)) - initialBalance;
    //     addLiquidity(otherHalf, newBalance);
    // }


    function addLiquidity(uint256 tokenAmount, uint256 usdtAmount) internal {
        uniswapV2Router.addLiquidity(
            address(this),
            address(USDT),
            tokenAmount,
            usdtAmount,
            0,
            0,
            address(0xdead),
            block.timestamp
        );
    }

    function swapTokenForUsdt(uint256 tokenAmount, address to) internal {
        unchecked {
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = address(USDT);
            // make the swap
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp
                );
        }
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