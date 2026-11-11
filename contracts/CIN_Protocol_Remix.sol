// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * CIN 协议 · Remix 一键编译版（v1.2 补丁）
 * ------------------------------------------------------------------
 * 本文件为自包含单文件：不 import 任何路径，粘贴进 Remix 即可编译。
 * 编译设置：Compiler 0.8.20，EVM Version paris 或 shanghai 均可，Optimizer 开启 200 runs。
 *
 * 相比原四份源码的补丁内容：
 *   1. CINToken 增加转账钩子：买入 6% / 卖出 6% / 转账 3% / LP 专用入口 9%
 *   2. 手续费四路切分：销毁 10% / LP 奖励 50% / 分享 20% / 社区 20%
 *   3. 分享奖励沿推荐链五级递减：20% / 18% / 16% / 14% / 10%，未达直推 3 人门槛的份额回流社区
 *   4. 推荐关系绑定、有效会员判定、LP 注入权重与奖励累积领取
 *   5. BuybackBurner 增加 treasury 参数与可开关的真实兑换路径
 *   6. AgentRewards 保持发放即销毁 10% 与 90 天线性归属
 *   7. CINCurve 保留区间积分闭式（内联库，不产生独立地址）
 *
 * 部署顺序：CINToken → BuybackBurner → AgentRewards → 授角色 → initPair → 开兑换
 * 详见文件末尾 DEPLOY NOTES。
 */

// ============================ 接口 ============================

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// ============================ 排放曲线库 ============================

/// @title 排放曲线：1/t^2 衰减的区间积分闭式
/// @dev 权重 w(t) = 2 / (t(t+1))，区间 [tStart, tEnd) 的累计为 2(tEnd-tStart)/(tStart*tEnd)。
///      全部函数 internal，编译时内联进调用方，不产生独立地址。
library CINCurve {
    uint256 internal constant WAD = 1e18;

    /// @notice 第 t 周期的相对权重（1e18 精度）
    function weightAt(uint256 t) internal pure returns (uint256) {
        require(t > 0, "CINCurve: t must be > 0");
        return (2 * WAD) / (t * (t + 1));
    }

    /// @notice 区间累计权重（1e18 精度），O(1)
    function cumulative(uint256 tStart, uint256 tEnd) internal pure returns (uint256) {
        require(tStart > 0, "CINCurve: tStart must be > 0");
        if (tEnd <= tStart) return 0;
        return (2 * WAD * (tEnd - tStart)) / (tStart * tEnd);
    }

    /// @notice 区间内可分配额度：totalAmount 按区间权重占比切分
    function shareInRange(uint256 totalAmount, uint256 tStart, uint256 tEnd, uint256 t0, uint256 t1)
        internal
        pure
        returns (uint256)
    {
        uint256 whole = cumulative(t0, t1);
        if (whole == 0) return 0;
        return (totalAmount * cumulative(tStart, tEnd)) / whole;
    }
}

// ============================ ERC20 基础实现（内联） ============================

