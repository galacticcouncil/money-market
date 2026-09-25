# HOLLAR Peg Stability and Liquidity Requirements

**Historical model, pinned to 22 September 2026.** Its balances and budget
estimates are not live launch limits. See the later
[PRIME validation](prime-pricing-replenishment.md) and
[RC activation gates](release-candidate.md#activation-gates) for current review.

Analysis performed locally on 2026-09-22, without production transactions or
contract changes. See the [current status](README.md) and subsequent
[coupled-arbitrage checkpoint](coupled-liquidity-checkpoint.md) before using these
no-refill stress estimates. These are conditional liquidity budgets, not a guarantee
of the peg or approval to deploy Propeller.

## Conclusions

The earlier work used actual market/HSM balances and limits, but did not model
reserve depletion and peg recovery over time. Raising mint limits is feasible;
**it does not provide stablecoin funding, secondary-market demand, or burn capacity**.

For initial 50/50 ETH/tBTC collateral, target Main plus loop borrowing is about
**4.7868 HOLLAR per dollar of TVL**. Under a planning assumption that 25% of those
HOLLAR subsequently reach the two HSM-linked stable pools:

- A $1m Propeller launch exposes those pools to about **1.197m HOLLAR** of sales.
- Absorbing that entire sale before any intervention, with the terminal sell
  quote still at least $0.99, needs **$4.374m of initially balanced pool TVL**.
  Half is HOLLAR and half is aUSDC/aUSDT at nominal par.
- The separate par-funded budget to retire all that sell inventory is
  **$1.197m**, or **$1.436m with an illustrative 20% funding margin**. This is a
  conservative full-absorption budget, NOT the mathematically minimum amount
  needed merely to touch $0.99. It is additional to pool capital, not the same
  dollars counted twice.
- Current HSM has about **$285k nominal collateral** and an independent
  **283,273 HOLLAR burn ceiling from its outstanding facilitator bucket level**.
  Even an HSM collateral donation alone does not remove the latter restriction.
- The HOLLAR/PRIME entry route is a different bottleneck: for a single complete
  $1m-TVL ramp with a 1% terminal price bound, the hypothetical balanced PRIME
  pool needs about **$26.01m total liquidity**. Staged execution with measured
  PRIME replenishment can reduce that inventory requirement substantially.

The 25% spillover is a sensitivity, not a measured routing forecast. PRIME
purchase already sells the same HOLLAR; do not sum PRIME purchases and subsequent
stable-pool spillover as two independent new HOLLAR issues. A PRIME seller/LP can
retain HOLLAR, sell it later, or buy something else. At 100% spillover the stable
pool/reserve targets below are approximately four times larger; at 10%, 0.4x.

## Current State

Read-only source: `hdx.tarn.hydration.cloud`, finalized block **14900756**, runtime
443, chain timestamp **2026-09-22 09:30:06 UTC**. Hash:
`0xc0f89ce05e34f0b024401fb220c0efc11c79b98a408b8e498281da4f744bae49`.
Observed cadence over the preceding 1,000 blocks is **2.184 seconds/block**;
this is an observation, not a guaranteed future service rate.

| Item | Snapshot |
| --- | ---: |
| HOLLAR ERC20 total supply | 12,664,412 HOLLAR |
| HSM aUSDT | $152,121 nominal |
| HSM aUSDC | $132,978 nominal |
| Total HSM collateral | $285,099 nominal |
| HSM facilitator bucket level, maximum net burn | 283,273 HOLLAR |
| Unused HSM mint ceiling | 17,716,727 HOLLAR |
| Unused money-market mint ceiling | 1,368,862 HOLLAR |
| HSM pool 111 HOLLAR / aUSDT | 1,053,572 / 1,009,153 |
| HSM pool 110 HOLLAR / aUSDC | 924,230 / 858,270 |
| Combined two-pool nominal TVL | $3,845,226 |
| Combined two-pool stable-asset side | $1,867,423 |

Pool 105 additionally holds about $378k of Wormhole USDC/USDT and $226k HOLLAR.
Other HOLLAR pools hold PRIME, yield tokens, EUR exposure, and other assets. They
are not counted as interchangeable funded HSM reserves. The simulation below
isolates pools 110/111; it is not an aggregate executable quote across all venues.

### Usable Depth Is Less Than Inventory

Without intervention, existing per-pool sale capacities before a **post-sale
1-HOLLAR sell quote** breaches the stated floor are:

| Floor | Pool 111 | Pool 110 | Optimally split total | Strict 50/50 total |
| --- | ---: | ---: | ---: | ---: |
| $0.995 | 378,727 H | 313,485 H | 692,212 H | 626,969 H |
| $0.990 | 542,142 H | 454,699 H | 996,842 H | 909,398 H |
| $0.980 | 676,468 H | 570,776 H | 1,247,244 H | 1,141,552 H |

The headline $1.87m stable inventory cannot all exit at approximately $1.
Routing matters: sums require allocation proportional to the two usable depths.
A fixed equal split hits the smaller pool's limit first. Terminal price, not
average fill, is used so a large trade's acceptable average cannot hide a
badly displaced peg afterwards. The probe is fee-inclusive, with micro-dollar
resolution; it is not a perfect derivative of the invariant.

### aTokens Are Not Immediately Redeemable Cash

| Underlying market | Cash held at aToken | Total aToken supply | Pool + HSM aToken holdings |
| --- | ---: | ---: | ---: |
| USDT | $919,891 | $2,200,480 | $1,161,274 |
| USDC | $771,397 | $1,706,629 | $991,249 |

The combined cash is about $1.691m, versus $2.153m of aTokens just in the two
pools and HSM. Cash is shared with all lenders, not reserved for peg defense;
there is already a roughly **$461k difference** under an all-at-once cash
redemption assumption. HSM can transfer aTokens without withdrawing underlying,
but recipients may not value an illiquid aToken at $1. A 2% aToken discount turns
a nominal $0.9995 HOLLAR/aToken quote into about **$0.9795 cash value**, even
before another HOLLAR sale. Stablecoin depegs and bridges introduce additional
risks. The numerical pool targets assume collateral par and redeemability.

## Liquidity Targets

Planning case: initial TVL, full target leverage, 25% eventual stable sell
pressure, equal routing, A=222, 0.02% pool fee, initially balanced pools, no
intervening arbitrage, terminal price at least $0.99.

| Propeller collateral TVL | Stable sell stress | Balanced stable-pool TVL | Stable side of pools | Separate full-absorption reserve |
| --- | ---: | ---: | ---: | ---: |
| $100k | 119,669 H | $437k | $219k | $120k |
| $500k | 598,346 H | $2.187m | $1.093m | $598k |
| $1m | 1,196,691 H | $4.374m | $2.187m | $1.197m |
| $10m | 11,966,912 H | $43.739m | $21.870m | $11.967m |
| $50m | 59,834,559 H | $218.695m | $109.348m | $59.835m |
| $100m | 119,669,118 H | $437.390m | $218.695m | $119.669m |

These are **total funded stocks**, not automatically additions to today's
positions. With current unequal/imbalanced pools, the extra balanced liquidity
needed for the same 50/50 stress is approximately **$0 / $0 / $730k / $40.096m /
$215.052m / $433.747m**, respectively. For $1m TVL that means adding about $365k
of stable assets and $365k HOLLAR, with the computed split between pools.
Adding only HOLLAR worsens the imbalance. LP shares must remain available during
stress; temporary mercenary liquidity is not a committed backstop.

For a $1m launch, target sensitivity is:

| Spillover | Pool TVL at $0.995 floor | At $0.99 | At $0.98 | Par-funded reserve |
| --- | ---: | ---: | ---: | ---: |
| 10% | $2.463m | $1.750m | $1.413m | $479k |
| 25% | $6.157m | $4.374m | $3.533m | $1.197m |
| 100% | $24.626m | $17.496m | $14.132m | $4.787m |

These are two protections: LP inventory absorbs a fast shock, reserve funding
can subsequently replenish pool inventory by buying HOLLAR. If one only needs
to stay inside the band and accepts a permanently imbalanced pool, less reserve
can suffice. Conversely, repeated shocks, existing holders, LP exits and aToken
haircuts need more. A 20% reserve margin is an illustrative policy buffer, not a
statistically calibrated confidence bound.

Today's burn budget could fully absorb the assumed spillover of at most about
**$237k TVL at 25%**, **$592k at 10%**, or **$59k at 100%**, before any allowance
for existing users. These are not launch limits or promises of instantaneous
execution. The entire reserve is shared with the existing 12.66m HOLLAR supply.
A 10%-of-existing-supply run alone is **1.266m HOLLAR**, larger than HSM's current
budget. Add that selected background-run stress to Propeller's budget, not vice
versa. For example, $1m TVL at 25% plus this run implies a **$2.463m par-funded
reserve**, or $2.956m with the illustrative 20% margin, before other risks.

### PRIME Route Depth

Independently, an initially balanced A=100, 0.04%-fee HOLLAR/PRIME pool would need
these totals to absorb a single full target entry and keep its terminal quote
within 1% of the stored PRIME peg:

| Propeller TVL | HOLLAR sold into PRIME | Balanced PRIME-pool total |
| --- | ---: | ---: |
| $100k | 478,676 H | $2.601m |
| $500k | 2,393,382 H | $13.005m |
| $1m | 4,786,765 H | $26.009m |
| $10m | 47,867,647 H | $260.094m |
| $50m | 239,338,235 H | $1.300bn |
| $100m | 478,676,471 H | $2.601bn |

Half is PRIME value and half HOLLAR. These deliberately severe no-refill,
single-ramp stocks are **not necessary if entry is staged and PRIME supply is
replenished**. Size the actual pool against the largest permitted execution
batch plus adverse inventory movement during refill latency. The current PRIME
pool has only about 318,641 PRIME (~$335k) and 735,940 HOLLAR. Its stored peg can
update on-chain; this calculation is not an executable oracle-price guarantee.
Adding liquidity only to stable pools does not solve this route bottleneck.

## Time-Based Stress Results

The model uses official Hydration stable-swap/HSM WASM, integer token ledgers,
actual configuration, and exact individual simulated OCW swaps. It includes
price gates, finite per-collateral holdings, the shared burn bucket, the flash
minter ceiling, and the 1-HOLLAR minimum arbitrage amount. One collateral is
serviced on each alternating block, matching the inspected OCW rotation.
It assumes every eligible candidate succeeds in inclusion; this is optimistic
operationally. Unchanged inactive intervals are skipped, not approximated with
large aggregated swaps. One-block-rounded daily periods sum to 89.999 days.

There are **54 entry/ramp cases**, **18 market-path stresses**, and **13 additional
sensitivities**. Entry ramps distribute sales as daily bursts over 1/7/30 days;
each is observed for 90 days. Daily burst arrival is not continuous execution.
There are no outside buyers, LP replenishment, new HSM mints, collateral yield
accrual, or discretionary governance recovery. aTokens remain at nominal par.

Representative current-funding results at 25% spillover, lower-priced pool:

| TVL / arrival | Worst nominal price | Day-90 price | HOLLAR burned |
| --- | ---: | ---: | ---: |
| $100k, immediate | $0.998846 | $0.998846 | 0 |
| $500k, immediate | $0.995324 | $0.997500 | 210,222 |
| $500k, 7 days | $0.996876 | $0.997500 | 210,226 |
| $1m, immediate | $0.975676 | $0.989534 | 283,259 |
| $1m, 7 days | $0.989435 | $0.989435 | 283,262 |
| $1m, 30 days | $0.989431 | $0.989431 | 283,250 |

Staging helps the transient dip, but persistent cumulative sell pressure still
uses up funding. The $10m-and-larger fixed-liquidity cases exhaust useful pool
depth. Their dust-level quotes in raw output are not forecasts that the global
market trades at those prices: real strategy slippage controls, circuit breakers,
other demand and routes change or stop execution. They establish that these
flows cannot be absorbed by the modeled inventory at the target band.

For the $1m / 25% immediate stress:

- No HSM collateral leaves the nominal quote at $0.975676 throughout.
- Half HSM collateral recovers only to $0.984590.
- Raising mint ceilings alone produces the exact same result as baseline.
- Donating $1.197m collateral without changing burn mechanics reaches only
  $0.989956. It changes per-pool allocation slightly but not the shared budget.
- Hypothetically adding both that collateral and that much usable burn budget
  recovers to $0.99 after about 3.14 hours and eventually to $0.9975. It still
  cannot prevent the initial $0.975676 print. With a seven-day ramp the same
  counterfactual stays above $0.9961. **Extra burn budget is an analytical
  counterfactual, not an existing governance setter or implemented solution.**
- Losing 50% of LP depth before the shock makes the modeled pool unusable near
  par, even though HSM nominal holdings have not changed.
- Sending everything through the USDT side is substantially worse than routing
  across both pools. The idle USDC reserve does not automatically serve USDT.
- A 10%-of-existing-HOLLAR-supply sale, without Propeller, dips to $0.968056 and
  reaches only $0.987337 with present HSM funding in this isolated-pool model.

### Repeated Market-Path Pressure

The 18 additional stresses reuse the earlier 90-day bull/bear/seesaw requested
borrowing paths, 50% exit on day 60, no Main discount, and externally funded
interest/negative carry. They route 25% of **positive** HOLLAR sale flows to
stable pools. They deliberately do not offset these with PRIME-side HOLLAR buys:
those buys support HOLLAR elsewhere but do not necessarily put USDC/USDT into
HSM. This is a conservative one-way funding envelope, not a jointly cleared
market simulation and not a prediction of net HOLLAR issuance.

Per $1m initial collateral, cumulative positive HOLLAR sales are approximately
**7.906m bull / 4.787m bear / 15.680m seesaw**, implying 25% stable-sale stresses
of **1.977m / 1.197m / 3.920m**. Sizing just for initial entry understates repeated
funding needs unless verified reverse flows actually replenish reserves.
Seesaw paths can have high gross turnover even when net debt growth is small.

## HSM Mechanics and Refill Requirements

Current configurations in both pools: buyback rate **0.0001 of imbalance per
block**, fee 0.01%, maximum buy price coefficient **0.998**, maximum holding
$8m per collateral. The max holding and mint ceilings are permissions, not
funding. The runtime buys HOLLAR with collateral using an **exact-output BUY
quote**, then applies the buyback fee. It does not quote an HOLLAR sell. The
older static helper's direction was corrected in this investigation; its old
price-gate estimates must not be used for sizing.

The inspected OCW handles one of the two collaterals each block. At the current
observed cadence and with both pools pushed to the $0.99 band, the theoretical
rotating-OCW rate ceiling is around **2.08m HOLLAR/day**. This is neither demand
nor guaranteed throughput: holdings, bucket level, price gates, inclusion, and
flash capacity still constrain it. Current burn capacity covers only about
**3.3 hours at that particular rate**. Raising the buyback rate can speed a
funded intervention but also spend finite reserves sooner; it cannot make a
cumulative deficit disappear. Current gates stop the sample recovery around
$0.9975 rather than restoring exact $1.

Plan funding over the entire period before external replenishment:

```text
S = stress net HOLLAR sales requiring independent stable buyers
Q = stable-pool depth supporting the allowed instantaneous/pending shock
R = committed, spendable stable funding for absorption over the refill interval

No-intervention balanced A=222 sizing at a $0.99 terminal floor:
Q ~= 3.655 * S

Conservative full retirement of the selected cumulative sell stock:
R ~= S at par, plus the chosen background-run and safety allowances

Continuous operations:
daily reserve refill >= daily absorbed HOLLAR * execution price
and an independently usable HOLLAR burn/retirement path must remain available
```

Do not credit the same stablecoins to LP reserves and HSM simultaneously. A
reserve refill via HSM minting brings stable collateral in **and creates new
HOLLAR**; it is not an unconditional net reduction of sell pressure. It helps
only if the recipient genuinely wants to hold/use that HOLLAR without
immediately selling it back. Ordinary aToken yield is not a credible refill
source for million-dollar fast redemptions.

HSM's burn calls decrease its own GHO facilitator bucket level. A read-only
`eth_call`, at the pinned block, from the HSM facilitator to `burn(level + 1)`
returned Solidity arithmetic panic `0x11`:
`0x4e487b710000000000000000000000000000000000000000000000000000000000000011`.
No transaction was signed or broadcast. The local GHO source confirms checked
subtraction before burning. Raising `bucketCapacity` does not raise `bucketLevel`.

Before relying on larger treasury-funded intervention, select and test an
actual mechanism: suitably backed HSM issuance with retained external demand,
an independently funded market buyer/holder, or repayment through the market
facilitator against actual eligible debt. Do not assume an arbitrary bucket-level
increase is an available or accounting-correct governance operation. Donations
remain useful where collateral holdings, rather than burn capacity, bind.

## Release Gates

1. Select an explicit downside band, largest sell batch, arrival-rate limit,
   refill horizon, spillover stress and background-holder run. The tables show
   alternatives; 25% spillover has not been validated as the right launch case.
2. Source and commit both stable-pool liquidity and independent cash-equivalent
   reserve funding. Stress LP withdrawal, aToken redemption, USDC/USDT depeg and
   competing lender withdrawals. Protected user ETH/tBTC principal is not this
   reserve.
3. Resolve and fork-test the actual burn/debt-repayment path before counting
   treasury top-ups beyond the HSM's current usable bucket. No production change
   implementing a new path was made here.
4. Stage PRIME entry against executable depth and confirmed refill, not total
   requested TVL or an increased borrowing limit. Monitor the PRIME and stable
   routes separately and stop new borrowing when either funding gate fails.
5. Monitor per-pool quotes at operational batch sizes, liquid stable backing,
   usable burn capacity, reserve depletion rate, aToken cash coverage and OCW
   inclusion. Alert on time-to-exhaustion, not only percentage of mint cap.
6. Couple the peg model to the interest-policy decision. HOLLAR repurchases for
   interest support demand, but are not guaranteed USDC/USDT reserve refill.
   Discount-driven leverage growth must not outrun the committed funding budget.

## Evidence and Reproduction

Files:

- `scripts/propeller/peg-model.mjs`: sizing and stateful stress.
- `scripts/propeller/peg-model.test.mjs`: 17 focused tests.
- `scripts/propeller/market-snapshot.mjs`: read-only balances, configuration,
  HOLLAR supply, observed block cadence, aToken underlying cash.
- `/tmp/propeller-peg-snapshot-20260922.json`: pinned inputs, SHA-256
  `a79ba33ba6fc63da3b71e59e7541551fb7a461c7310ce24a5894ebee5732a354`.
- `/tmp/propeller-peg-results-20260922.json`: all sizing rows, daily states,
  assumptions, dependency versions and WASM hashes.

```sh
HYDRATION_MATH_ROOT=/home/mrq/git/sdk/packages \
  node scripts/propeller/peg-model.mjs \
  /tmp/propeller-peg-snapshot-20260922.json \
  /tmp/propeller-peg-results-20260922.json

HYDRATION_MATH_ROOT=/home/mrq/git/sdk/packages \
PROPELLER_MARKET_SNAPSHOT=/tmp/propeller-peg-snapshot-20260922.json \
  node scripts/propeller/peg-model.test.mjs
```

Verification: 17 peg-model tests, eight pressure-model tests, and 21 interest
policy tests pass against the fresh snapshot. Exact integer identities track
HOLLAR entering pools versus final inventory plus burns, and stable collateral
across pool/HSM balances, seller receipts and arbitrage profits. No hidden
reserve creation, negative holdings, or burn overspend is permitted. This is
not a new Chopsticks peg-defense execution test or a repeat of contract tests.

The runtime source examined is clean at Hydration commit
`5165420990b3a0f39dff14a7344a6cd5ebe460ac`; HOLLAR source is clean at
`f41be9d54a5f06693ee524cc909982b26e2ae1eb`. This records the inspected local
source, not proof that every line matches deployed runtime 443. Relevant source:
`pallets/hsm/src/lib.rs` (`do_trade_hollar_in`, `calculate_ideal_trade_size`,
`process_arbitrage_opportunities`, flash-loan execution), `math/src/hsm/math.rs`,
and `src/contracts/gho/UpgradeableGhoToken.sol:59` in the HOLLAR repository.
Official documentation independently describes asymmetric HSM support and
explicitly does not guarantee the peg:
[Hydration HOLLAR](https://docs.hydration.net/products/hollar/).

Not modeled: global order flow or optimized inter-pool arbitrage, issuer PRIME
subscriptions/redemptions, circuit breakers, endogenous borrowing/repayment,
cash withdrawals, actual peg-source updates, flash gas/inclusion failures,
cross-chain latency, insolvency, or a native runtime emergency deployment.
Huge-capital rows are counterfactuals beyond today's reserve/mint/holding limits.
