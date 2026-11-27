import JuicerLean.FixedPoint.PublicSourceProofs
import JuicerLean.FixedPoint.PublicSettlementProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

structure CreditNumbers where
  cash : Nat
  cost : Nat
  charged : Nat
  nextFee : SourceFee

def creditNumbers (s : State) (key weight : Nat) : CreditNumbers :=
  let part := batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight
  let fees := settleFee (fee s key) (weight-part.1-part.2) part.2
  ⟨part.1,part.2,fees.2,fees.1⟩

def creditState (s : State) (key weight : Nat) (q : CreditNumbers) : State :=
  let remaining := weight-q.cash-q.cost
  let next := setPosition s key { position s key with
    cash := (position s key).cash+q.cash-q.charged,remaining := if key == 0 then 0 else remaining }
  { next with
    activeRemaining := if key == 0 then remaining else s.activeRemaining,
    sourceFees := s.sourceFees.set! key q.nextFee,
    feeReserve := s.feeReserve-((fee s key).feeLeft-q.nextFee.feeLeft),
    feesHollar := s.feesHollar+q.charged,ownedCash := s.ownedCash-q.charged,
    unallocated := s.unallocated-q.cash,unallocatedCost := s.unallocatedCost-q.cost,
    outstanding := s.outstanding-q.cash-q.cost,batchWeight := s.batchWeight+weight }

theorem creditPosition_state_factored (s : State) (key weight : Nat) :
    (creditPosition s key weight).1 = creditState s key weight (creditNumbers s key weight) := by
  rfl

structure CreditSafe (s : State) (key weight : Nat) (q : CreditNumbers) : Prop where
  index : key < s.positions.size
  weight_eq : weight = if key == 0 then s.activeRemaining else (position s key).remaining
  active : (position s 0).remaining = 0
  reduction : q.cash+q.cost ≤ weight
  cash : q.cash ≤ s.unallocated
  cost : q.cost ≤ s.unallocatedCost
  charged : q.charged ≤ (position s key).cash+q.cash
  fee : q.nextFee.feeLeft ≤ (fee s key).feeLeft
  junior : q.nextFee.feeLeft ≤ q.nextFee.yieldLeft

theorem credit_cash_balance (before after cash assigned charged unallocated owned : Nat)
    (hbefore : before+unallocated = owned)
    (hchange : after+cash = before+(cash+assigned-charged))
    (hassigned : assigned ≤ unallocated) (hcharged : charged ≤ cash+assigned) :
    after+(unallocated-assigned) = owned-charged := by omega

theorem credit_source_balance (active before after outstanding position weight cash cost : Nat)
    (hbefore : active+before = outstanding)
    (hchange : after+position = before+(weight-cash-cost))
    (hweight : position = weight) (hbound : cash+cost ≤ weight) :
    active+after = outstanding-cash-cost := by omega

theorem credit_active_balance (active before after outstanding cash cost : Nat)
    (hbefore : active+before = outstanding) (hchange : after = before)
    (hbound : cash+cost ≤ active) : (active-cash-cost)+after = outstanding-cash-cost := by omega

theorem credit_fee_balance (before after previous next : Nat)
    (hchange : after+previous = before+next) (hbound : next ≤ previous) :
    after = before-(previous-next) := by omega

theorem creditState_source (s : State) (key weight : Nat) (q : CreditNumbers)
    (h : (sourceProjection s).valid) (safe : CreditSafe s key weight q) :
    (sourceProjection (creditState s key weight q)).valid := by
  have hr := position_sum_replace s key { position s key with
    cash := (position s key).cash+q.cash-q.charged,
    remaining := if key == 0 then 0 else weight-q.cash-q.cost } MainPosition.remaining safe.index
  change s.activeRemaining+(sourceProjection s).exits.sum = s.outstanding at h
  change (sourceProjection (creditState s key weight q)).exits.sum+(position s key).remaining =
    (sourceProjection s).exits.sum+(if key == 0 then 0 else weight-q.cash-q.cost) at hr
  have hw := safe.weight_eq
  by_cases hz : key = 0
  · subst key
    simp only [beq_self_eq_true,ite_true] at hw hr
    rw [safe.active,Nat.add_zero,Nat.add_zero] at hr
    change (weight-q.cash-q.cost)+(sourceProjection (creditState s 0 weight q)).exits.sum = s.outstanding-q.cash-q.cost
    rw [hw]
    exact credit_active_balance _ _ _ _ _ _ h hr (hw ▸ safe.reduction)
  · simp only [beq_eq_false_iff_ne.mpr hz,Bool.false_eq_true,ite_false] at hw hr
    change (if key == 0 then weight-q.cash-q.cost else s.activeRemaining)+
      (sourceProjection (creditState s key weight q)).exits.sum = s.outstanding-q.cash-q.cost
    rw [if_neg (by simpa only [beq_iff_eq] using hz)]
    exact credit_source_balance _ _ _ _ _ _ _ _ h hr hw.symm safe.reduction

