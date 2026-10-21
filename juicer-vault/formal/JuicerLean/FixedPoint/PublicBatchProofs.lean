import JuicerLean.FixedPoint.PublicCreditProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def batchCostPaid (a c t p : Nat) : Nat := batchReduction a c t p-batchCash a c t p

theorem batch_cash_mono (a c t p q : Nat) (h : p ≤ q) :
    batchCash a c t p ≤ batchCash a c t q :=
  Nat.div_le_div_right (Nat.mul_le_mul_right _ (Nat.div_le_div_right (Nat.mul_le_mul_left _ h)))

theorem batch_cash_le_reduction (a c t p : Nat) : batchCash a c t p ≤ batchReduction a c t p :=
  proportional_le _ _ _ (by omega)

theorem batch_cost_mono (a c t p q : Nat) (hp : 0 < a+c) (h : p ≤ q) :
    batchCostPaid a c t p ≤ batchCostPaid a c t q := by
  have hd : batchReduction a c t p ≤ batchReduction a c t q :=
    Nat.div_le_div_right (Nat.mul_le_mul_left _ h)
  have hc := batch_cash_mono a c t p q h
  have hs := floor_fraction_lipschitz a (a+c) (batchReduction a c t p) (batchReduction a c t q)
    (by omega) hp hd
  have hb := batch_cash_le_reduction a c t p
  have he := batch_cash_le_reduction a c t q
  change batchCash a c t q-batchCash a c t p ≤ batchReduction a c t q-batchReduction a c t p at hs
  unfold batchCostPaid
  omega

theorem batch_cash_step (a c t p w : Nat) :
    batchCash a c t p+(batchSegment a c t p w).1 = batchCash a c t (p+w) := by
  have h := batch_cash_mono a c t p (p+w) (by omega)
  simp only [batchSegment]
  omega

theorem batch_cost_step (a c t p w : Nat) (hp : 0 < a+c) :
    batchCostPaid a c t p+(batchSegment a c t p w).2 = batchCostPaid a c t (p+w) := by
  have hc := batch_cash_step a c t p w
  have hs := batchSegment_conserved a c t p w hp
  have hb := batch_cash_le_reduction a c t p
  have he := batch_cash_le_reduction a c t (p+w)
  have hd : batchReduction a c t p ≤ batchReduction a c t (p+w) :=
    Nat.div_le_div_right (Nat.mul_le_mul_left _ (by omega))
  unfold batchCostPaid
  omega

theorem batch_full_totals (a c t : Nat) (hp : 0 < a+c) (ht : 0 < t) :
    batchCash a c t t = a ∧ batchCostPaid a c t t = c := by
  have hr : batchReduction a c t t = a+c := Nat.mul_div_cancel _ ht
  have hc : batchCash a c t t = a := by
    unfold batchCash
    rw [hr,Nat.mul_comm]
    exact Nat.mul_div_cancel _ hp
  rw [batchCostPaid,hr,hc]
  omega

theorem batch_segment_budget (a c t p w cash cost : Nat) (hp : 0 < a+c) (ht : 0 < t)
    (hw : p+w ≤ t) (hc : a-batchCash a c t p ≤ cash) (hcost : c-batchCostPaid a c t p ≤ cost) :
    (batchSegment a c t p w).1 ≤ cash ∧ (batchSegment a c t p w).2 ≤ cost ∧
    a-batchCash a c t (p+w) ≤ cash-(batchSegment a c t p w).1 ∧
    c-batchCostPaid a c t (p+w) ≤ cost-(batchSegment a c t p w).2 := by
  have hf := batch_full_totals a c t hp ht
  have hcm := batch_cash_mono a c t (p+w) t hw
  have hdm := batch_cost_mono a c t (p+w) t hp hw
  have hcs := batch_cash_step a c t p w
  have hds := batch_cost_step a c t p w hp
  omega

structure BatchBudgetData (amount cost total weight unallocated unallocatedCost : Nat) : Prop where
  positive : 0 < amount+cost
  capacity : amount+cost ≤ total
  weight_le : weight ≤ total
  cash : amount-batchCash amount cost total weight ≤ unallocated
  cost : cost-batchCostPaid amount cost total weight ≤ unallocatedCost

