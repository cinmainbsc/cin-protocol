# 可核验清单

这份文件只回答一个问题：**外人能自己查到什么。**

## 现在就能查到的

| 项 | 怎么查 | 现值 |
|---|---|---|
| 总供应量 | `totalSupply()` | 348,727,845.43 CIN |
| 供应硬顶 | `MAX_SUPPLY()` 常量 | 21,000,000,000 |
| 增发权归属 | `hasRole(MINTER, 0xed6e…375e)` | 1（由 EmissionCurve 持有） |
| 运营方是否持增发权 | `hasRole(MINTER, 0xb14c…01af)` | 0 |
| 运营方是否持管理员权 | `hasRole(DEFAULT_ADMIN, 0xb14c…01af)` | **1**（可撤销再授予） |
| 持有人总数 | BscScan Holders | **6 个地址**（前 3 占 99.95%） |
| 销毁计数 | Burner `totalCinBurned` | 739,713.157 |
| 回购支出 | Burner `totalPaymentSpent` | 0.7 USDT |
| 执行次数 | Burner `executionCount` | 1 |
| 池子储备 | Pair `getReserves()` | 10,178,042.02 CIN / 8.079136 USDT |
| 池子归属 | Pair `totalSupply()` vs 运营钱包 `balanceOf` | 9,066.257757 / 100% |

## 还没查清的（不掩盖）

1. **供应高度集中：两个单签 EOA 合计持有 97.03%**。operatorCenter `0x8e49…46fb` 持 287,000,000 枚（82.30%），社区钱包 `0xf64a…bf03` 持 51,359,940.46 枚（14.73%），两者均非多签、均无锁仓合约。这是当前最大的结构性风险，不是“未公开”问题——地址已查明，缺的是归属计划与多签改造。
2. `EmissionCurve` 的源码未在 BscScan 验证，其增发曲线无法通过源码复核。字节码实测：含 `mint(address,uint256)` 与 AccessControl，外部地址调用直接 revert，因此不存在任意人增发；其 DEFAULT_ADMIN 也由运营钱包持有。
3. `penaltySink` 目前指向运营钱包，尚未迁至多签。
4. 金库 5,135 万枚的来源与用途未书面说明：链上资金于 2026-11-12 由金库转至社区钱包地址，未注明用途。

以上四项在完成前，不接受任何“机制已完全去信任化”的说法。
