import JuicerLean.FixedPoint.PublicBatchProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def FreshCreditShape (s : State) : Prop :=
  0 < s.sourceHead ∧ s.sourceHead ≤ s.positions.size ∧
    ((s.positions.toList.take s.sourceHead).map MainPosition.remaining).sum = 0

instance (s : State) : Decidable (FreshCreditShape s) := by
  unfold FreshCreditShape
  infer_instance

def CreditReady (s : State) : Prop :=
  PositionFeeBacking s ∧ (position s 0).remaining = 0 ∧
    (if s.batchAmount == 0 && s.batchCost == 0 then FreshCreditShape s else BatchBudget s ∧ BatchShape s)

instance (s : State) : Decidable (CreditReady s) := by
  unfold CreditReady
  infer_instance

def setupCredit (s : State) : State :=
  { s with
    batchAmount := s.unallocated,batchCost := s.unallocatedCost,batchTotal := s.outstanding,
    batchWeight := 0,batchCursor := s.sourceHead,batchTail := s.positions.size }

def activeCredit (s : State) : State :=
  let (next,cost) := creditPosition (setupCredit s) 0 s.activeRemaining
  { next with delever := next.delever-cost }

def closeCredit (s : State) : State :=
  if s.batchCursor == s.batchTail then { s with batchAmount := 0,batchCost := 0,batchWeight := 0 } else s

def finishCredit (s : State) : State := closeCredit (creditSteps 64 s)

def receiveCredit (s : State) (amount cost : Nat) : State :=
  { s with
    unallocated := s.unallocated+amount,unallocatedCost := s.unallocatedCost+cost,
    ownedCash := s.ownedCash+amount }

def creditReceived (s : State) : State :=
  if s.batchAmount == 0 && s.batchCost == 0 then
    if s.unallocated == 0 && s.unallocatedCost == 0 then s else finishCredit (activeCredit s)
  else finishCredit s

theorem credit_factored (s : State) (amount cost : Nat) :
    credit s amount cost = creditReceived (receiveCredit s amount cost) := by
  unfold credit creditReceived finishCredit closeCredit activeCredit setupCredit receiveCredit
  simp only [Id.run,bind,pure]
  split_ifs <;> rfl

theorem closeCredit_public (s : State) (h : PublicInvariant s) : PublicInvariant (closeCredit s) := by
  unfold closeCredit
  split <;> exact h

theorem finishCredit_public (s : State) (h : CreditLoopInvariant s) : PublicInvariant (finishCredit s) :=
  closeCredit_public _ (creditSteps_preserves 64 s h).1

theorem fresh_credit_weights (s : State) (h : PublicInvariant s) (hs : FreshCreditShape s) :
    s.activeRemaining+((s.positions.toList.drop s.sourceHead).map MainPosition.remaining).sum = s.outstanding := by
  have hw := h.2.1
  change s.activeRemaining+(s.positions.toList.map MainPosition.remaining).sum = s.outstanding at hw
  have he := congrArg (fun xs : List MainPosition => (xs.map MainPosition.remaining).sum)
    (List.take_append_drop s.sourceHead s.positions.toList)
  simp only [List.map_append,List.sum_append,hs.2.2,Nat.zero_add] at he
  omega

theorem setupCredit_budget (s : State) (h : PublicInvariant s) (hp : 0 < s.unallocated+s.unallocatedCost) :
    BatchBudget (setupCredit s) := by
  have hb : s.freed+s.unallocated+s.unallocatedCost = s.outstanding := h.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  refine ⟨hp,by change s.unallocated+s.unallocatedCost ≤ s.outstanding; omega,Nat.zero_le _,?_,?_⟩
  · simp only [setupCredit,batchCash,batchReduction,Nat.mul_zero,Nat.zero_div,Nat.zero_mul,Nat.sub_zero,Nat.le_refl]
  · simp only [setupCredit,batchCostPaid,batchCash,batchReduction,Nat.mul_zero,Nat.zero_div,Nat.zero_mul,Nat.sub_zero,Nat.le_refl]