abstract contract ERC20Lite {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public virtual returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: allowance exceeded");
            _allowances[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @dev 子类覆写此函数即可插入转账钩子（税、燃烧、分润）
    function _transfer(address from, address to, uint256 amount) internal virtual {
        _move(from, to, amount);
    }

    /// @dev 原始记账，不经任何钩子
    function _move(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "ERC20: zero address");
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: balance exceeded");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: burn exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from zero");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

// ============================ 角色权限（内联） ============================

abstract contract AccessLite {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "Access: missing role");
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) public {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "Access: not admin");
        _grant(role, account);
    }

    function revokeRole(bytes32 role, address account) public {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "Access: not admin");
        _revoke(role, account);
    }

    /// @dev 内部授权，构造阶段自举使用；注意不要与业务内部函数重名
    function _grant(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _revoke(bytes32 role, address account) internal {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function _bootstrapAdmin() internal {
        _roles[DEFAULT_ADMIN_ROLE][msg.sender] = true;
    }
}

// ============================ 主币 CINToken ============================

/// @title CIN 协议主币
/// @notice 210 亿枚铸造上限；交易燃烧 + 手续费四路分润 + 五级身份递减分享
contract CINToken is ERC20Lite, AccessLite {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    uint256 public constant MAX_SUPPLY = 21_000_000_000 ether;

    // ---- 费率（单位 bps，10000 = 100%）----
    uint16 public buyFeeBps = 600; // 买入 6%
    uint16 public sellFeeBps = 600; // 卖出 6%
    uint16 public transferFeeBps = 300; // 转账 3%
    uint16 public lpFeeBps = 900; // LP 专用入口 9%

    // ---- 手续费四路切分 ----
    uint16 public burnShareBps = 1000; // 销毁 10%
    uint16 public lpShareBps = 5000; // LP 奖励 50%
    uint16 public referShareBps = 2000; // 分享 20%
    // 社区部分 = 10000 - burn - lp - refer，即 20%

    // ---- 五级分享比例 ----
    uint16 public level0Bps = 2000; // 运营中心 20%
    uint16 public level1Bps = 1800; // 创世合伙人 18%
    uint16 public level2Bps = 1600; // 社区合伙人 16%
    uint16 public level3Bps = 1400; // 推广合伙人 14%
    uint16 public level4Bps = 1000; // 共识会员 10%

    address public communityWallet;
    address public operatorCenter;

    mapping(address => bool) public isPair;
    mapping(address => bool) public taxExempt;
    bool public feeEnabled = true;

    // ---- 推荐关系 ----
    mapping(address => address) public referrer;
    mapping(address => uint256) public directCount;
    mapping(address => uint256) public activeDirect;
    mapping(address => bool) public isActive;

    uint256 public memberMinHolding = 1_000 ether; // 有效会员门槛
    uint256 public maxRefDepth = 20;
    uint256 public minActiveDirectRequired = 3;

    // ---- LP 奖励累积（按注入权重加权平分）----
    uint256 public lpAccPerWeight; // 每单位权重的累计奖励（1e18 精度）
    uint256 public totalLpWeight;
    uint256 public lpPoolBalance; // 账面：合约内待分配的 LP 奖励
    mapping(address => uint256) public lpWeight;
    mapping(address => uint256) public lpCredit;
    mapping(address => uint256) public lpPending;

    // ---- 统计（供仪表盘读取）----
    uint256 public totalFeeTaken;
    uint256 public totalBurnedByFee;
    uint256 public totalReferPaid;
    uint256 public totalCommunityPaid;

    event FeeTaken(address indexed from, address indexed to, uint256 amount, uint16 feeBps);
    event FeeSplit(uint256 burned, uint256 toLp, uint256 toRefer, uint256 toCommunity);
    event ReferrerBound(address indexed member, address indexed referrer);
    event LpWeightSet(address indexed account, uint256 weight);
    event LpClaimed(address indexed account, uint256 amount);
    event PairSet(address indexed pair);
    event TaxExemptSet(address indexed account, bool exempt);

    constructor(address communityWallet_, address operatorCenter_) ERC20Lite("CIN Protocol", "CIN") {
        require(communityWallet_ != address(0), "CIN: community wallet zero");
        require(operatorCenter_ != address(0), "CIN: operator center zero");
        communityWallet = communityWallet_;
        operatorCenter = operatorCenter_;
        taxExempt[address(this)] = true;
        taxExempt[communityWallet_] = true;
        taxExempt[operatorCenter_] = true;
        _bootstrapAdmin();
        _grant(GOVERNOR_ROLE, msg.sender);
    }

    // ================= 铸造与销毁 =================

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "CIN: cap exceeded");
        _mint(to, amount);
    }

    /// @notice 自持余额销毁：持有 BURNER_ROLE 的合约直接烧自己的余额
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(msg.sender, amount);
    }

    // ================= 转账钩子（核心补丁） =================

    function _transfer(address from, address to, uint256 amount) internal override {
        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }
        if (!feeEnabled || taxExempt[from] || taxExempt[to] || (isPair[from] && isPair[to])) {
            super._transfer(from, to, amount);
            _refreshMember(from);
            _refreshMember(to);
            return;
        }
        _transferWithBps(from, to, amount, _feeBpsFor(from, to));
    }

    /// @notice 交易税率判定：从池子出来是买入，进池子是卖出，其余是转账
    function _feeBpsFor(address from, address to) internal view returns (uint16) {
        bool fromPair = isPair[from];
        bool toPair = isPair[to];
        if (fromPair && toPair) return 0;
        if (fromPair) return buyFeeBps;
        if (toPair) return sellFeeBps;
        return transferFeeBps;
    }

    /// @notice LP 专用转账入口：向交易对注入流动性时按 9% 计费
    /// @dev 链上无法自动区分"添加流动性"与"普通卖币"，因此单列入口由前端调用
    function transferForLiquidity(address pair, uint256 amount) external returns (bool) {
        require(isPair[pair], "CIN: not a pair");
        _transferWithBps(msg.sender, pair, amount, lpFeeBps);
        return true;
    }

    function _transferWithBps(address from, address to, uint256 amount, uint16 bps) internal {
        if (bps == 0 || amount == 0) {
            super._transfer(from, to, amount);
            _refreshMember(from);
            _refreshMember(to);
            return;
        }
        uint256 fee = (amount * bps) / 10_000;
        uint256 net = amount - fee;
        if (fee == 0) {
            super._transfer(from, to, amount);
            _refreshMember(from);
            _refreshMember(to);
            return;
        }

        uint256 toBurn = (fee * burnShareBps) / 10_000;
        uint256 toLp = (fee * lpShareBps) / 10_000;
        uint256 toRefer = (fee * referShareBps) / 10_000;
        uint256 toCommunity = fee - toBurn - toLp - toRefer;

        if (toBurn > 0) {
            _burn(from, toBurn);
            totalBurnedByFee += toBurn;
        }
        if (toLp > 0) {
            _creditLp(from, toLp);
        }
        if (toRefer > 0) {
            uint256 unused = _payReferrers(from, toRefer);
            toCommunity += unused;
        }
        if (toCommunity > 0) {
            _move(from, communityWallet, toCommunity);
            totalCommunityPaid += toCommunity;
        }

        super._transfer(from, to, net);

        totalFeeTaken += fee;
        emit FeeTaken(from, to, amount, bps);
        emit FeeSplit(toBurn, toLp, toRefer, toCommunity);
        _refreshMember(from);
        _refreshMember(to);
    }

    /// @notice LP 奖励累积：无权重时直接回流社区，避免奖励卡在合约里
    function _creditLp(address from, uint256 amount) internal {
        if (totalLpWeight == 0) {
            _move(from, communityWallet, amount);
            totalCommunityPaid += amount;
            return;
        }
        _move(from, address(this), amount);
        lpPoolBalance += amount;
        lpAccPerWeight += (amount * 1e18) / totalLpWeight;
    }

    /// @notice 分享奖励沿推荐链五级递减，未达标层级的份额回流社区
    function _payReferrers(address from, uint256 amount) internal returns (uint256 unused) {
        address current = referrer[from];
        uint16[5] memory rates = [level0Bps, level1Bps, level2Bps, level3Bps, level4Bps];
        uint256 used;
        for (uint256 i = 0; i < 5; i++) {
            if (current == address(0)) break;
            if (current != from && activeDirect[current] >= minActiveDirectRequired) {
                uint256 share = (amount * rates[i]) / 10_000;
                if (share > 0) {
                    _move(from, current, share);
                    used += share;
                }
            }
            current = referrer[current];
        }
        totalReferPaid += used;
        return amount - used;
    }

    // ================= 推荐关系与有效会员 =================

    function bindReferrer(address ref) external {
        require(referrer[msg.sender] == address(0), "CIN: referrer already set");
        require(ref != address(0) && ref != msg.sender, "CIN: invalid referrer");

        address cursor = ref;
        uint256 depth;
        for (uint256 i = 0; i < maxRefDepth; i++) {
            if (cursor == address(0)) break;
            cursor = referrer[cursor];
            depth++;
        }
        require(depth < maxRefDepth, "CIN: referrer chain too deep");

        referrer[msg.sender] = ref;
        directCount[ref] += 1;
        _refreshMember(msg.sender);
        emit ReferrerBound(msg.sender, ref);
    }

    /// @notice 有效会员判定：余额达到门槛即为有效，并回写给推荐人计数
    function _refreshMember(address account) internal {
        if (account == address(0) || account == address(this)) return;
        bool qualifies = balanceOf(account) >= memberMinHolding;
        if (qualifies && !isActive[account]) {
            isActive[account] = true;
            address ref = referrer[account];
            if (ref != address(0)) activeDirect[ref] += 1;
        } else if (!qualifies && isActive[account]) {
            isActive[account] = false;
            address ref = referrer[account];
            if (ref != address(0) && activeDirect[ref] > 0) activeDirect[ref] -= 1;
        }
    }

    /// @notice 身份层级：4 运营中心 / 3 创世 / 2 社区 / 1 推广 / 0 共识 / 255 无
    function tierOf(address account) public view returns (uint8) {
        if (account == operatorCenter) return 4;
        uint256 bal = balanceOf(account);
        if (bal >= 10_000 ether) return 3;
        if (bal >= 5_000 ether) return 2;
        if (bal >= 2_000 ether) return 1;
        if (activeDirect[account] >= minActiveDirectRequired) return 0;
        return 255;
    }

    // ================= LP 奖励领取 =================

    function pendingLp(address account) public view returns (uint256) {
        uint256 accrued = (lpWeight[account] * lpAccPerWeight) / 1e18;
        return lpPending[account] + accrued - lpCredit[account];
    }

    function claimLp() external returns (uint256 amount) {
        amount = pendingLp(msg.sender);
        require(amount > 0, "CIN: nothing to claim");
        require(balanceOf(address(this)) >= amount, "CIN: lp pool short");
        lpPending[msg.sender] = 0;
        lpCredit[msg.sender] = (lpWeight[msg.sender] * lpAccPerWeight) / 1e18;
        if (lpPoolBalance >= amount) lpPoolBalance -= amount;
        _transfer(address(this), msg.sender, amount);
        emit LpClaimed(msg.sender, amount);
    }

    function setLpWeight(address account, uint256 weight) external onlyRole(GOVERNOR_ROLE) {
        _settleLp(account);
        totalLpWeight = totalLpWeight - lpWeight[account] + weight;
        lpWeight[account] = weight;
        lpCredit[account] = (weight * lpAccPerWeight) / 1e18;
        emit LpWeightSet(account, weight);
    }

    function _settleLp(address account) internal {
        lpPending[account] = pendingLp(account);
        lpCredit[account] = (lpWeight[account] * lpAccPerWeight) / 1e18;
    }

    // ================= 治理参数 =================

    function setFees(uint16 buy_, uint16 sell_, uint16 transfer_, uint16 lp_) external onlyRole(GOVERNOR_ROLE) {
        require(buy_ <= 1000 && sell_ <= 1000 && transfer_ <= 1000 && lp_ <= 1000, "CIN: fee too high");
        buyFeeBps = buy_;
        sellFeeBps = sell_;
        transferFeeBps = transfer_;
        lpFeeBps = lp_;
    }

    function setShares(uint16 burn_, uint16 lp_, uint16 refer_) external onlyRole(GOVERNOR_ROLE) {
        require(uint256(burn_) + lp_ + refer_ <= 10_000, "CIN: shares exceed 10000");
        burnShareBps = burn_;
        lpShareBps = lp_;
        referShareBps = refer_;
    }

    function setLevelRates(uint16 l0, uint16 l1, uint16 l2, uint16 l3, uint16 l4)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(uint256(l0) + l1 + l2 + l3 + l4 <= 10_000, "CIN: level rates exceed");
        level0Bps = l0;
        level1Bps = l1;
        level2Bps = l2;
        level3Bps = l3;
        level4Bps = l4;
    }

    function setPair(address pair) external onlyRole(GOVERNOR_ROLE) {
        require(pair != address(0), "CIN: zero pair");
        isPair[pair] = true;
        taxExempt[pair] = true;
        emit PairSet(pair);
    }

    function setTaxExempt(address account, bool exempt) external onlyRole(GOVERNOR_ROLE) {
        taxExempt[account] = exempt;
        emit TaxExemptSet(account, exempt);
    }

    function setCommunityWallet(address wallet) external onlyRole(GOVERNOR_ROLE) {
        require(wallet != address(0), "CIN: zero wallet");
        communityWallet = wallet;
        taxExempt[wallet] = true;
    }

    function setOperatorCenter(address center) external onlyRole(GOVERNOR_ROLE) {
        require(center != address(0), "CIN: zero center");
        operatorCenter = center;
        taxExempt[center] = true;
    }

    function setFeeEnabled(bool enabled) external onlyRole(GOVERNOR_ROLE) {
        feeEnabled = enabled;
    }

    function setMemberMinHolding(uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        memberMinHolding = amount;
    }
}

