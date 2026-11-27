import JuicerLean.FixedPoint.PublicCreditMutations
import JuicerLean.FixedPoint.PublicStartLoopProofs
import JuicerLean.FixedPoint.PublicDepositProofs
import JuicerLean.FixedPoint.PublicRebalanceProofs
import JuicerLean.FixedPoint.PublicHarvestProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem creditReady_setUnits (s : State) (i units : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (setAccount s i { account s i with units := units }) := h

theorem settleOwner_creditReady (s : State) (i : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (settleOwner s i) := by
  unfold settleOwner
  split <;> exact h

theorem checkpoint_creditReady (s : State) (a b : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hn : CreditReadyHistory (if !pendingAccounting s then allocateState s else s) := by
    split <;> exact h
  split
  · exact settleOwner_creditReady _ a hn
  · exact settleOwner_creditReady _ b (settleOwner_creditReady _ a hn)



theorem moveUnits_creditReady (s : State) (a b taken left : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (moveUnits s a b taken left) := h

theorem prepareTransfer_creditReady (s : State) (a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (prepareTransfer s a b n) := by
  rw [prepareTransfer_eq]
  have ht := settleOwner_creditReady (settleOwner s a) b (settleOwner_creditReady s a h)
  split
  · dsimp only
    split
    · trivial
    · split
      · split
        · trivial
        · split
          · trivial
          · split
            · split
              · trivial
              · exact moveUnits_creditReady _ a b _ _ ht
            · exact ht
      · exact ht
  · exact h

theorem finishTransfer_creditReady (s : State) (a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess CreditReadyHistory (finishTransfer s a b n) := by
  unfold finishTransfer
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem transfer_creditReady (s : State) (a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess CreditReadyHistory (transfer s a b n) := by
  rw [transfer_decomposition, onSuccess_bind]
  rintro ⟨next, moved⟩ heq
  have hn := onSuccess_of_eq (prepareTransfer_creditReady s a b n h) heq
  exact finishTransfer_creditReady next a b moved hn

theorem spend_creditReady (s : State) (owner caller amount : Nat) (h : CreditReadyHistory s) :
    OnSuccess CreditReadyHistory (spend s owner caller amount) := by
  unfold spend
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem cover_creditReady (s : State) (amount : Nat) (h : CreditReadyHistory s) :
    OnSuccess CreditReadyHistory (cover s amount) := by
  unfold cover
  split <;> trivial

theorem appendRequest_creditReady (s : State) (owner escrow committed : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (appendRequest s owner escrow committed) := h

theorem requestOutcome_creditReady (s : State) (owner escrow : Nat) (value : Option (Nat × Nat))
    (h : CreditReadyHistory s) : OnSuccess CreditReadyHistory (requestOutcome s owner escrow value) := by
  cases value with
  | none => trivial
  | some pair =>
    exact appendRequest_creditReady _ owner escrow pair.1 (creditReady_setUnits s owner pair.2 h)

theorem commitRequest_creditReady (s : State) (owner escrow amount : Nat) (h : CreditReadyHistory s) :
    OnSuccess CreditReadyHistory (commitRequest s owner escrow amount) :=
  commitRequest_property CreditReadyHistory s owner escrow amount
    (requestOutcome_creditReady s owner escrow _ h) (appendRequest_creditReady s owner escrow 0 h)

theorem creditReady_delever (s : State) (amount : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory { s with delever := amount } := h

theorem creditReady_synth (s : State) (amount : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory { s with synth := amount } := h

theorem finishSettle_creditReady (s : State) (i : Nat) (r : Request) (paid : Nat)
    (h : CreditReadyHistory s) :
    CreditReadyHistory (finishSettle s i r paid).1 := by
  have hn : CreditReadyHistory (settleRecord s i r (settleRedemption r.claim paid)) := h
  unfold finishSettle
  dsimp only
  split <;> exact hn

theorem settleOne_creditReady (s : State) (h : CreditReadyHistory s) : CreditReadyHistory (settleOne s).1 := by
  unfold settleOne
  split
  · exact h
  · dsimp only
    by_cases hd : ((request s s.head).claim.debt == (request s s.head).claim.repaid) = true
    · simp only [hd, ite_true]
      exact finishSettle_creditReady s s.head _ 0 h
    · simp only [hd]
      let p := pay s (s.head+1) ((request s s.head).claim.debt-(request s s.head).claim.repaid)
      have hp : CreditReadyHistory p.1 := pay_creditReady s _ _ h
      have hr : request p.1 s.head = request s s.head := pay_request s _ _ s.head
      change CreditReadyHistory (finishSettle p.1 s.head (request s s.head) p.2.1).1
      rw [← hr]
      exact finishSettle_creditReady p.1 s.head _ p.2.1 hp

theorem settleMany_creditReady (fuel : Nat) (s : State) (h : CreditReadyHistory s) :
    CreditReadyHistory (settleMany fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    have hn := settleOne_creditReady s h
    rcases heq : settleOne s with ⟨next, more⟩
    rw [heq] at hn
    simp only [settleMany, heq]
    split
    · exact ih next hn
    · exact hn

theorem compoundSale_creditReady (s : State) (sold : Nat) (h : CreditReadyHistory s) :
    OnSuccess CreditReadyHistory (compoundSale s sold) := by
  unfold compoundSale
  simp only [bind, pure, Except.bind, Except.pure]
  split
  · split
    · trivial
    · split
      · trivial
      · exact setPosition_creditReady s 0 _ h rfl (Nat.le_add_right _ _)
  · exact h

theorem fundCollateral_creditReady (s : State) (minted returned feeAmount : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (fundCollateral s minted returned feeAmount) := h

theorem bookFunding_creditReady (s : State) (source protocol basis : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory { s with book := { s.book with source := source, protocol := protocol }, basis := basis } := h

theorem reserveReward_creditReady (s : State) (value : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (reserveRewardState s value) := by
  exact bookFunding_creditReady s _ s.book.protocol _ h

theorem compoundFinish_creditReady (s : State) (out fresh sold reward service feeAmount cashBefore : Nat)
    (h : CreditReadyHistory s) :
    OnSuccess CreditReadyHistory (compoundFinish s out fresh sold reward service feeAmount cashBefore) := by
  unfold compoundFinish
  split
  · trivial
  · apply fundCollateral_creditReady
    split
    · exact reserveReward_creditReady s _ h
    · exact h

theorem compoundFunds_creditReady (s : State) (out reward service feeAmount : Nat) (h : CreditReadyHistory s) :
    OnSuccess CreditReadyHistory (compoundFunds s out reward service feeAmount) := by
  rw [compoundFunds_factored]
  dsimp only
  rw [onSuccess_bind]
  intro next heq
  have hn := onSuccess_of_eq (compoundSale_creditReady s _ h) heq
  rw [compoundTail_eq]
  exact compoundFinish_creditReady _ _ _ _ _ _ _ _
    (creditReady_synth (pay next 0 0).1 s.synth (pay_creditReady next 0 0 hn))

theorem settleOwner_exitCreditReady (s : State) (i : Nat) (h : ExitCreditReady s) :
    ExitCreditReady (settleOwner s i) := by
  unfold settleOwner
  split <;> exact h

theorem checkpoint_exitCreditReady (s : State) (a b : Nat) (h : ExitCreditReady s) :
    ExitCreditReady (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hn : ExitCreditReady (if !pendingAccounting s then allocateState s else s) := by
    split <;> exact h
  split
  · exact settleOwner_exitCreditReady _ a hn
  · exact settleOwner_exitCreditReady _ b (settleOwner_exitCreditReady _ a hn)

theorem unwindHead_creditReady (s : State) (h : ExitCreditReady s) :
    OnSuccess ExitCreditReady (unwindHead s) := by
  unfold unwindHead
  dsimp only
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · exact onSuccess_if _ _ _ _ trivial (unwindCommitted_creditReady s h)

theorem startOne_creditReady (s : State) (cursor : Nat) (h : ExitCreditReady s) :
    OnSuccess ExitCreditReady (startOne s cursor) := by
  have hn := unwindHead_creditReady _ (checkpoint_exitCreditReady (withUnwind s cursor) zeroId zeroId h)
  rw [← startOne_cursor, onSuccess_map] at hn
  exact hn

theorem startMany_creditReady (fuel : Nat) (s : State) (cursor : Nat) (h : ExitCreditReady s) :
    OnSuccess (fun result : State × Nat => ExitCreditReady result.1) (startMany fuel s cursor) := by
  induction fuel generalizing s cursor with
  | zero => exact h
  | succ fuel ih =>
    change OnSuccess _ (if s.requests.size ≤ cursor || s.time < (request s cursor).eligible then
      .ok (s, cursor) else startOne s cursor >>= fun next => startMany fuel next (cursor+1))
    split
    · exact h
    · rw [onSuccess_bind]
      intro next heq
      exact ih next (cursor+1) (onSuccess_of_eq (startOne_creditReady s cursor h) heq)

end Juicer.PublicCalls
