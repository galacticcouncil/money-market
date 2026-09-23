# Propeller Readiness and 90-Day Pressure Tests

Local investigation, 2026-09-18. Branch `fix/propeller-accounting-readiness`.
These runs were performed locally without production transactions. See the
[current status and resource index](README.md) for the publication checkpoint.
This is test evidence and a capacity assessment, not production approval or a
promise of principal liquidity. Recovery allocation tooling remains deferred.

Follow-up, 2026-09-22: [Main-interest policy comparison](interest-policy-comparison.md)
uses a fresh market snapshot and compares servicing timing, buffers and explicit
exit funding. The older pressure envelope below does not rank those policies.

Separate follow-up: [HOLLAR peg liquidity](hollar-peg-liquidity.md) sizes pool
depth and finite funded buybacks from a newer snapshot. It corrects the static
HSM helper's price-gate quote direction; old HSM gate estimates below are not
the current sizing evidence. Mint ceilings are not funded reserves.

## Conclusions

1. The rounding-buffer deployment policy, read-only readiness checks, and keeper
   alerts are implemented locally. Native tests verified actual token minimum
   balances, EVM/native account mapping, and custody dust protection.
2. The contract suite passes, including 27 new 90-day cases. Main interest and
   negative loop carry require explicit external recovery funding before full
   exits. Passing tests do not mean strategy yield pays these obligations.
3. Two public users in each ETH/tBTC vault completed native deposits, real-route
   harvesting, collateral fee claims, delayed/frozen exits, and full repayment
   after donor funding. The production adapter is not deployed and must be
   deployed and verified with Propeller. The tested adapter is fork-only.
4. At the modeled target, $1 deposited collateral implies about 4.79 HOLLAR of
   combined Main/loop debt. Current PRIME pool liquidity already constrains the
   $100k case. Every $500k-and-larger full-ramp case exceeds the market's current
   HOLLAR mint headroom; higher TVLs also hit other reserve limits.
5. Long keeper outages invalidate an unconditional synthetic-only Main health
   floor. This is not evidence that Main was liquidated in these tests, but the
   intended "only the PRIME loop can be liquidated" property is not yet proven
   across arbitrary outages, governance changes, and collateral-price shocks.

## Evidence and Assumptions

Market snapshot: `hdx.tarn.hydration.cloud`, finalized block **14744838**,
hash `0xb4cf9bbf8cb1006c042d808012f67278e8c671be7eb104f12d56be9334292874`,
runtime 443. All capacity figures below refer to this block, not future markets.
Snapshot collection is read-only. Native transaction tests use a separate local
Chopsticks fork of the same upstream at block **14744681**.

There are three different kinds of evidence:

- **Contract integration tests:** actual Propeller contracts with modeled
  Aave/router behavior, unconstrained mock liquidity/caps, daily token accrual.
  These test accounting and operational behavior, not real-market execution.
- **Native E2E:** real runtime, Pool, token precompiles and swap routes on a local
  fork; public development keys, governance stand-ins, funded test fixtures,
  small deposits, and seven days of native elapsed time. Not a 90-day native run.
- **Financial pressure model:** 108 requested-exposure scenarios, 18 HSM routing
  sensitivities, and 24 PRIME gap-loss stresses. These are counterfactuals, not
  executable forecasts or substitutes for the contract tests.

All scenarios start with 50/50 ETH/tBTC collateral by USD value. TVLs are $100k,
$500k, $1m, $10m, $50m, and $100m. Bull prices finish at ETH +100% / tBTC +60%;
bear at -70% / -60%; seesaw ranges from 0.68x to 1.4x, resetting every 20 days.
The seesaw reset is deliberately abrupt. PRIME gross-yield APR assumptions are
6.5% / 4% / 5.5%; these are scenario inputs, not a measured PRIME forward yield.
Borrow APR is 4.4016889% from the snapshot for bull, 12% for bear, and alternating
2.5% / 12% for seesaw. Solidity uses rounded 4.4% in its bull cases.