abbrev BatchBudget (s : State) : Prop :=
  BatchBudgetData s.batchAmount s.batchCost s.batchTotal s.batchWeight s.unallocated s.unallocatedCost

instance (s : State) : Decidable (BatchBudget s) :=
  decidable_of_iff
    (0 < s.batchAmount+s.batchCost ∧ s.batchAmount+s.batchCost ≤ s.batchTotal ∧ s.batchWeight ≤ s.batchTotal ∧
      s.batchAmount-batchCash s.batchAmount s.batchCost s.batchTotal s.batchWeight ≤ s.unallocated ∧
      s.batchCost-batchCostPaid s.batchAmount s.batchCost s.batchTotal s.batchWeight ≤ s.unallocatedCost)
    ⟨fun h => ⟨h.1,h.2.1,h.2.2.1,h.2.2.2.1,h.2.2.2.2⟩,
      fun h => ⟨h.positive,h.capacity,h.weight_le,h.cash,h.cost⟩⟩

theorem creditPosition_budget (s : State) (key weight : Nat) (h : BatchBudget s)
    (hw : s.batchWeight+weight ≤ s.batchTotal) : BatchBudget (creditPosition s key weight).1 := by
  have hb := batch_segment_budget s.batchAmount s.batchCost s.batchTotal s.batchWeight weight
    s.unallocated s.unallocatedCost h.positive (by have := h.capacity; have := h.positive; omega)
    hw h.cash h.cost
  rw [creditPosition_state_factored]
  exact ⟨h.positive,h.capacity,hw,hb.2.2.1,hb.2.2.2⟩

theorem creditPosition_public_of_budget (s : State) (key weight : Nat) (h : PublicInvariant s)
    (hi : key < s.positions.size)
    (hw : weight = if key == 0 then s.activeRemaining else (position s key).remaining)
    (ha : (position s 0).remaining = 0) (hf : PositionFeeBacking s) (hb : BatchBudget s)
    (hweight : s.batchWeight+weight ≤ s.batchTotal) : PublicInvariant (creditPosition s key weight).1 := by
  have hbudget := batch_segment_budget s.batchAmount s.batchCost s.batchTotal s.batchWeight weight
    s.unallocated s.unallocatedCost hb.positive (by have := hb.capacity; have := hb.positive; omega)
    hweight hb.cash hb.cost
  exact creditPosition_public s key weight h (creditNumbers_safe s key weight h hi hw ha hf
    hb.positive hb.capacity hbudget.1 hbudget.2.1)

def batchPending (s : State) : List MainPosition := (s.positions.toList.take s.batchTail).drop s.batchCursor

structure BatchShapeData (cursor tail size weight pending total : Nat) : Prop where
  cursor_positive : 0 < cursor
  cursor_le : cursor ≤ tail
  tail_le : tail ≤ size
  weights : weight+pending = total

abbrev BatchShape (s : State) : Prop :=
  BatchShapeData s.batchCursor s.batchTail s.positions.size s.batchWeight
    (batchPending s |>.map MainPosition.remaining).sum s.batchTotal

instance (s : State) : Decidable (BatchShape s) :=
  decidable_of_iff (0 < s.batchCursor ∧ s.batchCursor ≤ s.batchTail ∧ s.batchTail ≤ s.positions.size ∧
    s.batchWeight+(batchPending s |>.map MainPosition.remaining).sum = s.batchTotal)
    ⟨fun h => ⟨h.1,h.2.1,h.2.2.1,h.2.2.2⟩,
      fun h => ⟨h.cursor_positive,h.cursor_le,h.tail_le,h.weights⟩⟩

def creditCursor (s : State) (key : Nat) : State :=
  { s with
    batchCursor := key+1,
    sourceHead := if key == s.sourceHead && (position s key).remaining == 0 then s.sourceHead+1 else s.sourceHead }

def advanceCredit (s : State) : State :=
  creditCursor (creditPosition s s.batchCursor (position s s.batchCursor).remaining).1 s.batchCursor

theorem creditCursor_public (s : State) (key : Nat) (h : PublicInvariant s) :
    PublicInvariant (creditCursor s key) := h