// ============================ 回购销毁 ============================

/// @title 收入回购与销毁（L3 价值闭环）
/// @notice 稳定币收入经网关转入 → DEX 换 CIN → 80% 销毁、20% 留存金库
contract BuybackBurner is AccessLite {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");

    CINToken public immutable cin;
    IERC20Minimal public immutable paymentToken;
    address public dexRouter;
    address public treasury;
    uint16 public burnBps = 8000;
    bool public swapEnabled; // 部署后默认关闭，确认池子存在再打开
    bool public paused;
    uint256 private _locked;

    event BuybackExecuted(uint256 paymentSpent, uint256 cinBought, uint256 cinBurned, uint256 cinRetained);
    event RouterUpdated(address indexed router);
    event TreasuryUpdated(address indexed treasury);
    event SwapEnabledSet(bool enabled);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    modifier nonReentrant() {
        require(_locked == 0, "BB: reentrant");
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor(
        CINToken cin_,
        IERC20Minimal payment_,
        address router_,
        address treasury_,
        uint16 burnBps_
    ) {
        require(address(cin_) != address(0), "BB: cin zero");
        require(address(payment_) != address(0), "BB: payment zero");
        require(router_ != address(0), "BB: router zero");
        require(burnBps_ <= 10_000, "BB: burnBps > 10000");
        cin = cin_;
        paymentToken = payment_;
        dexRouter = router_;
        treasury = treasury_;
        burnBps = burnBps_;
        _bootstrapAdmin();
        _grant(GOVERNOR_ROLE, msg.sender);
    }

    function setRouter(address router_) external onlyRole(GOVERNOR_ROLE) {
        require(router_ != address(0), "BB: zero router");
        dexRouter = router_;
        emit RouterUpdated(router_);
    }

    function setTreasury(address treasury_) external onlyRole(GOVERNOR_ROLE) {
        require(treasury_ != address(0), "BB: zero treasury");
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setBurnBps(uint16 burnBps_) external onlyRole(GOVERNOR_ROLE) {
        require(burnBps_ <= 10_000, "BB: burnBps > 10000");
        burnBps = burnBps_;
    }

    function setSwapEnabled(bool enabled) external onlyRole(GOVERNOR_ROLE) {
        swapEnabled = enabled;
        emit SwapEnabledSet(enabled);
    }

    function setPaused(bool paused_) external onlyRole(GOVERNOR_ROLE) {
        paused = paused_;
    }

    /// @notice 兑换并销毁：仅网关可触发
    /// @dev 路径固定为 paymentToken → CIN；minCinOut 与 deadline 透传 DEX
    function execute(uint256 paymentAmount, uint256 minCinOut, uint256 deadline)
        external
        onlyRole(GATEWAY_ROLE)
        nonReentrant
    {
        require(!paused, "BB: paused");
        require(swapEnabled, "BB: swap disabled");
        require(paymentAmount > 0, "BB: zero amount");
        require(treasury != address(0), "BB: treasury unset");

        paymentToken.transferFrom(msg.sender, address(this), paymentAmount);
        paymentToken.approve(dexRouter, 0);
        paymentToken.approve(dexRouter, paymentAmount);

        address[] memory path = new address[](2);
        path[0] = address(paymentToken);
        path[1] = address(cin);

        uint256[] memory amounts = IUniswapV2Router02(dexRouter).swapExactTokensForTokens(
            paymentAmount, minCinOut, path, address(this), deadline
        );
        uint256 received = amounts[amounts.length - 1];
        require(received > 0, "BB: swap returned zero");

        uint256 toBurn = (received * burnBps) / 10_000;
        uint256 retained = received - toBurn;
        if (toBurn > 0) cin.burn(toBurn);
        if (retained > 0) cin.transfer(treasury, retained);

        emit BuybackExecuted(paymentAmount, received, toBurn, retained);
    }

    function emergencyWithdraw(IERC20Minimal token, uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        token.transfer(msg.sender, amount);
        emit EmergencyWithdraw(address(token), amount);
    }
}

// ============================ 任务酬劳 ============================

/// @title 任务酬劳与归属（L1 工具工作层）
/// @notice 发放即销毁 10%，剩余按 90 天线性归属
contract AgentRewards is AccessLite {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    struct Tranche {
        uint256 amount;
        uint256 start;
    }

    CINToken public immutable cin;
    uint16 public burnOnIssueBps = 1000;
    uint256 public vestSeconds = 90 days;

    mapping(address => Tranche[]) private _tranches;
    mapping(address => uint256) public claimed;
    uint256 public totalIssued;
    uint256 public totalBurnedOnIssue;

    event RewardsIssued(address indexed agent, uint256 gross, uint256 burned, uint256 vested);
    event RewardsClaimed(address indexed agent, uint256 amount);

    constructor(CINToken cin_) {
        require(address(cin_) != address(0), "AR: cin zero");
        cin = cin_;
        _bootstrapAdmin();
        _grant(ISSUER_ROLE, msg.sender);
    }

    function issue(address agent, uint256 gross) external onlyRole(ISSUER_ROLE) returns (uint256 net) {
        require(agent != address(0), "AR: zero agent");
        require(gross > 0, "AR: zero amount");

        uint256 toBurn = (gross * burnOnIssueBps) / 10_000;
        net = gross - toBurn;

        cin.mint(address(this), gross);
        if (toBurn > 0) {
            cin.burn(toBurn);
            totalBurnedOnIssue += toBurn;
        }
        _tranches[agent].push(Tranche({amount: net, start: block.timestamp}));
        totalIssued += gross;
        emit RewardsIssued(agent, gross, toBurn, net);
    }

    function claimable(address agent) public view returns (uint256) {
        uint256 vested;
        Tranche[] storage list = _tranches[agent];
        for (uint256 i = 0; i < list.length; i++) {
            uint256 elapsed = block.timestamp - list[i].start;
            if (elapsed >= vestSeconds) {
                vested += list[i].amount;
            } else {
                vested += (list[i].amount * elapsed) / vestSeconds;
            }
        }
        return vested - claimed[agent];
    }

    function claim() external returns (uint256 amount) {
        amount = claimable(msg.sender);
        require(amount > 0, "AR: nothing claimable");
        claimed[msg.sender] += amount;
        cin.transfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    function setBurnOnIssueBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bps <= 10_000, "AR: bps > 10000");
        burnOnIssueBps = bps;
    }

    function setVestSeconds(uint256 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vestSeconds = seconds_;
    }

    function trancheCount(address agent) external view returns (uint256) {
        return _tranches[agent].length;
    }
}

/*
 * ============================ DEPLOY NOTES ============================
 *
 * 编译：Remix → Solidity Compiler 选 0.8.20 → Compile CIN_Protocol_Remix.sol
 *       不开 import、不需要 npm、不需要 @openzeppelin
 *
 * 部署顺序（按序，每步确认成功再下一步）：
 *   1) CINToken(communityWallet, operatorCenter)
 *      communityWallet = 社区奖励收款地址（20%）
 *      operatorCenter  = 运营中心地址（分享链第一级 20%）
 *   2) BuybackBurner(cin, USDT, router, treasury, 8000)
 *      BSC-USDT 0x55d398326f99059fF775485246999027B3197955
 *      Pancake V2 0x10ED43C718714eb63d5aA57B78B54704E256024E
 *      treasury 建议多签；swapEnabled 默认 false
 *   3) AgentRewards(cin)
 *   4) 在 CINToken 上 grantRole：
 *      MINTER_ROLE → AgentRewards 地址
 *      BURNER_ROLE → AgentRewards 地址
 *      BURNER_ROLE → BuybackBurner 地址
 *   5) 在 CINToken 上 setPair(Pancake pair 地址)
 *      查法：factory.getPair(CIN, USDT)
 *   6) 池子确认有深度后，BuybackBurner.setSwapEnabled(true)
 *
 * 上线后需要人工维护的两处（合约无法自动完成）：
 *   - setLpWeight(地址, 权重)：链下核对实际注入的 LP 数量后写入，奖励按权重加权平分
 *   - 前端在"添加流动性"场景调用 transferForLiquidity(pair, amount)，按 9% 计费
 *
 * 与旧版四份源码的差异：
 *   - BuybackBurner 构造函数新增 treasury 参数（旧版缺）
 *   - _doSwap 空实现替换为真实 Pancake 调用 + swapEnabled 开关
 *   - CINToken 新增转账钩子、推荐关系、LP 奖励，字节码显著变大（约 2.5–3 KB）
 *   - 权限体系由 OZ 的 role-admin 间接授权简化为"部署者可授/撤任意角色"
 */
