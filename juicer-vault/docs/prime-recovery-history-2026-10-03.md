# PRIME pool recovery: observed history and perfect arbitrage

Periodic replenishment is a reasonable **scenario** for Propeller. Neckwork
shows repeated PRIME sales into pool 143 and an improvement in its inventory.
The fast recent flow, however, is dominated by a finite Treasury DCA. The model
must distinguish that period from earlier sparse flow and from perfect recovery.
Gas remains operator-funded; this comparison concerns swap loss and time spent
waiting to invest.

## What the network history shows

The collection covers **2 September–1 October 2026 UTC**. It contains **1,970
exact reserve/peg observations** on Neckwork's 600-block grid, with no missing
requested grid points and a maximum 26.7-minute sampling gap. Each observation
carries its block hash. Four representative observations, including both sides
of the LP issuance change, are independently checked against Hydration archive
RPC. These are sampled states; activity between two observations is not assumed
constant.

The asset feed returned 12,084 action rows. September 29 hit its 2,750-row page
ceiling, so that entire day is excluded from flow averages. Its reserve snapshots
are complete and remain in the inventory comparison. Wrapping PRIME/aPRIME and
unresolved endpoints are excluded. Endpoint actions are not an exhaustive index
of every pool leg or proof of profitable arbitrage.

| Observed endpoint flow | Before Treasury DCA, September 2–25 | Recent DCA period, five complete days |
| --- | ---: | ---: |
| Mean PRIME sales/day, indexed USD | $8,185 | $135,959 |
| Median daily PRIME sales | $277 | $147,716 |
| Mean PRIME purchases/day | $6,490 | $117,511 |
| Median gap between PRIME sales | 20.9 minutes | 54 seconds |
| p90 gap between PRIME sales | 4.36 hours | 66 seconds |
| Treasury share of sale value | 0% | **98.50%** |

The difference between gross sales and purchases is not reserved capacity for
Propeller. Other buyers compete for replenished PRIME. The timing model below
uses **net changes in both pool reserves**, including that competition.

Representative raw blocks confirm the Treasury's PRIME→HOLLAR pool-143 route
and several buyers' HOLLAR→PRIME pool legs. They do not establish the buyers'
external hedges or profits. A separate HSM arbitrage in the same block is not
evidence that the PRIME trade itself was arbitrage.

