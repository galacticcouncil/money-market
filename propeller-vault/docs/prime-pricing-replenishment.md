# PRIME Pricing and Replenishment Validation

2026-09-23, read-only production observations. This is evidence for
[RC1](release-candidate.md), not authorization to change an oracle, fund a trader,
open deposits or promise a redemption time. [Raw evidence and hashes](evidence/prime-validation-2026-09-23/summary.json).

## Pricing Result

At finalized Hydration block **14,939,389**, via `hdx.tarn`, Aave and pool 143
still use the manual PRIME source at **$1.0505**, last updated July 31.
The Hastra Solana reference was **1.060818912277193 wYLDS/PRIME**, observed at
a finalized slot with age below its 3,600-second limit. That is approximately
0.982% above the manual price, assuming wYLDS can be acquired for one USDC.
The staking vault's wYLDS/supply ratio was **1.06084667**, independently close
to the configured exchange rate. Neither observation proves off-chain solvency
or a guaranteed USD exit.

The earlier report's candidate address is superseded:

| Role                            | Address                                      | Observed value | Status                                                      |
| ------------------------------- | -------------------------------------------- | -------------: | ----------------------------------------------------------- |
| Active Aave and pool-143 source | `0xDEe587cC569bf1FcBdcD6d1472031d225f34C307` |     1.05050000 | Manual, about 54 days old                                   |
| Old Wormhole candidate          | `0x6e3E9403Cf486af5f2cE0A6b3d7a23ee0e6BC84e` |     1.05967921 | Superseded receiver target, about 6.5 days old              |
| Live receiver target            | `0x09221057Cf7E75953D199FB319E606972A6A82Cd` |     1.06080381 | Replacement checked oracle; not wired into Aave or pool 143 |
| One-day PRIME/HOLLAR EMA        | `0x000001040000000000000000000000de0000002b` |     1.06105730 | Guard input, not independent redemption NAV                 |

The replacement's live getters identify a **100 bp write-time deviation guard**,
the one-day EMA check feed and the receiver as price pusher. Governance owns it.
`previewSetPrice` accepts the measured Hastra price and rejects the obsolete
Scope-190 value near **1.00013125**, which differs by roughly 574 bp from its
check price. Do not restore the obsolete Scope path merely because its timestamps
are fresh. The current receiver mapping and replacement history are the relevant
starting points, not the old Garden deployment addresses.

The replacement's last accepted update was about **1.94 hours** old at the pinned
Hydration block. The 20 observed updates, rounds 6 through 25, were normally
about six hours apart, with a maximum interval of 41,322 seconds (11.48 hours).
This bounded history is not a forward service-level commitment. Review source provenance,
observation-time versus relay-time freshness, outage handling and independent
bytecode verification before approving it. This task read getters and previews;
it did not audit or deploy the oracle implementation or prove its complete
Solana-to-Hydration message path.

## Minting and Redemption

