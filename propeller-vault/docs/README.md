# Propeller Team Documentation

**9 October 2026 | Next version on `juicer-next`, PR #62 on Lark 4 | Production activation blocked**

Propeller's current design uses harvest-time Main interest servicing,
source-funded resizing and an earned PRIME execution allowance. It does not
require sponsored HOLLAR operating capital. The candidate is on
`prop_carry`. The [latest validation](deferred-deployment-validation-2026-10-04.md)
covers deferred deposits, shared swap controls, oracle price bounds and keeper
size selection. The [Lark deployment record](lark-deployment-2026-10-07.md)
covers the fresh-fork contracts, UI, hosted keepers, a mined and claimed
harvest, and the bots that keep Lark's oracles, pool prices and trade flow in
step with mainnet. Earlier reports retain their original artifact scope.

The next version on `juicer-next` ([plan](next-version-plan.md)) moves the
underfunding check to the keepers (they stop deposits through a `deficitStop`
flag), allocates yield at events instead of on every transfer, and puts funded
earnings in each holder's vault balance, so nothing is claimed. The
specifications below describe it. ICE intents are replacing the router for
entries, harvest swaps and normal exits, which become asynchronous, with the
router kept for the safety de-lever; that work (track B) is still being
integrated and not yet documented. The [new-Lark runbook](lark-next-runbook.md)
brings the next version up on Lark 0.

## Start Here

| Reader                      | Start with                                                                                                   | Outcome                                                                   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Everyone                    | [Architecture and user lifecycle](../README.md)                                                              | Understand the two debt positions, funding flows and user protections.    |
| Release reviewers           | [RC1 scope and activation gates](release-candidate.md)                                                       | Separate verified behavior from work required before production.          |
| Risk and governance         | [Principal and emergency policy](principal-safety.md), [Main servicing](main-debt-servicing.md)              | Review loss allocation, recovery funding and operating responsibilities.  |
| Liquidity and oracle owners | [PRIME pricing and replenishment](prime-pricing-replenishment.md)                                            | Assess reference wiring, executable spreads and launch inventory.         |
| Deployment and operations   | [Deployment runbook](../DEPLOYMENT.md), [keeper runbook](../looper/README.md)                                | Prepare exact artifacts, permissions, reserves, monitoring and rehearsal. |
| Contract reviewers          | [Servicing ledger](main-debt-servicing.md), [source upgrade boundary](source-upgrades.md), [tests](../test/) | Review accounting, recovery ownership and future compatibility.           |

## Agreed Design

- Protect original principal in the deposited token, not its dollar value.
  Preserve unpaid claims and stop deposits while underfunded: the keepers check
  the deficit off-chain and stop deposits above 50 bps. Governance funds
  residual recovery; recording a claim does not make repayment liquid.
- Yield, including previously compounded yield, may contribute to an emergency
  recovery. That requires explicit per-holder reconciliation and a reviewed
  execution path, not an unrestricted treasury withdrawal.
- Withdrawals wait 12 hours by default before unwinding. Emergency freezes also
  block already-settled claims. Ordinary FIFO settlement is not all-holder
  emergency recovery.
- Governance and the Technical Committee control the Main-only interest discount.
  Governance sets per-vault harvest fees, initially 5%. Fees accrue in collateral
  and are permissionlessly payable to the configured treasury recipient.
- Fresh after-fee harvests service Main interest. PRIME-loop unwind proceeds
  resize Main debt. Earned PRIME retention covers eligible execution costs;
  it is neither insurance nor a guaranteed repayment budget.
- Strategy rotation and incident-specific all-holder recovery accounting remain
  deferred. Their fairness and compatibility requirements are documented now.

