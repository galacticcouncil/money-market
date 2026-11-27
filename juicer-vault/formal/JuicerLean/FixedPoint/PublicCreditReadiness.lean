import JuicerLean.FixedPoint.PublicCreditEntryProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def CreditPrefix (s : State) : Prop :=
  0 < s.sourceHead ∧ s.sourceHead ≤ s.positions.size ∧
    ∀ i, i < s.sourceHead → (position s i).remaining = 0

instance (s : State) : Decidable (CreditPrefix s) := by unfold CreditPrefix; infer_instance

theorem creditPrefix_fresh (s : State) (h : CreditPrefix s) : FreshCreditShape s := by
  refine ⟨h.1, h.2.1, ?_⟩
  apply List.sum_eq_zero_iff_forall_eq_nat.mpr
  intro n hn
  obtain ⟨p, hp, rfl⟩ := List.mem_map.mp hn
  obtain ⟨i, hi, he⟩ := List.getElem_of_mem hp
  have hhead : i < s.sourceHead := by
    simp only [List.length_take, Array.length_toList] at hi
    omega
  have hsize : i < s.positions.size := hhead.trans_le h.2.1
  have hp : position s i = p := by
    simpa only [position, Array.getElem?_eq_getElem hsize, Option.getD_some,
      List.getElem_take, Array.getElem_toList] using he
  simpa only [hp] using h.2.2 i hhead

theorem fresh_creditPrefix (s : State) (h : FreshCreditShape s) : CreditPrefix s := by
  refine ⟨h.1, h.2.1, ?_⟩
  intro i hi
  have hs : i < s.positions.size := hi.trans_le h.2.1
  have ht : i < (s.positions.toList.take s.sourceHead).length := by
    simp only [List.length_take, Array.length_toList]; omega
  have hp : (position s i).remaining ∈ (s.positions.toList.take s.sourceHead).map MainPosition.remaining := by
    apply List.mem_map.mpr
    refine ⟨(s.positions.toList.take s.sourceHead)[i], List.getElem_mem ht, ?_⟩
    simp only [position, Array.getElem?_eq_getElem hs, Option.getD_some,
      List.getElem_take, Array.getElem_toList]
  exact List.sum_eq_zero_iff_forall_eq_nat.mp h.2.2 _ hp

def CreditReadyHistory (s : State) : Prop := CreditReady s ∧ CreditPrefix s

instance (s : State) : Decidable (CreditReadyHistory s) := by unfold CreditReadyHistory; infer_instance

theorem creditReadyHistory_genesis : CreditReadyHistory ({} : State) := by decide

