# Main Interest and the Operating Buffer

**Historical proposal, superseded by [yield-funded Main servicing](main-debt-servicing.md).**
The sponsored buffer described below was removed from the revised implementation.

Implementation of the approved **harvest servicing + user-owned HOLLAR buffer**
policy. Fresh deployment only. Production coverage, stressed rate, exit-cost
allowance, bootstrap amount and TVL limits still require governance approval.
Seven days / 10bp in tests are scenario inputs, not production defaults.

## Cash Waterfall

1. Convert harvested PRIME into actual collateral, subject to the existing
   oracle-relative execution floor and measured input/output balances.
2. Collect the per-vault protocol fee on that gross collateral. The default
   remains 5%, before Main interest. Fee custody and recipient rules are unchanged.
3. Convert only the required portion of **fresh after-fee collateral** to HOLLAR.
   Service active holders' accrued Main interest and replenish their buffer.
4. Supply the remaining collateral to Main. Previously compounded collateral,
   settled collateral claims and the collateral rounding reserve are not sold.

`pokeSettle` can also service Main interest from already-owned HOLLAR between
harvests, including during an emergency freeze. Exhaustion leaves debt and claims
outstanding, never erases them or automatically sells collateral. A negative
source carry or active backing deficit blocks new deposits/upward borrowing.

The buffer is not a treasury fee or insurance against permanent strategy losses.
Governance still funds residual HOLLAR shortfalls. Maintaining a principal claim
does not make it immediately liquid, or guarantee the Main health floor through
an arbitrarily long keeper outage or adverse reserve/oracle changes.

## Ownership

Each vault has its own non-upgradeable `PropellerOperatingBuffer`, permanently
bound to that vault. It has no admin sweep or arbitrary payout recipient.

- **Bootstrap cash** is an irrevocable external donation, separate from user cash.
  It is not counted in the vault's debt-backing check or treasury revenue.
- **Active cash** belongs proportionally to active vault shares, including shares
  waiting through the withdrawal cooldown. Share transfers carry this entitlement.
- **Started exits** receive their own proportional cash and debt allocation.
  Subsequent interest and repayments cannot spend another exit's or the active
  cohort's cash. An exit's cash can bridge a short/delayed source payment.
- **Late source proceeds** remain attributable to the original exit, even after
  its Main debt and collateral claim have been fully paid. They are never silently
  donated to remaining holders or reassigned to the treasury.

An incoming deposit allocates bootstrap cash of at least:

```text
max(target_after_borrow - existing_active_cash,
    ceil(existing_active_cash * newly_minted_shares / previous_active_supply))
```

This prevents dilution of incumbents' HOLLAR entitlement without charging the
depositor's collateral. The first governance deposit must also be funded. Public
deposits and upward rebalances revert atomically when sponsorship is insufficient.
Bootstrap is not automatically spent to service old interest or repair losses.

**Unresolved incentive policy:** under the current donation semantics, allocated
bootstrap becomes a depositor subsidy. An exit can claim its unused portion;
deposit/withdraw cycling can repeatedly consume the finite sponsorship budget.
The cooldown delays this but does not eliminate it. No automatic treasury refill
exists. Governance must explicitly accept that subsidy design or change bootstrap
into repayable reserve capital before approving this candidate. A regression test
demonstrates the behavior; donated capital is never reported as investment yield.

`totalAssets` / `convertToAssets` continue to quote **collateral only**. The HOLLAR
entitlement is separate. After an exit's debt is fully paid, `claimBuffer(id)` is
permissionless but pays only its original owner. It returns HOLLAR, not collateral.
Later source recoveries can be claimed again. Both local and source emergency
pauses stop buffer payouts as well as collateral payouts.

The permanently locked bootstrap shares retain their proportional entitlement.
There is no sweep of their cash. Raw, unsolicited HOLLAR transfers to the vault
retain the legacy settlement behavior: they fund the current repayment head.
For fair governance recovery, use explicit `fundPosition(key, amount)` allocations
instead. Key 0 is the active cohort; withdrawal id N has key N+1.

## Debt and Settlement

Debt units allocate the **live Main debt-token balance**, including the cached
Main discount and interest accrued after withdrawals start. SubLoop debt is not
discounted. New borrowing mints units; actual repayments burn the paying cohort's
units. External repayments reduce the live unit value proportionally.

Borrowing records the measured debt increase, not an assumed one-for-one mint.
Repayment measures cash spent and actual debt reduction separately. A bounded
scaled-debt rounding retry can spend a few additional HOLLAR base units from the
paying cohort's cash; it never spends collateral or unallocated sponsorship.
The rounding allowance is derived from the live normalized variable-debt index.
Collateral settlement and synthetic burning use actual debt reduction, not a
nominal cash transfer. `Repaid` reports the cash cost as well as debt discharged.

