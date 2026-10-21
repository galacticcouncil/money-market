# Propeller operation costs: three rounds of APY tuning

The best tested configuration earns **3.46% ETH / 3.65% BTC** in funded crypto
after direct operating costs, compared with **3.21% / 3.35%** for the recalibrated
baseline. These are first-year results for **one isolated $10,000 vault**, with
flat crypto prices and externally replenished liquidity. Shared infrastructure
and final withdrawal costs are shown separately below. They are conditional
model results, not a production APY forecast.

All three sequential rounds and the final stress campaign completed:
**64 successful contract scenarios, 24,090 simulated days**. The production
contracts, keeper and mainnet parameters are unchanged. This updates the
[historical five-round model](mainnet-tuning-five-rounds-2026-10-02.md) for the
[execution controller and economical keeper](execution-controls-implementation.md).

The [summary](evidence/operations-tuning-three-rounds-2026-10-03/summary.json),
[complete comparison](evidence/operations-tuning-three-rounds-2026-10-03/comparison.csv)
and [manifest](evidence/operations-tuning-three-rounds-2026-10-03/manifest.json)
contain the inputs, scores, checks and evidence hashes. Each round inherits the
actual preceding winner; the inherited case remains in the next comparison.

## What the updated model charges

The harness runs actual Propeller accounting, Main debt, yield ownership,
Harvester and ExecutionController contracts. Mocked market boundaries accrue
income and both debts hourly. Actual controlled actions enforce deposit and
harvest limits, shared directional budgets, minimums, quote freshness and output
floors. No income donation, entry sponsorship, discount or recovery funding is
introduced. A tiny fixture rounding reserve is excluded from income.

| Cost | Treatment |
| --- | --- |
| Main and source interest | Accrues on actual outstanding debts in the simulation |
| Source entry / unwind | 5bp / 7bp fills; charged through execution |
| PRIME to crypto and Main-interest servicing | ETH 60bp / BTC 100bp all-in route loss on each actual swap |
| Protocol fees | Existing 5% policy; no discount or fee waiver |
| Controlled deposits | Every admitted tranche plus one token approval |
| Harvest | Every productive harvest, plus the additional Main-servicing route when present |
| Maintenance | Productive ramps, rebalances, settlements, peg top-ups and safety calls only |
| Failed or racing keeper writes | Additional expected 1% of productive keeper gas, at full action allowance |
| Claim | One backed-yield claim allowance when crypto has been earned |
| RPCs, monitoring and two operators | Explicit $0 / $50 / $200 **total deployment per month** sensitivities |
| Deployment and policy renewal | Separate shared allowances: 100M gas once and 1M gas/month |
| Final withdrawal | Separate illustrative source trading and multi-transaction gas estimate |

Trading losses already reduce simulated wealth; they are not subtracted again
from the score. `executionAndMarkLossUsd` reconciles income, both debts, retained
equity, protocol receipts and funded crypto. In the PRIME-price shock it also
includes the valuation loss. Unconverted user and protocol carry are separate;
protocol carry never increases the user's score.

The model counts useful writes rather than charging daily successful no-ops.
Read-only previews and safety checks spend no chain gas, but their infrastructure
cost is part of the shared monthly scenarios. A $0 scenario means those services
are sponsored. None of these budgets is a quote from an operator or RPC provider.
Costs are deducted as a USD-equivalent burden at the horizon; the contracts do
not automatically deduct keeper bills from collateral, and periodic funding of
the bill is not simulated as capital leaving the position.

## Inputs and gas calibration

| Input | Value |
| --- | --- |
| Finalized Hydration market pin | Block 15,318,402, runtime 447 |
| PRIME effective APY | 5.6159% |
| PRIME Aave supply APR | 0.035760% |
| Combined modeled hourly accrual, annualized | 5.499652% |
| HOLLAR variable borrow APR | 4.401689% |
| ETH / tBTC LTV | 75% / 80% |
| PRIME oracle price | $1.06248121 |
| ETH / tBTC oracle price | $2,658.214563 / $84,389.270198 |
| Gas-price observation | 4,607,027 wei at block 15,318,481 |
| Source target / deployment HF | 1.05 / 1.05; unchanged |
| Crypto swap floor | 100bp maximum deviation; unchanged |

