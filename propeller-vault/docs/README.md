# Propeller Team Documentation

**23 September 2026 | RC1 for review | Production activation blocked**

Propeller's current design uses harvest-time Main interest servicing,
source-funded resizing and an earned PRIME execution allowance. It does not
require sponsored HOLLAR operating capital. The local candidate is on
`feat/propeller-interest-buffer`; the branch name predates that decision.

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
  Preserve unpaid claims and block deposits while underfunded. Governance funds
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
| Principal, delay, pauses, rounding and recovery   | [Principal preservation](principal-safety.md)                      |
| Future source rotation                            | [Upgrade boundary and deferred implementation](source-upgrades.md) |

## Verification and Research

| Evidence                                                                                                                                   | Scope                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| [RC verification](release-candidate.md#verification)                                                                                       | Current candidate summary; use this before historical test counts.                                           |
| [Production adapter and execution calibration](route-execution-calibration.md)                                                             | Conditional native lifecycle, real-route quotes, Main resizing and 2,220 retention/cost scenario executions. |
| [PRIME validation](prime-pricing-replenishment.md)                                                                                         | Dated production reads, replacement feed checks, mint/bridge state and observed replenishment.               |
| [Main debt verification](main-debt-verification.md)                                                                                        | Earlier 370-case contract campaign and native entry rejection; retained as dated evidence.                   |
| [Source compatibility](source-upgrades.md#checks-added-now)                                                                                | Storage and accounting tests, not a migration implementation.                                                |
| [Lean](../formal/README.md) and [Verity](../formal/bridge/README.md)                                                                       | Formal artifacts with separate scope and assumptions.                                                        |
| [90-day market study](market-stress-90d.md), [HOLLAR peg study](hollar-peg-liquidity.md), [coupled model](coupled-liquidity-checkpoint.md) | Historical models and calibration; not current launch budgets or provider commitments.                       |

Raw outputs are checked in under [evidence](evidence/). Reports distinguish
mocked market behavior, native fork fixtures, live read-only observations and
funded recovery. Turnover is not committed replenishment; funded exits are not
proof of self-financing.

## Integration References

- Integration branch: `propeller`; current RC work: `feat/propeller-interest-buffer`.
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
