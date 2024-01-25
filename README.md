# DexAggregator

Aggregate DEX pairs on IC, provides trading pair listings and routing, trading pair evaluations, and DEX trading competitions.

## Pair Score (trading pair evaluations)

Pair scoring rule (pair_score = score1 + score2 + score3)

- score1 (max 70)
    - (Not verified) ListingReferrer Propose: +10 per Sponsor
    - Verified ListingReferrer Propose: +15 per Sponsor
    - Sponsored (Sponsors >= 5): +10
- score2 (max 20)
    - Set a score through DAO proposal. Typically, this is scored as 0. Only trading pairs of well-known or special contributing projects will have a score set by the proposal.
- score3
    - (pair_vol_token1_usd / 10000 / max(years, 1)) ^ 0.5 / 2  +  (pair_liquidity_token1_usd / 10000) ^ 0.5 * 2

Upgrade rules

- A new trading pair defaults to STAGE0.
- Upgrade from STAGE0 to STAGE1: pair_score >= 30.
- Upgrade from STAGE1 to STAGE2: pair_score >= 60, for at least one month.

Degrade rules

- Degrade from STAGE2 to STAGE1: pair_score < 50, for at least three months.
- Degrade from STAGE1 to STAGE0: pair_score < 20, for at least three months.

Display of trading pairs in DEX UI

- STAGE0 implies too much unknown risk and it is not recommended to show a list of STAGE0 pairs.
- STAGE1 means that some traders are concerned and need to keep watching the risk.
- STAGE2 means that more traders are concerned and need to keep watching the risk.

## Canisters

**Tools & Dependencies**

- dfx: 0.15.3 (https://github.com/dfinity/sdk/releases/tag/0.15.3)
    - moc: 0.10.3 
- vessel: 0.7.0 (https://github.com/dfinity/vessel/releases/tag/v0.7.0)

**Testnet**

- Canister-id: pwokq-miaaa-aaaak-act6a-cai
- Module hash: ca5aa27c134d03475ef1141e97adfe22b3f06bf425b138b2cf00891e313aaabe
- Version: 0.8.5
- Build: {
    "args": "--compacting-gc"
}

## Disclaimer

Pair Score is an automatic evaluation mechanism of DexAggregator for trading pairs, which is based on the comprehensive evaluation of the number of sponsors, liquidity, volume, etc. It is for your reference only, and is not considered as investment advice.