The [official integration guide](https://help.hastra.io/35f2339356548002a00ef2e113e44090)
describes USDC-to-wYLDS minting, PRIME conversion at its stored rate, and a separate
operator-mediated wYLDS-to-USDC redemption process. We also inspected
[Hastra source at `31bfa206`](https://github.com/provenance-io/hastra-sol-vault/tree/31bfa2066534f210e72158d98ff5372eb7b630c5).
The collector validates account owners, discriminators, mints and account layouts;
it does not reproduce deployed Solana program binaries or submit transactions.

Observed live state:

- Mint and staking pause flags are false; observed vault token accounts are not frozen.
- About **129.614m wYLDS** backs **122.180m PRIME** in the Solana stake vault.
  That covers about **129.611m wYLDS** of claims at the stored rate.
- The USDC redemption vault holds **729,596.91 USDC**, versus **825,233.32 wYLDS**
  across nine outstanding request accounts. The nominal difference is **95,636.41**.
  Requests and cash were read a few slots apart, and requests may be stale or
  unexecutable. This is not a solvency conclusion, but the cash is not an
  unencumbered Propeller reserve.
- The USDC deposit vault held zero. Deposits bring their own USDC, so this does
  not by itself block minting or demonstrate missing backing.
- The deprecated `unbondingPeriod` field still contains **86,400**. Current
  source treats it as unused, while the integration guide says zero. Do not infer
  live redemption latency from that field alone; confirm the deployed version
  and an actual end-to-end operational redemption before relying on immediacy.

No mint/redeem, relay, bridge or treasury transaction was submitted. Funding
commitments, withdrawal service levels and off-chain reserve attestations remain
outside what these chain reads establish.

## Bridging

The live Solana PRIME NTT is unpaused and in locking mode. Its custody account
holds about **9.177m PRIME**. The outbound limiter is **449,016.984704 PRIME**,
fully available at the snapshot, with a 24-hour refill period. This supersedes
the 100,000 PRIME value in the older local deployment JSON.

The Hydration manager is also unpaused and bound to asset 43, with a much larger
inbound limit. Asset provenance matches the Solana PRIME mint. Solana is therefore
the smaller observed immediate-release limiter in this direction. Above-limit
transfers can queue for 24 hours; **this is not a hard maximum daily throughput**.
Backflows also replenish capacity. Shared users, bridge execution, funding and
the destination market still matter. Locked custody is backing for circulating
bridged tokens, not free inventory to count again as trader replenishment.

## Observed Replenishment

Canonical Neckwork, **August 24 through September 22**: 1,100 activity records,
fully paginated; 1,060 classified economic actions after excluding 35 wrapper
conversions and five unresolved records. These are PRIME endpoint trades, not
a complete attribution of every pool leg or proof that each seller is an arbitrageur.

| Measure                           |                    Result |
| --------------------------------- | ------------------------: |
| Mean gross PRIME sales            |             $7,724.74/day |
| Median gross PRIME sales          |               $312.27/day |
| p90 daily gross sales             |            $12,804.26/day |
| Largest day                       |               $129,002.37 |
| Days with less than $1,000 sales  |                  22 of 30 |
| PRIME sold / bought               |   219,794.26 / 232,658.86 |
| Net PRIME sold                    |      **-12,864.60 PRIME** |
| Largest gap without a $1,000 sell | Approximately 166.4 hours |

The largest seller represents about 55.5% of gross sales. Frequent tiny trades
do not establish a continuous large-order refill service. The negative net
endpoint flow also means gross turnover cannot be used as net inventory creation.
Historical gaps are observations, not measured arbitrage response times.

The indexer returned all 720 recent closed hourly candles but only 2,153 of 2,160
requested 90-day points. Three aToken daily-candle endpoints returned 404; those
missing series are recorded, not fabricated. Sampled pool reserve history can
be forward-filled and is not an exact funding-flow ledger.

## Refill Economics

Using official SDK math, the measured Hastra mint rate and the pinned
PRIME-to-HOLLAR pool 143 followed by HOLLAR-to-aUSDC pool 110:

| PRIME sold | Current-peg gross edge | After hypothetical full peg update |
| ---------: | ---------------------: | ---------------------------------: |
|      1,000 |               -9.50 bp |                          +86.79 bp |
|     10,000 |              -13.73 bp |                          +82.55 bp |
|     50,000 |              -30.68 bp |                          +65.57 bp |
|    100,000 |              -48.74 bp |                          +47.43 bp |
|    150,000 |              -64.65 bp |                          +31.40 bp |

These include AMM fees but exclude gas, bridging, inventory/settlement costs,
concurrent trades and HSM reactions. aUSDC withdrawal also needs shared Aave USDC
cash, about **958k USDC** in this snapshot. They are hypothetical isolated fills,
not transactions or a complete optimal-arbitrage model. Still, the current
negative edge explains why we cannot assume traders will replenish inventory to
the desired balance just because the pool is actively traded.

The additional PRIME sale needed for the **next 1,000 HOLLAR entry** to pass:

| Oracle and peg            |   100 bp floor |     50 bp floor |      25 bp floor |
| ------------------------- | -------------: | --------------: | ---------------: |
| Current                   | 4,352.73 PRIME | 82,772.00 PRIME | 138,076.92 PRIME |
| Both updated to reference | 2,197.88 PRIME | 80,094.43 PRIME | 135,030.71 PRIME |

Displayed amounts round upwards; native-unit thresholds are in the evidence.
These are one-shot inventory sensitivities, not a request to subsidize the
current negative-edge trade. Updating only Aave's oracle does not update the
pool's stored peg immediately. Its live `maxPegUpdate` is 40 parts per billion
per block; convergence is gradual, and must be tested with intervening trades.

## Launch Requirements

For a 50/50 ETH-tBTC, 30-day ramp to the modeled target leverage:

| Collateral TVL | Gross HOLLAR-to-PRIME demand per day | Multiple of observed mean gross sales |
| -------------: | -----------------------------------: | ------------------------------------: |
|          $100k |                              $15,956 |                                  2.1x |
|          $500k |                              $79,779 |                                 10.3x |
|            $1m |                             $159,559 |                                 20.7x |
|           $10m |                           $1,595,588 |                                206.6x |
|           $50m |                           $7,977,941 |                              1,032.8x |
|          $100m |                          $15,955,882 |                              2,065.6x |

This is requested deployment flow, not approved capacity or money creation
without consequences. The $1m case needs about 150,411 PRIME/day plus funded
inventory across settlement delays. Existing market users compete for capacity.

Before opening deposits:

1. Approve and wire the correct checked reference, retaining the separation
   between a fair-value price and market-relative swap protection. Validate
   source identity, units, freshness, outage behavior and governance powers.
2. Replay peg convergence and real refill trades on a fresh `hdx.tarn` fork.
   Requote after inventory changes; do not widen floors to force success.
3. Obtain a funded provider plan: committed PRIME/day, maximum net size, two-way
   spread, bridge/USDC settlement limits and outage response. Alternatively use
   explicitly funded protocol inventory with the same budgets. No provider
   commitment was verified in this investigation.
4. Bound admission/ramp and harvest sizes to those executable budgets, preserve
   principal claims during shortfalls and keep a funded governance recovery plan.

**Conclusion:** the reference rate and mint/bridge infrastructure are substantially
validated. Production oracle wiring and dependable, funded replenishment remain
open gates. Neither a fresh reference nor historical arbitrage proves launch
capacity.
