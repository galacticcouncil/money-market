# Yield-Funded Main Debt: Verification

Historical verification checkpoint for the PR #60 revision, using the pinned
2026-09-22 fixture. It is included in [RC1](release-candidate.md), but is not
production deployment, slippage approval or independent audit. The earlier
sponsored-buffer results do not verify this revision.

For the subsequent fresh-fork HydraAugustus investigation, quote calibration and
higher-friction contract reruns, see [execution calibration](route-execution-calibration.md).
The pinned results below remain historical evidence, not the latest adapter test.

## Policy Tested

See [the current policy](main-debt-servicing.md). No mandatory sponsored HOLLAR
balance remains. Main resizing uses net PRIME-loop unwind proceeds; fresh
after-fee harvests service Main interest. Execution losses can spend earmarked
un-compounded yield, never erase Main debt or the recorded collateral promise.
No slippage limit is automatically widened.

## Contract Campaign

[Machine-readable summary](evidence/main-debt-2026-09-22/contract-campaign-summary.json)
and [all 370 rows](evidence/main-debt-2026-09-22/contract-campaign.csv).

- 90 days, 50/50 ETH/tBTC, $100k/$500k/$1m/$10m/$50m/$100m TVL.
- Flat, bull, bear, seesaw and rally/crash paths; 0/50/100% Main discounts;
  with and without a 30-day keeper outage.
- Sensitivities cover 10/25/50/100bp execution ceilings, modeled 10bp fills,
  harvest frequency, settlement delays, early exits, and separately measured
  Main-interest/Main-debt/PRIME-debt incentives.
- All 370 cases pass exact collateral-claim and deposited-token principal
  assertions **after explicit governance recovery where needed**.
- 266 cases require more than 0.01 HOLLAR recovery; the largest gross support
  is 6.2445% of TVL. Support includes entry friction and final deficits, not only
  permanent economic losses. It is never counted as organic yield.
- 165 cases retain source receivables above 0.01 HOLLAR after Main debt and
  collateral claims settle. Those claims remain owned, not written off.
- 216 synthetic-only coverage checks miss before keeper maintenance across the
  campaign. No modeled loop liquidation occurs in these paths; separate E2E
  tests exercise forced loop loss and governance recovery. This is not proof
  of uninterrupted synthetic-only coverage through arbitrary outages.

The market boundary is mocked: Aave accrual, router prices and liquidation
outcomes are fixtures, while vault/source/fee/discount/settlement code is real.
This does not establish native pool depth or executable $100m TVL.

The $50m rally/crash recovery required more than the original 600 keeper-call
test budget: health-factor-safe unwinds converge geometrically. The runner now
permits 1,500 calls; it does not increase on-chain per-transaction gas limits or
forgive remaining debt. Entry support also covers measured per-vault NAV rounding
deficits, not just the shared source's aggregate deficit.

## Retention Cost

The conservative holdback matters economically. At $1m TVL, zero Main discount,
10bp modeled loop costs and the default 100bp test ceiling, the flat 90-day case
has zero collateral-token compounding, about 3,779.51 HOLLAR already paid as exit
surplus and 8,519.33 HOLLAR still receivable. It includes 375.000053 HOLLAR of
explicit entry support. Zero compounding is not zero total economic return.

At a 10bp ceiling with the same modeled fills, collateral gains are 0.73% ETH
and 0.78% tBTC, plus separately recorded HOLLAR. Support is about 504.04 HOLLAR.
These are realized 90-day token returns with partial exits, not annualized APY,
not guaranteed returns, and not evidence that the native route can fill at 10bp.
Retention and executable slippage must be approved together before release.

## Native Rehearsal

[Deployment, readiness and test evidence](evidence/main-debt-2026-09-22/native-verification.json).

Fresh local Chopsticks fork from `wss://hdx.tarn.hydration.cloud`, block
14,900,756, runtime 443. Public development keys and local storage overrides
only. Native runtime/code-size/gas limits were not relaxed.