theorem creditState_cash (s : State) (key weight : Nat) (q : CreditNumbers)
    (h : (cashProjection s).valid) (safe : CreditSafe s key weight q) :
    (cashProjection (creditState s key weight q)).valid := by
  have hc := position_sum_replace s key { position s key with
    cash := (position s key).cash+q.cash-q.charged,
    remaining := if key == 0 then 0 else weight-q.cash-q.cost } MainPosition.cash safe.index
  change (cashProjection s).cohorts.sum+s.unallocated = s.ownedCash at h
  change (cashProjection (creditState s key weight q)).cohorts.sum+(position s key).cash =
    (cashProjection s).cohorts.sum+((position s key).cash+q.cash-q.charged) at hc
  exact credit_cash_balance _ _ _ _ _ _ _ h hc safe.cash safe.charged

theorem creditState_operational (s : State) (key weight : Nat) (q : CreditNumbers)
    (h : OperationalInvariant s) (safe : CreditSafe s key weight q) :
    OperationalInvariant (creditState s key weight q) := by
  rcases h with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  have hfindex : key < s.sourceFees.size := by rw [hfs]; exact safe.index
  have hsum := list_sum_map_set s.sourceFees.toList key q.nextFee {} SourceFee.feeLeft (by simpa using hfindex)
  simp only [Array.getElem?_toList] at hsum
  change ((s.sourceFees.toList.set key q.nextFee).map SourceFee.feeLeft).sum+(fee s key).feeLeft =
    (s.sourceFees.toList.map SourceFee.feeLeft).sum+q.nextFee.feeLeft at hsum
  have hmainSum := position_sum_replace s key { position s key with
    cash := (position s key).cash+q.cash-q.charged,
    remaining := if key == 0 then 0 else weight-q.cash-q.cost } MainPosition.units safe.index
  change ((creditState s key weight q).positions.toList.map MainPosition.units).sum+(position s key).units =
    (s.positions.toList.map MainPosition.units).sum+(position s key).units at hmainSum
  refine ⟨hw,ha,hc,hap,?_,hu,hsupply,?_,?_,?_,?_,?_,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  · simpa only [creditState,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hpos
  · exact hmain.trans (Nat.add_right_cancel hmainSum).symm
  · change s.freed+(s.unallocated-q.cash)+(s.unallocatedCost-q.cost) = s.outstanding-q.cash-q.cost
    have hca := safe.cash
    have hco := safe.cost
    omega
  · simpa only [creditState,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hfs
  · change s.feeReserve-((fee s key).feeLeft-q.nextFee.feeLeft) =
      ((s.sourceFees.set! key q.nextFee).toList.map SourceFee.feeLeft).sum
    rw [Array.set!_eq_setIfInBounds,Array.toList_setIfInBounds,hfr]
    exact (credit_fee_balance _ _ _ _ hsum safe.fee).symm
  · intro f hf
    change f ∈ (s.sourceFees.set! key q.nextFee).toList at hf
    rw [Array.set!_eq_setIfInBounds,Array.toList_setIfInBounds] at hf
    rcases List.mem_or_eq_of_mem_set hf with hm | rfl
    · exact hfee f hm
    · exact safe.junior

theorem creditState_public (s : State) (key weight : Nat) (q : CreditNumbers)
    (h : PublicInvariant s) (safe : CreditSafe s key weight q) :
    PublicInvariant (creditState s key weight q) := by
  apply public_of_operational
  · exact h.1
  · exact creditState_source s key weight q h.2.1 safe
  · exact creditState_cash s key weight q h.2.2.1 safe
  · exact h.2.2.2.2.1
  · exact creditState_operational s key weight q h.2.2.2.2.2 safe

theorem creditPosition_public (s : State) (key weight : Nat) (h : PublicInvariant s)
    (safe : CreditSafe s key weight (creditNumbers s key weight)) :
    PublicInvariant (creditPosition s key weight).1 := by
  rw [creditPosition_state_factored]
  exact creditState_public s key weight _ h safe

def FeeBacking (f : SourceFee) (cash remaining : Nat) : Prop :=
  f.feeLeft ≤ cash ∨ f.yieldLeft ≤ cash+remaining

instance (f : SourceFee) (cash remaining : Nat) : Decidable (FeeBacking f cash remaining) := by
  unfold FeeBacking
  infer_instance

theorem settleFee_charge_le_yield (f : SourceFee) (remaining cost : Nat)
    (h : f.feeLeft ≤ f.yieldLeft) : (settleFee f remaining cost).2 ≤ f.yieldLeft-cost := by
  have hp := proportional_le (f.yieldLeft-min f.yieldLeft cost) f.feeLeft f.yieldLeft h
  simp only [settleFee]
  split_ifs <;> simp_all only [beq_iff_eq,Nat.mul_comm]
  all_goals omega

theorem settleFee_cash_backing (f : SourceFee) (cash weight assigned cost : Nat)
    (hjunior : f.feeLeft ≤ f.yieldLeft) (hback : FeeBacking f cash weight)
    (hpart : assigned+cost ≤ weight) :
    (settleFee f (weight-assigned-cost) cost).2 ≤ cash+assigned ∧
    FeeBacking (settleFee f (weight-assigned-cost) cost).1
      (cash+assigned-(settleFee f (weight-assigned-cost) cost).2) (weight-assigned-cost) := by
  have hfee := settleFee_never_increases f (weight-assigned-cost) cost
  have hyield := settleFee_charge_le_yield f (weight-assigned-cost) cost hjunior
  by_cases hz : weight-assigned-cost = 0
  · have hn : (settleFee f (weight-assigned-cost) cost).1 = ⟨0,0⟩ := by
      simp only [settleFee,hz,beq_self_eq_true,ite_true]
    refine ⟨?_,?_⟩
    · rcases hback with hf | hy <;> omega
    · rw [hn]; exact Or.inl (Nat.zero_le _)
  · have hc := unfinished_fee_not_charged f (weight-assigned-cost) cost hz
    refine ⟨by omega,?_⟩
    rw [hc,Nat.sub_zero]
    rcases hback with hf | hy
    · exact Or.inl (by omega)
    · apply Or.inr
      change (settleFee f (weight-assigned-cost) cost).1.yieldLeft ≤ cash+assigned+(weight-assigned-cost)
      simp only [settleFee,beq_iff_eq,hz,ite_false]
      omega

def PositionFeeBacking (s : State) : Prop :=
  ∀ key, key < s.positions.size → FeeBacking (fee s key) (position s key).cash
    (if key == 0 then s.activeRemaining else (position s key).remaining)

instance (s : State) : Decidable (PositionFeeBacking s) := by
  unfold PositionFeeBacking
  infer_instance

theorem public_fee_junior (s : State) (key : Nat) (h : PublicInvariant s) (hi : key < s.positions.size) :
    (fee s key).feeLeft ≤ (fee s key).yieldLeft := by
  have hfs : s.sourceFees.size = s.positions.size := h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  have hmem : fee s key ∈ s.sourceFees.toList := by
    change (s.sourceFees[key]?).getD {} ∈ s.sourceFees.toList
    rw [Array.getElem?_eq_getElem (by omega),Option.getD_some]
    exact List.getElem_mem (by simpa using (show key < s.sourceFees.size from by omega))
  exact h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1 _ hmem

theorem creditNumbers_safe (s : State) (key weight : Nat) (h : PublicInvariant s)
    (hi : key < s.positions.size)
    (hw : weight = if key == 0 then s.activeRemaining else (position s key).remaining)
    (ha : (position s 0).remaining = 0) (hf : PositionFeeBacking s)
    (hp : 0 < s.batchAmount+s.batchCost) (ht : s.batchAmount+s.batchCost ≤ s.batchTotal)
    (hc : (batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight).1 ≤ s.unallocated)
    (hcost : (batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight).2 ≤ s.unallocatedCost) :
    CreditSafe s key weight (creditNumbers s key weight) := by
  have hj := public_fee_junior s key h hi
  have hpart := batchSegment_never_overcredits s.batchAmount s.batchCost s.batchTotal s.batchWeight weight
    hp (by omega) ht
  have hback := settleFee_cash_backing (fee s key) (position s key).cash weight _ _ hj
    (hw ▸ hf key hi) hpart
  have hnext := settleFee_never_increases (fee s key)
    (weight-(batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight).1-
      (batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight).2)
    (batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight).2
  exact ⟨hi,hw,ha,hpart,hc,hcost,hback.1,by dsimp only [creditNumbers]; omega,
    settleFee_remains_junior _ _ _ hj⟩

theorem creditState_position (s : State) (key weight : Nat) (q : CreditNumbers) (i : Nat)
    (hi : key < s.positions.size) :
    position (creditState s key weight q) i = if key = i then
      { position s key with
        cash := (position s key).cash+q.cash-q.charged,
        remaining := if key == 0 then 0 else weight-q.cash-q.cost } else position s i := by
  by_cases he : key = i
  · subst i
    simp [creditState,setPosition,position,Array.set!_eq_setIfInBounds,hi]
  · simp only [creditState,setPosition,position,Array.set!_eq_setIfInBounds,Array.getElem?_setIfInBounds,if_neg he]

theorem creditState_fee (s : State) (key weight : Nat) (q : CreditNumbers) (i : Nat)
    (hi : key < s.sourceFees.size) :
    fee (creditState s key weight q) i = if key = i then q.nextFee else fee s i := by
  by_cases he : key = i
  · subst i
    simp [creditState,fee,Array.set!_eq_setIfInBounds,hi]
  · simp only [creditState,fee,Array.set!_eq_setIfInBounds,Array.getElem?_setIfInBounds,if_neg he]

theorem creditPosition_active (s : State) (key weight : Nat) (hi : key < s.positions.size)
    (ha : (position s 0).remaining = 0) : (position (creditPosition s key weight).1 0).remaining = 0 := by
  rw [creditPosition_state_factored,creditState_position s key weight _ 0 hi]
  by_cases hz : key = 0
  · simp [hz]
  · simp [hz,ha]

theorem creditPosition_fee_backing (s : State) (key weight : Nat) (h : PublicInvariant s)
    (safe : CreditSafe s key weight (creditNumbers s key weight)) (hf : PositionFeeBacking s) :
    PositionFeeBacking (creditPosition s key weight).1 := by
  let q := creditNumbers s key weight
  have hfs : s.sourceFees.size = s.positions.size := h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  have hfi : key < s.sourceFees.size := by rw [hfs]; exact safe.index
  have hn := (settleFee_cash_backing (fee s key) (position s key).cash weight q.cash q.cost
    (public_fee_junior s key h safe.index) (safe.weight_eq ▸ hf key safe.index) safe.reduction).2
  change FeeBacking q.nextFee ((position s key).cash+q.cash-q.charged) (weight-q.cash-q.cost) at hn
  rw [creditPosition_state_factored]
  intro i hi
  have his : i < s.positions.size := by
    simpa only [creditState,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hi
  change FeeBacking (fee (creditState s key weight q) i) (position (creditState s key weight q) i).cash
    (if i == 0 then (creditState s key weight q).activeRemaining else
      (position (creditState s key weight q) i).remaining)
  rw [creditState_fee s key weight q i hfi,creditState_position s key weight q i safe.index]
  by_cases he : key = i
  · subst i
    simp only [ite_true]
    by_cases hz : key = 0
    · simpa only [creditState,hz,beq_self_eq_true,ite_true] using hn
    · simpa only [creditState,beq_eq_false_iff_ne.mpr hz,Bool.false_eq_true,ite_false] using hn
  · simp only [if_neg he]
    by_cases hz : i = 0
    · subst i
      simpa only [creditState,beq_self_eq_true,ite_true,beq_eq_false_iff_ne.mpr he,Bool.false_eq_true,ite_false]
        using hf 0 his
    · simpa only [beq_eq_false_iff_ne.mpr hz,Bool.false_eq_true,ite_false] using hf i his

end Juicer.PublicCalls
