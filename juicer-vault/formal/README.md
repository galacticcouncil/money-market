# juicer-vault — Lean 4 formal spec

Formal verification of **Juicer** — a protocol-managed leveraged-yield product on
Hydration — in **Lean 4**. Contains conditional mathematical proofs and executable integer models checked against Solidity.
[Current implementation mapping and limits](SOLIDITY_PARITY.md) is the coverage record.
[Source-body and guard-prefix proofs](SOLIDITY_BODIES.md) record the compiled AST bindings and their trust boundary.
[Funded-transfer rounding](ROUNDING.md) records the allowance fix and a separate seeded
counterexample to exact aggregate unit conservation across lazy rescales.

Lives beside the contracts it models: `juicer-vault/{src,test,formal}`.
A self-contained Lake project; `check-runtime.py` builds Lean and runs the Foundry comparisons.
Strategy: Path C.

## Layout

```
JuicerLean/
├─ Spec/
│  ├─ State.lean          balance-sheet State, mainHF / borrowCapacity / subHF, WellFormed
│  ├─ Invariants.lean     principalFloored, pegBand, subLoopHealthy
│  ├─ Floor.lean          Phase 1: the "never liquidated" theorems
│  ├─ Ops.lean            transitions: mintSynthToPeg, maintainPeg, accrueInterest, tick, repay
│  ├─ Preservation.lean   Phase 2: invariant preservation; tick_safe (HF≥1 after every tick)
│  ├─ Redemption.lean     Phase 2: escrow / shareConservation / freedBacked → collateral_out_ge_in;
│  │                      next version: the exit fold (burned units' funded slice → escrow)
│  ├─ SubLoop.lean        single-vault loop model: deLever, accrueLoop (yield), the full Op
│  │                      trace semantics (LoopSafe/Safe/SafeBacked closed under any op list);
│  │                      next version: ICE intents in flight (IceLoop)
│  ├─ SubLoopShares.lean  multi-vault shared-loop share model: deposit/unwind conservation +
│  │                      per-vault isolation (one vault's ops can't move another's equity)
│  ├─ RedeemCredit.lean   `_creditFreed` redemption-credit model: the shipped (floored,
│  │                      remaining-weighted) rule never over-credits; the REJECTED
│  │                      requested-weighted alternative provably does (bug G, formalized)
│  ├─ Aggregate.lean      portfolio-wide (whole book of positions) theorems: no over-mint,
│  │                      peg band, and collateral-out-ge-in across every position at once
│  ├─ YieldShares.lean    next version (plan §3): balances that include funded earnings, no
│  │                      claims — Σ balanceOf identity, exact local transfers, value conservation
│  ├─ Allocation.lean     next version (plan §2): event-driven allocation on a lazy index —
│  │                      refines YieldShares, transfers settle two holders, no pre-entry yield
│  └─ Examples.lean       worked numeric instances (concrete ETH position, one-wei mint,
│                          loop-at-HF-1.05, full-unwind) cross-checking the Solidity test suite
└─ FixedPoint/
   ├─ Uint256.lean        WAD/bps integer model (what Solidity stores)
   ├─ Runtime.lean        current integer accounting and single-slot ICE behavior
   ├─ Rounding.lean       displayed-transfer bounds and integer/real mul-div refinement
   ├─ YieldTransitions.lean reserve limits, exit/harvest conservation and settled ownership traces
   ├─ LazyOwnership.lean  lazy holder traces with an explicit rescale rounding budget
   ├─ RescaleBounds.lean  uniform slack and funded-claim bounds across bounded rescale histories
   ├─ RoundingResidue.lean cumulative unit/funded under-credit bounds through lazy histories
   ├─ LazyRefinement.lean epoch/scale normalization, runtime bounds and a rescale counterexample
   ├─ Lifecycle.lean      holders and waiting requests, share partition and reachable liability bounds
   ├─ LifecycleRefinement.lean request creation, exact runtime exit normalization and escrow guards
   ├─ MainDebt.lean       debt cohorts, source batches, vested fees and reserve limits
   ├─ Orchestration.lean  frozen batch cursors, later receipts, bounded calls and repayment retry
   ├─ MainHistories.lean  reachable source-claim and cash partitions across cohort operations
   ├─ PolicyQueue.lean    controller budgets, quotes, FIFO starts and collateral claims
   ├─ QueueHistories.lean repeated settlement/claim histories and FIFO settlement work
   ├─ PublicCalls.lean    raw public-call sequences, harvest/fees, debt rounding, deleveraging and rollback
   ├─ PublicInvariants.lean custody, source, cash and lifecycle invariants for public-call histories
   ├─ PublicPreservation.lean successful allowance/transfer custody preservation helpers
   ├─ PublicStateProofs.lean concrete settlement and normalized liability preservation
   ├─ PublicTransferProofs.lean wallet, funded-unit and allowance preservation
   ├─ PublicClaimProofs.lean started-request claims and concrete queue partitions
   ├─ PublicCertificates.lean checked public-call semantics and combined invariant certificates
   ├─ SolidityDispatch.lean typed 31-opcode fixture dispatcher and universal raw-call correspondence
   ├─ PublicReachability.lean certified raw-call domain and arbitrary finite trace preservation
   ├─ PublicBoundaryRegressions.lean fabricated future epochs and vault impersonation boundaries
   ├─ ScaledDebt.lean     Aave half-up ray arithmetic and executable scaled-balance histories
   ├─ Checked.lean        uint256 arithmetic failures and atomic transaction semantics
   ├─ CheckedRefinement.lean successful checked operations refine the natural-number models
   ├─ Environment.lean    external observation guards and ICE authentication limits
   ├─ AuditChanges.lean   PR #79 arithmetic, pacing, fund and empty-request regressions
   ├─ SharedIntent.lean   shared SubLoop intents, two vaults, gifts and harvest ordering
   ├─ AuditProgress.lean  conditional queue and pacing progress proofs
   ├─ AuditLossAllocation.lean executable audit counterexamples for loss assignment
   └─ Refine.lean         Phase 3: integer floor guard conservatively refines the real floor,
                           incl. the loop-yield (accrueLoop) and re-peg fixed-point refinements
```

