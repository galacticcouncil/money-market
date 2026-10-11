import JuicerLean.FixedPoint.PublicCalls
import JuicerLean.FixedPoint.LifecycleRefinement
import JuicerLean.FixedPoint.MainHistories

set_option maxRecDepth 2000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls

open Runtime

def custody (s : State) : Nat × Nat × Nat × Nat :=
  (s.assets, s.reserve, s.supplied, s.liquid)

def CollateralConserved (s : State) : Prop :=
  s.assets + s.reserve = s.supplied + s.liquid

theorem collateral_of_custody {a b : State} (h : custody a = custody b)
    (ha : CollateralConserved a) : CollateralConserved b := by
  simp only [custody, Prod.mk.injEq] at h
  simp_all [CollateralConserved]

@[simp] theorem settleOwner_custody (s : State) (a : Nat) :
    custody (settleOwner s a) = custody s := by
  unfold settleOwner
  split <;> rfl

@[simp] theorem checkpoint_custody (s : State) (a b : Nat) :
    custody (checkpoint s a b) = custody s := by
  unfold checkpoint
  simp only [Id.run, bind, pure]
  split <;> split <;> simp only [settleOwner_custody] <;> rfl

@[simp] theorem pay_custody (s : State) (key limit : Nat) :
    custody (pay s key limit).1 = custody s := by
  rfl

@[simp] theorem creditPosition_custody (s : State) (key weight : Nat) :
    custody (creditPosition s key weight).1 = custody s := by rfl

@[simp] theorem creditSteps_custody (fuel : Nat) (s : State) :
    custody (creditSteps fuel s) = custody s := by
  induction fuel generalizing s with
  | zero => rfl
  | succ fuel ih =>
    simp only [creditSteps]
    split
    · rfl
    · rw [ih]
      rfl

@[simp] theorem credit_custody (s : State) (amount cost : Nat) :
    custody (credit s amount cost) = custody s := by
  unfold credit
  simp only [Id.run, bind, pure]
  split
  · split
    · rfl
    · split <;> change custody (creditSteps 64 _) = custody s
      all_goals rw [creditSteps_custody]; rfl
  · split <;> change custody (creditSteps 64 _) = custody s
    all_goals rw [creditSteps_custody]; rfl

theorem cover_collateral {s next : State} {amount : Nat}
    (hcall : cover s amount = .ok next) (h : CollateralConserved s) :
    CollateralConserved next := by
  unfold cover at hcall
  by_cases hc : s.reserve < amount
  · rw [if_pos hc] at hcall
    contradiction
  · rw [if_neg hc] at hcall
    injection hcall
    subst next
    simp only [CollateralConserved] at h ⊢
    omega

@[simp] theorem settleRecord_collateral (s : State) (id : Nat) (r : Request)
    (next : RedemptionState) (h : CollateralConserved s) :
    CollateralConserved (settleRecord s id r next) := by
  simp only [settleRecord, CollateralConserved] at h ⊢
  have hw := min_le_right (next.settled - r.claim.settled) s.supplied
  omega

@[simp] theorem finishSettle_collateral (s : State) (id : Nat) (r : Request) (paid : Nat)
    (h : CollateralConserved s) : CollateralConserved (finishSettle s id r paid).1 := by
  by_cases hs : (settleRedemption r.claim paid).repaid < (settleRedemption r.claim paid).debt
  · simpa [finishSettle, hs] using
      settleRecord_collateral s id r (settleRedemption r.claim paid) h
  · simpa [finishSettle, hs] using
      settleRecord_collateral s id r (settleRedemption r.claim paid) h

@[simp] theorem settleOne_collateral (s : State) (h : CollateralConserved s) :
    CollateralConserved (settleOne s).1 := by
  by_cases hg : (s.paused || s.sourcePaused || s.delever != 0 || s.unwind ≤ s.head) = true
  · simp [settleOne, hg, h]
  · by_cases hd : ((request s s.head).claim.debt == (request s s.head).claim.repaid) = true
    · simpa [settleOne, hg, hd] using finishSettle_collateral s s.head (request s s.head) 0 h
    · have hp := collateral_of_custody
        (pay_custody s (s.head + 1)
          ((request s s.head).claim.debt - (request s s.head).claim.repaid)) h
      simpa [settleOne, hg, hd] using finishSettle_collateral
        (pay s (s.head + 1)
          ((request s s.head).claim.debt - (request s s.head).claim.repaid)).1
        s.head (request s s.head)
        (pay s (s.head + 1)
          ((request s s.head).claim.debt - (request s s.head).claim.repaid)).2.1 hp

