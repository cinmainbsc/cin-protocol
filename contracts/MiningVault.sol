// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title CIN LP 矿机（零增发，收益全部来自交易税 LP 份额）
/// @notice 用户质押 CIN/USDT 的 Pancake LP Token，按「LP 数量 × 档位系数」分享
///         主合约累积的 LP 奖励（交易税 50% 那部分），不发任何新币。
/// @dev 自包含单文件，不依赖 OpenZeppelin，可直接粘贴进 Remix 编译。
///
/// 部署顺序（必须按序执行，否则矿机没有收益）：
///   1. 部署本合约（构造参数：LP 地址、CIN 地址）
///   2. CIN 主合约：setTaxExempt(vault, true)   —— 让发放奖励不被扣 6%
///   3. CIN 主合约：setLpWeight(vault, 权重)     —— 把 LP 份额全部指向本合约
///   4. 运营定期调用 harvest()，把主合约里的 LP 奖励拉进本合约，自动按权重分配

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICIN is IERC20 {
    /// @dev 主合约的 LP 奖励领取接口
    function claimLp() external returns (uint256);
}

contract CINMiningVault {
    // ============ 常量 ============
    uint256 private constant ACC = 1e18;        // 累积精度
    uint16 private constant BPS = 10_000;       // 万分基准
    uint32 private constant MAX_LOCK = 365 days;

    // ============ 状态 ============
    IERC20 public immutable lp;      // Pancake CIN/USDT LP Token
    ICIN public immutable cin;       // CIN 代币
    address public owner;

    /// 档位：lockSeconds 锁仓时长，factorBps 权重系数（6000 = 0.6 倍）
    struct Tier {
        uint32 lockSeconds;
        uint16 factorBps;
    }
    Tier[3] public tiers;

    struct Stake {
        uint256 amount;        // 质押的 LP 数量
        uint256 weight;        // amount × factorBps / 10000
        uint16  factorBps;     // 当前档位系数
        uint256 unlockAt;      // 解锁时间戳
        uint256 accSnapshot;   // 上次结算时的 accCinPerWeight
        uint256 accrued;       // 已结算、未领取的 CIN
    }
    mapping(address => Stake) public stakes;

    uint256 public totalWeight;        // 全网权重合计
    uint256 public accCinPerWeight;    // 每单位权重累计的 CIN（ACC 精度）
    uint256 public lastCinBalance;     // 上次记账时的合约 CIN 余额

    uint16  public penaltyBps = 3000;  // 提前解锁罚没比例（30%）
    address public penaltySink;        // 罚没 CIN 收款地址（用于加池）
    uint256 public totalPenalized;     // 累计罚没（链上可核验）

    bool private locked;

    // ============ 事件 ============
    event Staked(address indexed user, uint256 amount, uint16 factorBps, uint256 unlockAt);
    event Withdrawn(address indexed user, uint256 amount, uint256 penalty);
    event Claimed(address indexed user, uint256 amount);
    event Harvested(address indexed caller, uint256 amount);
    event PenaltySinkSet(address sink);
    event PenaltyBpsSet(uint16 bps);
    event TierSet(uint8 tier, uint32 lockSeconds, uint16 factorBps);
    event OwnerChanged(address owner);

    // ============ 修饰器 ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Vault: not owner");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "Vault: reentrant");
        locked = true;
        _;
        locked = false;
    }

    constructor(IERC20 lp_, ICIN cin_) {
        require(address(lp_) != address(0) && address(cin_) != address(0), "Vault: zero addr");
        lp = lp_;
        cin = cin_;
        owner = msg.sender;
        penaltySink = msg.sender;

        // 灵活 0 天 0.6 / 稳健 30 天 1.0 / 长期 90 天 1.5
        tiers[0] = Tier(0, 6000);
        tiers[1] = Tier(30 days, 10000);
        tiers[2] = Tier(90 days, 15000);
    }

    // ============ 内部记账 ============

    /// @dev 把「合约当前 CIN 余额」相对上次记账的增量，按权重分配到 accCinPerWeight
    function _update() internal {
        uint256 bal = cin.balanceOf(address(this));
        if (bal > lastCinBalance) {
            // 无人质押时不动 lastCinBalance，把这段增量的记账权留给第一位质押者，
            // 否则奖励会永久卡在合约里再也分不出去
            if (totalWeight > 0) {
                accCinPerWeight += ((bal - lastCinBalance) * ACC) / totalWeight;
                lastCinBalance = bal;
            }
        } else if (bal < lastCinBalance) {
            // 领取转出导致的余额下降，同步基准，避免把转出误判为负奖励
            lastCinBalance = bal;
        }
    }

    /// @dev 把用户待领收益落账，并把权重快照刷新到当前 acc
    function _settle(Stake storage s) internal {
        if (s.weight > 0) {
            s.accrued += (s.weight * (accCinPerWeight - s.accSnapshot)) / ACC;
        }
        s.accSnapshot = accCinPerWeight;
    }

    function _currentFactor(uint8 tier) internal view returns (uint32 lockSec, uint16 factorBps) {
        require(tier < 3, "Vault: bad tier");
        Tier storage t = tiers[tier];
        return (t.lockSeconds, t.factorBps);
    }

    // ============ 查询 ============

    /// @notice 用户当前可领 CIN（含尚未记账的合约余额增量）
    function pending(address user) public view returns (uint256) {
        Stake storage s = stakes[user];
        if (s.weight == 0) return s.accrued;

        uint256 acc = accCinPerWeight;
        uint256 bal = cin.balanceOf(address(this));
        if (bal > lastCinBalance && totalWeight > 0) {
            acc += ((bal - lastCinBalance) * ACC) / totalWeight;
        }
        return s.accrued + (s.weight * (acc - s.accSnapshot)) / ACC;
    }

    /// @notice 若现在退出，会被罚没多少（未到解锁期的为 accrued × penaltyBps）
    function pendingPenalty(address user) public view returns (uint256) {
        Stake storage s = stakes[user];
        if (s.weight == 0) return 0;
        if (block.timestamp >= s.unlockAt) return 0;
        return (pending(user) * penaltyBps) / BPS;
    }

    // ============ 质押 / 退出 ============

    /// @notice 质押 LP。已有仓位时追加：必须为同一档位，解锁期从本次重新起算
    function stake(uint256 amount, uint8 tier) external nonReentrant {
        require(amount > 0, "Vault: zero amount");
        (uint32 lockSec, uint16 factorBps) = _currentFactor(tier);

        _update();
        Stake storage s = stakes[msg.sender];

        if (s.amount > 0) {
            require(s.factorBps == factorBps, "Vault: different tier, withdraw first");
            _settle(s);
            totalWeight -= s.weight;
        } else {
            s.accSnapshot = accCinPerWeight;
        }

        require(lp.transferFrom(msg.sender, address(this), amount), "Vault: lp transfer failed");

        s.amount += amount;
        s.factorBps = factorBps;
        s.weight = (s.amount * factorBps) / BPS;
        s.unlockAt = block.timestamp + lockSec;

        totalWeight += s.weight;
        emit Staked(msg.sender, amount, factorBps, s.unlockAt);
    }

    /// @notice 取回 LP（可部分）。未到解锁期扣未领收益的 penaltyBps，本金全额退还
    function withdraw(uint256 amount) external nonReentrant {
        Stake storage s = stakes[msg.sender];
        require(amount > 0 && amount <= s.amount, "Vault: bad amount");

        _update();
        _settle(s);

        uint256 penalty;
        if (block.timestamp < s.unlockAt && s.accrued > 0) {
            penalty = (s.accrued * penaltyBps) / BPS;
            s.accrued -= penalty;
            totalPenalized += penalty;
            if (penalty > 0) {
                require(cin.transfer(penaltySink, penalty), "Vault: penalty transfer failed");
                lastCinBalance = cin.balanceOf(address(this));
            }
        }

        totalWeight -= s.weight;
        s.amount -= amount;
        s.weight = (s.amount * s.factorBps) / BPS;
        totalWeight += s.weight;

        require(lp.transfer(msg.sender, amount), "Vault: lp transfer failed");
        emit Withdrawn(msg.sender, amount, penalty);
    }

    /// @notice 领取已累积的 CIN 奖励
    function claim() external nonReentrant returns (uint256 amount) {
        Stake storage s = stakes[msg.sender];
        _update();
        _settle(s);

        amount = s.accrued;
        require(amount > 0, "Vault: nothing to claim");
        s.accrued = 0;

        require(cin.transfer(msg.sender, amount), "Vault: reward transfer failed");
        lastCinBalance = cin.balanceOf(address(this));
        emit Claimed(msg.sender, amount);
    }

    /// @notice 紧急退出：放弃全部未领收益，LP 本金全额取回，不受锁仓限制
    function emergencyWithdraw() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        uint256 amount = s.amount;
        require(amount > 0, "Vault: empty");

        totalWeight -= s.weight;
        s.amount = 0;
        s.weight = 0;
        s.accrued = 0;
        s.accSnapshot = accCinPerWeight;

        require(lp.transfer(msg.sender, amount), "Vault: lp transfer failed");
        emit Withdrawn(msg.sender, amount, 0);
    }

    // ============ 奖励拉取 ============

    /// @notice 从 CIN 主合约领取本 vault 的 LP 奖励并按权重记账（任何人可调）
    /// @dev 主合约当前无可领额度时会 revert，这里吞掉错误，避免 harvest 整体失败
    function harvest() external nonReentrant returns (uint256) {
        uint256 before = cin.balanceOf(address(this));
        try cin.claimLp() {} catch {}
        uint256 afterBal = cin.balanceOf(address(this));
        uint256 gained = afterBal > before ? afterBal - before : 0;
        _update();
        emit Harvested(msg.sender, gained);
        return gained;
    }

    // ============ 治理 ============

    function setPenaltyBps(uint16 bps) external onlyOwner {
        require(bps <= 5000, "Vault: penalty too high");
        penaltyBps = bps;
        emit PenaltyBpsSet(bps);
    }

    function setPenaltySink(address sink) external onlyOwner {
        require(sink != address(0), "Vault: zero sink");
        penaltySink = sink;
        emit PenaltySinkSet(sink);
    }

    /// @notice 调整档位（锁仓时长与系数），不影响已质押仓位
    function setTier(uint8 tier, uint32 lockSeconds, uint16 factorBps) external onlyOwner {
        require(tier < 3, "Vault: bad tier");
        require(lockSeconds <= MAX_LOCK, "Vault: lock too long");
        require(factorBps > 0 && factorBps <= 20000, "Vault: bad factor");
        tiers[tier] = Tier(lockSeconds, factorBps);
        emit TierSet(tier, lockSeconds, factorBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Vault: zero owner");
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    /// @notice 治理救援误转入的其他代币（不动 LP 与 CIN）
    function rescue(address token, uint256 amount) external onlyOwner {
        require(token != address(lp) && token != address(cin), "Vault: protected token");
        require(IERC20(token).transfer(owner, amount), "Vault: rescue failed");
    }
}
