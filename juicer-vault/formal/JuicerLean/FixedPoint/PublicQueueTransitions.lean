import JuicerLean.FixedPoint.PublicStartLoopProofs
import JuicerLean.FixedPoint.PublicDepositProofs
import JuicerLean.FixedPoint.PublicRebalanceProofs
import JuicerLean.FixedPoint.PublicHarvestProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 100000

namespace Juicer.PublicCalls
open Runtime

theorem queue_genesis : QueueBacking ({} : State) := by decide

theorem queue_setPosition (s : State) (i : Nat) (p : MainPosition) (h : QueueBacking s) :
    QueueBacking (setPosition s i p) := by
  refine ⟨h.1, ?_⟩
  simpa only [setPosition, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using h.2

theorem settleOwner_queue (s : State) (i : Nat) (h : QueueBacking s) :
    QueueBacking (settleOwner s i) := by
  unfold settleOwner
  split <;> exact h

theorem checkpoint_queue (s : State) (a b : Nat) (h : QueueBacking s) :
    QueueBacking (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hn : QueueBacking (if !pendingAccounting s then allocateState s else s) := by
    split <;> exact h
  split
  · exact settleOwner_queue _ a hn
  · exact settleOwner_queue _ b (settleOwner_queue _ a hn)

theorem pay_queue (s : State) (key limit : Nat) (h : QueueBacking s) :
    QueueBacking (pay s key limit).1 := pay_queueBacking s key limit h

theorem moveUnits_queue (s : State) (a b taken left : Nat) (h : QueueBacking s) :
    QueueBacking (moveUnits s a b taken left) := h

theorem prepareTransfer_queue (s : State) (a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (prepareTransfer s a b n) := by
  rw [prepareTransfer_eq]
  have ht := settleOwner_queue (settleOwner s a) b (settleOwner_queue s a h)
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
              · exact moveUnits_queue _ a b _ _ ht
            · exact ht
      · exact ht
  · exact h

theorem finishTransfer_queue (s : State) (a b n : Nat) (h : QueueBacking s) :
    OnSuccess QueueBacking (finishTransfer s a b n) := by
  unfold finishTransfer
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem transfer_queue (s : State) (a b n : Nat) (h : QueueBacking s) :
    OnSuccess QueueBacking (transfer s a b n) := by
  rw [transfer_decomposition, onSuccess_bind]
  rintro ⟨next, moved⟩ heq
  have hn := onSuccess_of_eq (prepareTransfer_queue s a b n h) heq
  exact finishTransfer_queue next a b moved hn

theorem spend_queue (s : State) (owner caller amount : Nat) (h : QueueBacking s) :
    OnSuccess QueueBacking (spend s owner caller amount) := by
  unfold spend
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem cover_queue (s : State) (amount : Nat) (h : QueueBacking s) :
    OnSuccess QueueBacking (cover s amount) := by
  unfold cover
  split
  · trivial
  · exact ⟨h.1.trans (Nat.le_add_right _ _), h.2⟩

theorem appendRequest_queue (s : State) (owner escrow committed : Nat) (h : QueueBacking s) :
    QueueBacking (appendRequest s owner escrow committed) := h

theorem requestOutcome_queue (s : State) (owner escrow : Nat) (value : Option (Nat × Nat))
    (h : QueueBacking s) : OnSuccess QueueBacking (requestOutcome s owner escrow value) := by
  cases value with
  | none => trivial
  | some pair =>
    exact appendRequest_queue _ owner escrow pair.1 h

theorem commitRequest_queue (s : State) (owner escrow amount : Nat) (h : QueueBacking s) :
    OnSuccess QueueBacking (commitRequest s owner escrow amount) :=
  commitRequest_property QueueBacking s owner escrow amount
    (requestOutcome_queue s owner escrow _ h) (appendRequest_queue s owner escrow 0 h)

theorem queue_delever (s : State) (amount : Nat) (h : QueueBacking s) :
    QueueBacking { s with delever := amount } := h

theorem queue_synth (s : State) (amount : Nat) (h : QueueBacking s) :
    QueueBacking { s with synth := amount } := h

theorem credit_queue (s : State) (amount cost : Nat) (h : QueueBacking s) :
    QueueBacking (credit s amount cost) := by
  rw [credit_factored]
  exact creditReceived_queueBacking _ h

theorem settleOne_queue (s : State) (h : QueueBacking s) : QueueBacking (settleOne s).1 := by
  unfold settleOne
  split
  · exact h
  · dsimp only
    split
    · exact finishSettle_backing s _ _ _ h
    · exact finishSettle_backing _ _ _ _ (pay_queueBacking s _ _ h)

theorem settleMany_queue (fuel : Nat) (s : State) (h : QueueBacking s) :
    QueueBacking (settleMany fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    have hn := settleOne_queue s h
    rcases heq : settleOne s with ⟨next, more⟩
    rw [heq] at hn
    simp only [settleMany, heq]
    split
    · exact ih next hn
    · exact hn

theorem compoundSale_queue (s : State) (sold : Nat) (h : QueueBacking s) :
    OnSuccess QueueBacking (compoundSale s sold) := by
  unfold compoundSale
  simp only [bind, pure, Except.bind, Except.pure]
  split
  · split
    · trivial
    · split
      · trivial
      · exact queue_setPosition s 0 _ h
  · exact h

theorem fundCollateral_queue (s : State) (minted returned feeAmount : Nat) (h : QueueBacking s) :
    QueueBacking (fundCollateral s minted returned feeAmount) :=
  ⟨h.1.trans (Nat.le_add_right _ _), h.2⟩

theorem bookFunding_queue (s : State) (source protocol basis : Nat) (h : QueueBacking s) :
    QueueBacking { s with book := { s.book with source := source, protocol := protocol }, basis := basis } := h

theorem reserveReward_queue (s : State) (value : Nat) (h : QueueBacking s) :
    QueueBacking (reserveRewardState s value) := by
  exact bookFunding_queue s _ s.book.protocol _ h

theorem compoundFinish_queue (s : State) (out fresh sold reward service feeAmount cashBefore : Nat)
    (h : QueueBacking s) :
    OnSuccess QueueBacking (compoundFinish s out fresh sold reward service feeAmount cashBefore) := by
  unfold compoundFinish
  split
  · trivial
  · apply fundCollateral_queue
    split
    · exact reserveReward_queue s _ h
    · exact h

theorem compoundFunds_queue (s : State) (out reward service feeAmount : Nat) (h : QueueBacking s) :
    OnSuccess QueueBacking (compoundFunds s out reward service feeAmount) := by
  rw [compoundFunds_factored]
  dsimp only
  rw [onSuccess_bind]
  intro next heq
  have hn := onSuccess_of_eq (compoundSale_queue s _ h) heq
  rw [compoundTail_eq]
  exact compoundFinish_queue _ _ _ _ _ _ _ _
    (queue_synth (pay next 0 0).1 s.synth (pay_queue next 0 0 hn))

end Juicer.PublicCalls