theorem batchPending_cons (s : State) (hs : BatchShape s) (hi : s.batchCursor < s.batchTail) :
    batchPending s = position s s.batchCursor :: (s.positions.toList.take s.batchTail).drop (s.batchCursor+1) := by
  have hsize : s.batchCursor < (s.positions.toList.take s.batchTail).length := by
    simp only [List.length_take,Array.length_toList]
    have := hs.tail_le
    omega
  unfold batchPending
  rw [List.drop_eq_getElem_cons hsize]
  congr 1
  simp only [List.getElem_take,Array.getElem_toList,position]
  rw [Array.getElem?_eq_getElem (hi.trans_le hs.tail_le),Option.getD_some]

theorem batchPending_advance (s : State) :
    batchPending (advanceCredit s) = (s.positions.toList.take s.batchTail).drop (s.batchCursor+1) := by
  unfold advanceCredit
  rw [creditPosition_state_factored]
  simp only [batchPending,creditCursor,creditState,setPosition,Array.set!_eq_setIfInBounds,
    Array.toList_setIfInBounds,List.take_set,List.drop_set_of_lt (Nat.lt_succ_self _)]

theorem advanceCredit_shape (s : State) (hs : BatchShape s) (hi : s.batchCursor < s.batchTail) :
    BatchShape (advanceCredit s) := by
  have hc := batchPending_cons s hs hi
  have hw := hs.weights
  rw [hc,List.map_cons,List.sum_cons] at hw
  refine ⟨Nat.succ_pos _,by exact hi,?_,?_⟩
  · simpa only [advanceCredit,creditCursor,creditPosition_state_factored,creditState,setPosition,
      Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hs.tail_le
  · rw [batchPending_advance]
    change (s.batchWeight+(position s s.batchCursor).remaining)+
      ((s.positions.toList.take s.batchTail).drop (s.batchCursor+1) |>.map MainPosition.remaining).sum = s.batchTotal
    omega

def CreditLoopInvariant (s : State) : Prop :=
  PublicInvariant s ∧ BatchBudget s ∧ BatchShape s ∧ PositionFeeBacking s ∧ (position s 0).remaining = 0

theorem advanceCredit_preserves (s : State) (h : CreditLoopInvariant s) (hi : s.batchCursor < s.batchTail) :
    CreditLoopInvariant (advanceCredit s) := by
  rcases h with ⟨h,hb,hs,hf,ha⟩
  have hindex : s.batchCursor < s.positions.size := hi.trans_le hs.tail_le
  have hweight : s.batchWeight+(position s s.batchCursor).remaining ≤ s.batchTotal := by
    have hw := hs.weights
    rw [batchPending_cons s hs hi,List.map_cons,List.sum_cons] at hw
    omega
  have hw : (position s s.batchCursor).remaining =
      if s.batchCursor == 0 then s.activeRemaining else (position s s.batchCursor).remaining := by
    have hz : s.batchCursor ≠ 0 := Nat.ne_zero_of_lt hs.cursor_positive
    simp only [beq_eq_false_iff_ne.mpr hz,Bool.false_eq_true,ite_false]
  have hbudget := batch_segment_budget s.batchAmount s.batchCost s.batchTotal s.batchWeight
    (position s s.batchCursor).remaining s.unallocated s.unallocatedCost hb.positive
    (by have := hb.positive; have := hb.capacity; omega) hweight hb.cash hb.cost
  have safe := creditNumbers_safe s s.batchCursor (position s s.batchCursor).remaining h hindex hw ha hf
    hb.positive hb.capacity hbudget.1 hbudget.2.1
  refine ⟨creditCursor_public _ _ (creditPosition_public _ _ _ h safe),?_,advanceCredit_shape s hs hi,?_,?_⟩
  · have hn := creditPosition_budget s s.batchCursor _ hb hweight
    exact ⟨hn.positive,hn.capacity,hn.weight_le,hn.cash,hn.cost⟩
  · exact creditPosition_fee_backing s s.batchCursor _ h safe hf
  · exact creditPosition_active s s.batchCursor _ hindex ha

theorem creditSteps_preserves (fuel : Nat) (s : State) (h : CreditLoopInvariant s) :
    CreditLoopInvariant (creditSteps fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    change CreditLoopInvariant (if s.batchTail ≤ s.batchCursor then s else creditSteps fuel (advanceCredit s))
    split
    · exact h
    · rename_i hnext
      exact ih _ (advanceCredit_preserves s h (by omega))

end Juicer.PublicCalls
