# CIN Protocol (BSC)

CIN 是部署在 BNB Smart Chain 上的 BEP-20 代币，配套一套可链上核验的分账、回购销毁与流动性激励合约。
本仓库只放**已验证的源码、地址簿与核验方法**，不放宣传材料。

## 合约地址

| 合约 | 地址 | 状态 |
|---|---|---|
| CINToken (BEP-20) | `0x49ba7945105bc55b75a87522132040a1c2ac33b4` | BscScan 已验证 |
| BuybackBurner v2 | `0x1b986ddb4264fd7858501139b75f59af235eaf99` | BscScan 已验证（solc 0.8.20 / 优化关闭 / paris） |
| CINMiningVault | `0x72DA093081377b679bF27A32Aaf091F9Ee7949E9` | BscScan 已验证 |
| EmissionCurve | `0xed6ebf9a22896d65b0e5ab54bc292d35d6da375e` | 源码未验证；**增发权已于 2026-11-13 撤销，当前已无作用** |
| CIN/USDT Pair | `0x9b733b0f0a8828cdf5d52c3de49ddad3db108d03` | PancakeSwap V2，token0 = CIN |

> v1 引擎 `0x701c908a4a914cb8762774d2cc93ef7b8d375fa1` 已退役：余额 0、销毁权已撤销，任何场景都不要再用这个地址。

## 链上数值（RPC 直读，2026-11-13）

| 项 | 值 |
|---|---|
| totalSupply | `348,727,845.43` CIN |
| MAX_SUPPLY（硬顶常量） | `21,000,000,000` |
| 池子储备 | `10,178,042.02` CIN / `8.079136` USDT |
| 标价 | `7.938e-7` USDT/CIN |
| LP 总量 / 运营钱包持有 | `9,066.257757` / 100% |
| 累计销毁 | `739,713.157` CIN（1 次执行，0.7 USDT） |

## 权限现状（截至 2026-11-13）

- `MINTER_ROLE`：**当前没有任何地址持有**。2026-11-13 已撤销 EmissionCurve 的授权
  （tx `0xedba0c469c339d896688fac16d167d623cfdff9e5013ddd4dd1628dc427faa8f`）。
  供应自此只减不增；如未来需要排放，只能由 ADMIN 重新授权。
- `DEFAULT_ADMIN_ROLE` / `GOVERNOR_ROLE`：由运营钱包 `0xb14c276ecd90158af14258cf62c8e1425a3f01af` 持有。
  **因此管理员可以再次授权增发——但这是主动行为，不是现有能力。**
- `BURNER_ROLE`：仅 `BuybackBurner v2` 持有；v1 已撤销。

> 表述纪律：不要写“永久无增发”。可以写“当前无任何地址持有增发权（已撤销，可查）”。

## 持仓结构（6 个地址，2026-11-13 实测）

| 地址 | 角色 | 占比 |
|---|---|---|
| `0x8e49…46fb` | operatorCenter（单签 EOA） | 82.30% |
| `0xf64a…bf03` | 社区钱包（单签 EOA） | 14.73% |
| `0x9b73…8d03` | CIN/USDT Pair | 2.92% |
| `0xb14c…01af` | 运营钱包 | 0.028% |

前两个地址合计 97.03%，均非多签、无锁仓。这是当前最大的结构性风险。

## 核验方法

合约只读接口可直接在 BscScan 的 Read Contract 页调用，或用任意 RPC：

```
eth_call totalSupply()            0x18160ddd
eth_call balanceOf(address)       0x70a08231 + 32 字节地址
eth_call getReserves()            0x0902f1ac   (Pair)
eth_call hasRole(bytes32,address) 0x91d14854   (CINToken)
```

## 仓库结构

```
contracts/CIN_Protocol_Remix.sol   # 主合约扁平化源码（与链上字节码一致，勿改）
contracts/MiningVault.sol          # LP 质押金库
contracts/BuybackBurnerV2.sol      # 现行回购引擎（v2 修正版）
addresses.md                       # 合约 / 钱包 / 角色哈希地址簿
TRUST.md                           # 可核验清单与未查清项
```

ABI 不内置，直接从 BscScan 对应合约页的 Contract 标签导出，避免与实际字节码不同步。

## 免责声明

本项目为个人开发者独立运营的早期项目，流动性极小，价格不构成任何投资参考。源码与地址公开，供自行核验，不构成任何形式的投资建议或收益承诺。

License: MIT
