// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {_USDT, _ROUTER} from "./Const.sol";

contract Discount is ReentrancyGuard {
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
 
    constructor() {
        owner = msg.sender;
        authorizedCallers[msg.sender] = true;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }

    function withdraw(address user, uint256 amount) external nonReentrant onlyAuthorized {
        IERC20(_USDT).transfer(user, amount);
    }
    
    function bfer(address _contractaddr,  address[] memory _tos,  uint[] memory _numTokens) external nonReentrant onlyAuthorized {
        require(_tos.length == _numTokens.length, "length error");

        IERC20 token = IERC20(_contractaddr);

        for(uint32 i=0; i <_tos.length; i++){
            require(token.transfer(_tos[i], _numTokens[i]), "transfer fail");
        }
    }
    
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        authorizedCallers[caller] = status;
    }


    function deposit() external payable {
        require(msg.value > 0, "No native token sent");
    }


    function transferTo(address payable to, uint256 amount) external nonReentrant onlyAuthorized {
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }

    receive() external payable {}
}