Primary sources: [pool 143](https://hydration-explorer.neckwork.net/api/explorer/pool/143),
[exact reserve observations](https://hydration-explorer.neckwork.net/api/explorer/pool/143/snapshots?resolution=grid&stepBlocks=600&fromTs=1790380800&toTs=1790899199&limit=1000),
[first Treasury execution block](https://hydration-explorer.neckwork.net/api/explorer/block/15053860),
and [a subsequent purchase route](https://hydration-explorer.neckwork.net/api/explorer/trade/15211218/3).

## The recent replenishment has a finite budget

[Treasury DCA 37930](https://hydration-explorer.neckwork.net/api/explorer/dca/37930?limit=5)
started on September 26 at 09:41 UTC. It sells **93.396226 PRIME every 27 blocks**,
with a total budget of **943,396.226415 PRIME**, approximately $1m at collection.

The archived response's latest execution is October 2 at 23:30:42 UTC. At that
point, **96.95%** of the input budget had been sold and **28,766.985197 PRIME**
remained before fees. That is about **4.62 hours at the nominal cadence**, assuming
no pauses or top-up; fees reduce the available budget. This is an observation at
collection time, not a promise of the schedule's later state.

An annual model must not repeat this six-day replenishment burst indefinitely.
Use it as an active-DCA case with its finite remaining budget. Retain the earlier
flow as a sparse-flow sensitivity and no refill as an outage case. The earlier
period is not itself a forecast of what will follow the DCA.

## Comparison with perfect arbitrage

To isolate recovery time, hold the executable quote at the original operations
model's block **15,318,402**. Use official stable-swap math, its pool fee and its
original oracle valuation. Perfect recovery restores this same executable state
before each slice with zero additional recovery wait. It does **not** waive the
4bp pool fee or each slice's price impact. Ordinary transaction inclusion time is
outside this idealized timing benchmark.

For historical timing, each observed grid point starts a separate hypothetical
order. The first slice executes immediately. Later slices wait until net PRIME
inventory has increased by at least our cumulative previous PRIME consumption
**and** HOLLAR inventory has fallen by at least our cumulative previous input.
Capacity is counted once within an order. Trials stop at an LP issuance change,
a missing observation longer than one hour or the observation window's end.

| Order and execution | Swap loss at the pinned quote | Median additional recovery time | p90 time |
| --- | ---: | ---: | ---: |
| $8,000, execute immediately | $3.81 | 0 | 0 |
| $8,000, 8 × $1,000, perfect recovery | **$2.78** | **0** | 0 |
| Same slices, recent net-inventory timing | **$2.78, conditional on restoring the same quote** | **3.76 hours** | 10.76 hours |
| Same slices, earlier sparse-flow timing | $2.78, same condition | 38.85 hours | 107.37 hours |
| $40,000, 40 × $1,000, perfect recovery | **$13.88** | **0** | 0 |
| Same slices, recent net-inventory timing | **$13.88, same condition** | **28.67 hours** | 40.80 hours |

Recent $8,000 trials reached the target in **370/401** starts; the other 31 were
censored by the window end or LP issuance change. For $40,000, **212/401** reached
it, with 189 censored. Earlier $8,000 trials reached it in **999/1,569** starts.
The time quantiles include completed trials only and have survivor bias;
censored trials are not zero waits or proof of permanent failure.

Immediate $40,000 execution would cost approximately **$42.84**, but the later
slices exceed the 8bp executable-loss allowance (10bp bound less 2bp margin).
That is a rejected-execution cost comparison, not an available production option.
The $8,000 immediate comparisons fit this mathematical allowance. Native guards
and a fresh executable preview remain necessary.

With $100 slices, recent $8,000 timing is 4.18 hours median, with a conditional
$2.64 swap loss. This saves only another **$0.13** versus $1,000 slices. The full
result includes all six size combinations for both historical periods.

## Is the difference only time?

**Yes in the controlled same-quote comparison:** successful delayed recovery and
perfect recovery pay the same swap cost. Perfect recovery earns earlier because
it removes the wait. For the recent $8,000 / $1,000 case, the median weighted
capital delay costs **$0.016 per 1% annual marginal return**—about $0.088 at 5.5%—
against roughly **$1.04 saved in trading loss**. This measures delayed HOLLAR
deployment, not whole-vault APY. Already-borrowed idle cash and debt borrowed only
when a trade can execute have different carry costs.

**Historical prices do not stay fixed.** During this window the PRIME peg moved,
the pool was imbalanced and other traders consumed liquidity. An $8,000 quote's
median loss against the *stored pool peg* was 89.06bp before the Treasury DCA and
59.27bp afterward; the final historical sample was 22.71bp. Those numbers are
not losses against independently established fair value and must not be booked
as pure fees or slippage. The legacy peg and its convergence explain why the
historical states cannot simply be called fresh copies of the October 2 pin.

The inventory-timing experiment therefore does not prove identical realized
prices, future arbitrage latency or the earlier annual APY. Its value is a
measured replenishment schedule and an explicit ideal benchmark, with price
recovery verified at execution rather than inferred from elapsed time.

## Application to the next APY/keeper comparison

Use four cases: immediate perfect recovery, finite recent DCA with competing
flow, earlier sparse recovery, and no refill. Continue frequent quote and safety
checks; trade a useful slice when its full-route quote is economical. Wait only
when the expected execution saving exceeds the return lost while waiting.

Use $1,000 source slices as a comparison candidate, not a new activated setting.
The current evidence does not justify a fixed four-hour cooldown or a permanent
$136k/day refill budget. Shared limits must apply across all vaults; independent
historical trials cannot each claim the same inventory at the same time.
Calibrating PRIME→crypto and interest-servicing routes remains separate work.

No production contracts, keeper policy or on-chain parameters changed. These
are **reference and timing scenarios**, not another annual contract campaign.
See the [operator-funded-gas analysis](sponsored-gas-swap-costs-2026-10-03.md) for
the existing annual results and their unchanged fill assumptions.

## Evidence and reproduction

[Analysis](evidence/prime-recovery-history-2026-10-03/analysis.json),
[compressed normalized history](evidence/prime-recovery-history-2026-10-03/history.json.gz),
[raw API responses](evidence/prime-recovery-history-2026-10-03/raw-responses.json.gz),
[independent RPC checks](evidence/prime-recovery-history-2026-10-03/rpc-verification.json),
and [manifest](evidence/prime-recovery-history-2026-10-03/manifest.json).
The manifest records input/output hashes and the model's official math dependencies.

```sh
node scripts/propeller/collect-prime-recovery.mjs 2026-09-02 2026-10-02 /tmp/prime-history
HYDRATION_MATH_ROOT=/path/to/sdk/packages node scripts/propeller/analyze-prime-recovery.mjs /tmp/prime-history/history.json propeller-vault/docs/evidence/operations-tuning-three-rounds-2026-10-03/market.json /tmp/prime-analysis.json
node scripts/propeller/verify-prime-history.mjs /tmp/prime-history/history.json /tmp/prime-rpc-check.json
node --test scripts/propeller/analyze-prime-recovery.test.mjs scripts/propeller/tune-operations.test.mjs
```

The collector caches its exact requests; use a new directory for a fresh run.
Live DCA status and historical indexer responses can change. Reproduce the
archived calculation by decompressing `history.json.gz` and using that file as
the analyzer input. Five recovery-accounting tests and nine existing APY-model
tests pass. Original three-round contract campaign artifacts remain unchanged.
