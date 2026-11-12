// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================================
//  BuybackBurnerV2 —— CIN 回购销毁引擎（修正版，单文件自包含，可直接粘进 Remix）
//
//  与 v1（0x701c908a4a914cb8762774d2cc93ef7b8d375fa1）的唯一实质性差异：
//      v1 用 router 返回的 amounts[last]（= 扣税前产出）当作实收，
//      而 CIN 对「从池子转出」收 6% 买入税，合约实际只拿到 94%，
//      于是 80% 销毁 + 20% 留存 = 100% > 94% → 必然 revert: ERC20: balance exceeded。
//      v2 改为「转账前余额 → swap → 转账后余额」的差值，取真实到手量分配。
//  => v2 不需要任何垫付，事件里的 cinBought 也是真实到手数。
//
//  主网地址：0x1b986ddb4264fd7858501139b75f59af235eaf99
//  编译设置：solc 0.8.20 / optimizer 关闭 / evm paris（BscScan Exact Match）
// ============================================================================

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @dev CIN 额外需要 burn（自持余额销毁，需持有 BURNER_ROLE）
interface ICIN is IERC20Minimal {
    function burn(uint256 amount) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// ============================ 角色权限（与主合约同构） ============================

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

// ============================ 回购销毁引擎 ============================

/// @title BuybackBurnerV2
/// @notice 稳定币经网关转入 → DEX 换 CIN → 按 burnBps 销毁、余下留存金库
contract BuybackBurnerV2 is AccessLite {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");

    ICIN public immutable cin;
    IERC20Minimal public immutable paymentToken;
    address public dexRouter;
    address public treasury;
    uint16 public burnBps = 8000;
    bool public swapEnabled;
    bool public paused;
    uint256 private _locked;

    uint256 public totalPaymentSpent;
    uint256 public totalCinBurned;
    uint256 public executionCount;

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
        address cin_,
        address payment_,
        address router_,
        address treasury_,
        uint16 burnBps_
    ) {
        require(cin_ != address(0), "BB: cin zero");
        require(payment_ != address(0), "BB: payment zero");
        require(router_ != address(0), "BB: router zero");
        require(burnBps_ <= 10_000, "BB: burnBps > 10000");
        cin = ICIN(cin_);
        paymentToken = IERC20Minimal(payment_);
        dexRouter = router_;
        treasury = treasury_;
        burnBps = burnBps_;
        _bootstrapAdmin();
        _grant(GOVERNOR_ROLE, msg.sender);
    }

    // ---------------- 治理 ----------------

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

    function emergencyWithdraw(IERC20Minimal token, uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        token.transfer(msg.sender, amount);
        emit EmergencyWithdraw(address(token), amount);
    }

    // ---------------- 核心 ----------------

    /// @notice minCinOut 按 router 口径（税前产出下限）传入
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

        uint256 balBefore = cin.balanceOf(address(this));

        uint256[] memory amounts = IUniswapV2Router02(dexRouter).swapExactTokensForTokens(
            paymentAmount, minCinOut, path, address(this), deadline
        );
        require(amounts.length == 2, "BB: bad path");

        uint256 received = cin.balanceOf(address(this)) - balBefore;
        require(received > 0, "BB: swap returned zero");

        uint256 toBurn = (received * burnBps) / 10_000;
        uint256 retained = received - toBurn;

        if (toBurn > 0) cin.burn(toBurn);
        if (retained > 0) cin.transfer(treasury, retained);

        totalPaymentSpent += paymentAmount;
        totalCinBurned += toBurn;
        executionCount += 1;

        emit BuybackExecuted(paymentAmount, received, toBurn, retained);
    }

    // ---------------- 只读辅助 ----------------

    function previewBurn(uint256 netReceived) external view returns (uint256 toBurn, uint256 retained) {
        toBurn = (netReceived * burnBps) / 10_000;
        retained = netReceived - toBurn;
    }
}
