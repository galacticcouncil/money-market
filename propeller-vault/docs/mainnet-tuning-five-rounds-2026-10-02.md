# Propeller: five rounds of mainnet model tuning

The best tested **execution-efficiency configuration** produces **3.38% ETH /
3.58% BTC** first-year funded-crypto return after modeled keeper costs. The
highest tested user-return policy, **100% Main interest discount and zero
protocol fee**, produces **7.43% / 7.93%**. That policy forgoes lending and fee
revenue; it is a separate governance choice.

These are conditional model results for one $10,000 vault at a time, not a
mainnet APY forecast. All five rounds are complete: **88 successful contract
scenarios / 32,850 simulated days**. Production contracts, keeper configuration,
and on-chain parameters are unchanged. The measured liquidity envelope does
not establish that a $10,000 vault can reach modeled leverage without external
pool replenishment.

The [summary](evidence/mainnet-tuning-five-rounds-2026-10-02/summary.json),
[complete comparison CSV](evidence/mainnet-tuning-five-rounds-2026-10-02/comparison.csv)
and [evidence manifest](evidence/mainnet-tuning-five-rounds-2026-10-02/manifest.json)
contain the inputs, individual results and hashes.

## Objective and calibration

The objective is additional **funded crypto**, after source and Main interest,
protocol fees, execution costs and a native keeper gas budget. Funded crypto
can actually back the owner's collateral claim. Unconverted source earnings
are reported separately. Keeper gas is currently paid by the operator; the
cost-adjusted score charges it to the strategy for an honest comparison, without
pretending the contracts deduct it from user shares.

| Input | Value / source |
| --- | --- |
| Finalized Hydration pin | 15,311,067, runtime 447 |
| Independent later pin | 15,311,623 |
| HOLLAR variable borrow APR | 4.401689% |
| PRIME effective APY | 5.6515%, Hastra PRIME-specific API record |
| PRIME Aave supply APR | 0.035760% |
| Modeled combined source daily accrual, annualized | 5.533750% |
| Alternative trailing NAV growth | 6.100756% log annual rate over 9.41 days, plus Aave income |
| Crypto LTV | ETH 75%; tBTC 80% |
| Source target / deployment HF | 1.05 / 1.05; unchanged |
| Keeper ramp stop buffer | 0.5% above target; unchanged |
| Source entry / exit loss | 5bp / 7bp baseline; explicit sensitivities below |
| Crypto swap loss | ETH 60bp; BTC 100bp, including the servicing swap |
| Crypto slippage bound | 100bp; unchanged |
| Protocol fee / Main discount in efficiency rounds | 5% / 0% |