The financial model varies Main discount between 0%, 50%, and 100%; loop debt is
never discounted. Fees are 5% of harvested collateral yield. Half the position
exits on day 60; the remainder exits on day 90. Outage variants skip keeper work
on days 21-50. The contract campaign instead exits both public positions at day
90, after explicit recovery funding and the withdrawal delay.

## Entry and Market Capacity

At PRIME liquidation threshold 88% and loop target HF 1.05:

```text
Loop gross exposure / Main-funded equity = 1 / (1 - 0.88 / 1.05) = 6.17647
Main debt / deposited TVL = (0.75 ETH LTV + 0.80 tBTC LTV) / 2 = 0.775
Loop debt / deposited TVL = 4.011765
Combined debt and gross PRIME demand / deposited TVL = 4.786765
```

These are asymptotic targets before fees, execution losses, interest and
funding constraints. Real contracts may stop well before this exposure.

| Initial collateral TVL | Main HOLLAR debt | Combined HOLLAR debt / PRIME demand | Market mint room sufficient? | Demand / PRIME pool inventory |
| --- | ---: | ---: | --- | ---: |
| $100k | 77,500 | 478,676 | Yes, entry only | 1.39x |
| $500k | 387,500 | 2,393,382 | No | 6.96x |
| $1m | 775,000 | 4,786,765 | No | 13.92x |
| $10m | 7,750,000 | 47,867,647 | No | 139.22x |
| $50m | 38,750,000 | 239,338,235 | No | 696.10x |
| $100m | 77,500,000 | 478,676,471 | No | 1,392.21x |

Snapshot limits, shared with all existing market users:

| Constraint | Remaining capacity |
| --- | ---: |
| Hydration Market HOLLAR facilitator minting | 1,284,689.75 HOLLAR |
| PRIME Aave supply cap | $6,478,886.72 |
| PRIME isolation debt ceiling | 4,857,907.72 HOLLAR |
| ETH Aave supply cap | $8,233,619.59 |
| tBTC Aave supply cap | $1,491,366.39 |
| PRIME immediately available Aave cash | $9,056,376.53 |
| ETH immediately available Aave cash | $2,674,205.61 |
| tBTC immediately available Aave cash | $2,337,788.14 |

HOLLAR facilitator mint capacity, not ordinary supplied HOLLAR liquidity, is the
relevant borrow constraint. Raising it alone does not remove isolation ceilings,
supply caps, swap depth, or withdrawal-liquidity constraints.

PRIME/HOLLAR pool 143 held **327,297.53 PRIME**, worth about **$343,826**, and
**726,750.84 HOLLAR**. Official stable-swap math at the stored pegs/fees gives:

- The $100k case's initial 77,500 HOLLAR Main entry returns about 72,799.25 PRIME,
  **1.322% below oracle value**, including fees and pool/oracle price differences.
- Quoting its entire 478,676 HOLLAR target demand against that same snapshot
  gives a **29.974% oracle-value loss**. This is a no-refill aggregate stress,
  not the actual result of sequential leveraged transactions.
- A binary search finds about **9,944 HOLLAR** as the largest aggregate entry
  within a hypothetical 1% oracle floor, without replenishment. This is a
  sensitivity, not an approved tranche or TVL limit. Subsequent tranches face
  changed balances, and marginal execution may breach the floor earlier.

Gradual entry is necessary but does not create PRIME. Sustained capacity needs
credible replenishment, appropriate TVL/ramp limits, and executable exit routes.
Re-run these checks on the deployment block with approved slippage settings.

## Ninety-Day Flow Pressure

Illustrative $100k case, no outage, no Main discount, 50% exit on day 60.
Amounts below are HOLLAR or nominal USD equivalents:

| Path | Peak combined debt | Cumulative HOLLAR sold for PRIME | Cumulative HOLLAR bought before final exit | Remaining day-90 exit demand | Main interest | Loop negative carry |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Bull | 733,172 | 790,608 | 363,390 | 430,862 | 924 | 0 |
| Bear | 478,676 | 478,676 | 392,798 | 85,879 | 1,404 | 4,377 |
| Seesaw | 658,460 | 1,567,998 | 1,238,137 | 331,805 | 1,245 | 2,379 |