Hastra's PRIME-specific effective APY is backward-looking NAV growth, already
net of its fee and including wYLDS income. It is converted to an equivalent
hourly rate; only separate Aave PRIME income is added. Sources:
[Hastra methodology](https://help.hastra.io/prime/what-is-prime-(staked-wylds)) and
[public feed](https://hastra.io/hastra-pulse/public/api/v1/por). Direct ETH/tBTC
Aave supply income is excluded. PRIME NAV growth is represented by equivalent
aPRIME value growth at the mock boundary; this does not reproduce live NAV feeds.

The model charges gas allowances, not Foundry test gas. It uses the
[native execution receipts](evidence/execution-controls-2026-10-03/native-controls.json)
for the controlled deposit and harvest anchors. The measured harvest involved
two primary collateral routes and **no Main-servicing leg**. Charging that whole
allowance to each isolated modeled vault is conservative; it is not a measured
one-vault all-path ceiling.
The controlled deposit anchor is ETH; the same allowance is a provisional
budget for BTC rather than a separately measured controlled BTC receipt.

| Action | Gas allowance | Basis |
| --- | ---: | --- |
| Controlled deposit | 4,109,528 | Native estimate allowance; receipt 2,945,947 |
| Harvest before Main servicing | 8,193,855 | Native estimate allowance; receipt 6,161,900 |
| Additional Main-servicing route | 3,000,000 | Provisional budget |
| Controlled ramp / rebalance | 4,000,000 / 4,500,000 | Provisional budgets |
| Safety repayment / scheduling | 2,000,000 / 300,000 | Provisional budgets |
| Peg / settlement | 800,000 / 1,400,000 | Rounded maintenance budgets |
| Approval / yield claim | 150,000 / 1,000,000 | Provisional budgets |

Allowances already contain estimation headroom. The separate fee-quote margin
is 20%, giving about **$0.01470 per million allowance gas** at the pinned prices.
A modeled harvest with Main servicing therefore costs about **$0.1645**.
The fivefold gas-price stress changes cost and keeper decisions; it does not
relax or multiply the native per-transaction gas cap. These provisional productive
paths, especially a controlled harvest with Main servicing, still need native
receipt calibration before fixing a production budget.

The new read-only native probe found zero productive work in its existing fork
state. Its ramp and rebalance call bounds are recorded, but they are **not** used
as productive-action estimates. No mainnet transaction or local state override
was used by that probe.

## Three rounds

The objective is funded crypto after direct operations, averaged across the
isolated ETH and BTC cases. A candidate cannot win with a backing deficit,
HF below one, incomplete admission, missing asset case or changed fee/discount
policy. This is a tested parameter search, not a claim of a global optimum.

| Round | Result retained for the next round | ETH | BTC |
| --- | --- | ---: | ---: |
| 1: harvest threshold | 25bp beats 1/5/10/50bp; baseline retained | 3.2076% | 3.3502% |
| 2: trade size and admission rate | $8,000 maximum and burst; $5,000/day refill ceiling | 3.4153% | 3.6064% |
| 3: threshold refinement and optional buy cadence | 30bp; hourly opportunities beat 6-hour/daily pacing | **3.4614%** | **3.6468%** |

Round 1's 1bp threshold caused 342/348 harvests and $74.83/$80.26 of direct
operations. First crypto arrived only a few days earlier. At 50bp, lower gas
expense did not compensate for earnings left unconverted at the horizon.

Round 2's $250/day cases fragmented source borrowing into many small trades,
spending $160–$192 in direct operations. Larger permitted replenishment lets
useful trades consolidate, provided actual liquidity arrives. With an available
$8,000 burst, the selected $10,000 deposit fits in one admission; the baseline
needed two admissions and about 21 days. This is an isolated full-budget case,
not simultaneous capacity for two vaults or every depositor.

Round 3 follows the observed bottleneck: there were no economic batching skips
at the source's 25bp threshold. Changing an inactive gas-delay setting could not
produce a gain. It compares 20/25/30bp source thresholds and 1/6/24-hour optional
buy opportunities. The last improvement is modest and sensitive to harvest
timing at the one-year horizon; the two-year winner is checked separately.

The selected source threshold is 0.30% of source principal equity, not a dollar
minimum or an APY. Admission minimum remains 10 HOLLAR. PRIME harvests have a
$1 input minimum, $200 maximum and $1,000/day budget at the initial oracle price.
Main-servicing lanes have separate $200-equivalent maxima and $1,000/day budgets;
their minimum is one collateral base unit. USD equivalents are converted to
fixed token units when the policy is configured. The keeper retains its $1 gross
minimum, 10bp gas/value target, 24-hour batching age and $10 Main-interest urgency.

The **24-hour setting does not guarantee daily realization**: source readiness,
the source threshold and on-chain budgets come first. In the winner, first
harvest is around day 58, first funded user crypto around **day 88**, and later
harvest gaps approach ten days. Urgency or elapsed batching age bypasses the
10bp economic target, so it is not a strict bound on gas/value for every harvest.
Reducing this startup delay needs work beyond keeper scheduling.

## User earnings and shared costs

For each isolated $10,000 winning case over one year:

| Item | ETH | BTC |
| --- | ---: | ---: |
| Source income | $2,334.80 | $2,490.95 |
| Main interest | $334.73 | $357.44 |
| Source interest | $1,532.04 | $1,634.18 |
| Trading losses | $29.26 | $35.81 |
| Realized protocol receipts | $36.35 | $38.66 |
| Funded user crypto | $354.42 | $373.88 |
| Direct operation cost | $8.28 | $9.20 |
| Funded crypto after direct operations | **$346.14** | **$364.68** |
| Additional unconverted user carry | $45.57 | $48.41 |
| Unconverted protocol carry, excluded from user return | $2.40 | $2.55 |
| Harvests / source ramps | 32 / 22 | 32 / 22 |

The remaining net economic value stays in source backing; unconverted carry
includes retained execution allowance and is not free, immediately withdrawable
crypto. An illustrative complete source close costs another **$33.10 / $35.33**
in trading and **$0.34 / $0.39** in multi-transaction gas allowances. That estimate
does not execute withdrawal queues or prove timely redemption and is excluded
from the funded-return headline. The source-close accounting coverage gap is
zero in the baseline winner.

A $50/month total operating budget costs $600/year. Shared over $10,000 it removes
**6 percentage points**; over $100,000, **0.60 points**; over $1 million, **0.06
points**. At $200/month those deductions are 24, 2.40 and 0.24 points. Shared
deployment/renewal costs are also included in the JSON `allIn` sensitivities.
The model preserves costs that exceed principal rather than hiding them behind
a -100% return cap; a multi-year CAGR with negative end wealth is undefined.

Do not extrapolate the $10,000 return unchanged to a larger deployment. The
explicit **$100,000 vault** case takes about **59.5 days** to finish admission,
earns first funded crypto around day 152, and returns **2.62% / 2.74%** after
direct operations. Charging that deployment $50/month plus the shared on-chain
allowances gives approximately **2.02% / 2.13%**, before final withdrawal.
By comparison, a standalone $10,000 deployment paying the same bill is negative:
approximately **-2.56% / -2.37%**. Per-user balances inside an established pooled
vault should not each be charged a separate copy of the operators' fixed budget.

## Stress results and implementation limits

All figures below exclude shared monthly infrastructure and final withdrawal.
Positive funded crypto accumulated before a later loss does not cancel an
unpaid backing deficit; inspect the deficit-adjusted result in the evidence.

| Scenario | ETH funded return after direct costs | BTC | Finding |
| --- | ---: | ---: | --- |
| $1,000 isolated vault | 2.79% | 2.98% | $7.48/$7.46 operating cost is a larger percentage |
| $100,000 isolated vault | 2.62% | 2.74% | Admission and ramp consume more of the year |
| Two-year hold, annualized | 3.95% | 4.17% | Startup costs spread over a longer holding period |
| Fivefold gas price | 3.13% | 3.28% | Cost includes the more expensive keeper economic checks |
| No external admission refill | **0.48%** | **0.41%** | $8,000 burst cannot fund the modeled leveraged scale |
| Source fills worsen to 7bp entry / 9bp exit | 3.10% | 3.26% | Slower recovery from entry losses |
| 14-day keeper outage from day 180 | 3.43% | 3.61% | Conditional calm-market interruption, not an outage safety proof |
| Borrow APR rises to 8%, source APR falls to 4% at day 180 | 1.11% | 1.17% | **$863 / $920 backing deficits**; not a viable return |
| Permanent 3% PRIME price drop at day 180 | 1.11% | 1.17% | **$1,155 / $1,235 backing deficits**; not a viable return |

Fresh SDK route math at the market pin shows roughly 3.3–4.2bp entry loss for
$1–$5,000, with $10,000 around 5.13bp. The 10bp source ceiling with a 2bp quote
margin supports about $12,750–$15,000 cumulative sequential input at that pin
without refill. The model keeps an $8,000 burst, consistent with the more
conservative earlier holdout. This validates neither persistent $5,000/day
replenishment nor native circuit-breaker headroom. No liquidity provider fee or
funded replenishment service is silently assumed to be included in gas.

This is an **hourly policy simulation**, not an exact replay of the production
keeper. It can make up to eight sequential ramps per observation; production
polls more frequently and submits one ramp per cycle. Its quote traffic, temporal
rounding and transaction counts need a real cadence replay before budgeting
production. Delaying the entire keeper loop would also delay safety execution;
the rejected 6/24-hour buy experiments must not be implemented by slowing safety
monitoring. Independent 30-second safety monitoring and redundant operators
remain requirements. No new keeper cadence gate is implemented in this change.

Rejected admissions remain in the modeled owner's wallet and are retried later;
there is no production admission queue. Return uses the full planned capital
from day zero, including the portion awaiting admission. The model uses one
owner and one vault per scenario, so it does not establish fairness under shared
multi-vault budget saturation. It does not simulate fresh-quote inclusion moves,
liquidations, supplier fees, staffing contracts or audit budgets. Recovery policy,
native Main-servicing calibration, committed liquidity and exact deployment
rehearsal remain release work.

## Validation and reproduction

The campaign asserts conservation of earned income after both debt costs,
non-decreasing previously funded user crypto, reserved-share bounds, and vault /
source ownership agreement at every observation. All 64 cases pass, including
loss scenarios that correctly retain a funding deficit. Fourteen Node tests pass
across the updated and historical models, covering cost allocation, user/protocol
separation, missing results, deficits, eligibility and cost losses beyond principal.
Production creation and runtime bytecode equality is recorded separately; no
production source or keeper code changed.

With the repository dependencies and Solc 0.8.22 installed, copy the archived
`market.json`, `hastra-por.json`, `gas-price.json` and `routes.json` into an empty
evidence directory. Compile the harness once to avoid concurrent compilation,
then run the rounds in order. For example, from the repository root:

```sh
ops_dir=/tmp/propeller-operations-replay
mkdir -p "$ops_dir"
cp propeller-vault/docs/evidence/operations-tuning-three-rounds-2026-10-03/{market,hastra-por,gas-price,routes}.json "$ops_dir/"
forge test --root propeller-vault --offline --evm-version london --dynamic-test-linking --out "$ops_dir/out" --cache-path "$ops_dir/cache" --match-path test/OperationsTuning.t.sol --match-test test_operationsTuning
node scripts/propeller/tune-operations.mjs "$ops_dir" 1
node scripts/propeller/tune-operations.mjs "$ops_dir" 2
node scripts/propeller/tune-operations.mjs "$ops_dir" 3
node scripts/propeller/tune-operations.mjs "$ops_dir" holdouts
node scripts/propeller/summarize-operations-tuning.mjs "$ops_dir"
node --test scripts/propeller/tune-operations.test.mjs scripts/propeller/tune-mainnet.test.mjs
```

The first Forge command skips the opt-in economic case while compiling it.
The runner supplies the explicit scenario inputs and run flag. `OPS_WORKERS=1`
reduces process concurrency if needed. Evidence caching checks the contract
inputs, harness hash and original log hash; current cost presentation is applied
again to immutable metrics without rerunning or altering those logs.