Hastra defines its displayed effective APY as trailing NAV growth, including
wYLDS income and net of its own 50bp fee. The model converts that APY to a daily
rate and adds only the separate Aave supply accrual. It does not add wYLDS
income again or subtract the Hastra fee twice. The PRIME-specific record is
used rather than the API's aggregate across different products.
Sources: [Hastra's methodology](https://help.hastra.io/prime/what-is-prime-(staked-wylds)),
[public feed](https://hastra.io/hastra-pulse/public/api/v1/por), and the archived
JSON inputs. The later feed observation still reported 5.6515%.

The harness uses actual Propeller contracts with mocked Aave and router
boundaries. Income and debt accrue daily; native crypto prices stay fixed.
PRIME NAV growth is represented by equivalent aPRIME value growth at the mock
boundary. Direct ETH/tBTC Aave supply income is excluded. There is **no income
donation, entry sponsorship, forced initial ramp or recovery top-up**. Initial
swap losses must recover through earned income before the Main readiness guard
allows further ramping. The fixture's tiny rounding reserve cannot manufacture
material income; an economic conservation assertion includes both debts,
remaining source equity, cash, funded crypto and protocol fees.

## Five rounds, with each winner feeding the next

Returns below include modeled keeper costs. Each column represents an isolated
$10,000 vault, not two vaults drawing on separate copies of actual liquidity.

| Round | Retained choice / finding | ETH | BTC | First funded crypto |
| --- | --- | ---: | ---: | --- |
| 1: calibrated baseline | 100bp source reserve; 0.10% harvest threshold; $1k ramp | -0.27% | -0.28% | None within 365 days |
| 2: source reserve | 10bp beats 15/25/50/100bp under the modeled fills | 3.25% | 3.43% | Day 90 |
| 3: harvest size and cadence | 0.25% of source principal equity; check daily | 3.36% | 3.55% | Day 95 |
| 4: ramp size and cadence | Up to $5k per source trade; daily opportunities | 3.38% | 3.58% | Day 84 |
| 5: holdouts and stresses | Winner survives modeled quote deterioration; rate/price losses expose funding gaps | 3.38% | 3.58% | Day 84 in baseline conditions |

The baseline's funded collateral return is exactly zero, before keeper costs;
its negative cost-adjusted score is operating expense. It retains about **$445
ETH-case / $472 BTC-case** of owned, unconverted source yield at year-end.
With the selected configuration those amounts fall to **$50 / $53**, while
additional funded crypto rises to **$366 / $385**. Source harvesting begins on
day 57; the first harvests service Main obligations before user crypto grows.

Most of the improvement is earlier conversion. Counting funded crypto plus
owned unconverted yield at oracle value, after keeper costs and before terminal
execution, the baseline returns **4.18% / 4.44%**, versus **3.88% / 4.11%** for
the selected configuration. Thus the winner serves the crypto-accumulation
objective; it does not maximize flat-price USD wealth. The source reserve is
owned value held back for execution, not a fee that disappears when reduced.

At $10,000, the 0.25% source-equity threshold is initially about **$18.75 ETH /
$20 BTC**. It reduces annual harvests from 78 to 35 relative to round 2.
The larger ramp reduces productive source borrowing calls from 44–46 to 22.
At $1,000, a $25 absolute harvest minimum improves the cost-adjusted score to
**1.36% / 1.30%**, but delays first funded crypto to days **155 / 149**. There is
no universal size threshold that simultaneously maximizes APY and payout speed.

## Round 5: sensitivity and funding obligations

| Scenario | ETH return after costs | BTC return after costs | Other result |
| --- | ---: | ---: | --- |
| Selected, two years | 3.92% annualized | 4.15% annualized | Startup drag amortizes |
| Later quotes, 7bp entry / 7bp exit | 3.14% | 3.20% | First crypto days 104 / 105 |
| Worse fills, 8bp entry / 9bp exit | 2.98% | 3.13% | First crypto day 119 |
| 25bp reserve, baseline fills | 2.78% | 2.82% | First crypto day 141 |
| 25bp reserve, 20bp source fills | 0.72% | 0.73% | First crypto days 286 / 288 |
| 14-day keeper outage | 3.42% | 3.61% | No final modeled backing deficit |
| Borrow APR 8%, source accrual 4%, from day 180 | 0.93% funded | 0.98% funded | **$865 / $923 source backing deficit** |
| Permanent 3% PRIME price gap on day 180 | 0.93% funded | 0.98% funded | **$1,141 / $1,222 source backing deficit** |

Already funded user crypto was never spent by ordinary servicing. That does
not make a funding gap harmless: the collateral promise still needs debt
coverage to support exits. Including those gaps, modeled economic results are
**-7.72% / -8.24%** for the rate shock and **-10.48% / -11.24%** for the PRIME
gap. These are economic funding losses, not implemented collateral haircuts.
No recovery money is silently added to make those cases pass.

The benign outage's slightly higher return reflects fewer transactions and
different harvest timing on a constant-price path. It is not evidence that
outages are safe or a reason to stop safety monitoring. A fivefold gas-price
sensitivity reduces the selected $10k-vault score to about **2.29% / 2.48%**.

## Governance choices that increase user APY

These scenarios retain the selected size/rate settings and leave SubLoop
borrowing fully charged. Revenue figures are measured within each scenario;
changing the policy changes subsequent balances, so they are not identical
notional books.

| Main interest discount | Protocol fee | ETH after keeper costs | BTC after keeper costs | Main interest waived per $10k vault |
| ---: | ---: | ---: | ---: | ---: |
| 0% | 5% | 3.38% | 3.58% | $0 |
| 0% | 1% | 3.69% | 3.92% | $0 |
| 0% | 0% | 3.77% | 4.00% | $0 |
| 50% | 5% | 5.30% | 5.65% | $169 / $181 |
| 100% | 5% | 7.03% | 7.51% | $341 / $364 |
| 100% | 0% | **7.43%** | **7.93%** | **$341 / $365**, plus waived fees |

The existing-fee efficiency case collects about $37 / $39 of annual protocol
fees. At full Main discount it collects about $38 / $41; eliminating those fees
raises the user result further. The maximum-user-return case first funds crypto
on day **43**, so even it does not turn every day's new source NAV into crypto
immediately. Separate yield ownership remains necessary throughout startup.

## Liquidity constrains admission and ramping

Source `dcaSlippagePpm` also sets the reserve against the gross source position.
It is independent of the vault's crypto `compoundSlippageBps`. Tightening the
source limit must not accidentally tighten BTC purchases to 10bp.

Official SDK stable-swap math at the two finalized pins gives:

| Quote / sequential budget | First pin | Later pin |
| --- | ---: | ---: |
| $1k HOLLAR → PRIME loss | 2.19bp | 5.12bp |
| $1k PRIME → HOLLAR loss | 6.17bp | 3.24bp |
| Repeated $1k buys, 10bp ceiling and 2bp margin | $16k cumulative | $8k cumulative |
| Repeated $1k buys, 25bp ceiling and 2bp margin | $56k cumulative | $48k cumulative |

These sequential tests mutate pool reserves; they do not reset liquidity after
each trade. They hold pegs, oracle and amplification fixed and omit native
circuit breakers, so the figures are necessary quote constraints, not promised
execution capacity. Simultaneous users and external trades share the same budget.

At maximum source leverage and BTC LTV, retaining 20% of the smaller observed
budget implies illustrative **aggregate** startup TVL ceilings of about **$1.3k
at 10bp**, or **$7.8k at 25bp**. Round down further for a pilot and re-quote before
entry; neither is a permanent safe cap. A $10k-vault APY projection therefore
depends on replenished liquidity. Raising the reserve to 25bp broadens the quote
envelope but reduces payouts, and actual fills near that bound cost more.

Initial deposits deploy their whole Main borrow synchronously. `deployTranche`
caps later `pokeBorrow` operations, not the initial deposit. Admission must check
the entire initial swap and aggregate exposure; a small keeper tranche alone
does not limit deposit impact. Native USD prices must also be used when converting
the $5k unwind budget into PRIME units.

## Concrete control design for implementation review

1. Keep source target HF 1.05, deployment HF 1.05, the keeper's 0.5% ramp buffer,
   collateral LTVs and 100bp crypto protection unchanged.
2. Use **10bp source tolerance only with fresh quote and admission gates**.
   Require entry and safety-exit quotes to leave a margin; 2bp is the tested
   sizing assumption. Pause new ramp when quotes fail instead of widening the
   limit to force a fill. Consider 25bp only with its measured APY/cost tradeoff.
3. Set `harvestThreshold` to **2.5e15** (0.25% of source principal equity) for
   the tested $10k scale. Preview after-fee output, Main service and gas to add
   an absolute economic minimum at small scale. Preserve safety servicing when
   an ordinary user-reward threshold is not met.
4. Allow up to **5,000 HOLLAR** per deployment tranche, capped further by the
   live quote, aggregate admission budget and existing backing/HF guards.
   The model evaluates up to eight guarded opportunities per day; it does not
   prove a hard daily execution quota or guaranteed pool replenishment.
5. Keep frequent **read-only** safety monitoring. Submit Main maintenance and
   routine settlement when necessary rather than blindly repeating successful
   no-ops. Main synthetic coverage must be maintained before its debt buffer
   can be exhausted; repayment and emergency handling must bypass APY batching.
6. If highest user APY is the governance objective, the best tested policy is
   **100% Main interest discount and zero protocol fee**. Make the waived revenue
   and operator budget explicit. Source interest is never discounted by this policy.

The current keeper polls every 30 seconds and runs slow work every ten cycles.
It can submit successful no-ops. Native read-only probes in the existing local
fork required up to about **741k gas for peg maintenance, 1.330M for settlement,
and 1.167M for rebalance**. The model charges daily budgets of 0.8M / 1.4M / 1.2M
for those calls, including no-ops, plus the native-calibrated harvest/ramp costs.
It uses the prior measured gas price with another 20% margin.

At a fixed five-minute frequency, that routine budget alone annualizes to about
**$6,390 per vault**, compared with about **$22 daily-scheduled**. This is a
frequency sensitivity with fixed gas and no polling/receipt latency, not measured
annual spending. It establishes why the current submission cadence must not be
assumed in the favorable APY numbers. Daily modeled writes and economic gates
require keeper work; slowing risk monitoring is not the proposed implementation.

## Validation and reproduction

Every modeled day preserves previously funded collateral, reconciles vault and
source shares, and bounds reserved yield shares. End-of-case conservation rejects
wealth exceeding modeled income after both debts' interest. Source discounts
remain zero. Stress scheduling treats an already-covered `deLever` target as the
same benign `HealthyEnough` response the real keeper handles, then continues
repayment. The two-year holdout checks that the result is not solely a first-year
endpoint effect.

Five Node checks verify APY conversion, complete-success log parsing, explicit
gas/exit costs, subsidy/deficit exclusion from efficiency selection, and funding
losses despite positive previously funded crypto. **16 relevant Solidity
regressions passed**, including 256 mixed-action ownership fuzz runs; zero
failures or skips. Their log is recorded alongside the campaign logs. This pass changes no production
bytecode; native deployment and runtime-cap evidence remains in the preceding
[three-pass validation](pr62-three-pass-validation-2026-10-02.md).

Run each round sequentially after placing the archived public input JSON files
in a writable work directory (separate from the checked-in evidence directory):

```sh
node --test scripts/propeller/tune-mainnet.test.mjs
node scripts/propeller/tune-mainnet.mjs /tmp/propeller-tuning-run 1
node scripts/propeller/tune-mainnet.mjs /tmp/propeller-tuning-run 2
node scripts/propeller/tune-mainnet.mjs /tmp/propeller-tuning-run 3
node scripts/propeller/tune-mainnet.mjs /tmp/propeller-tuning-run 4
node scripts/propeller/tune-mainnet.mjs /tmp/propeller-tuning-run 5
HYDRATION_MATH_ROOT=/path/to/sdk/packages node scripts/propeller/tuning-routes.mjs \
  /tmp/propeller-tuning-run/market.json /tmp/propeller-tuning-run/routes.json
node scripts/propeller/summarize-mainnet-tuning.mjs /tmp/propeller-tuning-run
```

The summary also expects the archived holdout route and native maintenance
probe JSON. Source math dependency versions/hashes are in `routes.json`. The
campaign uses Solc 0.8.22, London, via-IR, optimizer 200, and explicit output/cache
directories. Optional standalone native gas probing uses `eth_call` against a
localhost fork only and never signs or submits a transaction.