theorem activeCredit_loop (s : State) (h : PublicInvariant s) (hf : PositionFeeBacking s)
    (ha : (position s 0).remaining = 0) (hs : FreshCreditShape s) (hp : 0 < s.unallocated+s.unallocatedCost) :
    CreditLoopInvariant (activeCredit s) := by
  have hi : 0 < s.positions.size := h.2.2.2.2.2.2.2.2.2.1
  have hsetup : PublicInvariant (setupCredit s) := h
  have hb := setupCredit_budget s h hp
  have hw := fresh_credit_weights s h hs
  have hweight : (setupCredit s).batchWeight+s.activeRemaining ≤ (setupCredit s).batchTotal := by
    change 0+s.activeRemaining ≤ s.outstanding
    omega
  have hbudget := batch_segment_budget (setupCredit s).batchAmount (setupCredit s).batchCost
    (setupCredit s).batchTotal 0 s.activeRemaining s.unallocated s.unallocatedCost hb.positive
    (by have := hb.positive; have := hb.capacity; omega) hweight hb.cash hb.cost
  have safe := creditNumbers_safe (setupCredit s) 0 s.activeRemaining hsetup hi (by rfl) ha hf
    hb.positive hb.capacity hbudget.1 hbudget.2.1
  have hn := creditPosition_public (setupCredit s) 0 s.activeRemaining hsetup safe
  have hbn := creditPosition_budget (setupCredit s) 0 s.activeRemaining hb hweight
  refine ⟨hn,⟨hbn.positive,hbn.capacity,hbn.weight_le,hbn.cash,hbn.cost⟩,?_,
    creditPosition_fee_backing (setupCredit s) 0 s.activeRemaining hsetup safe hf,
    creditPosition_active (setupCredit s) 0 s.activeRemaining hi ha⟩
  refine ⟨hs.1,hs.2.1,?_,?_⟩
  · simp only [activeCredit,creditPosition_state_factored,creditState,setPosition,setupCredit,
      Array.set!_eq_setIfInBounds,Array.size_setIfInBounds,Nat.le_refl]
  · change (0+s.activeRemaining)+(batchPending (activeCredit s) |>.map MainPosition.remaining).sum = s.outstanding
    rw [Nat.zero_add]
    have he : batchPending (activeCredit s) = s.positions.toList.drop s.sourceHead := by
      simp only [batchPending,activeCredit,creditPosition_state_factored,creditState,setPosition,setupCredit,
        Array.set!_eq_setIfInBounds,Array.toList_setIfInBounds,List.take_set,
        List.take_length,List.drop_set_of_lt hs.1,← Array.length_toList]
    rw [he]
    exact hw

theorem creditReceived_public (s : State) (h : PublicInvariant s) (hr : CreditReady s) :
    PublicInvariant (creditReceived s) := by
  rcases hr with ⟨hf,ha,hs⟩
  unfold creditReceived
  split
  · rename_i hnew
    rw [if_pos hnew] at hs
    split
    · exact h
    · rename_i hreceipts
      have hp : 0 < s.unallocated+s.unallocatedCost := by
        simp only [Bool.and_eq_true,beq_iff_eq] at hreceipts
        omega
      exact finishCredit_public _ (activeCredit_loop s h hf ha hs hp)
  · rename_i hresume
    rw [if_neg hresume] at hs
    exact finishCredit_public s ⟨h,hs.1,hs.2,hf,ha⟩

