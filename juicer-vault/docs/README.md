# Juicer Team Documentation

**3 November 2026 | Launch candidate: PR #89, `juicer-headroom-exits` into `propeller` | Production activation blocked**

Juicer's current design uses harvest-time Main interest servicing,
source-funded resizing and an earned PRIME execution allowance. It does not
require sponsored HOLLAR operating capital. The candidate is PR #89; its
[review package](external-review.md) is the current reference. Dated
validations, Lark deployment records and model studies are listed in the
[archive](archive.md); they retain their original artifact scope.

The current version ([plan](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/next-version-plan.md)) enforces an on-chain
Main-backing admission ceiling (50 bps at initialize, 250 at launch) and retains
the keepers' hysteretic `deficitStop`, allocates yield at events instead of on
every transfer, and puts funded earnings in each holder's vault balance, so
nothing is claimed. The specifications below describe it. The loop's entries
and routine exits go out as ICE intents, asynchronously, with the router kept
for the safety de-lever. The [new-Lark runbook](lark-next-runbook.md) brings it
up on Lark 0.

## Start Here

| Reader                      | Start with                                                                                                   | Outcome                                                                   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Everyone                    | [Architecture and user lifecycle](../README.md)                                                              | Understand the two debt positions, funding flows and user protections.    |
| Release reviewers           | [Review package](external-review.md), [RC1 scope and activation gates](release-candidate.md)                 | Separate verified behavior from work required before production.          |
| Risk and governance         | [Principal and emergency policy](principal-safety.md), [Main servicing](main-debt-servicing.md)              | Review loss allocation, recovery funding and operating responsibilities.  |
| Liquidity and oracle owners | [PRIME pricing and replenishment](prime-pricing-replenishment.md)                                            | Assess reference wiring, executable spreads and launch inventory.         |
| Deployment and operations   | [Deployment runbook](../DEPLOYMENT.md), [keeper runbook](../looper/README.md)                                | Prepare exact artifacts, permissions, reserves, monitoring and rehearsal. |
| Contract reviewers          | [Servicing ledger](main-debt-servicing.md), [source upgrade boundary](source-upgrades.md), [tests](../test/) | Review accounting, recovery ownership and future compatibility.           |

## Agreed Design

- Protect original principal in the deposited token, not its dollar value.
  Preserve unpaid claims and stop deposits while underfunded: every deposit
  checks the live deficit and rejects it above the admission bound (50 bps at
  initialize, 250 at launch); keepers retain a hysteretic stop. Governance funds
  residual recovery; recording a claim does not make repayment liquid.
- Yield, including previously compounded yield, may contribute to an emergency
  recovery. That requires explicit per-holder reconciliation and a reviewed
  execution path, not an unrestricted treasury withdrawal.
- Withdrawals wait 12 hours by default (7 days at launch) before unwinding. Emergency freezes also
  block already-settled claims. Ordinary FIFO settlement is not all-holder
  emergency recovery.
- Governance and the Technical Committee control the Main and loop interest discounts.
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

PR #62 implements separate yield ownership; see [its specification](yield-ownership.md).
The [execution-controls implementation](execution-controls-implementation.md)
adds size/rate controls; production policy configuration remains an activation gate.
The PR completion records, dated validations, Lark deployment records and model
studies behind these documents are in the [archive](archive.md).

| Evidence | Scope |
| --- | --- |
| [RC verification](release-candidate.md#verification) | Current candidate summary; use this before historical test counts. |
| [PRIME validation](prime-pricing-replenishment.md) | Dated production reads, replacement feed checks, mint/bridge state and observed replenishment. |
| [Source compatibility](source-upgrades.md#checks-added-now) | Storage and accounting tests, not a migration implementation. |
| [Lean](../formal/README.md) and [Verity](../formal/bridge/README.md) | Formal artifacts with separate scope and assumptions. |
| [Archive](archive.md) | Dated validations, Lark deployments, campaigns and historical models; not current launch budgets or provider commitments. |

Raw outputs are checked in under [evidence](evidence/). Reports distinguish
mocked market behavior, native fork fixtures, live read-only observations and
funded recovery. Turnover is not committed replenishment; funded exits are not
proof of self-financing.

## Integration References

- Integration branch: `propeller`; launch candidate: PR #89, `juicer-headroom-exits`.
  The earlier `feat/propeller-interest-buffer`, `prop_carry` and `juicer-next`
  branches are historical.
- [PR #46](https://github.com/galacticcouncil/money-market/pull/46): umbrella integration; the agreed target is `hydration`.
- [PR #60](https://github.com/galacticcouncil/money-market/pull/60): Main-servicing work; earlier buffer terminology is superseded by the current specification.
- [PR #57](https://github.com/galacticcouncil/money-market/pull/57) and [PR #53](https://github.com/galacticcouncil/money-market/pull/53): discount/fee and accounting/yield-source review history.
- [Governance task](../../tasks/proposals/juicer.ts), [readiness checker](../../scripts/juicer/verify-readiness.ts), [deployment scripts](../script/).
- [lark-4 record](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/deployments/lark-4.md) and [PR #53 audit](../audit/propeller-audit-ys-propeller-fixes-20260731.md): historical context, not production addresses or RC approval.

Branch names and links identify the work; confirm live PR state and the exact
reviewed commit before merge or deployment.

## Superseded Material

The sponsored operating-buffer proposal and its verification, the
interest-policy comparison and the principal-safety history explain earlier
decisions but are not the current implementation specification. They are in
the [archive](archive.md).

The current specifications and RC checklist take precedence over historical
narrative. No production deployment, governance action or launch approval is
implied by publishing this documentation.
