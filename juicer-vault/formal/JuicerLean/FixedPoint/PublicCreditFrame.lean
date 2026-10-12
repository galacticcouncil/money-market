import JuicerLean.FixedPoint.PublicCreditReadiness

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

structure CreditFrame (s t : State) : Prop where
  remaining : (t.positions.toList.map MainPosition.remaining).take s.positions.size =
    s.positions.toList.map MainPosition.remaining
  head : t.sourceHead = s.sourceHead
  amount : t.batchAmount = s.batchAmount
  cost : t.batchCost = s.batchCost
  total : t.batchTotal = s.batchTotal
  weight : t.batchWeight = s.batchWeight
  cursor : t.batchCursor = s.batchCursor
  tail : t.batchTail = s.batchTail
  cash_le : s.unallocated ≤ t.unallocated
  cost_le : s.unallocatedCost ≤ t.unallocatedCost

theorem creditFrame_size {s t : State} (h : CreditFrame s t) : s.positions.size ≤ t.positions.size := by
  have he := congrArg List.length h.remaining
  simp only [List.length_take, List.length_map, Array.length_toList] at he
  omega

theorem creditFrame_take {s t : State} (h : CreditFrame s t) (n : Nat) (hn : n ≤ s.positions.size) :
    (t.positions.toList.map MainPosition.remaining).take n =
      (s.positions.toList.map MainPosition.remaining).take n := by
  have he := congrArg (List.take n) h.remaining
  simpa only [List.take_take, Nat.min_eq_left hn] using he

theorem creditFrame_position {s t : State} (h : CreditFrame s t) (i : Nat) (hi : i < s.positions.size) :
    (position t i).remaining = (position s i).remaining := by
  have ht : i < t.positions.size := hi.trans_le (creditFrame_size h)
  have he := congrArg (fun xs : List Nat => xs[i]?) h.remaining
  simp only [List.getElem?_take_of_lt hi, List.getElem?_map,
    Array.getElem?_toList, Array.getElem?_eq_getElem hi, Array.getElem?_eq_getElem ht,
    Option.map_some, Option.some.injEq] at he
  simpa only [position, Array.getElem?_eq_getElem hi, Array.getElem?_eq_getElem ht,
    Option.getD_some] using he

theorem creditFrame_prefix {s t : State} (frame : CreditFrame s t) (h : CreditPrefix s) : CreditPrefix t := by
  refine ⟨by simpa only [frame.head] using h.1, ?_, ?_⟩
  · rw [frame.head]
    exact h.2.1.trans (creditFrame_size frame)
  · intro i hi
    rw [frame.head] at hi
    rw [creditFrame_position frame i (hi.trans_le h.2.1)]
    exact h.2.2 i hi

theorem creditFrame_budget {s t : State} (frame : CreditFrame s t) (h : BatchBudget s) : BatchBudget t := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · simpa only [frame.amount, frame.cost] using h.positive
  · simpa only [frame.amount, frame.cost, frame.total] using h.capacity
  · simpa only [frame.weight, frame.total] using h.weight_le
  · simpa only [frame.amount, frame.cost, frame.total, frame.weight] using h.cash.trans frame.cash_le
  · simpa only [frame.amount, frame.cost, frame.total, frame.weight] using h.cost.trans frame.cost_le

theorem creditFrame_shape {s t : State} (frame : CreditFrame s t) (h : BatchShape s) : BatchShape t := by
  refine ⟨by simpa only [frame.cursor] using h.cursor_positive,
    by simpa only [frame.cursor, frame.tail] using h.cursor_le, ?_, ?_⟩
  · rw [frame.tail]
    exact h.tail_le.trans (creditFrame_size frame)
  · have he := creditFrame_take frame s.batchTail h.tail_le
    have hs := h.weights
    simp only [batchPending, List.map_drop, List.map_take] at hs ⊢
    rw [frame.weight, frame.tail, frame.cursor, frame.total, he]
    exact hs

theorem creditFrame_ready {s t : State} (frame : CreditFrame s t) (h : CreditReadyHistory s)
    (hf : PositionFeeBacking t) : CreditReadyHistory t := by
  have hp := creditFrame_prefix frame h.2
  refine ⟨⟨hf, ?_, ?_⟩, hp⟩
  · rw [creditFrame_position frame 0 (h.2.1.trans_le h.2.2.1)]
    exact h.1.2.1
  · change if t.batchAmount == 0 && t.batchCost == 0 then FreshCreditShape t else BatchBudget t ∧ BatchShape t
    rw [frame.amount, frame.cost]
    split
    · exact creditPrefix_fresh t hp
    · rename_i he
      have hn := h.1.2.2
      rw [if_neg he] at hn
      exact ⟨creditFrame_budget frame hn.1, creditFrame_shape frame hn.2⟩

theorem remaining_setPosition (s : State) (key : Nat) (p : MainPosition)
    (hp : p.remaining = (position s key).remaining) :
    (setPosition s key p).positions.toList.map MainPosition.remaining = s.positions.toList.map MainPosition.remaining := by
  simp only [setPosition, Array.set!_eq_setIfInBounds, Array.toList_setIfInBounds, List.map_set, hp]
  by_cases hi : key < s.positions.size
  · have hm : key < (s.positions.toList.map MainPosition.remaining).length := by simpa using hi
    convert List.set_getElem_self hm using 1
    simp only [List.getElem_map, Array.getElem_toList, position,
      Array.getElem?_eq_getElem hi, Option.getD_some]
  · exact List.set_eq_of_length_le (by simpa using Nat.le_of_not_gt hi)

theorem creditFrame_setPosition (s : State) (key : Nat) (p : MainPosition)
    (hp : p.remaining = (position s key).remaining) : CreditFrame s (setPosition s key p) := by
  refine ⟨?_, rfl, rfl, rfl, rfl, rfl, rfl, rfl, le_rfl, le_rfl⟩
  rw [remaining_setPosition s key p hp]
  exact List.take_of_length_le (by simp)

end Juicer.PublicCalls