theorem settleMany_collateral (fuel : Nat) (s : State) (h : CollateralConserved s) :
    CollateralConserved (settleMany fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    simp only [settleMany]
    split
    · exact ih _ (settleOne_collateral s h)
    · exact settleOne_collateral s h

inductive CustodyStep : State → State → Prop
  | frame {s next} (h : custody next = custody s) : CustodyStep s next
  | cover {s next amount} (h : cover s amount = .ok next) : CustodyStep s next
  | settle (s : State) (fuel : Nat) : CustodyStep s (settleMany fuel s)
  | addBoth (s : State) (amount : Nat) : CustodyStep s
      { s with assets := s.assets + amount, supplied := s.supplied + amount }
  | removeBoth (s : State) (amount : Nat) (ha : amount ≤ s.assets) (hl : amount ≤ s.liquid) :
      CustodyStep s { s with assets := s.assets - amount, liquid := s.liquid - amount }
  | moveSupply (s : State) (amount : Nat) (ha : amount ≤ s.supplied) : CustodyStep s
      { s with supplied := s.supplied - amount, liquid := s.liquid + amount }

theorem custody_step_preserves {s next : State} (h : CollateralConserved s)
    (step : CustodyStep s next) : CollateralConserved next := by
  cases step with
  | frame hc => exact collateral_of_custody hc.symm h
  | cover hc => exact cover_collateral hc h
  | settle fuel => exact settleMany_collateral fuel _ h
  | addBoth amount => simp only [CollateralConserved] at h ⊢; omega
  | removeBoth amount ha hl => simp only [CollateralConserved] at h ⊢; omega
  | moveSupply amount ha => simp only [CollateralConserved] at h ⊢; omega

theorem custody_trace_preserves {s next : State} (h : CollateralConserved s)
    (steps : Relation.ReflTransGen CustodyStep s next) : CollateralConserved next := by
  induction steps with
  | refl => exact h
  | tail _ step ih => exact custody_step_preserves ih step

inductive CertifiedCalls : State → List Action → State → Prop
  | nil (s) : CertifiedCalls s [] s
  | cons (s : State) (action : Action) (actions : List Action) (next final : State)
      (step : CustodyStep s (execute s action).1)
      (heq : next = (execute s action).1)
      (rest : CertifiedCalls next actions final) :
      CertifiedCalls s (action :: actions) final

theorem certified_calls_preserve {s final : State} {actions : List Action}
    (h : CollateralConserved s) (calls : CertifiedCalls s actions final) :
    CollateralConserved final := by
  induction calls with
  | nil => exact h
  | cons _ _ _ next _ step heq _ ih =>
    subst next
    exact ih (custody_step_preserves h step)

theorem failed_call_custody_step (s : State) (action : Action) (code : Nat)
    (h : runCall s action = .error code) : CustodyStep s (execute s action).1 := by
  apply CustodyStep.frame
  simp [execute, h]

theorem genesis_collateral : CollateralConserved ({} : State) := by
  rfl

def sourceProjection (s : State) : SourceClaims :=
  ⟨s.activeRemaining, s.positions.toList.map MainPosition.remaining, s.outstanding⟩

def cashProjection (s : State) : CashBook :=
  ⟨s.positions.toList.map MainPosition.cash, s.unallocated, s.ownedCash, s.protocolReserve⟩

theorem source_partition_of_history (s : State)
    (steps : Relation.ReflTransGen SourceClaims.Step ⟨0, [0], 0⟩ (sourceProjection s)) :
    s.activeRemaining + (s.positions.toList.map MainPosition.remaining).sum = s.outstanding := by
  exact source_claims_trace_preserves _ _ (by simp [SourceClaims.valid]) steps

theorem cash_partition_of_history (s : State)
    (steps : Relation.ReflTransGen CashBook.Step ⟨[0], 0, 0, 0⟩ (cashProjection s)) :
    (s.positions.toList.map MainPosition.cash).sum + s.unallocated = s.ownedCash := by
  exact cash_book_trace_preserves _ _ (by simp [CashBook.valid]) steps

def publicLifecycle (s : State) (slack parked : Nat) : Lifecycle ray :=
  let holders := (List.range 5).map fun i => normalizeAccount s.book (account s i) (wallet s i)
  let waiting := (List.range (s.requests.size - s.unwind)).map fun offset =>
    let r := request s (s.unwind + offset)
    normalizeAccount s.book r.account r.claim.shares
  ⟨⟨s.book.total, s.book.index, slack, holders ++ waiting⟩,
    s.supply, wallet s fundId, s.queued, parked⟩

theorem lifecycle_valid_of_history (wallets : List Nat) (s : State) (slack parked : Nat)
    (steps : Relation.ReflTransGen Lifecycle.Step (Lifecycle.genesis wallets)
      (publicLifecycle s slack parked)) : (publicLifecycle s slack parked).valid :=
  lifecycle_trace_preserves _ _ (lifecycle_genesis_valid wallets) steps

theorem lifecycle_claim_bound_of_history (wallets : List Nat) (s : State) (slack parked : Nat)
    (steps : Relation.ReflTransGen Lifecycle.Step (Lifecycle.genesis wallets)
      (publicLifecycle s slack parked)) :
    ((publicLifecycle s slack parked).ledger.accounts.map
      (LazyAccount.claim s.book.total s.book.index)).sum ≤ s.book.total + slack / ray := by
  have h := lifecycle_valid_of_history wallets s slack parked steps
  exact lazy_claims_bound _ h.1 (by norm_num [ray])

end Juicer.PublicCalls
