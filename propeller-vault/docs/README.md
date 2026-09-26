# Propeller Status and Resources

As of 2026-09-23: **release candidate 1 (RC1)** for independent review and
native rehearsal. RC1 is the `propeller` tip carried by
[PR #46](https://github.com/galacticcouncil/money-market/pull/46) into `hydration`.
It includes Main borrowing discounts, per-vault harvest fees, accounting fixes,
withdrawal controls, keeper/readiness changes, regression tests and economic
research.

RC1 freezes the reviewed scope; it is not a production approval. Main-interest
servicing is **not in RC1**. The isolated HOLLAR operating buffer is developed
separately in draft [PR #60](https://github.com/galacticcouncil/money-market/pull/60)
and would need its own review before joining a later candidate. The
pre-deployment gates below remain open.

## Branches and Reviews

- Consolidated integration branch: `propeller`. It includes the discount/fee
  commits and the accounting/readiness and research commits from
  `fix/propeller-accounting-readiness` (`0c7229d`, `1f10b8b`). The original
  feature branches remain available as historical checkpoints.
- [PR #57: Main discounts and fees](https://github.com/galacticcouncil/money-market/pull/57)
  merged into `propeller` as `ee7c79e` on 2026-09-22.
- [PR #53: accounting and yield-source changes](https://github.com/galacticcouncil/money-market/pull/53)
  merged into `propeller` as `5c1bac4`.
- [PR #46: original integration](https://github.com/galacticcouncil/money-market/pull/46)
  remains open, now targeting `hydration`. The entire current `feat/bil` tip is
  already an ancestor of `hydration`. The latest `hydration` base is merged into
  `propeller`: ignore rules retain both branches' exclusions, and the superseded
  HDCL deployment plan is replaced by the existing BIL plan. Propeller's build
  paths now use the renamed `bil-vault/lib` submodules with unchanged pins.
- [PR #53 audit](../audit/propeller-audit-ys-propeller-fixes-20260731.md)
  is historical review evidence, not approval of RC1.

## Resource Map

| Area | Resources |
| --- | --- |
| Architecture | [Vault README](../README.md), [contracts](../src/) |
| Main discount | [Policy and implementation](main-borrow-discount.md) |
| Harvest fees | [Per-vault fee specification](protocol-fees.md) |
| Principal and emergencies | [Principal policy and accounting limitations](principal-safety.md) |
| Deployment | [Deployment guide](../DEPLOYMENT.md), [scripts](../script/), [governance proposal task](../../tasks/proposals/propeller.ts) |
| Deployment verification | [Readiness checks](../../scripts/propeller/verify-readiness.ts) |
| Keeper operations | [Keeper runbook and rounding policy](../looper/README.md) |
| Tests | [Solidity tests](../test/), [keeper tests](../looper/test/) |
| Formal verification | [Lean](../formal/README.md), [Verity bridge](../formal/bridge/README.md); assumptions and scope apply |
| Testnet | [lark-4 deployment record](../deployments/lark-4.md); historical, not production addresses |
| Native and long-term testing | [90-day stresses and fork evidence](market-stress-90d.md) |
| Main interest | [Policy comparison](interest-policy-comparison.md); not in RC1, buffer implementation in draft [PR #60](https://github.com/galacticcouncil/money-market/pull/60) |
| Peg stress | [Finite-funding/no-refill model](hollar-peg-liquidity.md) |
| Arbitrage and calibration | [Coupled model checkpoint](coupled-liquidity-checkpoint.md), [model scripts](../../scripts/propeller/) |
| Public evidence | [Pinned market fixture](../../scripts/propeller/fixtures/market-20260922.json), [calibration and preliminary outputs](evidence/2026-09-22/) |

## Confirmed Policy

- Protect original deposited-token principal, not its USD value. Never write off
  unpaid claims; block new deposits while underfunded. Governance funds residual
  HOLLAR shortfalls. Preserving a claim does not provide repayment liquidity.
- Compounded yield may cover emergency losses. All affected holders must be
  included fairly. Detailed manual recovery accounting is deferred; the ordinary
  FIFO queue is not itself a fair emergency-distribution mechanism.
- Configurable withdrawal delay defaults to 12 hours **before starting unwinds**.
  Emergency freeze stops withdrawals and settled claims. Safety operations remain
  separately available.
- Technical Committee controls Main HOLLAR discounts; PRIME-loop debt remains
  undiscounted. Governance sets per-vault fees, initially 5% of harvested
  collateral after swaps and before Main servicing. Fees accrue in collateral,
  permissionlessly claimable to the configured recipient.

## Verification of RC1

- Solidity: **231 passed, zero failed, three skipped** across 35 suites, rerun
  on 2026-09-23 at `55acd38` after the `hydration` merge. Optional fork/Verity
  suites were skipped; this is not a fresh native fork run.
- Keeper tests/build, native-rounding unit tests and standalone readiness
  TypeScript check passed. All five JavaScript model/calibration test files
  passed against the checked-in snapshot, including 24 coupled-model tests and
  five history-calibration tests.
- Previous `hdx.tarn` Chopsticks rehearsal deployed the contracts and exercised
  small real-route lifecycles using a **fork-only adapter and explicit external
  donor funding**. It did not verify the production HydraAugustus adapter or
  prove exits are self-financing.
- Runtime sizes at `55acd38` (optimizer 200, via IR, `--evm-version london`):
  CollateralVault 24,510 bytes (**66 bytes** below EIP-170), SubLoop 19,340,
  Harvester 7,042, SyntheticToken 4,827. Recheck size and deployment gas for
  every subsequent build/configuration.

Reproduce from `propeller-vault` after initialising the `bil-vault/lib`
submodules (see [Build / test](../README.md#build--test)):

```sh
FOUNDRY_ALLOW_PATHS="[\"$(realpath ../bil-vault/lib)\"]" forge test --offline
forge build --offline --evm-version london --sizes
```

`foundry.toml` defaults to `paris`; deployment scripts pass `--evm-version
london` (see [DEPLOYMENT.md](../DEPLOYMENT.md)). Both targets run on Hydration's
EVM; size figures are quoted for the London deploy target.

## Pre-Deployment Gates (Open)

RC1 is reviewable as-is; none of these gates is closed by publishing it.

1. Main-interest servicing and settlement-cost funding. More collateral
   increases borrowing headroom, not HOLLAR repayment proceeds. RC1 does not
   service Main interest; the candidate implementation is draft PR #60.
2. Verify Main protection under accrued debt, keeper outages and source losses;
   rehearse emergency pause and governance-funded recovery with all holders.
3. Deploy and test the production swap adapter, routes, approvals, slippage,
   custody, governance wiring and exact deployable artifacts on a fresh fork.
4. Resolve the independent PRIME-reference/oracle discrepancy and finish the
   calibrated six-TVL, 90-day bull/bear/seesaw liquidity campaign, including
   arbitrage/settlement outages, LP withdrawals and shared money-market cash.
5. Set justified TVL/ramp/pause budgets, arrange funded backstops and redundant
   keeper monitoring, then obtain independent review of the exact deployed candidate.

No production deployment, automatic recovery transfer, PR merge or production
configuration approval is implied by publishing these resources.
