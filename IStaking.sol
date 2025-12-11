// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IStaking {
    function balances(address) external view returns (uint256);
    function isPreacher(address) external  view returns(bool);
}