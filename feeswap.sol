// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {_USDT, _ROUTER} from "./Const.sol";

address constant USDT = _USDT;

contract Distributor {
    bool public inSwapAndLiquify;
    address public owner;
    mapping(address => bool) public authorizedCallers;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender] || msg.sender == owner, "Not authorized");
        _;
    }

    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }


    address public RICH;
    IUniswapV2Router02 constant uniswapV2Router = IUniswapV2Router02(_ROUTER);
    
    constructor(address _token) {
        owner = msg.sender;
        authorizedCallers[msg.sender] = true;

        RICH = _token;
        IERC20(_USDT).approve(address(_ROUTER), type(uint256).max);
        IERC20(_token).approve(address(_ROUTER), type(uint256).max);
    }

    function swapAndLiquify() external lockTheSwap onlyAuthorized {
        IERC20 usdt = IERC20(USDT);
        IERC20 rich = IERC20(RICH);

        uint256 tokens = rich.balanceOf(address(this));

        uint256 half = tokens / 2;

        uint256 otherHalf = tokens - half;
        uint256 initialBalance = usdt.balanceOf(address(this));
        swapTokenForUsdt(half, address(this));

        uint256 newBalance = usdt.balanceOf(address(this)) - initialBalance;
        addLiquidity(otherHalf, newBalance);
    }

    function swapTokenForUsdt(uint256 tokenAmount, address to) internal {
        unchecked {
            address[] memory path = new address[](2);
            path[0] = address(RICH);
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


    
    function addLiquidity(uint256 tokenAmount, uint256 usdtAmount) internal {
        uniswapV2Router.addLiquidity(
            address(RICH),
            address(USDT),
            tokenAmount,
            usdtAmount,
            0,
            0,
            address(0xdead),
            block.timestamp
        );
    }

    function setRICH(address _token) external onlyAuthorized {
        RICH = _token;
        IERC20(RICH).approve(address(_ROUTER), type(uint256).max);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }
    
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        authorizedCallers[caller] = status;
    }
}