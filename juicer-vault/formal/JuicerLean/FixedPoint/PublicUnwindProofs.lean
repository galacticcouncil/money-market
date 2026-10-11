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
    (ho : 0 < (unwindNumbers s).owed) (hc : (unwindNumbers s).rounding ≤ s.reserve) :
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
  if q.owed == 0 then .error 2
  else if pendingAccounting s then .error 18
  else if q.slice == 0 && q.debt > (position s 0).cash*q.shares/activeSupply s then .error 19
  else if s.reserve < q.rounding then .error 17
  else .ok (unwindCommitted s q)

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
          have hpositive : 0 < (unwindNumbers s).owed := by simp only [beq_iff_eq] at hzero; omega
          have hbudget : (unwindNumbers s).rounding ≤ s.reserve := by omega
          have hreserved := hr (Bool.eq_false_iff.mpr hpending)
          have facts := unwindNumbers_facts s h hb hi hreserved hpositive hbudget
          exact ⟨unwindCommitted_public s _ h hi ho facts,unwindCommitted_queueBacking s _ hb facts⟩

end Juicer.PublicCalls
