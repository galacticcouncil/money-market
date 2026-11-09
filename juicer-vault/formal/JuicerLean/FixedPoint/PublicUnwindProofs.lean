import JuicerLean.FixedPoint.PublicUnwindStateProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def unwindNumbers (s : State) : UnwindNumbers :=
  let out := waitingExit s
  let supply := activeSupply s
  let shares := (request s s.unwind).claim.shares+out.folded
  let numerator := activeAssets s*shares
  let owed := ceilDiv numerator supply
  let activeSlice := (s.held-out.book.source-out.book.protocol-out.reward-out.fee)*shares/supply
  let slice := activeSlice+out.reward+out.fee
  let basis := s.basis*shares/supply
  let claim := sourceValue s slice
  let sourceFee := (claim*activeSlice/slice-basis)*s.feeBps/10000+claim*out.fee/slice
  let vested := if s.expanded then vestFee claim basis sourceFee else {}
  let (active,exit,total) := mainExit (position s 0) s.mainUnits s.debt shares supply claim
  let debt := mainDebtOf s.debt total exit
  let synth := if s.debt == 0 then 0 else s.synth*debt/s.debt
  ⟨shares,owed,debt,synth,slice,basis,claim,owed-numerator/supply,active,exit,total,vested⟩

theorem unwindNumbers_shares (s : State) :
    (unwindNumbers s).shares = (request s s.unwind).claim.shares+(waitingExit s).folded := rfl

theorem unwindNumbers_facts (s : State) (h : PublicInvariant s) (hb : QueueBacking s)
    (hi : s.unwind < s.requests.size) (hr : s.book.source+s.book.protocol ≤ s.held)
    (ho : 0 < (unwindNumbers s).owed ∨ ((unwindNumbers s).shares = 0 ∧ (unwindNumbers s).debt = 0)) (hc : (unwindNumbers s).rounding ≤ s.reserve) :
    UnwindFacts s (unwindNumbers s) := by
  have hs := waitingExit_shares_le_active s h.2.2.2.2.2 hi
  have hslice := waitingExit_source_slice s _ hs hr
  refine ⟨?_,rfl,ho,hc,?_⟩
  · apply mainExit_facts s _ _ _ _ h.2.2.2.2.2 hs hslice rfl
    change (if s.expanded then vestFee _ _ _ else ({} : SourceFee)).feeLeft ≤
      (if s.expanded then vestFee _ _ _ else ({} : SourceFee)).yieldLeft
    split
    · exact vested_fee_le_yield _ _ _
    · exact Nat.le_refl 0
  · exact rounded_exit_backing s.assets s.owed _ (activeSupply s) hb.1 hs

def unwindHead (s : State) : Except Nat State :=
  let q := unwindNumbers s
  if q.owed == 0 && q.shares != 0 then .error 2
  else if pendingAccounting s then .error 18
  else if q.slice == 0 && q.debt > (position s 0).cash*q.shares/activeSupply s then .error 19
  else if s.reserve < q.rounding then .error 17
  else .ok (unwindCommitted s q)

theorem unwindNumbers_redemption (s : State)
    (hzero : ¬ ((unwindNumbers s).owed == 0 && (unwindNumbers s).shares != 0) = true) :
    0 < (unwindNumbers s).owed ∨ ((unwindNumbers s).shares = 0 ∧ (unwindNumbers s).debt = 0) := by
  simp only [Bool.and_eq_true, beq_iff_eq, bne_iff_ne] at hzero
  by_cases hs : (unwindNumbers s).shares = 0
  · refine Or.inr ⟨hs, ?_⟩
    change mainDebtOf s.debt (mainExit (position s 0) s.mainUnits s.debt
      (unwindNumbers s).shares (activeSupply s) 0).2.2
      (mainExit (position s 0) s.mainUnits s.debt (unwindNumbers s).shares (activeSupply s) 0).2.1 = 0
    simp [hs, mainExit, mainDebtOf, fundedOf]
  · exact Or.inl (by omega)

theorem unwindHead_public (s : State) (h : PublicInvariant s) (hb : QueueBacking s)
    (hi : s.unwind < s.requests.size) (ho : (request s s.unwind).owner < 5)
    (hr : pendingAccounting s = false → s.book.source+s.book.protocol ≤ s.held) :
    OnSuccess (fun next => PublicInvariant next ∧ QueueBacking next) (unwindHead s) := by
  unfold unwindHead
  dsimp only
  split
  · trivial
  next hzero =>
    split
    · trivial
    next hpending =>
      split
      · trivial
      next hdebt =>
        split
        · trivial
        next hreserve =>
          have hpositive := unwindNumbers_redemption s hzero
          have hbudget : (unwindNumbers s).rounding ≤ s.reserve := by omega
          have hreserved := hr (Bool.eq_false_iff.mpr hpending)
          have facts := unwindNumbers_facts s h hb hi hreserved hpositive hbudget
          exact ⟨unwindCommitted_public s _ h hi ho facts,unwindCommitted_queueBacking s _ hb facts⟩

end Juicer.PublicCalls