`BRIDGE_SPIKE.md` — Phase 4 EVM bridge go/no-go (Verity-native; **GO, qualified**).

## Headline results (all machine-checked, 0 `sorry`, axioms = `propext`/`Classical.choice`/`Quot.sound` only)

| Theorem | Claim |
|---|---|
| `floor_main_hf` | `principalFloored ⟹ mainHF ≥ 1` |
| `never_liquidated_at_any_price` | the floor holds at **every** price `p ≥ 0`, incl. `p = 0` |
| `peg_floored` | the spec mint rule (`synth·LT = mainDebt·k`, `k ≥ 1`) establishes the floor |
| `synth_adds_no_borrow_power` | the vault borrowing budget excludes synthetic; Aave itself gives it 100 bps LTV |
| `tick_safe` | a maintenance tick (accrue interest → re-peg) lands at `mainHF ≥ 1` |
| `collateral_out_ge_in` | under `freedBacked`, settlement returns ≥ the deposited collateral |
| `claimShares_escrowOk` | escrow stays a non-negative subset of shares (`escrow`) |
| `principalFloored_refines` | the on-chain integer floor guard conservatively implies the real floor |
| `run_LoopSafe` / `run_SafeBacked` | the full `LoopSafe`/`Safe`/`freedBacked` bundle is closed under **any** trace of ops (deposit, tick, repay, deLever, accrueLoop, redemption) |
| `genesis_run_mainHF` | `mainHF ≥ 1` from genesis (deposit) through any subsequent valid op trace |
| `solidity_dispatch_corresponds` | the complete source-pinned 31-opcode fixture dispatcher selects the same raw model call for every action |
| `validSolidityTrace_invariant` | every arbitrary finite raw trace in the certified Solidity action domain preserves the combined public invariant |
| `validSolidityReachable_invariant` | every state reachable through certified raw fixture transitions satisfies the combined public invariant |
| `ordinaryTrace_fixture_ready` | every arbitrary finite ordinary trace from any of the three Solidity fixture genesis states preserves the financial invariant and all public-call readiness premises |
| `agg_synthConserved` | no over-mint of the synthetic across the **whole book** of positions at once |
| `agg_collateral_out_ge_in` | portfolio-wide redemption solvency: aggregate collateral out ≥ in, under `freedBacked` |
| `deposit_conserved` / `deposit_isolation` | shared-loop deposit conserves total shares and cannot move another vault's balance |
| `requestUnwind_conserved` / `requestUnwind_isolation` | same, for unwind requests |
| `floored_credit_no_over_credit` | the shipped `_creditFreed` weighting (remaining-to-credit, floored) never distributes more than `freed` |
| `buggy_over_credits` / `buggy_strictly_over` | the REJECTED requested-weighted alternative provably over-credits — this is bug G, kept as a negative result so the fix's rationale is machine-checked too |
| `accrueLoop_restores_freedBacked` | modeling loop yield: equity growth raises `subHF` and restores `freedBacked` after redemption pressure |

