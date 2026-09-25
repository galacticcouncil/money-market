# Yield-Funded Main Debt Servicing

Current RC1 specification, 23 September 2026. This supersedes the sponsored
operating-buffer proposal from the earlier PR #60 checkpoint.
Fresh deployments only. The old buffer evidence is historical, not verification
of these revised contracts. No production slippage setting is approved here.

## Funding and Principal

- Falling collateral prices trigger the existing banded Main rebalance. The
  vault requests a proportional PRIME-loop unwind; the loop repays its own debt
  and returns net HOLLAR, which repays Main. User collateral is not sold.
- Main interest is serviced from fresh harvested yield, after the existing
  per-vault protocol fee. The default fee remains 5% of collateral received by
  the harvest swap, before Main servicing. Only the remainder compounds.
- No HOLLAR cash target, duration/stress-rate policy, automatic sponsorship or
  sponsored withdrawal bonus remains. Binding a Main debt ledger does not
  require funding it. Governance's locked initial vault shares and collateral
  rounding reserve are distinct and still required.
- Unpaid interest remains debt. Earned source equity can back it between
  harvests; new deposits are blocked when backing is insufficient. Synthetic
  maintenance remains necessary independently of repayment liquidity.
- Entry costs arise before income. Early exits, negative carry, delayed fills
  and losses can require waiting or explicit governance recovery. Future yield
  is not counted as cash already available. No principal or source claim is
  erased to make settlement appear complete.

## Execution Costs

The source retains unharvested PRIME surplus against the current gross PRIME
position's configured oracle-relative execution-loss ceiling:

```text
cost_allowance = ceil(oracle_HOLLAR_value(aPRIME_balance) * slippage_ppm / 1e6)
harvestable = max(source_equity - active_cost_basis - pending_unwinds
                 - cost_allowance, 0)
```

This allowance is filled only by source surplus (yield or explicit incentives).
It is not a treasury-funded HOLLAR account, a new liability, an admission funding
requirement, or insurance. When earnings are smaller than the allowance, harvest
waits; it never takes users' collateral to fill it. An unwind earmarks its share
of un-compounded yield. Measured ordinary unwind swap losses reduce that yield
allowance and its source quote, never source cost basis or the vault's recorded
collateral promise. Unused allowance is returned with source proceeds; the
maximum permitted loss is not automatically charged as an exit fee. Costs beyond
earned allowance remain an unfunded liability requiring recovery.

At $4.8m gross exposure, a 1% ceiling retains about 48,000 HOLLAR-equivalent of
PRIME; a 10bp ceiling retains about 4,800. These are illustrative arithmetic,
not approved budgets or guaranteed cash. A wider execution ceiling therefore
also delays compounding. The allowance does not forecast long settlement-time
interest, future prices or arbitrary recovery costs.

Every entry and unwind transaction enforces the oracle floor on-chain, including
nonzero minimum output and bounded integer encoding. There is no automatic
slippage widening. An unsuccessful swap rolls back that transaction's borrowing
and asset movements. Operators may reduce governance-configured tranche sizes
or wait, but a strict floor can also stall safety deleveraging: monitoring and
recovery are still required. An inaccurate oracle reference is not repaired by
quietly weakening the floor.

The unchanged native market failed small entries at the tested 1% floor. The
later [production-adapter rehearsal](route-execution-calibration.md) retained
that floor but changed the oracle reference as an explicit fork fixture.
Neither that conditional success nor an older relaxed-floor fixture establishes
production execution or authorizes widening the loss ceiling.

## Main Debt Ledger

`PropellerMainDebt` replaces `PropellerOperatingBuffer`. Each fresh vault binds
one immutable ledger through `setMainDebt`. It accounts for live discounted debt,
active-holder and exit cash, source receivables, and explicit recovery donations.
It has no admin sweep, bootstrap budget or automatic sponsor allocation.

Measured debt increases/decreases, not nominal token transfers, determine debt
units and principal settlement. Exits pay their own post-start interest before
advancing collateral release. Proportional debt units also recognize direct Aave
repayment on behalf of the vault. A bounded scaled-debt rounding retry uses only
that cohort's actual HOLLAR.

Source cash and reported earned-yield execution expenses are allocated
proportionally to outstanding source claims in frozen batches of at most 64 exit
records per call. New unwinds wait until past receipts/costs are allocated.
Cumulative rounding conserves the entire receipt and cost. This prevents an early
exit from taking all the source's available earned cost allowance while later
exits retain all the execution shortfall. Collateral processing is still FIFO;
this is not the deferred governance emergency settlement/indexing system. A Main
resize target follows net source proceeds after measured expenses, whereas a
user's Main debt and collateral promise are never reduced by an expense entry.

`claimSurplus(id)` pays available HOLLAR only to the original exit owner after
that exit's Main debt is cleared. Late source claims remain attributable to that
owner. Local and source emergency pauses block this payout. Targeted recovery
uses `fundPosition(0, amount)` for active holders or `fundPosition(id+1, amount)`
for an exit; it does not mint vault shares. Raw vault donations retain their
legacy FIFO recovery behavior, so governance must use explicit cohort allocation
when funding affected holders fairly.

## Manual Incentives

Governance may approve HOLLAR and call Aave `repay` on behalf of either position:

- PRIME-loop repayment raises source equity without raising its cost basis.
  It first repairs any deficit, then supports retained execution allowance and
  harvestable carry. Harvest applies the existing fee/interest waterfall and
  compounds the remainder into the participating vaults' collateral.
- Main repayment lowers the selected vault's live debt. Existing active and exit
  debt units receive the proportional benefit. It does not directly raise the
  collateral share price; an upward rebalance can subsequently borrow again.

These are measured external subsidies, not organically earned yield. No automatic
incentive controller is added. Announced lump-sum incentives can attract timed
entry; a repay/harvest transaction group does not implement time-weighted rewards.

## Deployment

Deploy the fresh vault/source implementations and proxies, then run
`script/DeployMainDebt.s.sol` with `MAIN_DEBT_VAULT`. The script deploys the ledger
and prints its governance binding call; it has no HOLLAR funding inputs. Bind it
before fee registration and protect its native custody account from dust removal.
Keep the PRIME-to-collateral and collateral-to-HOLLAR routes, rounding reserves,
discount/fee bindings, governance handover and readiness checks.

Do not upgrade a live old-buffer deployment into this storage/API revision.
Propeller is not deployed, so migration is intentionally out of scope.

For upgrades after a future production deployment, preserve the stable source's
shares, claims and cumulative cost counters. See the [source upgrade boundary
and deferred rotation plan](source-upgrades.md); this preparation does not add
multi-strategy operation or live ledger replacement.
