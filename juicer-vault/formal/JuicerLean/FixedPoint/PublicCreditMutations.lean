import JuicerLean.FixedPoint.PublicCreditPayment
import JuicerLean.FixedPoint.PublicActiveFeeTransitions

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem position_set_all (s : State) (key : Nat) (p : MainPosition) (i : Nat) :
    position (setPosition s key p) i =
      if key = i ∧ key < s.positions.size then p else position s i := by
  simp only [setPosition, position, Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
  split_ifs <;> simp_all
  omega

theorem setPosition_creditReady (s : State) (key : Nat) (p : MainPosition) (h : CreditReadyHistory s)
    (hr : p.remaining = (position s key).remaining) (hc : (position s key).cash ≤ p.cash) :
    CreditReadyHistory (setPosition s key p) := by
  apply creditFrame_ready (creditFrame_setPosition s key p hr) h
  intro i hi
  have hs : i < s.positions.size := by simpa only [setPosition,
    Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hi
  change FeeBacking (fee s i) (position (setPosition s key p) i).cash
    (if i == 0 then s.activeRemaining else (position (setPosition s key p) i).remaining)
  rw [position_set_all]
  split
  · rename_i he
    rcases he with ⟨rfl, _⟩
    rw [hr]
    rcases h.1.1 key hs with hf | hf
    · exact Or.inl (hf.trans hc)
    · exact Or.inr (by omega)
  · exact h.1.1 i hs

theorem sourceExit_creditFrame (s : State) (active exit : MainPosition) (total slice basis claim : Nat)
    (vested : SourceFee) (hr : active.remaining = (position s 0).remaining) :
    CreditFrame s (sourceExitState s active exit total slice basis claim vested) := by
  refine ⟨?_, rfl, rfl, rfl, rfl, rfl, rfl, rfl, le_rfl, le_rfl⟩
  change (((setPosition s 0 active).positions.push exit).toList.map MainPosition.remaining).take s.positions.size = _
  rw [Array.toList_push, List.map_append, remaining_setPosition s 0 active hr]
  have he : s.positions.size = (s.positions.toList.map MainPosition.remaining).length := by simp
  rw [he, List.take_append_length]

theorem sourceExit_feeBacking (s : State) (active exit : MainPosition) (total slice basis claim : Nat)
    (vested : SourceFee) (h : PositionFeeBacking s)
    (hpos : 0 < s.positions.size) (halign : s.sourceFees.size = s.positions.size) (hz : (fee s 0).feeLeft = 0)
    (hf : vested.yieldLeft ≤ exit.remaining) :
    PositionFeeBacking (sourceExitState s active exit total slice basis claim vested) := by
  intro i hi
  have his : i ≤ s.positions.size := by
    simpa only [sourceExitState, setPosition, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds, Array.size_push, Nat.lt_add_one_iff] using hi
  by_cases hend : i = s.positions.size
  · subst i
    change FeeBacking (fee (sourceExitState s active exit total slice basis claim vested) s.positions.size)
      (position (sourceExitState s active exit total slice basis claim vested) s.positions.size).cash
      (if s.positions.size == 0 then s.activeRemaining else
        (position (sourceExitState s active exit total slice basis claim vested) s.positions.size).remaining)
    have hsize : s.positions.size ≠ 0 := Nat.ne_zero_of_lt hpos
    simp only [sourceExitState, fee, position, setPosition, Array.getElem?_push,
      Array.set!_eq_setIfInBounds, Array.size_setIfInBounds, halign, ite_true,
      Option.getD_some, beq_eq_false_iff_ne.mpr hsize, Bool.false_eq_true, ite_false]
    exact Or.inr (hf.trans (Nat.le_add_left _ _))
  · have hlt : i < s.positions.size := by omega
    have hne : i ≠ s.sourceFees.size := by omega
    change FeeBacking (fee (sourceExitState s active exit total slice basis claim vested) i)
      (position (sourceExitState s active exit total slice basis claim vested) i).cash
      (if i == 0 then s.activeRemaining else
        (position (sourceExitState s active exit total slice basis claim vested) i).remaining)
    simp only [sourceExitState, fee, position, setPosition, Array.getElem?_push,
      Array.set!_eq_setIfInBounds, Array.size_setIfInBounds, if_neg hend, if_neg hne]
    by_cases hi0 : i = 0
    · subst i
      simp only [Array.getElem?_setIfInBounds, ite_true, hlt, Option.getD_some,
        beq_self_eq_true]
      exact Or.inl (by simpa only [fee] using hz.le.trans (Nat.zero_le active.cash))
    · simp only [Array.getElem?_setIfInBounds, if_neg (Ne.symm hi0)]
      exact h i hlt

def ExitCreditReady (s : State) : Prop :=
  CreditReadyHistory s ∧ s.sourceFees.size = s.positions.size ∧ (fee s 0).feeLeft = 0

theorem sourceExit_creditReady (s : State) (active exit : MainPosition) (total slice basis claim : Nat)
    (vested : SourceFee) (h : ExitCreditReady s)
    (hr : active.remaining = (position s 0).remaining) (hf : vested.yieldLeft ≤ exit.remaining) :
    ExitCreditReady (sourceExitState s active exit total slice basis claim vested) := by
  have hpos : 0 < s.positions.size := h.1.2.1.trans_le h.1.2.2.1
  refine ⟨creditFrame_ready (sourceExit_creditFrame s active exit total slice basis claim vested hr)
    h.1 (sourceExit_feeBacking s active exit total slice basis claim vested h.1.1.1 hpos h.2.1 h.2.2 hf), ?_, ?_⟩
  · simpa only [sourceExitState, setPosition, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds, Array.size_push] using congrArg (·+1) h.2.1
  · have hz : 0 ≠ s.sourceFees.size := by rw [h.2.1]; omega
    simpa only [sourceExitState, fee, Array.getElem?_push, if_neg hz] using h.2.2

theorem unwindCommitted_creditReady (s : State) (h : ExitCreditReady s) :
    ExitCreditReady (unwindCommitted s (unwindNumbers s)) := by
  let q := unwindNumbers s
  have prepared : ExitCreditReady (prepareExitOwnership s) := by
    simpa only [ExitCreditReady, CreditReadyHistory, CreditReady, CreditPrefix,
      PositionFeeBacking, FreshCreditShape, BatchBudget, BatchShape, batchPending,
      prepareExitOwnership, foldExitWallets, moveWallets, setWallet, commitExitAccount,
      setAccount, position, fee] using h
  have hr : q.active.remaining = (position (prepareExitOwnership s) 0).remaining := rfl
  have hf : q.vested.yieldLeft ≤ q.exit.remaining := by
    change (if s.expanded then vestFee q.claim q.basis _ else ({} : SourceFee)).yieldLeft ≤ q.claim
    split
    · exact Nat.sub_le _ _
    · exact Nat.zero_le _
  have hn := sourceExit_creditReady (prepareExitOwnership s) q.active q.exit q.total q.slice q.basis
    q.claim q.vested prepared hr hf
  simpa only [ExitCreditReady, CreditReadyHistory, CreditReady, CreditPrefix,
    PositionFeeBacking, FreshCreditShape, BatchBudget, BatchShape, batchPending,
    unwindCommitted, activateWaiting, unwindCovered, coverExit, unwindBooked] using hn

theorem activeDelever_creditReady (s : State) (slice basis : Nat) (h : CreditReadyHistory s)
    (hfees : 0 < s.sourceFees.size) :
    CreditReadyHistory (addActiveFee (unwindActiveSource s slice basis)
      (vestFee (sourceValue s slice) basis ((sourceValue s slice-basis)*s.feeBps/10000))) := by
  apply creditFrame_ready (h := h)
  · refine ⟨?_, rfl, rfl, rfl, rfl, rfl, rfl, rfl, le_rfl, le_rfl⟩
    change (s.positions.toList.map MainPosition.remaining).take s.positions.size = _
    exact List.take_of_length_le (by simp)
  · intro i hi
    by_cases hz : i = 0
    · subst i
      simp only [addActiveFee, unwindActiveSource, fee, Array.set!_eq_setIfInBounds,
        Array.getElem?_setIfInBounds, ite_true, hfees, Option.getD_some, position,
        beq_self_eq_true, vestFee]
      apply Or.inr
      change sourceValue s slice-basis ≤ (position s 0).cash+sourceValue s slice
      omega
    · simpa only [addActiveFee, unwindActiveSource, fee, Array.set!_eq_setIfInBounds,
        Array.getElem?_setIfInBounds, if_neg (Ne.symm hz),
        beq_eq_false_iff_ne.mpr hz, Bool.false_eq_true, ite_false] using h.1.1 i hi

end Juicer.PublicCalls
