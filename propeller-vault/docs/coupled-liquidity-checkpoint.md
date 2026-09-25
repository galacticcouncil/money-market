# Coupled Liquidity Research Checkpoint

**Historical research checkpoint.** The later [PRIME validation](prime-pricing-replenishment.md)
adds pricing and replenishment evidence but does not establish a committed
provider or finish the calibrated launch-capacity campaign. See [RC1](release-candidate.md).

2026-09-22. **The full recalibrated six-TVL campaign is unfinished.** These are
public observations, preliminary simulations and model infrastructure, not a
production liquidity requirement or approved launch capacity. No production
transactions were sent. See the [resource index](README.md) for release gates.

## What the Model Adds

The [coupled model](../../scripts/propeller/coupled-peg-model.mjs) tracks inventory
in the PRIME/HOLLAR and stable pools, finite prefunded market-maker assets,
cross-pool arbitrage, delayed PRIME/stable settlement, finite independent HOLLAR
buyers, HSM collateral and its facilitator bucket, and shared money-market cash.
Arbitrage moves existing HOLLAR; it does not create an independent buyer or
unlimited USDC. Raising a mint cap creates permission, not funding.

Each accepted trade changes inventory. Entry/exit guards queue unavailable flow
instead of assuming execution. Token-conservation assertions cover external
mint/burn and settlement, plus explicit LP withdrawal stress. Unit tests cover
arbitrage and settlement outages, shared cash exhaustion, independent PRIME fair
value versus the oracle execution guard, LP withdrawals and entry-only pauses.

## Pinned Market

[Hydration snapshot](../../scripts/propeller/fixtures/market-20260922.json):
block 14900756, runtime 443, 2026-09-22 09:30:06 UTC, read through `hdx.tarn`.
SHA-256: `a79ba33ba6fc63da3b71e59e7541551fb7a461c7310ce24a5894ebee5732a354`.

- HOLLAR supply: approximately 12.664m.
- HSM nominal aToken holdings: $285,099. Its facilitator level permits only
  283,273 HOLLAR of net burns; collateral donations or a larger ceiling alone
  do not replenish that burn budget.
- Shared USDC/USDT money-market cash: approximately $1.691m against $2.153m
  of relevant aToken pool/HSM claims. Do not count all aTokens as independent
  immediately withdrawable cash.
- PRIME pool: approximately 318,641 PRIME and 735,940 HOLLAR; stored PRIME
  peg/oracle reference 1.0505.
- Initial target exposure at the modeled leverage and 50/50 ETH/tBTC split:
  4.7868 HOLLAR per collateral dollar. A $1m, 30-day ramp requests approximately
  159,559 HOLLAR/day of PRIME purchases, before market-path changes.

## Canonical Neckwork Calibration

