# CheckedOracles — Hydration production deploy

Four `CheckedOracle`s (see `contracts/CheckedOracle.sol`) fed by the wormhole-direct
receivers, each rejecting pushed prices that stray more than `maxDiffBps` from the
asset's pool day-EMA. Consumers (wired later, by governance): apyUSD + PRIME become
`AaveOracle` sources for the money market; wstETH + jitoSOL become the peg sources of
stablepools 4200 (wstETH/aETH) and 90001 (jitoSOL/aSOL).

## Parameters (pinned in `tasks/misc/deploy-checked-oracles-hydration.ts`)

| | apyUSD | PRIME | wstETH | jitoSOL |
|---|---|---|---|---|
| Artifact | `APYUSD-CheckedOracle` | `PRIME-CheckedOracle` | `WSTETH-CheckedOracle` | `JITOSOL-CheckedOracle` |
| Description | `apyUSD/USD` | `PRIME/USD` | `wstETH/stETH` | `jitoSOL/SOL` |
| Initial price (8 dec, unchecked) | `136723180` | `105050000` | `124030000` | `129240000` |
| Check feed (day-EMA precompile) | `0x…00de0000002e` HOLLAR→apyUSD | `0x…00de0000002b` HOLLAR→PRIME | `0x…0014000f4569` WETH→wstETH | `0x…0f453000000028` SOL→jitoSOL |
| `maxDiffBps` | 100 | 100 | 50 | 75 |
| Pusher | Ethereum receiver `0x6913…1083` | Solana receiver `0x582e…69c3` | Ethereum receiver | Solana receiver |
| Owner | `POOL_ADMIN` = aave-manager `0xaa7e…aa7e0` (all four) | | | |

Initial prices are what each consumer sees today (apyUSD/PRIME: current `AaveOracle`
answers; wstETH/jitoSOL: current peg-source oracles of pools 4200/90001), so the later
source swap is a no-op at the moment of switching.

Band rationale: wstETH/jitoSOL are same-unit rate feeds (max observed feed-vs-EMA
deviation 0.19% / 0.29% over Aug 26–Sep 14, pre live-peg); PRIME and apyUSD have
HOLLAR-quoted anchors, so HOLLAR/USD wobble (observed to −0.74%) passes into the
deviation — hence 100 bps.

## Prerequisites

- Deployer address must be whitelisted in `evmAccounts.contractDeployer`
  (Hydration gates contract creation; otherwise `AddressNotWhitelisted`).
- Deployer funded with WETH for gas.
- Branch compiled once with `SKIP_LOAD=true npx hardhat compile` (generates typechain).

## Run

```bash
npx hardhat deploy-checked-oracles-hydration --network hydration
# subset:
npx hardhat deploy-checked-oracles-hydration --network hydration --only WSTETH,JITOSOL
```

The task deploys via `deploy-checked-oracle` and then prints, per oracle: reported
price, band, pusher, check-feed reading, and `previewSetPrice(<current wormhole feed
value>)`.

## Expected day-one behaviour (as of 2026-09-16)

| | check feed reads | wormhole feed now | previewSetPrice |
|---|---|---|---|
| apyUSD | ~1.371 | ~1.4267 | **REJECT** (+4.1% — structural fair-vs-pool basis; frozen at 1.3672 until the pool closes to <1%) |
| PRIME | ~1.0606 | ~1.0595 (feed fixed Sep 16 03:04 UTC) | **ACCEPT** (−0.09%) — first push steps 1.0505 → ~1.0595 |
| wstETH | ~1.2419 | ~1.2438 | **ACCEPT** (+0.15%) |
| jitoSOL | ~1.2989 | ~1.3011 | **ACCEPT** (+0.17%) — route SOL↔jitoSOL registered Sep 15 |

An apyUSD REJECT and (until the feed is fixed) a PRIME REJECT are the design working,
not misconfiguration.

## Dry-run (chopsticks mainnet fork @ #14,475,106, 2026-09-16)

All four deployed via the task with every post-deploy check passing (`config OK`):
initial price, owner, pusher, check feed, check decimals = 8, band. Previews on the
fork's (≈9-day-old) state behaved as designed — apyUSD REJECT (+395 bps), PRIME REJECT
(+549 bps, feed still broken at that block), wstETH ACCEPT (+14 bps), jitoSOL check
UNAVAILABLE / fail-closed (route not yet registered at that block). Fork deployer
`0x2222…9531` funded + whitelisted via `dev_setStorage` (see `bootstrap-fork.js`).

## After deploy (not part of this task)

1. whm: receiver `assetId → oracle` mappings re-pointed to the four new addresses
   (receiver owner action).
2. Governance: `AaveOracle.setAssetSources` for apyUSD + PRIME; stableswap peg-source
   updates for pools 4200 + 90001. Chopsticks dry-run each.
3. Alerting on `checkPrice()`-vs-feed divergence (>150 bps) and on oracle staleness.