## Runtime correspondence

aligned with PR #79's audit fixes, including the earlier allowance and ceil-rescale fixes. `solidity-manifest.json` records the
exact source snapshot. the real-number models prove ideal accounting properties;
`FixedPoint/Runtime.lean` adds current integer arithmetic, epoch and rescale behavior.
Run `python3 check-runtime.py` to rebuild proofs, regenerate and compare 1,526 Lean cases with the
actual Solidity, and detect source, compiled-artifact or storage-layout drift. Same integrity bar: 0 `sorry`, axioms
`propext`/`Classical.choice`/`Quot.sound` only.

The integer lazy-account model proves aggregate bounds through settlement, wallet-weight changes,
allocation, unit movement, burns, rescaling and write-off. Account and waiting-request indices use
an overflow-safe ceil shift during rescaling. `RescaleBounds.lean` proves the numerator slack stays
below one precision unit through arbitrary histories from genesis, so aggregate unit claims and
aggregate funded claims cannot exceed their respective totals.
The lifecycle layer includes waiting requests' committed units and accrual weights. Its share
partition derives the allocation weight premise from genesis. Resumable source batches, retries,
partial/final claim histories and selected checked-arithmetic failures have separate executable
models and proofs. These are integer transition proofs with explicit environmental boundaries.
the fixture dispatcher map is complete and source-checked. `check-bytecode.py` reproducibly pins
creation bytecode, runtime templates, compiler settings, immutable/link references and method ids
for 11 production contracts; it detects artifact drift but does not prove semantic equivalence
between contract bodies and Lean. The table below
describes the separate ideal-arithmetic models.