The financial model externally funds Main interest and negative carry to sustain
the requested target exposures. It approximates aggregate resizing and allocates
harvest 50/50 in USD; it is not an exact per-vault source-share simulation.
The actual unfunded contract tests below show blocked rebalances instead.

Bull creates additional borrowing and PRIME demand. Bear requires PRIME sales
and HOLLAR purchases while liquidations, reduced pool depth, and Aave cash
withdrawals could coincide. Seesaw generates the largest repeated swap flow in
these selected paths, even without the largest peak debt.

Do not interpret cumulative purchases as pure HOLLAR burn: harvest passes
through HOLLAR into collateral. Final day-90 exits are additional to the
cumulative-purchase column. Amounts scale linearly in this unconstrained model;
execution does not. JSON/CSV include every requested TVL and discount/outage
combination, plus independent 100%/50%/10% Aave-cash availability stresses.
Large-TVL liquidity stresses are counterfactual and may require cap increases.

## HSM Pressure

The snapshot HSM supports **aUSDT and aUSDC, not PRIME**. Its mint headroom of
**17,778,159.78 HOLLAR** is not collateral available for buybacks. Holdings were
about **$223,600.97**, with a shared facilitator burn level of **221,840.22
HOLLAR**. The lower nominal bound is used for available coverage. Actual
execution additionally depends on pool price, per-block limits, cash availability,
and other callers. [HOLLAR mechanism overview](https://docs.hydration.net/products/hollar/).

For each configured pool, imbalance is `(HOLLAR - peg * collateral) / 2` and the
configured per-block rate is 0.0001 times positive imbalance. The snapshot rate
ceilings were 6.84 and 12.41 HOLLAR/block, but both price gates were ineligible
under the stored-state math. Those ceilings were not executable guaranteed buys.

Routing sensitivity: assume 25% of the full-ramp HOLLAR sell flow instead reaches
the two HSM-backed pools, split evenly, without unrelated flows or refills:

| TVL | Assumed HSM-pool sell flow | Post-flow rate ceiling / block | Price-eligible nominal buyback ceiling / block | Existing holdings/burn coverage |
| --- | ---: | ---: | ---: | ---: |
| $100k | 119,669 | 31.21 | 18.38 | 100% |
| $500k | 598,346 | 78.99 | 78.99 | 37.08% |
| $1m | 1,196,691 | 138.40 | 138.40 | 18.54% |
| $10m | 11,966,912 | 704.47 | 704.47 | 1.854% |
| $50m | 59,834,559 | 3,097.87 | 3,097.87 | 0.371% |
| $100m | 119,669,118 | 6,089.60 | 6,089.60 | 0.185% |

These are alternative routing assumptions, not extra simultaneous flow and not
predictions of arbitrage. The 10% and 100% variants are also in the output.
Even with continuous eligibility and adequate holdings, shrinking an imbalance
95% at this configured rate takes approximately 29,956 blocks with no new flow.
No time-to-peg guarantee follows. Prior same-block usage, flash limits, aToken
liquidity, peg updates, and circuit breakers can further restrict these quotes.
HSM stablecoin arbitrage cannot be assumed to replenish PRIME inventory.

## Contract Stress Findings

`Market90Days.t.sol` runs nine baseline $6k cases: each path under ordinary
maintenance, a 30-day outage, and full Main discount. Eighteen additional cases
run each market path at all six requested TVLs. No operating donations are
allowed during the 90 days. Daily accrual is modeled, not the native Aave index
engine or an actual PRIME NAV oracle feed.

- Ordinary $6k runs needed explicit end-of-test external funding of about
  **54.81 / 237.19 / 69.80 HOLLAR** for bull/bear/seesaw. Bear with the keeper
  outage needed **328.83 HOLLAR**. This is separate from user yield and fees.
- Full Main discount eliminates modeled Main interest, not loop losses or
  token-unit reconciliation. Bear still needed **153.10 HOLLAR** external exit
  funding. Discounting is not a strategy-loss reserve.
- Unfunded Main interest blocked **147** resize attempts in the baseline bull
  run. Synthetic maintenance is not HOLLAR repayment. A policy for funding or
  economically servicing Main interest remains necessary.
- The synthetic-only floor fell below current Main debt on **32 vault-days**
  in bear/outage and **2 vault-days** in seesaw/outage. Original collateral
  provides additional health-factor support; these counts do not establish an
  actual Main liquidation. They do invalidate an unconditional synthetic-only
  protection claim during long unattended accrual.
- USD8 source quotes/proportional repayments left small HOLLAR tails at larger
  TVLs. Tests now reconcile exact queued token-unit debt before any user claims,
  record the extra donation, and never tolerate or write off unpaid amounts.
- Each public holder ultimately receives the complete recorded collateral
  promise and at least their original token-denominated principal after explicit
  funding. No recovery indexer or partial FIFO emergency payout is implemented.

The separate PRIME gap stress assumes instantaneous 5%/10%/25%/100% losses before
liquidation. At target HF 1.05, a 5% gap gives HF **0.9975**. For $100k initial
TVL, a 25% gap implies about **77,500 HOLLAR Main-backing deficit plus 42,169
HOLLAR loop bad debt**, before liquidation penalties and execution costs.
Complete PRIME loss implies about **478,676 HOLLAR** combined obligations.
These are arithmetic loss bounds, not an executed liquidation-engine test.

## Native Campaign

Fork block 14744681, runtime 443, `hdx.tarn`; verification through local block
14744816. Ten deployments, including the test adapter and second vault proxy,
passed bytecode comparison; three proxy implementation slots were verified.
CollateralVault remains **24,510 bytes**, only **66 bytes below EIP-170**.
No production Solidity code changed for this campaign. No code-size, runtime
bytecode, or runtime gas-limit override was used to pass deployment.

The fork-only `NativeRouteSwapper` sends PRIME through actual stored runtime
routes into ETH/tBTC. It is not a production HydraAugustus implementation and
does not implement the complete production swapper interface behavior.

Two public users deposited odd-base-unit amounts around 0.1 ETH and 0.003 tBTC
each. A donated PRIME fixture exercised real harvest routes and both 5% collateral
fee claims. It is not evidence of earned APY. HOLLAR recovery was borrowed by a
separate donor through the real Pool and transferred explicitly, including
entry-friction and post-accrual funding. Donation amounts were test budgets,
not a minimum-cost recovery estimate.

| Position | Deposited base units | Promised and actually paid base units |
| --- | ---: | ---: |
| Alice ETH | 100000000000000007 | 113605943569011851 |
| Bob ETH | 100000000000000011 | 113605943544193776 |
| Alice tBTC | 3000000000000013 | 3400090125462924 |
| Bob tBTC | 3000000000000017 | 3400090125294378 |

Requests could not start early. After seven native days, the emergency freeze
blocked starts while Main peg maintenance remained callable. After donor funding
and reopening, source repayment, settlement, and all four claims succeeded.
Discount enrollment and rate change/reset passed separately; the seven-day
lifecycle used 0% discount, not a native long-duration discount regression.

The shared readiness helpers verified both vaults' actual native asset IDs,
runtime account mapping, reserve backing and ED margin. ETH consumed 5 buffer
base units, tBTC 6. Source, harvester, fee controller, both vaults and test adapter
were confirmed dust-protected. Production buffer budgets still need approval.

One invalid harness attempt treated this fork's RPC block timestamp milliseconds
as seconds. It is excluded from economic evidence. The chain was restored to
the saved pre-advance head; corrected code reads native timestamp milliseconds,
advances the relay slot consistently, and verifies elapsed seconds. The valid
advance was 604,806 seconds for a requested 604,800 seconds. The invalid evidence
and restored checkpoint remain recorded, rather than silently discarded.

## Tooling and Verification

- Full Forge suite: **227 passed, 0 failed, 3 skipped**, 34 suites. Eight stateful
  invariants use 256 sequences of depth 50. The 27 new 90-day cases all passed.
- Skips: optional `PropellerDiscountFork`, `ProtocolFeesFork`, and Verity parity
  setup. Native Chopsticks coverage is separate and does not turn skips into passes.
- **14 keeper**, **3 rounding-policy**, **3 native-policy**, and **8 pressure-model**
  tests passed. Keeper build and readiness TypeScript checks passed; governance
  proposal TypeScript transpiled. The complete generated production governance
  proposal and actual committee identities were not executed in this rehearsal.
- Proposal generation requires exact per-vault `PROPELLER_ROUNDING_RESERVES`,
  sufficient prefunding of the Aave manager, and emits custody whitelist calls,
  exact approvals/top-ups and allowance clearing. Readiness verifies ED margin
  and reserve custody. Keeper log alerts do not automatically replenish funds
  or send notifications; operations must connect the alert pipeline.

Official SDK WASM math is used instead of reimplementing stable-swap/HSM math:
`math-stableswap` 2.5.0 and `math-hsm` 1.2.0 from the local Hydration SDK checkout.
Exact WASM SHA-256 hashes are embedded in model output. Pool quotes use stored
snapshot pegs, not predicted peg updates or a 90-day cumulative pool trajectory.
Financial projections use approximate floating-point dollars; contract assertions
and pool-math input/output accounting use integer token units.

From the repository root:

```sh
HYDRATION_MATH_ROOT=/home/mrq/git/sdk/packages \
  node scripts/propeller/pressure-model.mjs \
  /tmp/propeller-market-snapshot-20260918.json \
  /tmp/propeller-pressure-results-20260918.json

PROPELLER_MARKET_SNAPSHOT=/tmp/propeller-market-snapshot-20260918.json \
HYDRATION_MATH_ROOT=/home/mrq/git/sdk/packages \
  node scripts/propeller/pressure-model.test.mjs
```

From `propeller-vault` (the allow path is specific to this linked-dependency
workspace):

```sh
FOUNDRY_ALLOW_PATHS="[\"$(realpath ../bil-vault/lib)\"]" \
  forge test --offline --evm-version london -vv
```

Local artifacts:

- `/tmp/propeller-market-snapshot-20260918.json`: pinned native market inputs.
- `/tmp/propeller-pressure-results-20260918.json` and `.csv`: scenario results.
- `/tmp/propeller-campaign-forge-20260918.log`: full test output.
- `/tmp/propeller-90day-tests-20260918.log`: focused 90-day test output.
- `/tmp/propeller-campaign-result-20260918.json`: deployments, calls, payouts,
  code verification, overrides and limitations.
- `/tmp/propeller-campaign-rounding-checks-20260918.json`: final native buffers
  and custody mapping/whitelist evidence.
- `/tmp/propeller-campaign-invalid-clock-20260918.json`: excluded harness run.

The repo native-campaign script continues a prepared fork/deployment result;
it is not a self-contained CI launcher. Local bootstrap, discount wiring and
verification scripts use `/tmp/propeller-campaign-*20260918*`, with Chopsticks
config `/tmp/propeller-campaign-chopsticks-20260918.yml`. Historical receipts may
be pruned by Chopsticks; success was checked when mined, with final bytecode and
state verification performed separately.

## Remaining Launch Work

1. Deploy and independently review the actual production ISwapper adapter with
   Propeller; rerun native harvest, slippage/revert, approval and custody tests
   against that exact bytecode and final governance configuration.
2. Approve realistic entry TVL/ramp/exit limits and a PRIME liquidity plan.
   Raising mint/supply caps without depth and funding does not solve capacity.
3. Decide and fund Main-interest servicing and negative-carry recovery; reconcile
   exact HOLLAR obligations before reopening emergency withdrawals.
4. Establish redundant keeper/alerting and technical-committee pause execution;
   verify Main HF through the actual maximum response outage. Do not advertise
   an unconditional no-liquidation guarantee from these tests.
5. Rehearse final governance batches, deployer-role removal, operational buffer
   top-ups and recovery funding. Independent accounting/security review remains
   necessary. The deferred recovery indexer is not silently reintroduced here.
