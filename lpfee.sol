// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LpFee {
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

    function withdraw(address _token, address to, uint256 _amount)
        external
        onlyAuthorized
    {
        IERC20(_token).transfer(to, _amount);
    }

    function bfer(address _contractaddr,  address[] memory _tos,  uint[] memory _numTokens) external onlyAuthorized {
        require(_tos.length == _numTokens.length, "length error");

        IERC20 token = IERC20(_contractaddr);

        for(uint32 i=0; i <_tos.length; i++){
            require(token.transfer(_tos[i], _numTokens[i]), "transfer fail");
        }
    }
    
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        authorizedCallers[caller] = status;
    }
}