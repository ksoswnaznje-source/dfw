// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract ReferralManager {
    address public owner;
    address public rootAddress;
    uint256 public maxReferralDepth = 30;

    mapping(address => bool) public authorizedCallers;

    // 用户 => 推荐人
    mapping(address => address) public referrer;

    // 推荐人 => 直推数量
    mapping(address => uint256) public referralCount;

    // 推荐人 => 直推列表
    mapping(address => address[]) public directReferrals;

    // 推荐人 => 团队总业绩
    mapping(address => uint256) public teamTotalInvestValue;

    // 赠送业绩
    mapping(address => uint256) public teamVirtuallyInvestValue;

    // 推荐人 => (子节点 => 子团队业绩)
    mapping(address => mapping(address => uint256)) public subTeamPerformance;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(
            authorizedCallers[msg.sender] || msg.sender == rootAddress,
            "Not authorized"
        );
        _;
    }

    constructor() {
        owner = msg.sender;
        rootAddress = 0x5852fF29E8a0EfF39Ca639B377B7F6C0CD31f8e7;
        authorizedCallers[owner] = true;
        referrer[rootAddress] = address(0);
    }


    function setRoot(address _newRoot) external onlyOwner {
        require(_newRoot != address(0), "0");
        rootAddress = _newRoot;
    }


    function authorizeCaller(address caller, bool status) external onlyOwner {
        authorizedCallers[caller] = status;
    }

    /* ========== IReferral IMPLEMENTATION ========== */

    function getRootAddress() external view returns (address) {
        return rootAddress;
    }

    function getReferral(address _address) external view returns (address) {
        return referrer[_address];
    }

    function isBindReferral(address _address) public view returns (bool) {
        return referrer[_address] != address(0);
    }

    function getReferralCount(address _address) external view returns (uint256) {
        return referralCount[_address];
    }

    function getteamTotalInvestValue(address _user) external view returns (uint256) {
        return teamTotalInvestValue[_user];
    }

    /// @notice 分页获取直推用户
    function getReferrals(address _address, uint256 _num) external view returns (address[] memory) {
        address[] memory refs = directReferrals[_address];
        uint256 len = refs.length;

        if (_num >= len) return refs;

        // 仅返回前 _num 个
        address[] memory result = new address[](_num);
        for (uint256 i = 0; i < _num; i++) {
            result[i] = refs[i];
        }
        return result;
    }

    /// @notice 设置推荐人，实现 BindReferral
    function bindReferral(address parent, address user, uint256 amount) external onlyAuthorized {
        require(user != address(0), "zero");
        require(parent != user, "self");
        require(referrer[user] == address(0), "already bind");
        require(
            referrer[parent] != address(0) || parent == rootAddress,
            "invalid parent"
        );


        // 防环检查
        address cur = parent;
        uint256 depth = 0;
        while (cur != address(0) && cur != rootAddress  && depth < maxReferralDepth) {
            require(cur != user, "loop");
            cur = referrer[cur];
            depth++;
        }

        referrer[user] = parent;
        directReferrals[parent].push(user);
        referralCount[parent]++;

        if (amount > 0) {
            require(addSubVTeam(user, amount), "addVt fail");
        }

    }


    function addSubVTeam(address user, uint256 amount) internal returns (bool) {
        require(user != address(0), "zero");
        require(amount > 0, "amount=0");

        address child = user;
        address parent = referrer[child];
        uint256 depth = 0;

        while (parent != address(0) && depth < maxReferralDepth) {
            // 增加该 parent 的团队总业绩
            teamTotalInvestValue[parent] += amount;

            // 增加 parent -> child 的子区业绩
            subTeamPerformance[parent][child] += amount;

            // move up
            child = parent;
            parent = referrer[child];
            depth++;
        }

        return true;
    }

    /* ========== PERFORMANCE LOGIC ========== */

    function addSubTeam(address user, uint256 amount) external onlyAuthorized returns (bool) {
        require(user != address(0), "zero");
        require(amount > 0, "amount=0");

        address child = user;
        address parent = referrer[child];
        uint256 depth = 0;

        while (parent != address(0) && depth < maxReferralDepth) {
            // 增加该 parent 的团队总业绩
            teamTotalInvestValue[parent] += amount;

            // 增加 parent -> child 的子区业绩
            subTeamPerformance[parent][child] += amount;

            // move up
            child = parent;
            parent = referrer[child];
            depth++;
        }

        return true;
    }

    function subSubTeam(address user, uint256 amount) external onlyAuthorized returns (bool) {
        require(user != address(0), "zero");
        require(amount > 0, "amount=0");

        address child = user;
        address parent = referrer[child];
        uint256 depth = 0;

        while (parent != address(0) && depth < maxReferralDepth) {
            // 防止 underflow：确保 parent 的团队业绩足够
            require(teamTotalInvestValue[parent] >= amount, "parent total underflow");
            teamTotalInvestValue[parent] -= amount;

            // 防止 subTeamPerformance 下溢
            require(subTeamPerformance[parent][child] >= amount, "sub team underflow");
            subTeamPerformance[parent][child] -= amount;

            // move up
            child = parent;
            parent = referrer[child];
            depth++;
        }

        return true;
    }


    /// @notice 获取当前地址的所有上级，直到根节点
    /// @param user 要查询的用户地址
    /// @return ancestors 上级地址数组，从直接上级到根节点
    function getAncestors(address user) external view returns (address[] memory ancestors) {
        require(user != address(0), "zero address");
        // 先计算实际的上级数量
        uint256 count = 0;
        address current = referrer[user];
        uint256 depth = 0;

        while (current != address(0) && depth < maxReferralDepth) {
            count++;
            if (current == rootAddress) {
                break;
            }
            current = referrer[current];
            depth++;
        }

        // 创建固定大小的数组
        ancestors = new address[](count);
        // 填充数组
        current = referrer[user];
        depth = 0;
        uint256 index = 0;

        while (current != address(0) && depth < maxReferralDepth && index < count) {
            ancestors[index] = current;
            index++;
            if (current == rootAddress) {
                break;
            }
            current = referrer[current];
            depth++;
        }

        return ancestors;
    }

    /// @notice 获取当前地址到根节点的层级深度
    /// @param user 要查询的用户地址
    /// @return depth 从用户到根节点的层级数
    function getDepthToRoot(address user) external view returns (uint256 depth) {
        require(user != address(0), "zero address");

        address current = referrer[user];
        depth = 0;

        while (current != address(0) && depth < maxReferralDepth) {
            depth++;
            if (current == rootAddress) {
                break;
            }
            current = referrer[current];
        }

        return depth;
    }

    /// @notice 获取用户的直推子区数量
    function getDirectReferralCount(address user) external view returns (uint256) {
        return directReferrals[user].length;
    }

    /// @notice 获取 parent 对某 child 的子区业绩
    function getSubTeamPerformance(address parent, address child) external view returns (uint256) {
        return subTeamPerformance[parent][child];
    }

    /// @notice 获取 parent 的团队总业绩
    function getTeamTotal(address parent) external view returns (uint256) {
        return teamTotalInvestValue[parent];
    }

    /* ========== 大小区业绩计算 ========== */

    /**
     * @notice 计算大区和小区业绩
     * @param user 用户地址
     * @return bigAreaPerformance 大区业绩（最大的一个区）
     * @return smallAreaPerformance 小区业绩（排除大区后的总和）
     */
    function getBigAndSmallArea(address user) public view returns (
        uint256 bigAreaPerformance,
        uint256 smallAreaPerformance
    ) {
        address[] memory directChildren = directReferrals[user];
        uint256 length = directChildren.length;

        if (length == 0) {
            return (0, 0);
        }

        // 获取所有子区业绩
        uint256[] memory performances = new uint256[](length);
        uint256 totalPerformance = 0;
        uint256 maxPerformance = 0;

        for (uint256 i = 0; i < length; i++) {
            performances[i] = subTeamPerformance[user][directChildren[i]];
            totalPerformance += performances[i];

            // 找出最大业绩
            if (performances[i] > maxPerformance) {
                maxPerformance = performances[i];
            }
        }

        // 大区 = 最大的子区业绩
        bigAreaPerformance = maxPerformance;
        // 小区 = 总业绩 - 大区业绩
        smallAreaPerformance = totalPerformance - bigAreaPerformance;
        return (bigAreaPerformance, smallAreaPerformance);
    }


    /// @notice 获取用户的所有子区业绩详情
    /// @param user 用户地址
    /// @return children 子节点地址数组
    /// @return performances 对应的子区业绩数组
    function getSubAreasDetail(address user)
    external
    view
    returns (
        address[] memory children,
        uint256[] memory performances
    )
    {
        children = directReferrals[user];
        uint256 len = children.length;
        performances = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            performances[i] = subTeamPerformance[user][children[i]];
        }

        return (children, performances);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }
}