[Derived calibration](evidence/2026-09-22/neckwork-calibration.json) uses the
canonical [pool API](https://hydration-explorer.neckwork.net/api/explorer/pool/143),
not the older Shellfish deployment. The collector retrieves dedicated pool
history, candles and economic actions; generic account history is only a
cross-check because it can omit ERC20/aToken balances.

August 23 through September 21 (30 complete days):

| Observation | Result |
| --- | ---: |
| Classified PRIME endpoint actions | 1,076 |
| Wrapper conversions excluded | 33 |
| Unresolved actions excluded | 5 |
| PRIME sold | 245,848 PRIME |
| Average daily PRIME sale value | $8,635 |
| Median daily sale value | $339 |
| p90 daily sale value | $27,713 |
| Maximum daily sale value | $129,002 |
| Average daily PRIME purchase value | $10,504 |
| Median / p90 inter-trade gap | 6.2 / 127 minutes |
| p90 gap between actions at least $1,000 | 4.51 hours |

These are **observed endpoint flows, not committed replenishment capacity or
identified arbitrage latency**. Only the sampled largest routes were inspected;
not every action is proven to be arbitrage or attributed across all route legs.
Daily reserve changes combine trades, LP actions and transfers. Upstream sampled
series can forward-fill missing buckets and do not expose exact block identities.
Unchanged LP issuance cannot exclude offsetting intraday liquidity changes.

The 90-day candle window has 2,153 of 2,160 closed hourly PRIME observations;
the last 30 days have all 720. Missing aToken candles are recorded, not replaced
with zeros. The derived artifact records coverage and the raw collection hash;
the 8.1 MB raw response remains local at
`/tmp/propeller-neckwork-canonical-history-20260922.json`. Recollecting may yield
different historical data or coverage. [Neckwork issue #6](https://github.com/1xGiraffe/hydration-neckwork/issues/6)
requests bounded reserve snapshots and provenance through MCP.

## PRIME Reference Discrepancy

The [independent Solana read](evidence/2026-09-22/prime-reference.json), taken at
11:44:41 UTC, reports **1.0606553548682192 wYLDS/PRIME**, finalized slot 449369007.
Its update was 514 seconds old against a 3,600-second freshness limit. The
[Hydration recheck](evidence/2026-09-22/prime-hydration-reference.json) at block
14904279 still reported **1.0505** from the configured ManagedOracle.

The roughly 0.97% reference difference must be separated from swap slippage.
At a hypothetical 1% oracle-relative entry limit, most of the allowance could
be consumed before fees or replenishment costs. The model now has separate
`primeFairPrice` and oracle-guard valuation; changing the former does not relax
the latter. This is not a recommendation to widen the production guard.

The independent feed is **wYLDS NAV, not an executable USDC quote**. It does not
establish issuer redemption cash, bridge latency, pause status or executable
size. See the [official Hastra integration guide](https://help.hastra.io/35f2339356548002a00ef2e113e44090)
and [price-account implementation](https://github.com/provenance-io/hastra-sol-vault/blob/main/programs/vault-stake/src/state.rs).
The price-read helper is a research collector, not a production oracle.

## Preliminary Coupled Runs

Both archived runs below use $1m TVL, a 30-day entry ramp, 90 simulated days,
$500k maker capital, $1m/day PRIME settlement capacity, six-hour settlement,
five-minute ticks and a 1% oracle-relative execution guard. They assume PRIME
acquisition at the Hydration oracle and **predate the independent fair-price
correction**. Replenishment and buyer funding are assumptions, not commitments.

| Result | No additional buyers | Independently funded buyers |
| --- | ---: | ---: |
| Planned borrowing filled | 25.6% | 100% by day 30 |
| Final borrowing | $1.225m | $4.787m |
| Unexecuted target demand | $3.562m | $0 |
| Independent buyer spending | $0 | $4.664m |
| HOLLAR retained by buyers | $0 | 4.669m |
| Minimum sampled stable quote | $0.99335 | $0.99855 |
| HSM burns | 283,270 HOLLAR | 0 |
| Remaining shared MM cash | $0.589m | $1.499m |

Archived outputs: [no-buyers run](evidence/2026-09-22/coupled-no-buyers.json),
[funded-buyers run](evidence/2026-09-22/coupled-funded-buyers.json).
Prices partly remain close to peg because entry stops at its execution guard;
that is not evidence that the planned TVL can enter. The funded scenario needs
millions of independent buyer dollars, not just repeated arbitrage turnover.
The earlier approximately $26m PRIME-pool estimate was a no-refill stress case,
not a normal-operation minimum.

## Reproduction and Limits

Run from the repository root with Node.js 22+ and the Hydration SDK math packages
available. The recorded runs used `math-stableswap` 2.5.0 and `math-hsm` 1.2.0;
the output includes their WASM hashes. Set `HYDRATION_MATH_ROOT` to your SDK
`packages` directory. On the analysis machine it is `/home/mrq/git/sdk/packages`.

```sh
HYDRATION_MATH_ROOT=/path/to/sdk/packages \
PROPELLER_MARKET_SNAPSHOT=scripts/propeller/fixtures/market-20260922.json \
  node --test scripts/propeller/*.test.mjs

HYDRATION_MATH_ROOT=/path/to/sdk/packages \
COUPLED_OPTIONS='{"tvl":1000000,"days":90,"buyerCoverage":1,"primeFairPrice":1.0606553548682192}' \
  node scripts/propeller/coupled-peg-model.mjs \
  scripts/propeller/fixtures/market-20260922.json /tmp/coupled-case.json

node scripts/propeller/neckwork-pool-history.mjs \
  scripts/propeller/fixtures/market-20260922.json /tmp/neckwork-history.json
node scripts/propeller/neckwork-calibration.mjs /tmp/neckwork-history.json \
  scripts/propeller/fixtures/market-20260922.json /tmp/neckwork-calibration.json
node scripts/propeller/prime-reference.mjs /tmp/prime-reference.json
```

The example fair-price scenario is a sensitivity input, not a completed or
approved result. RPC collectors need network access; model tests use the fixture.
The native rehearsal script uses public development accounts on a fixed localhost
endpoint and requires its prior fork setup; it is not a production deployer.

Remaining analysis work:

1. Run all six requested TVLs ($100k, $500k, $1m, $10m, $50m, $100m), 50/50
   ETH/tBTC, bull/bear/seesaw over 90 days with separately justified fair price,
   observed-flow sensitivities and explicit funding assumptions.
2. Cross-check timestep convergence and outages, LP withdrawals, external lender
   cash withdrawals, emergency pauses and exits. A coarse hourly benchmark is
   not proof of equivalent five-minute behavior.
3. Validate HSM premium-side sizing against native execution; the current
   premium-mint candidate uses an approximate terminal-price probe. Integer
   conservation is not proof of executable HSM parity.
4. Integrate or explicitly reconcile Main/loop interest, actual Aave health
   factors, changing pegs/NAV and recovery budgets with the separate interest
   and contract models. The coupled model alone is not a 90-day APY or
   liquidation-engine simulation.
5. Obtain real settlement/backstop commitments and production adapter evidence
   before converting scenario results into launch caps or liquidity budgets.
