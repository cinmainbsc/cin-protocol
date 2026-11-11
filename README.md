# CIN — On-chain Fee Split Protocol

CIN is a BEP-20 token deployed on BNB Smart Chain with a hard cap of 21,000,000,000 CIN and a current supply of 350,000,000 CIN. Every transaction fee is
split inside the contract on each trade; the receiver split is readable on-chain and
verifiable on BscScan. Minting is restricted to the emission contract at 0xed6e...375e; the operator account holds neither MINTER_ROLE nor DEFAULT_ADMIN_ROLE, so it cannot mint or revoke. No team allocation, no unlock schedule.

## Deployed contracts (BNB Smart Chain mainnet)

| Contract | Address |
|---|---|
| CINToken (BEP-20, verified) | `0x49ba7945105bc55b75a87522132040a1c2ac33b4` |
| CINMiningVault (LP staking) | `0x72DA093081377b679bF27A32Aaf091F9Ee7949E9` |
| BuybackBurner | `0x701c908a4a914cb8762774d2cc93ef7b8d375fa1` |
| CIN/USDT Pair (PancakeSwap V2) | `0x9b733b0f0a8828cdf5d52c3de49ddad3db108d03` |

- Current supply: 350,000,000 CIN (hard cap 21,000,000,000)
- Buy / sell fee: 600 bps (6%)
- Compiler: Solidity 0.8.20, optimizer 200 runs, MIT — verified as Exact Match on BscScan

## Mechanics

**Fee split.** On every buy and sell, the 6% fee is split by the contract itself:
10% to the buyback-and-burn reserve, 50% to the LP reward pool, 20% to the referral pool,
20% to the community treasury. All four destinations are ordinary addresses and can be
inspected on BscScan.

**LP mining vault.** Users stake CIN/USDT LP tokens for 0, 30 or 90 days at 0.60x, 1.00x
and 1.50x weight multipliers, and earn a proportional share of the LP reward pool. Rewards
are funded by the 50% fee slice — no new tokens are minted. Early exit applies a 30% penalty
on unclaimed rewards only; principal is returned in full, and the penalty goes back into the
liquidity pool.

## Official channels

- Website: https://cinmain.online
- X: https://x.com/cinmainbsc
- Email: admin@cinmain.online
- Whitepaper: https://cinmain.online/whitepaper.pdf

## Repository layout

```
contracts/CIN_Protocol_Remix.sol   # flattened single-file build used for the mainnet deploy
contracts/MiningVault.sol          # LP staking vault (standalone source)
```

The flattened file is the exact source submitted to BscScan for verification.

## Disclaimer

This repository documents a deployed smart contract for transparency purposes. It is not
investment advice, and it makes no promise of return.

---

# CIN 链上分账协议（中文）

BNB Smart Chain 上的 BEP-20 代币，硬顶 21,000,000,000 枚，当前供应 350,000,000 枚。
每笔交易的手续费由合约在链上直接拆分，去向可逐笔在 BscScan 核对。

增发权限只授予排放合约 `0xed6ebf9a22896d65b0e5ab54bc292d35d6da375e`，按合约内写定的曲线执行；
运营账户既不持有 MINTER_ROLE，也不持有 DEFAULT_ADMIN_ROLE，因此无法增发、也无法撤销该授权。
除此之外无团队预留、无解锁计划。

- 当前供应 350,000,000 枚（硬顶 21,000,000,000 枚）
- 买卖税 6%，四向拆分：10% 回购销毁储备 / 50% LP 奖励池 / 20% 推荐池 / 20% 社区金库
- LP 矿机零增发：质押 CIN/USDT LP，0 / 30 / 90 天三档，权重 0.60 / 1.00 / 1.50 倍
- 提前退出仅对未领收益罚没 30%，本金全额返还，罚没全部回到流动性池

官网 https://cinmain.online · X https://x.com/cinmainbsc · 邮箱 admin@cinmain.online

本仓库仅用于公开已部署合约以供核验，不构成投资建议。