theorem creditPosition_queueBacking (s : State) (key weight : Nat) (h : QueueBacking s) :
    QueueBacking (creditPosition s key weight).1 := by
  rw [creditPosition_state_factored]
  refine ⟨h.1,?_⟩
  simpa only [creditState,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using h.2

theorem creditSteps_queueBacking (fuel : Nat) (s : State) (h : QueueBacking s) :
    QueueBacking (creditSteps fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    change QueueBacking (if s.batchTail ≤ s.batchCursor then s else creditSteps fuel (advanceCredit s))
    split
    · exact h
    · exact ih (advanceCredit s) (creditPosition_queueBacking s s.batchCursor _ h)

theorem closeCredit_queueBacking (s : State) (h : QueueBacking s) : QueueBacking (closeCredit s) := by
  unfold closeCredit
  split <;> exact h

theorem finishCredit_queueBacking (s : State) (h : QueueBacking s) : QueueBacking (finishCredit s) :=
  closeCredit_queueBacking _ (creditSteps_queueBacking 64 s h)

theorem delever_queueBacking (s : State) (amount : Nat) (h : QueueBacking s) :
    QueueBacking { s with delever := amount } := h

theorem activeCredit_queueBacking (s : State) (h : QueueBacking s) : QueueBacking (activeCredit s) := by
  unfold activeCredit
  exact delever_queueBacking _ _ (creditPosition_queueBacking (setupCredit s) 0 s.activeRemaining h)

theorem creditReceived_queueBacking (s : State) (h : QueueBacking s) : QueueBacking (creditReceived s) := by
  unfold creditReceived
  split
  · split
    · exact h
    · exact finishCredit_queueBacking (activeCredit s) (activeCredit_queueBacking s h)
  · exact finishCredit_queueBacking s h

def pullCreditState (s : State) (cash cost : Nat) : State :=
  { s with
    freed := s.freed-(cash+cost),sourceCash := s.sourceCash-(cash+cost),sourceCost := s.sourceCost+cost,
    unallocated := s.unallocated+cash,unallocatedCost := s.unallocatedCost+cost,ownedCash := s.ownedCash+cash }

theorem pullCreditState_public (s : State) (cash cost : Nat) (h : PublicInvariant s) (hb : cash+cost ≤ s.freed) :
    PublicInvariant (pullCreditState s cash cost) := by
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · have hc := h.2.2.1
    change (cashProjection s).cohorts.sum+s.unallocated = s.ownedCash at hc
    change (cashProjection s).cohorts.sum+(s.unallocated+cash) = s.ownedCash+cash
    omega
  · exact h.2.2.2.2.1
  · rcases h.2.2.2.2.2 with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,?_,hfs,hfr,hfee,?_,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    · change (s.freed-(cash+cost))+(s.unallocated+cash)+(s.unallocatedCost+cost) = s.outstanding
      omega
    · intro hex
      have hs := hsourceCash hex
      change sourceValue s s.held+(s.freed-(cash+cost)) ≤ s.sourceCash-(cash+cost)
      omega

theorem pullCreditState_ready (s : State) (cash cost : Nat) (h : CreditReady s) :
    CreditReady (pullCreditState s cash cost) := by
  rcases h with ⟨hf,ha,hs⟩
  refine ⟨hf,ha,?_⟩
  change if s.batchAmount == 0 && s.batchCost == 0 then FreshCreditShape (pullCreditState s cash cost)
    else BatchBudget (pullCreditState s cash cost) ∧ BatchShape (pullCreditState s cash cost)
  split
  · rename_i he
    rw [if_pos he] at hs
    exact hs
  · rename_i he
    rw [if_neg he] at hs
    refine ⟨⟨hs.1.positive,hs.1.capacity,hs.1.weight_le,?_,?_⟩,
      ⟨hs.2.cursor_positive,hs.2.cursor_le,hs.2.tail_le,hs.2.weights⟩⟩
    · exact hs.1.cash.trans (Nat.le_add_right _ _)
    · exact hs.1.cost.trans (Nat.le_add_right _ _)

def pokeSettleTail (s : State) : State :=
  let (next,_,reduced) := pay s 0 s.delever
  settleMany 32 { next with delever := if next.debt == 0 then 0 else next.delever-reduced }

theorem pokeSettleTail_public (s : State) (h : PublicInvariant s) (hb : QueueBacking s) :
    PublicInvariant (pokeSettleTail s) := by
  have hi : 0 < s.positions.size := h.2.2.2.2.2.2.2.2.2.1
  have hn := pay_public s 0 s.delever hi h
  have hq := pay_queueBacking s 0 s.delever hb
  rcases heq : pay s 0 s.delever with ⟨next,paid,reduced⟩
  rw [heq] at hn hq
  unfold pokeSettleTail
  rw [heq]
  exact (settleMany_preserves 32 { next with
    delever := if next.debt == 0 then 0 else next.delever-reduced } hn hq).1

def SourcePullBounds (s : State) : Prop := s.pullBps ≤ 10000 ∧ s.costBps ≤ 10000

instance (s : State) : Decidable (SourcePullBounds s) := by
  unfold SourcePullBounds
  infer_instance

theorem raw_pokeSettle_factored (s : State) (caller a b n : Nat) :
    rawRunCall s ⟨6,caller,a,b,n⟩ = (
      let gross := s.freed*s.pullBps/10000
      let cost := gross*s.costBps/10000
      let freed := gross-cost
      let next := pokeSettleTail (credit { s with
        freed := s.freed-gross,sourceCash := s.sourceCash-gross,sourceCost := s.sourceCost+cost } freed cost)
      .ok (next,freed+(s.debt-next.debt)+(next.head-s.head)+(if pendingAccounting s then 1 else 0))) := by
  rfl

theorem sourceCredit_preserves (s : State) (gross cost : Nat) (h : PublicInvariant s)
    (hr : CreditReady s) (hb : QueueBacking s) (hg : gross ≤ s.freed) (hc : cost ≤ gross) :
    PublicInvariant (credit { s with
      freed := s.freed-gross,sourceCash := s.sourceCash-gross,sourceCost := s.sourceCost+cost } (gross-cost) cost) ∧
    QueueBacking (credit { s with
      freed := s.freed-gross,sourceCash := s.sourceCash-gross,sourceCost := s.sourceCost+cost } (gross-cost) cost) := by
  have he : gross-cost+cost = gross := Nat.sub_add_cancel hc
  let pulled := { s with
    freed := s.freed-gross,sourceCash := s.sourceCash-gross,sourceCost := s.sourceCost+cost }
  have hreceived : receiveCredit pulled (gross-cost) cost = pullCreditState s (gross-cost) cost := by
    simp only [receiveCredit,pulled,pullCreditState,he]
  have hcredit : credit pulled (gross-cost) cost = creditReceived (pullCreditState s (gross-cost) cost) := by
    rw [credit_factored,hreceived]
  have hn := creditReceived_public (pullCreditState s (gross-cost) cost)
    (pullCreditState_public s _ _ h (by omega)) (pullCreditState_ready s _ _ hr)
  have hq := creditReceived_queueBacking (pullCreditState s (gross-cost) cost) hb
  exact (congrArg (fun next => PublicInvariant next ∧ QueueBacking next) hcredit).mpr ⟨hn,hq⟩

theorem raw_pokeSettle_public (s : State) (caller a b n : Nat) (h : PublicInvariant s)
    (hr : CreditReady s) (hb : QueueBacking s) (hp : SourcePullBounds s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rawRunCall s ⟨6,caller,a,b,n⟩) :=
  let gross := s.freed*s.pullBps/10000
  let cost := gross*s.costBps/10000
  let hn := sourceCredit_preserves s gross cost h hr hb
    (proportional_le _ _ _ hp.1) (proportional_le _ _ _ hp.2)
  (congrArg (OnSuccess (fun result : State × Nat => PublicInvariant result.1))
    (raw_pokeSettle_factored s caller a b n)).mpr (pokeSettleTail_public _ hn.1 hn.2)

end Juicer.PublicCalls
