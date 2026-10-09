# propeller-vault — Lean 4 formal spec

Formal verification of **Propeller** — a protocol-managed leveraged-yield product on
Hydration — in **Lean 4**. Turns the invariants currently checked only by the Solidity fuzz
tests (`../test/invariant/`) into machine-checked theorems over *all* inputs.

Lives beside the contracts it models: `propeller-vault/{src,test,formal}` (branch `propeller`).
A self-contained Lake project; the Foundry build ignores it and vice-versa.
Strategy: Path C.

## Layout

```
PropellerLean/
├─ Spec/
│  ├─ State.lean          balance-sheet State, mainHF / borrowCapacity / subHF, WellFormed
│  ├─ Invariants.lean     principalFloored, pegBand, subLoopHealthy
│  ├─ Floor.lean          Phase 1: the "never liquidated" theorems
│  ├─ Ops.lean            transitions: mintSynthToPeg, maintainPeg, accrueInterest, tick, repay
│  ├─ Preservation.lean   Phase 2: invariant preservation; tick_safe (HF≥1 after every tick)
│  ├─ Redemption.lean     Phase 2: escrow / shareConservation / freedBacked → collateral_out_ge_in;
│  │                      next version: the exit fold (burned units' funded slice → escrow)
│  ├─ SubLoop.lean        single-vault loop model: deLever, accrueLoop (yield), the full Op
│  │                      trace semantics (LoopSafe/Safe/SafeBacked closed under any op list)
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
│  └─ Examples.lean       worked numeric instances (concrete ETH position, dust threshold,
│                          loop-at-HF-1.05, full-unwind) cross-checking the Solidity test suite
└─ FixedPoint/
   ├─ Uint256.lean        WAD/bps integer model (what Solidity stores)
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
| `synth_adds_no_borrow_power` | the synthetic (LTV 0) grants zero borrow power (`noSynthBorrow`) |
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

Modeled from `../docs/next-version-plan.md` and track A's 9 Oct design update (no claims: units
are the only claim on the fund, transfers beyond the wallet move units) while the Solidity lands in
parallel; the bridge/parity tests follow once it merges. Same integrity bar: 0 `sorry`, axioms
`propext`/`Classical.choice`/`Quot.sound` only.

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
| `ShareBook.eventVsTransfer` | against the old per-transfer allocation, only the interval's pre-transfer yield on the moved shares changes hands |
| `ShareBook.deposit_newcomer` / `ShareBook.mintFirst_captures` | deposits allocate before they mint, so a newcomer captures no pre-entry yield (minting first would) |
| `ShareBook.startExit_wallets` / `ShareBook.startExit_fold` | share conservation including the exit fold: supply and holders' wallets unchanged; exactly the burned units' funded slice moves from the fund into the escrow and joins the request's shares |
| `ShareBook.startExit_fullExit` / `ShareBook.requestRedeem_max_then_startExit` | after a full exit the owner has no units, no slice of the fund and no balance |
| `ShareBook.startExit_slice_other` / `ShareBook.startExit_unitPrice` | an exit moves nobody else's slice or unit price |
| `State.startExit_requestRedeem` / `State.startExit_escrowOk` | seen by the redemption state the fold is `requestRedeem fold`, so `escrowOk` survives it |
| `ShareBook.startExit_quote` / `ShareBook.runExit_totalBalance_add` | quoting after the fold pays the folded shares at the same per-share value and keeps the remaining holders'; the balance identity holds through any trace with exits |

## Build & verify

```sh
. ~/.elan/env
lake build
# integrity gate:
echo 'import PropellerLean
#print axioms Propeller.State.floor_main_hf
#print axioms Propeller.FixedPoint.principalFloored_refines' | lake env lean /dev/stdin
```

Toolchain: Lean `v4.30.0` + Mathlib `v4.30.0` (pinned in `lean-toolchain` / `lakefile.toml`).
