import JuicerLean.FixedPoint.SharedIntent
import JuicerLean.FixedPoint.AuditProgress

set_option maxRecDepth 8000
set_option maxHeartbeats 2000000

namespace Juicer.SharedIntent
open Runtime

theorem waiting_reconcile_identity (s : State) (h : (pendingOutcome s).1 = 1) :
    reconcile s = (s,1) := by simp [reconcile, h]

theorem cleared_callback_is_idempotent (s : State) (nonce amount : Nat)
    (he : s.pending.kind = 0) (hp : 0 < nonce) (hn : nonce ≤ s.nonce) :
    callback s nonce amount = some (s,0) := by
  simp [callback, he, Nat.ne_of_gt hp, Nat.not_lt.mpr hn]

theorem refund_preserves_shares_and_costs (s : State) :
    (settle s 0).total = s.total ∧ (settle s 0).vaults = s.vaults := by
  simp [settle]

theorem entry_fill_preserves_shares (s : State) (amount : Nat) (h : s.pending.kind = 1) :
    (settle s amount).total = s.total ∧ (settle s amount).vaults = s.vaults := by
  simp [settle, h]

def run : State → List (Nat × Nat × Nat) → Option State
  | s, [] => some s
  | s, (op,actor,amount) :: rest => do
    let (next, _) ← call s op actor amount
    run next rest

def stateAfter (actions : List (Nat × Nat × Nat)) : State := (run {} actions).getD {}

def entrySeed : List (Nat × Nat × Nat) := [(0,0,1000 * wad), (0,1,1000 * wad), (1,0,0)]

def exitBeforeFill := stateAfter (entrySeed ++ [(7,1,1000 * wad), (2,1,1980 * 10^6), (4,0,0)])
def exitAfterFill := stateAfter (entrySeed ++ [(2,1,1980 * 10^6), (4,0,0), (7,1,1000 * wad)])

theorem entry_exit_cost_shift :
    (vault exitBeforeFill 1).requested = 1000 * wad ∧
    (vault exitAfterFill 1).requested = 990 * wad ∧
    live exitBeforeFill = 980 * wad ∧ live exitAfterFill = 990 * wad ∧
    equity exitBeforeFill = equity exitAfterFill := by decide

def joinBeforeFill := stateAfter [(0,0,1000 * wad), (1,0,0), (0,1,1000 * wad),
  (2,1,990 * 10^6), (4,0,0)]
def joinAfterFill := stateAfter [(0,0,1000 * wad), (1,0,0), (2,1,990 * 10^6),
  (4,0,0), (0,1,1000 * wad)]

theorem entrant_shares_earlier_entry_loss :
    live joinBeforeFill * (vault joinBeforeFill 1).shares / joinBeforeFill.total = 995 * wad ∧
    999 * wad < live joinAfterFill * (vault joinAfterFill 1).shares / joinAfterFill.total := by decide

def giftSpoof := stateAfter [(0,0,1000 * wad), (1,0,0), (5,0,980100000), (4,0,0)]

theorem near_full_gift_still_is_not_authentication :
    giftSpoof.pending.kind = 0 ∧ (giftSpoof.pallet[1]?.getD (default : PalletIntent)).status = 1 ∧
    equity giftSpoof = 9801 * 10^17 ∧ giftSpoof.total = 1000 * wad := by decide

def parkedGiftRound (gift compounded : Nat) : Nat × Nat :=
  let cut := gift / 2
  (gift - cut, compounded + cut)

def parkedGiftRounds : Nat → Nat × Nat → Nat × Nat
  | 0, state => state
  | n + 1, state => parkedGiftRounds n (parkedGiftRound state.1 state.2)

theorem parked_gift_is_reassigned_each_round :
    parkedGiftRounds 5 (1000 * 10^6, 0) = (31250000,968750000) ∧
    (parkedGiftRounds 5 (1000 * 10^6, 0)).1 +
      (parkedGiftRounds 5 (1000 * 10^6, 0)).2 = 1000 * 10^6 := by decide

def cappedCosts : State := {
  target := 200, unwinders := #[0,1],
  vaults := #[{ requested := 100, allowance := 100 }, { requested := 100 }] }

theorem capped_exit_cost_stays_with_live_equity :
    let next := chargeCost cappedCosts 10
    (vault next 0).cost = 5 ∧ (vault next 1).cost = 0 ∧ next.target = 195 ∧
      10 - ((vault next 0).cost + (vault next 1).cost) = 5 := by decide

def priorSliceOrigin : State := {
  target := 100, unwinders := #[0],
  vaults := #[{ requested := 100, allowance := 100 }, {}] }

def priorSliceWithLateRequest : State := {
  target := 200, unwinders := #[0,1],
  vaults := #[{ requested := 100, allowance := 100 },
    { requested := 100, allowance := 100 }] }

theorem late_request_shares_prior_slice_cost :
    let origin := chargeCost priorSliceOrigin 10
    let joined := chargeCost priorSliceWithLateRequest 10
    (vault origin 0).cost = 10 ∧ (vault origin 1).cost = 0 ∧
    (vault joined 0).cost = 5 ∧ (vault joined 1).cost = 5 ∧
    origin.target = 90 ∧ joined.target = 190 := by decide

end Juicer.SharedIntent

namespace Juicer.Runtime

def deficitExit (supply debt backing units : ℕ) : ℕ × ℕ :=
  let exit := (mainExit { units, principal := debt } units debt 1000 supply (backing * 1000 / supply)).2.1
  (exit.principal, exit.remaining)

theorem newcomer_dilutes_existing_deficit :
    deficitExit 1000 1000 900 1000 = (1000,900) ∧
    deficitExit 2000 2000 1900 2000 = (1000,950) ∧
    1000 - 900 = 2 * (1000 - 950) := by decide

def recoveryBook : Book := { total := 100, source := 100 }
def recoveryView (supply equity : ℕ) : AllocationInput := {
  held := 1100, equity, basis := 1000, required := 1000,
  supply, funded := 0, fundedValue := 0, fee := 0 }

def dippedBook := allocate recoveryBook (recoveryView 1000 1050)
def recoveredBook (supply : ℕ) := allocate dippedBook (recoveryView supply 1100)
def recoveryClaim (supply units weight : ℕ) :=
  let b := recoveredBook supply
  fundedOf b.source b.total (accountUnits b { units } weight)

theorem undeployed_weight_receives_recovery :
    dippedBook.source = 52 ∧ dippedBook.total = 100 ∧
    (recoveredBook 1000).source = (recoveredBook 2000).source ∧
    recoveryClaim 1000 100 1000 = 100 ∧
    recoveryClaim 2000 100 1000 = 75 ∧ recoveryClaim 2000 0 1000 = 23 := by decide

theorem recovery_still_conserves_allocated_source :
    (recoveredBook 2000).source = 100 ∧
    recoveryClaim 2000 100 1000 + recoveryClaim 2000 0 1000 ≤ (recoveredBook 2000).source := by decide

end Juicer.Runtime