See the [RC checklist](release-candidate.md#activation-gates) for unresolved
launch decisions. Defaults and experimental limits are not deployment approvals.

## Current Specifications

| Topic                                             | Document                                                           |
| ------------------------------------------------- | ------------------------------------------------------------------ |
| Main interest, execution allowance and incentives | [Yield-funded Main servicing](main-debt-servicing.md)              |
| Discount authority, eligibility and cache refresh | [Main borrowing discount](main-borrow-discount.md)                 |
| Fee basis, recipient and claims                   | [Per-vault protocol fees](protocol-fees.md)                        |
| Yield ownership, allocation and balances | [Separate ownership, event allocation, balances without claims](yield-ownership.md) |
| Principal, delay, pauses, rounding and recovery   | [Principal preservation](principal-safety.md)                      |
| Future source rotation                            | [Upgrade boundary and deferred implementation](source-upgrades.md) |

## Verification and Research

The [2 October PR integration checkpoint](pr-integration-2026-10-02.md) records
the combined #60/#61/#63 regression and updated runtime sizes. PR #62 implements separate yield
ownership; see [its specification](yield-ownership.md) and
[implementation validation](pr62-completion-2026-10-02.md).
The later [execution-controls implementation](execution-controls-implementation.md)
adds size/rate controls; production policy configuration remains an activation gate.

[September 25 PR completion](pr60-completion.md) resolves the target-branch
documentation conflicts and the model replay failures recorded in RC1. It
includes a reproducible, fixture-selected verification command and hashed logs.

| Evidence                                                                                                                                   | Scope                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| [RC verification](release-candidate.md#verification)                                                                                       | Current candidate summary; use this before historical test counts.                                           |
| [Lark deployment, 7 October](lark-deployment-2026-10-07.md) | Fresh-fork contracts, hosted keepers, a mined and claimed harvest, and mainnet-synced oracles, pool prices and trade flow. Test policies and subsidies only. |
| [Production adapter and execution calibration](route-execution-calibration.md)                                                             | Conditional native lifecycle, real-route quotes, Main resizing and 2,220 retention/cost scenario executions. |
| [PRIME validation](prime-pricing-replenishment.md)                                                                                         | Dated production reads, replacement feed checks, mint/bridge state and observed replenishment.               |
| [Swap costs with operator-funded gas](sponsored-gas-swap-costs-2026-10-03.md) | Re-ranked existing APY cases; fees and price impact separated from external operator expenses. |
| [PRIME recovery history and perfect arbitrage](prime-recovery-history-2026-10-03.md) | Exact Neckwork reserves, finite Treasury DCA, competing flow and conditional replenishment timing. |
| [Four rounds of historical APY modeling](historical-apy-four-rounds-2026-10-03.md) | 90 days of exact oracle/index/pool inputs, observed versus perfect arbitrage, actual bull/pullback/saw regimes and held-out controls. |
| [Main debt verification](main-debt-verification.md)                                                                                        | Earlier 370-case contract campaign and native entry rejection; retained as dated evidence.                   |
| [Source compatibility](source-upgrades.md#checks-added-now)                                                                                | Storage and accounting tests, not a migration implementation.                                                |
| [Lean](../formal/README.md) and [Verity](../formal/bridge/README.md)                                                                       | Formal artifacts with separate scope and assumptions.                                                        |
| [90-day market study](market-stress-90d.md), [HOLLAR peg study](hollar-peg-liquidity.md), [coupled model](coupled-liquidity-checkpoint.md) | Historical models and calibration; not current launch budgets or provider commitments.                       |

Raw outputs are checked in under [evidence](evidence/). Reports distinguish
mocked market behavior, native fork fixtures, live read-only observations and
funded recovery. Turnover is not committed replenishment; funded exits are not
proof of self-financing.

## Integration References

- Integration branch: `propeller`; current RC work: `feat/propeller-interest-buffer`;
  next version: `juicer-next`, stacked on `prop_carry`.
- [PR #46](https://github.com/galacticcouncil/money-market/pull/46): umbrella integration; the agreed target is `hydration`.
- [PR #60](https://github.com/galacticcouncil/money-market/pull/60): Main-servicing work; earlier buffer terminology is superseded by the current specification.
- [PR #57](https://github.com/galacticcouncil/money-market/pull/57) and [PR #53](https://github.com/galacticcouncil/money-market/pull/53): discount/fee and accounting/yield-source review history.
- [Governance task](../../tasks/proposals/propeller.ts), [readiness checker](../../scripts/propeller/verify-readiness.ts), [deployment scripts](../script/).
- [lark-4 record](../deployments/lark-4.md) and [PR #53 audit](../audit/propeller-audit-ys-propeller-fixes-20260731.md): historical context, not production addresses or RC approval.

Branch names and links identify the work; confirm live PR state and the exact
reviewed commit before merge or deployment.

## Superseded Material

These documents explain earlier decisions and retain evidence, but are not the
current implementation specification:

- [Sponsored operating-buffer proposal](operating-buffer.md) and [its verification](operating-buffer-verification.md).
- [Interest-policy comparison](interest-policy-comparison.md).
- [Principal-safety history](principal-safety-history.md), including dated test counts and original recovery discussions.

The current specifications and RC checklist take precedence over historical
narrative. No production deployment, governance action or launch approval is
implied by publishing this documentation.
