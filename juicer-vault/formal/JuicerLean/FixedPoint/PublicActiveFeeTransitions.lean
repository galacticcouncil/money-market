import JuicerLean.FixedPoint.PublicStartLoopProofs
import JuicerLean.FixedPoint.PublicDepositProofs
import JuicerLean.FixedPoint.PublicRebalanceProofs
import JuicerLean.FixedPoint.PublicHarvestProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 100000

namespace Juicer.PublicCalls
open Runtime

def ActiveFeeSafe (s : State) : Prop := 0 < s.sourceFees.size ∧ ZeroActiveFee s

instance (s : State) : Decidable (ActiveFeeSafe s) := by unfold ActiveFeeSafe; infer_instance

theorem activeFeeSafe_genesis : ActiveFeeSafe ({} : State) := by decide

theorem activeFeeSafe_setUnits (s : State) (i units : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (setAccount s i { account s i with units := units }) := h

theorem settleOwner_activeFeeSafe (s : State) (i : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (settleOwner s i) := by
  unfold settleOwner
  split <;> exact h

theorem checkpoint_activeFeeSafe (s : State) (a b : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hn : ActiveFeeSafe (if !pendingAccounting s then allocateState s else s) := by
    split <;> exact h
  split
  · exact settleOwner_activeFeeSafe _ a hn
  · exact settleOwner_activeFeeSafe _ b (settleOwner_activeFeeSafe _ a hn)

theorem pay_activeFeeSafe (s : State) (key limit : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (pay s key limit).1 := by
  rw [pay_state_factored]
  exact h

theorem moveUnits_activeFeeSafe (s : State) (a b taken left : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (moveUnits s a b taken left) := h

theorem prepareTransfer_activeFeeSafe (s : State) (a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (prepareTransfer s a b n) := by
  rw [prepareTransfer_eq]
  have ht := settleOwner_activeFeeSafe (settleOwner s a) b (settleOwner_activeFeeSafe s a h)
  split
  · dsimp only
    split
    · split
      · trivial
      · split
        · trivial
        · split
          · split
            · trivial
            · exact moveUnits_activeFeeSafe _ a b _ _ ht
          · exact ht
    · exact ht
  · exact h

theorem finishTransfer_activeFeeSafe (s : State) (a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (finishTransfer s a b n) := by
  unfold finishTransfer
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem transfer_activeFeeSafe (s : State) (a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (transfer s a b n) := by
  rw [transfer_decomposition, onSuccess_bind]
  rintro ⟨next, moved⟩ heq
  have hn := onSuccess_of_eq (prepareTransfer_activeFeeSafe s a b n h) heq
  exact finishTransfer_activeFeeSafe next a b moved hn

theorem spend_activeFeeSafe (s : State) (owner caller amount : Nat) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (spend s owner caller amount) := by
  unfold spend
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem cover_activeFeeSafe (s : State) (amount : Nat) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (cover s amount) := by
  unfold cover
  split <;> trivial

theorem appendRequest_activeFeeSafe (s : State) (owner escrow committed : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (appendRequest s owner escrow committed) := h

theorem requestOutcome_activeFeeSafe (s : State) (owner escrow : Nat) (value : Option (Nat × Nat))
    (h : ActiveFeeSafe s) : OnSuccess ActiveFeeSafe (requestOutcome s owner escrow value) := by
  cases value with
  | none => trivial
  | some pair =>
    exact appendRequest_activeFeeSafe _ owner escrow pair.1 (activeFeeSafe_setUnits s owner pair.2 h)

theorem commitRequest_activeFeeSafe (s : State) (owner escrow amount : Nat) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (commitRequest s owner escrow amount) :=
  commitRequest_property ActiveFeeSafe s owner escrow amount
    (requestOutcome_activeFeeSafe s owner escrow _ h) (appendRequest_activeFeeSafe s owner escrow 0 h)

theorem creditPosition_activeFeeSafe (s : State) (key weight : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (creditPosition s key weight).1 := by
  rw [creditPosition_state_factored]
  refine ⟨?_, ?_⟩
  · simpa only [creditState, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using h.1
  · intro hr
    by_cases hk : key = 0
    · subst key
      rw [creditState_fee s 0 weight _ 0 h.1]
      simp only [ite_true]
      change weight - (batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight).1 -
        (batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight).2 = 0 at hr
      simp only [creditNumbers, settleFee, hr, beq_self_eq_true, ite_true]
    · have hz : s.activeRemaining = 0 := by
        simpa only [creditState, beq_eq_false_iff_ne.mpr hk, Bool.false_eq_true, ite_false] using hr
      change (fee (creditState s key weight (creditNumbers s key weight)) 0).feeLeft = 0
      simpa only [fee, creditState, Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds,
        if_neg hk] using h.2 hz

theorem creditCursor_activeFeeSafe (s : State) (key : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (creditCursor s key) := h

theorem creditSteps_activeFeeSafe (fuel : Nat) (s : State) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (creditSteps fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    change ActiveFeeSafe (if s.batchTail ≤ s.batchCursor then s else creditSteps fuel (advanceCredit s))
    split
    · exact h
    · exact ih (advanceCredit s) (creditCursor_activeFeeSafe _ _ (creditPosition_activeFeeSafe s s.batchCursor _ h))

theorem closeCredit_activeFeeSafe (s : State) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (closeCredit s) := by
  unfold closeCredit
  split <;> exact h

theorem finishCredit_activeFeeSafe (s : State) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (finishCredit s) := closeCredit_activeFeeSafe _ (creditSteps_activeFeeSafe 64 s h)

theorem activeFeeSafe_delever (s : State) (amount : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe { s with delever := amount } := h

theorem activeFeeSafe_synth (s : State) (amount : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe { s with synth := amount } := h

theorem activeCredit_activeFeeSafe (s : State) (h : ActiveFeeSafe s) : ActiveFeeSafe (activeCredit s) := by
  unfold activeCredit
  exact activeFeeSafe_delever (creditPosition (setupCredit s) 0 s.activeRemaining).1 _
    (creditPosition_activeFeeSafe (setupCredit s) 0 s.activeRemaining h)

theorem credit_activeFeeSafe (s : State) (amount cost : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (credit s amount cost) := by
  rw [credit_factored]
  let next := receiveCredit s amount cost
  have hn : ActiveFeeSafe next := h
  change ActiveFeeSafe (creditReceived next)
  unfold creditReceived
  split
  · split
    · exact hn
    · exact finishCredit_activeFeeSafe (activeCredit next) (activeCredit_activeFeeSafe next hn)
  · exact finishCredit_activeFeeSafe next hn

theorem finishSettle_activeFeeSafe (s : State) (i : Nat) (r : Request) (paid : Nat)
    (h : ActiveFeeSafe s) :
    ActiveFeeSafe (finishSettle s i r paid).1 := by
  have hn : ActiveFeeSafe (settleRecord s i r (settleRedemption r.claim paid)) := h
  unfold finishSettle
  dsimp only
  split <;> exact hn

theorem settleOne_activeFeeSafe (s : State) (h : ActiveFeeSafe s) : ActiveFeeSafe (settleOne s).1 := by
  unfold settleOne
  split
  · exact h
  · dsimp only
    by_cases hd : ((request s s.head).claim.debt == (request s s.head).claim.repaid) = true
    · simp only [hd, ite_true]
      exact finishSettle_activeFeeSafe s s.head _ 0 h
    · simp only [hd]
      let p := pay s (s.head+1) ((request s s.head).claim.debt-(request s s.head).claim.repaid)
      have hp : ActiveFeeSafe p.1 := pay_activeFeeSafe s _ _ h
      have hr : request p.1 s.head = request s s.head := pay_request s _ _ s.head
      change ActiveFeeSafe (finishSettle p.1 s.head (request s s.head) p.2.1).1
      rw [← hr]
      exact finishSettle_activeFeeSafe p.1 s.head _ p.2.1 hp

theorem settleMany_activeFeeSafe (fuel : Nat) (s : State) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (settleMany fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    have hn := settleOne_activeFeeSafe s h
    rcases heq : settleOne s with ⟨next, more⟩
    rw [heq] at hn
    simp only [settleMany, heq]
    split
    · exact ih next hn
    · exact hn

theorem compoundSale_activeFeeSafe (s : State) (sold : Nat) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (compoundSale s sold) := by
  unfold compoundSale
  simp only [bind, pure, Except.bind, Except.pure]
  split
  · split
    · trivial
    · split
      · trivial
      · exact h
  · exact h

theorem fundCollateral_activeFeeSafe (s : State) (minted returned feeAmount : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (fundCollateral s minted returned feeAmount) := h

theorem bookFunding_activeFeeSafe (s : State) (source protocol basis : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe { s with book := { s.book with source := source, protocol := protocol }, basis := basis } := h

theorem reserveReward_activeFeeSafe (s : State) (value : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (reserveRewardState s value) := by
  exact bookFunding_activeFeeSafe s _ s.book.protocol _ h

theorem compoundFinish_activeFeeSafe (s : State) (out fresh sold reward service feeAmount cashBefore : Nat)
    (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (compoundFinish s out fresh sold reward service feeAmount cashBefore) := by
  unfold compoundFinish
  split
  · trivial
  · apply fundCollateral_activeFeeSafe
    split
    · exact reserveReward_activeFeeSafe s _ h
    · exact h

theorem compoundFunds_activeFeeSafe (s : State) (out reward service feeAmount : Nat) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (compoundFunds s out reward service feeAmount) := by
  rw [compoundFunds_factored]
  dsimp only
  rw [onSuccess_bind]
  intro next heq
  have hn := onSuccess_of_eq (compoundSale_activeFeeSafe s _ h) heq
  rw [compoundTail_eq]
  exact compoundFinish_activeFeeSafe _ _ _ _ _ _ _ _
    (activeFeeSafe_synth (pay next 0 0).1 s.synth (pay_activeFeeSafe next 0 0 hn))

theorem pushSourceFee_activeFeeSafe (s : State) (f : SourceFee) (h : ActiveFeeSafe s) :
    ActiveFeeSafe { s with sourceFees := s.sourceFees.push f } := by
  refine ⟨by simpa only [Array.size_push] using Nat.succ_pos s.sourceFees.size, ?_⟩
  intro hz
  have hn : 0 ≠ s.sourceFees.size := Nat.ne_of_lt h.1
  simpa only [fee, Array.getElem?_push, if_neg hn] using h.2 hz

theorem unwindCommitted_activeFeeSafe (s : State) (q : UnwindNumbers) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (unwindCommitted s q) := by
  have hn := pushSourceFee_activeFeeSafe s q.vested h
  simpa only [ActiveFeeSafe, ZeroActiveFee, fee, unwindCommitted, activateWaiting, unwindCovered,
    coverExit, unwindBooked, sourceExitState, setPosition, prepareExitOwnership, foldExitWallets,
    moveWallets, setWallet, commitExitAccount, setAccount] using hn

theorem unwindHead_activeFeeSafe (s : State) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (unwindHead s) := by
  unfold unwindHead
  dsimp only
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · exact onSuccess_if _ _ _ _ trivial (unwindCommitted_activeFeeSafe s _ h)

theorem startOne_activeFeeSafe (s : State) (cursor : Nat) (h : ActiveFeeSafe s) :
    OnSuccess ActiveFeeSafe (startOne s cursor) := by
  have hn := unwindHead_activeFeeSafe _ (checkpoint_activeFeeSafe (withUnwind s cursor) zeroId zeroId h)
  rw [← startOne_cursor, onSuccess_map] at hn
  exact hn

theorem startMany_activeFeeSafe (fuel : Nat) (s : State) (cursor : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (startMany fuel s cursor) := by
  induction fuel generalizing s cursor with
  | zero => exact h
  | succ fuel ih =>
    change OnSuccess _ (if s.requests.size ≤ cursor || s.time < (request s cursor).eligible then
      .ok (s, cursor) else startOne s cursor >>= fun next => startMany fuel next (cursor+1))
    split
    · exact h
    · rw [onSuccess_bind]
      intro next heq
      exact ih next (cursor+1) (onSuccess_of_eq (startOne_activeFeeSafe s cursor h) heq)

end Juicer.PublicCalls
