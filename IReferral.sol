// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IReferral{
    
    event BindReferral(address indexed user,address parent);
    
    function getReferral(address _address)external view returns(address);

    function isBindReferral(address _address) external view returns(bool);

    function getReferralCount(address _address) external view returns(uint256);

    function bindReferral(address _referral,address _user) external;

    function getReferrals(address _address,uint256 _num) external view returns(address[] memory);

    function getRootAddress()external view returns(address);

    function addSubTeam(address user, uint256 amount) external returns (bool);

    function subSubTeam(address user, uint256 amount) external returns (bool);

    function getteamTotalInvestValue(address _user) external view returns (uint256);

    function getAncestors(address user) external view returns (address[] memory);

    function getBigAndSmallArea(address user)
        external
        view
        returns (
            uint256 bigAreaPerformance,
            uint256 smallAreaPerformance
        );
}