theorem creditPosition_prefix (s : State) (key weight : Nat) (h : CreditPrefix s)
    (hw : key ≠ 0 → weight = (position s key).remaining) :
    CreditPrefix (creditPosition s key weight).1 := by
  rw [creditPosition_state_factored]
  refine ⟨h.1, ?_, ?_⟩
  · simpa only [creditState, setPosition, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using h.2.1
  · intro i hi
    change i < s.sourceHead at hi
    have hs : i < s.positions.size := hi.trans_le h.2.1
    by_cases he : key = i
    · subst key
      rw [creditState_position s i weight _ i hs]
      simp only [ite_true]
      by_cases hz : i = 0
      · simp only [hz, beq_self_eq_true, ite_true]
      · simp only [beq_eq_false_iff_ne.mpr hz, Bool.false_eq_true, ite_false,
          hw hz, h.2.2 i hi, Nat.zero_sub]
    · simpa only [creditState, setPosition, position, Array.set!_eq_setIfInBounds,
        Array.getElem?_setIfInBounds, if_neg he] using h.2.2 i hi

theorem creditCursor_prefix (s : State) (key : Nat) (h : CreditPrefix s) (hk : key < s.positions.size) :
    CreditPrefix (creditCursor s key) := by
  unfold creditCursor
  split
  · rename_i he
    have hh : key = s.sourceHead ∧ (position s key).remaining = 0 := by
      simpa only [Bool.and_eq_true, beq_iff_eq] using he
    refine ⟨Nat.succ_pos _, ?_, ?_⟩
    · change s.sourceHead+1 ≤ s.positions.size
      omega
    intro i hi
    change i < s.sourceHead+1 at hi
    by_cases hz : i = s.sourceHead
    · simpa only [hz, ← hh.1] using hh.2
    · exact h.2.2 i (by omega)
  · exact h

theorem advanceCredit_prefix (s : State) (h : CreditPrefix s) (hi : s.batchCursor < s.positions.size) :
    CreditPrefix (advanceCredit s) := by
  unfold advanceCredit
  apply creditCursor_prefix
  · exact creditPosition_prefix s s.batchCursor _ h (fun _ => rfl)
  · simpa only [creditPosition_state_factored, creditState, setPosition,
      Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hi

theorem creditSteps_history (fuel : Nat) (s : State) (h : CreditLoopInvariant s) (hp : CreditPrefix s) :
    CreditLoopInvariant (creditSteps fuel s) ∧ CreditPrefix (creditSteps fuel s) := by
  induction fuel generalizing s with
  | zero => exact ⟨h, hp⟩
  | succ fuel ih =>
    change CreditLoopInvariant (if s.batchTail ≤ s.batchCursor then s else creditSteps fuel (advanceCredit s)) ∧
      CreditPrefix (if s.batchTail ≤ s.batchCursor then s else creditSteps fuel (advanceCredit s))
    split
    · exact ⟨h, hp⟩
    · rename_i hn
      have hi : s.batchCursor < s.batchTail := by omega
      exact ih _ (advanceCredit_preserves s h hi)
        (advanceCredit_prefix s hp (hi.trans_le h.2.2.1.tail_le))

theorem closeCredit_ready (s : State) (h : CreditLoopInvariant s) (hp : CreditPrefix s) :
    CreditReadyHistory (closeCredit s) := by
  unfold closeCredit
  split
  · exact ⟨⟨h.2.2.2.1, h.2.2.2.2, creditPrefix_fresh s hp⟩, hp⟩
  · refine ⟨⟨h.2.2.2.1, h.2.2.2.2, ?_⟩, hp⟩
    change if s.batchAmount == 0 && s.batchCost == 0 then FreshCreditShape s else BatchBudget s ∧ BatchShape s
    split
    · exact creditPrefix_fresh s hp
    · exact ⟨h.2.1, h.2.2.1⟩

theorem finishCredit_ready (s : State) (h : CreditLoopInvariant s) (hp : CreditPrefix s) :
    CreditReadyHistory (finishCredit s) :=
  let next := creditSteps_history 64 s h hp
  closeCredit_ready _ next.1 next.2

theorem activeCredit_prefix (s : State) (h : CreditPrefix s) : CreditPrefix (activeCredit s) :=
  creditPosition_prefix (setupCredit s) 0 s.activeRemaining h (fun hn => False.elim (hn rfl))

theorem creditReceived_ready (s : State) (h : PublicInvariant s) (hr : CreditReadyHistory s) :
    CreditReadyHistory (creditReceived s) := by
  unfold creditReceived
  split
  · rename_i hnew
    split
    · exact hr
    · rename_i hreceipts
      have hp : 0 < s.unallocated+s.unallocatedCost := by
        simp only [Bool.and_eq_true, beq_iff_eq] at hreceipts
        omega
      exact finishCredit_ready _
        (activeCredit_loop s h hr.1.1 hr.1.2.1 (creditPrefix_fresh s hr.2) hp)
        (activeCredit_prefix s hr.2)
  · rename_i hresume
    have hh := hr.1.2.2
    rw [if_neg hresume] at hh
    exact finishCredit_ready s ⟨h, hh.1, hh.2, hr.1.1, hr.1.2.1⟩ hr.2

end Juicer.PublicCalls