An exit's initial debt snapshot remains the base for collateral release. Later
interest is paid first, without advancing its collateral settlement. Only payment
of the snapshotted debt advances `Redemption.repaid`. The existing
`totalQueuedDebt` therefore remains **unpaid snapshotted debt**, not a live interest
quote; sum the buffer's `debtOf(id + 1)` for current exit debt.

Main down-rebalance targets are different: they measure **total debt reduction**,
including paid interest, not just principal reduction. New unwind snapshots wait
until that resize and its source funding finish. Rebalances also wait for older
source claims, including claims whose collateral exit has already completed.

Source credit distribution is bounded to 64 cohorts per `pokeSettle`; another call
continues distribution without another source transfer. Source claims are never
written off. Ordinary settlement is still FIFO, not the deferred fair emergency
settlement engine. Governance must pause and account for all affected holders
before distributing scarce emergency recovery funds.

## Sizing

Governance explicitly configures a coverage interval, stressed annual rate floor
and gross exit-cost allowance. There is no enabled production default.

```text
x(r) = r * coverage_seconds / seconds_per_year
bound(r) = ceil(active_Main_debt * x(r) / (1 - x(r)))
interest_budget = max(ceil(bound(live_gross_rate) * (1 - cached_Main_discount)),
                      bound(stress_rate))
target = interest_budget + ceil(gross_source_exit_exposure * exit_cost_bps / 10000)
```

GHO discounts gross index growth, rather than compounding a discounted rate.
The interest bound requires x < 1 and conservatively covers compounded interest
at the chosen constant rate. It does not promise coverage after that interval or
after rates exceed the chosen stress assumptions. The current reserve rate is
read from the deployed Aave `ReserveData` ABI, not hard-coded.

`IYieldSource.exitCostExposure` reports gross exposure. SubLoop uses the larger of
observed gross collateral and fully ramped exposure at its live PRIME LT / deploy
HF floor, attributed to the vault's live source shares. This is deliberately not
just net equity or the currently un-ramped balance. A different yield source must
implement the new view. Execution cost, PRIME fair value, HOLLAR peg, native market
depth and settlement capacity still need independent calibration.

The exit allowance bridges Main repayment; it does not manufacture SubLoop
liquidity or forgive SubLoop liabilities. A residual source claim may remain after
collateral is released. Losses exceeding available cash still need governance.

## Deployment and Operations

The vault implementation constructs an immutable, stateless `CompoundLogic`
helper for compound/repayment execution. Only those two guarded vault entry paths
delegate to it; the target is not configurable and the helper does not access
vault storage. This preserves EIP-170 headroom without changing optimizer settings
or increasing the network's code-size limit.

1. Deploy the new source/vault implementations and fresh proxies.
2. Run `script/DeployOperatingBuffer.s.sol` once per vault. Supply all four
   `OPERATING_*` policy/funding inputs and `OPERATING_VAULT`; the script deploys
   the buffer and prints governance calls, not production funding transactions.
3. Dust-whitelist every buffer custody account before funding native assets.
   Execute buffer binding, policy configuration and explicit HOLLAR sponsorship.
   Wire the buffer before registering the vault with the fee controller.
4. Configure the real adapter for both PRIME-to-collateral and
   collateral-to-HOLLAR routes, with exact approvals and oracle floors.
5. Fund the separate collateral rounding reserve and governance seed deposit.
   Run readiness checks, approve budgets and open public deposits only afterward.

The keeper harvests before slow-cycle Main servicing, monitors coverage, avoids
new ramping while the buffer is below target, and continues pulling late source
recoveries after collateral exits. Contract funding guards remain authoritative.
Permissionless callers are not a substitute for redundant monitoring and timely
emergency governance.

## Verification Scope

Focused tests cover fee ordering, exhausted buffers, late deposits, separate exit
interest, partial repayments, late recoveries, pauses and configuration authority.
Stateful invariants account for every cash bucket, bootstrap cash and debt unit.

`OperatingBufferCampaign.t.sol` executes the actual Propeller contracts for the
selected policy's 180 main cases and 190 sensitivities. Aave accrual, prices, router
costs and unlimited market capacities are explicit fixtures. These are not 370
native forks or proof that the larger TVLs fit today's markets. The three rejected
policy alternatives remain historical off-chain controls, not new contract code.

The separate native rehearsal uses actual Hydration Pool/GHO/runtime execution,
small positions, public development keys, explicit donor funding and a clearly
labeled fork-only adapter. Production HydraAugustus remains a deployment gate.
Results and exact reproduction commands are recorded with the verification report.
