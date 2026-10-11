# juicer-vault — Lean 4 formal spec

Formal verification of **Juicer** — a protocol-managed leveraged-yield product on
Hydration — in **Lean 4**. Contains conditional mathematical proofs and executable integer models checked against Solidity.
[Current implementation mapping and limits](SOLIDITY_PARITY.md) is the coverage record.
[Funded-transfer rounding](ROUNDING.md) records the allowance mismatch and a separate seeded
counterexample to exact aggregate unit conservation across lazy rescales.

Lives beside the contracts it models: `juicer-vault/{src,test,formal}` (branch `juicer-next`).
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
   ├─ LazyRefinement.lean epoch/scale normalization, runtime bounds and a rescale counterexample
   ├─ Lifecycle.lean      holders and waiting requests, share partition and reachable liability bounds
   ├─ LifecycleRefinement.lean request creation, exact runtime exit normalization and escrow guards
   ├─ MainDebt.lean       debt cohorts, source batches, vested fees and reserve limits
   ├─ Orchestration.lean  frozen batch cursors, later receipts, bounded calls and repayment retry
   ├─ MainHistories.lean  reachable source-claim and cash partitions across cohort operations
   ├─ PolicyQueue.lean    controller budgets, quotes, FIFO starts and collateral claims
   ├─ QueueHistories.lean repeated settlement/claim histories and FIFO settlement work
   ├─ PublicCalls.lean    public-call sequences, harvest/fees, debt rounding, deleveraging and rollback
   ├─ PublicInvariants.lean custody, source, cash and lifecycle invariants for public-call histories
   ├─ ScaledDebt.lean     Aave half-up ray arithmetic and executable scaled-balance histories
   ├─ Checked.lean        uint256 arithmetic failures and atomic transaction semantics
   ├─ CheckedRefinement.lean successful checked operations refine the natural-number models
   ├─ Environment.lean    external observation guards and ICE authentication limits
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
| `agg_synthConserved` | no over-mint of the synthetic across the **whole book** of positions at once |
| `agg_collateral_out_ge_in` | portfolio-wide redemption solvency: aggregate collateral out ≥ in, under `freedBacked` |
| `deposit_conserved` / `deposit_isolation` | shared-loop deposit conserves total shares and cannot move another vault's balance |
| `requestUnwind_conserved` / `requestUnwind_isolation` | same, for unwind requests |
| `floored_credit_no_over_credit` | the shipped `_creditFreed` weighting (remaining-to-credit, floored) never distributes more than `freed` |
| `buggy_over_credits` / `buggy_strictly_over` | the REJECTED requested-weighted alternative provably over-credits — this is bug G, kept as a negative result so the fix's rationale is machine-checked too |
| `accrueLoop_restores_freedBacked` | modeling loop yield: equity growth raises `subHF` and restores `freedBacked` after redemption pressure |

## Next version (`juicer-next`, plan §2–§4, §7)

aligned with Solidity on `juicer-next` at `21f5aa7` on 10 october. the real-number models prove ideal accounting
properties; `FixedPoint/Runtime.lean` adds current integer arithmetic, epoch and rescale behavior.
Run `python3 check-runtime.py` to rebuild proofs, regenerate and compare 1,424 Lean cases with the
actual Solidity, and detect source or storage-layout drift. Same integrity bar: 0 `sorry`, axioms
`propext`/`Classical.choice`/`Quot.sound` only.

The integer lazy-account model proves aggregate bounds through settlement, wallet-weight changes,
allocation, unit movement, burns, rescaling and write-off. Rescaling needs an explicit rounding
budget; exact aggregate unit conservation is false for the seeded state in `ROUNDING.md`.
`RescaleBounds.lean` proves a uniform slack bound for arbitrary histories whose rescale weight is
bounded, plus conditions under which aggregate funded claims still cannot exceed the fund.
The lifecycle layer includes waiting requests' committed units and accrual weights. Its share
partition derives the allocation weight premise from genesis. Resumable source batches, retries,
partial/final claim histories and selected checked-arithmetic failures have separate executable
models and proofs. These are integer transition proofs with explicit environmental boundaries;
full compiled-Solidity trace equivalence remains outside this project. The table below
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
| `bounded_trace_slack` / `bounded_genesis_funded` | arbitrary bounded rescale histories keep a uniform rounding budget and an explicit aggregate funded-claim bound |
| `certified_calls_preserve` | collateral custody is conserved through any certified history of executable public-call results; failed calls supply frame certificates automatically |
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
| `IceLoop.submit_grossHF` / `IceLoop.ramp_fill_grossHF` / `IceLoop.ramp_aaveHF_lt` | abstract gross-asset ratio only; runtime HF instead nets ENTRY input against debt and restores EXIT input to collateral |
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

`python3 check-stateful.py` runs public-call campaigns in two fixtures and replays them in Lean
from fixture genesis. The checker compares state and outcomes after every step, enforces accounting
partitions and rejects incomplete traces. The baseline covers vault/Main queues and claims; the
market fixture adds harvests, compounding, nonzero fees/costs, interest, debt rounding and
price-driven deleveraging. The default eight seeds per fixture cover 5,017 recorded steps and
1,059 expected reverts. Larger campaigns are configurable. See [stateful parity](STATEFUL_PARITY.md)
for coverage gates and external mock boundaries. `check-runtime.py` includes both default fixtures.

separate integration checks reach a 64-bit accounting rescale through public vault calls in a
controlled loss/refill environment, replay 516 calls against Aave v3's actual
`VariableDebtToken`, run repeated harvests across two vaults sharing one loop, and exercise a long
ICE entry/expiry/reconcile/exit sequence. the Aave pool/index driver and ICE dispatch remain mocks;
these checks do not claim deployed-protocol equivalence.