| Theorem | Claim |
|---|---|
| `ShareBook.totalBalance_add` / `ShareBook.run_totalBalance_add` | Σ balanceOf + (waiting requests' units)/totalUnits × F = totalSupply at every state reachable by deposit, transfer, allocation, harvest, requestRedeem and the escrow burn; so Σ balanceOf ≤ totalSupply, `=` once no units wait with a request (`totalBalance_eq`) |
| `ShareBook.sum_slice_le` | the holders' funded slices never exceed F |
| `ShareBook.transfer_balanceOf_from` / `_to` / `_other` | a transfer within the sender's balance moves exactly `x` of displayed balance; no third account's balance moves |
| `ShareBook.transfer_frame` / `ShareBook.transfer_value` | a transfer writes only the two holders' wallets and units; value moves only between them |
| `ShareBook.allocate_totalValue` / `allocate_value_mono` / `allocate_slice_dip` | allocation adds exactly the new yield in value and never lowers a holder's value; a displayed slice can dip by at most the holder's pro-rata share of the new yield |
| `ShareBook.requestRedeem_max_empties` | `requestRedeem(balanceOf)` escrows the whole wallet and commits every unit |
| `ShareBook.rejected_claim_shifts` | the plan's first claim rule (take `units/T × F`, burn units by value) lowers every passive holder's slice once S > 0 — kept as the reason for the redesign |
| `LazyBook.view_run` / `LazyBook.run_totalBalance_add` | the lazy index (one bump per event, holders settled only when touched) implements the eager book along any trace, so the balance identity holds at every lazily reachable state |
| `LazyBook.transfer_frame` / `LazyBook.transfer_noAlloc` | a transfer settles and writes only its two holders; it moves no index and mints no units |
| `LazyBook.allocation_consistent` / `LazyBook.allocate_view_congr` | an event credits `m × weight/outside` on the balances standing at the event, however many transfers preceded it and whenever each holder last settled |
| `lazy_trace_slack_lt_precision` / `lazy_genesis_funded_no_overclaim` | arbitrary lazy-ledger histories from genesis keep sub-precision slack and cannot overclaim aggregate funded shares |
| `residue_trace_bound` / `lazy_units_residue` / `lazy_funded_residue` | an explicit cumulative budget bounds aggregate unit and funded under-credit through allocation, settlement, transfer, escrow, start, burn, repeated rescale and write-off |
| `certified_calls_preserve` | collateral custody is conserved through any hand-certified history of raw public-call results; failed raw calls supply frame certificates automatically |
| `runCall_success_preserves` / `execute_preserves` | every successful checked public call satisfies the combined public invariant, and every checked execution preserves it from a certified input because rejected calls roll back |
| `certifiedReplay_total` / `certifiedReplay_preserves` | every finite checked-call sequence from a certified input produces certificates, and every state in the resulting history satisfies custody, source/cash, lifecycle and operational invariants |
| `source_partition_of_history` / `cash_partition_of_history` / `lifecycle_claim_bound_of_history` | public-state projections inherit the existing Main source, cash and lazy-liability bounds from arbitrary valid transition histories |
| `rayMulHalf_interval` / `rayDivHalf_interval` | Aave's half-up ray multiplication and division lie in their exact quotient intervals |
| `ShareBook.eventVsTransfer` | against the old per-transfer allocation, only the interval's pre-transfer yield on the moved shares changes hands |
| `ShareBook.deposit_newcomer` / `ShareBook.mintFirst_captures` | deposits allocate before they mint, so a newcomer captures no pre-entry yield (minting first would) |
| `ShareBook.startExit_wallets` / `ShareBook.startExit_fold` | share conservation including the exit fold: supply and holders' wallets unchanged; exactly the burned units' funded slice moves from the fund into the escrow and joins the request's shares |
| `ShareBook.startExit_fullExit` / `ShareBook.requestRedeem_max_then_startExit` | after a full exit the owner has no units, no slice of the fund and no balance |
| `ShareBook.startExit_slice_other` / `ShareBook.startExit_unitPrice` | an exit moves nobody else's slice or unit price |
| `State.startExit_requestRedeem` / `State.startExit_escrowOk` | seen by the redemption state the fold is `requestRedeem fold`, so `escrowOk` survives it |
| `ShareBook.startExit_quote` / `ShareBook.runExit_totalBalance_add` | quoting after the fold pays the folded shares at the same per-share value and keeps the remaining holders'; the balance identity holds through any trace with exits |
| `IceLoop.submit_equity` / `IceLoop.run_equity_noFill` | in-flight input counts in equity at oracle value; submit, expiry, callback and reconcile keep equity — only a fill moves it, by exactly the execution difference (`fill_equity`; no worse than the slippage floor, `fill_equity_ge`) |
| `IceLoop.submit_grossHF` / `IceLoop.ramp_fill_grossHF` / `IceLoop.ramp_aaveHF_lt` | abstract gross-asset ratio only; runtime HF adds in-flight input and available unwind cash to collateral, leaving debt unchanged |
| `IceLoop.submit_oracleSaleOk_iff` / `IceLoop.deLever_raises_grossHF` | the abstract oracle-fair sale preserves signed equity and raises its gross-asset ratio; the runtime trigger is modeled separately |
| `IceLoop.submit_busy` / `IceLoop.late_callback` / `IceLoop.reconcile_eq_callback` | one intent per lane, never overwritten; once reconciled, a late callback changes nothing after any further trace; callback and reconcile record the same thing |
| `IceLoop.naiveEquity_sub_equity` | an equity view that keeps counting a pending record after its outcome landed overstates by exactly that input |
| `IceLoop.oracleSaleOk_iff_valid` / `IceLoop.onto_subHF` | a quiescent loop (no idle cash, nothing in flight) is the original `State` loop |

## Build & verify

```sh
. ~/.elan/env
lake build
# integrity gate:
echo 'import JuicerLean
#print axioms Juicer.State.floor_main_hf
#print axioms Juicer.FixedPoint.principalFloored_refines' | lake env lean /dev/stdin
```

Toolchain: Lean `v4.30.0` + Mathlib `v4.30.0` (pinned in `lean-toolchain` / `lakefile.toml`).

## Current Solidity arithmetic

`FixedPoint/Runtime.lean` covers ceil-first synthetic minting (including dust), account epochs and
unit shifts, rounded unit transfers, allocation and write-offs, exit folds, backing gross-up,
harvest splits, and single-slot ICE observation, HF, equity, de-lever target and callback guards.
Its universal proofs include the synthetic floor for every debt, caps and unit conservation,
four rescale steps for any uint256 total, and stale/unauthorized callback behavior.

The checked-in vectors are generated by Lean, not copied from Solidity test expectations.
`MachineVectors.lean` adds 604 cases: 488 arithmetic boundaries, 40 account views, eight backing
gross-ups, 12 resumable batches, 32 retries and 24 three-claim histories. The boundary cases check
exact revert data as well as successful values. The public lifecycle regression starts from
deposits and uses the vault's actual transfer, request, start, settle and claim entrypoints;
external pool/yield behavior is mocked. Separate rollback tests exercise failures after writes.
The old Verity bridge remains a separate simplified reference model; see [bridge scope](bridge/PARITY.md).

`python3 check-stateful.py` runs public-call campaigns in three fixtures and replays them in Lean
from fixture genesis. The checker compares state and outcomes after every step, enforces accounting
partitions and rejects incomplete traces. every action is decoded through the typed Solidity map,
checked against the fixture domain and executed by `rawRunCall`; every successful post-state must
carry the combined certificate. twenty-one opcodes, including compound, are admitted from their pre-state
invariant alone; transfer and transferFrom additionally require ordinary holders and bounded
destinations, claim requires a started request, and sync, requestRedeem and deposit require
account/request epochs and scales consistent with the book's history. requestRedeem also requires
an ordinary owner; deposit requires a bounded receiver and a zero reward index when supply is zero.
rebalance additionally requires zero fee remainder when the active source remainder is zero.
pokeSettle requires backed queue collateral, consistent batch weights/budgets, backed fees and
source pull/cost rates at most 10000 basis points. harvest burns the minimum of its quote and
the single-vault fixture's held-share capacity; the capacity bound is unconditional. startUnwinds
requires consistent metadata, queue backing, ordinary waiting owners and a fee rate at most
10000 basis points; its proof covers arbitrary loop lengths. all 31 opcodes have preservation
proofs based on inputs. domain admission uses those rules or a raw revert, with no successful
post-state certificate fallback.

account/request metadata is inductive across every raw call, including reverts and unsupported
opcodes, without financial or fixture-domain premises. `PublicCallBounds` proves that source
pull/cost rates and fee rates stay at most 10000 basis points and every stored request retains an
ordinary owner across arbitrary finite fixture-call histories. `PublicReady` combines those facts
with initialization, active-fee, queue-backing, credit-readiness and the financial invariant.
`OrdinaryAction` retains the source-pinned fixture restrictions, limits direct transfer callers
to the four external holders, and requires a started claim or a raw revert; it assumes none of
the accounting readiness predicates. `ordinaryTrace_fixture_ready` derives the complete
certificate for arbitrary finite ordinary histories from each concrete fixture genesis, including
rollback. credit readiness keeps the source prefix empty during suspended batches and preserves
fee backing through repayments and appended exits.

negative regressions make the domain and model corrections explicit. the permissive old fixture
domain can impersonate the locked-share address, drain supply to zero, and retain a nonzero reward
index; the initialization theorem excludes that caller. a public harvest history quotes
`750000000000000002` source shares while holding `750000000000000000`. Solidity already caps the
burn. the model now applies that cap and consumes only the realized source/protocol reserve slice,
preserving the two remaining reward units until the next checkpoint. deposits also reject amounts
above the caller's collateral balance before consuming it; raising the TVL cap previously exposed
a successful model deposit where ERC20 transfer reverts. Solidity rollback regressions and
kernel-checked model cases cover both fixture balance scales.
the baseline covers vault/Main queues and claims; the
market fixture adds harvests, compounding, nonzero fees/costs, interest, debt rounding and
price-driven deleveraging. the loss/recovery fixture keeps ray-scale holders and a waiting request
live across repeated partial write-downs and recoveries, verifies that carry restores incumbent
claims before new weight can mint units, and then settles, starts, claims, writes off and refills.
the public history must remain at scale zero. larger campaigns are configurable. see
[stateful parity](STATEFUL_PARITY.md) for generated counts, coverage gates and external mock
boundaries. `check-runtime.py` includes all three default fixtures plus two focused ten-call
harvest-capacity replays.

`AuditChanges.lean` covers the first allocation's whole-fund units, the 99% arrival threshold,
effective backing, proportional pacing and cash-based delever repayment. empty requests may
start with zero shares, owed collateral and debt; the queue proofs retain their cumulative payout
and burn bounds. the gate also runs the PR #79 public-flow regressions for fund rejection,
empty queues, foreign collateral flags, safety sales and harvest reconciliation.

`SharedIntent.lean` follows two vaults through actual SubLoop intent inputs and outputs, landed
fills, refunds, balance rebasing, unwind cost checkpoints and Harvester weight reads. six traces
execute the production SubLoop and Harvester for 1,176 public calls and compare every modeled
field and return or revert. mutation coverage delays Harvester reconciliation and is rejected in
six states. the traces also retain a separate pallet state, so a near-full unsolicited arrival
can clear SubLoop's slot while the original pallet intent remains open.

`AuditProgress.lean` states liveness assumptions explicitly: mature requests, enough repayment
cash and debt capacity, positive lane capacity, no uint64 wrap and continued keeper calls. under
those assumptions it proves bounded progress for arbitrary empty and funded queues, target
clearance despite repayment rounding, and at most one extra pacing quantum per fragment.
`AuditLossAllocation.lean` retains the original loss-allocation counterexamples and adds the
implemented policy boundaries: deposits admit at most a rounded-up 50 bps deficit, a pending
intent freezes deposits/requests/pulls, parked gifts keep a per-vault owner, and partial reserve
recovery restores the prior loss carry before current wallet weight can mint units. capped exit
cost above a request's earned allowance remains an explicit source liability under the principal
preservation policy. this maps audit findings #3/#19 and #32/#39 to the shared replay,
#5/#12/#29/#30/#31 to conditional progress, and #6/#13/#15/#22/#25/#35/#38 to the executable
loss-allocation boundaries.

`check-dispatch.py` independently checks all 31 target, selector and action-argument mappings
against the pinned Solidity `perform` functions. `solidity_dispatch_corresponds` and
`solidity_execute_corresponds` then prove the typed dispatcher equals the raw Lean public-call
machine for every action, including unsupported opcodes.

`check-bytecode.py` rebuilds and hashes the production creation bytecode and runtime templates at
the pinned solc 0.8.22, optimizer-200, via-ir, Paris settings. it also checks the ABI selectors used
by the production-target fixture branches. constructor immutables remain template references, so
this is an artifact-identity check rather than a deployed-address or semantic-equivalence proof.

`solidity_bodies.py` extracts the actual solc AST for `_shiftIndex` and five stateful bodies:
vault `deposit`, `startUnwinds`, `pokeSettle`, and accounting `beginHarvest`, `splitHarvest`.
the pure helper uses a checked uint256 interpreter. the stateful bindings check signatures,
selectors, modifier order, complete normalized AST digests and ordered block/branch/loop/call/
write traces. Lean composes the three vault bindings with their exact guard prefixes and public
transition models, and proves the two harvest arithmetic transitions and reserve bounds.
unsupported opaque syntax is rejected. see [body proof scope](SOLIDITY_BODIES.md) for the exact
compiler/EVM trust boundary.

`solidity_guards.py` checks compiled authorization and reentrancy guard bodies, 32 leading
entrypoint prefixes and the explicit transfer check. the proofs cover rejection, lock reset and
composition with the raw public invariant. role administration, upgrades and whole-protocol
callback safety remain outside this coverage.

seeded rescale fixtures reach 64-bit and cumulative 256-bit accounting scales for both account and
waiting-request arithmetic. public loss/refill campaigns instead prove that the high-water carry
restores the existing cohort without a rescale. focused integration checks replay 516 calls against Aave v3's actual
`VariableDebtToken`, run repeated harvests across two vaults sharing one loop, and exercise a long
ICE entry/expiry/reconcile/exit sequence. the Aave pool/index driver and ICE dispatch remain mocks;
these checks do not claim deployed-protocol equivalence.