- CollateralVault: 24,381 runtime bytes, 195 bytes below EIP-170; native creation
  uses 10,868,370 gas including its CompoundLogic helper.
- PropellerMainDebt: 14,279 runtime bytes; SubLoop: 20,436 bytes.
- The revised stack deploys; bytecode, constructor helper, immutable bindings,
  proxy implementation slots, fee/discount registration and custody are checked.
- Both ledgers start with zero sponsored HOLLAR.
- Entry is **blocked by the unchanged 1% oracle-relative floor**. The pinned
  quote is 20.5 HOLLAR -> 19.312911 PRIME, below the 19.319371 PRIME minimum.
  No relaxed-floor lifecycle is claimed for this revision.
- Readiness: 112/125 checks pass. The 13 failures include development governance
  stand-ins, missing synthetic Substrate registry mapping, unseeded vaults and
  zero loop equity after the entry rejection. They are not waived launch checks.

The swap adapter remains a fork-only fixture, not the production HydraAugustus
integration. No native 90-day lifecycle or no-subsidy native exit is demonstrated.

## Other Verification

The focused multi-vault/yield-funded suite passes 19 tests, including full exits
using earned execution yield without governance HOLLAR. Nine stateful invariants
pass at 256 runs x 50 calls with earned PRIME, nonzero swap costs, interest and
external repayments in the action set. Principal claims use exact integer
assertions; fee-inversion tests separately account for bounded fee rounding.

Eight real Aave/GHO fee and discount fork tests pass at the same block. Keeper
tests/build and standalone readiness TypeScript checking pass. Economic-control
tests are rerun with the checked-in snapshot and local Hydration SDK pool math;
their outputs are distinct from the actual-contract campaign. The
[rerun summary](evidence/main-debt-2026-09-22/model-rerun-summary.json) includes
720 historical policy cases, 460 sensitivities, 108 pressure cases and the
finite-inventory peg/arbitrage controls. The historical policies are not a
second implementation of the revised ledger.

The complete ordinary Solidity regression passes 268 tests with zero failures
and three skipped setups. Two skips are the Aave/GHO fork suites run separately
above; the optional Verity parity harness remains skipped. The passing tests
include exact repayment of the unwind rounding tail: restoring the source's
8dp quote may leave a larger 18dp Main obligation, which requires separately
funding that exit's measured debt. No principal tolerance or debt write-off is
used to close it.

After the final serial rebuild, the test artifacts' local source hashes match
the workspace. The seven production contract bytecode templates are unchanged
from the native rehearsal. Overlapping Forge jobs against one cache/output
directory can leave stale test artifacts; run the commands below serially.

## Reproduce

Use pinned `bil-vault/lib` dependencies and the production compiler settings.
From `propeller-vault`:

```sh
forge test --offline --evm-version london --no-match-contract MainDebtCampaignTest -vv
RUN_MAIN_DEBT_CAMPAIGN=true FOUNDRY_GAS_LIMIT=1000000000000 \
  forge test --offline --evm-version london \
  --match-contract MainDebtCampaignTest --match-test test_campaign -vv
```

The high runner gas budget is only for multi-scenario test methods. A failing
case can be isolated using `REPLAY_CASE=true`, `CASE_PATH`, `CASE_DIMENSION`,
`CASE_DISCOUNT`, and `CASE_OUTAGE`. The evidence generator rejects incomplete
or duplicate grids, so replay output cannot masquerade as a full campaign.

## Remaining Release Gates

Resolve the oracle-reference/real-route execution mismatch without silently
widening losses; approve the retention/tranche policy; deploy and test the real
adapter; verify production roles, registry and rounding funding; demonstrate
outage protection and timely governance-funded recovery; independently review
the new earned-yield expense and proportional settlement accounting. Existing
formal proofs do not cover the new ledger and execution-cost accounting.
