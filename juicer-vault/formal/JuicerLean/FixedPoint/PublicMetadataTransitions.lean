import JuicerLean.FixedPoint.PublicStartLoopProofs
import JuicerLean.FixedPoint.PublicDepositProofs
import JuicerLean.FixedPoint.PublicRebalanceProofs
import JuicerLean.FixedPoint.PublicHarvestProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 100000

namespace Juicer.PublicCalls
open Runtime

theorem metadata_account (s : State) (i : Nat) (h : PublicMetadata s) :
    AccountHistory s.book (account s i) := by
  by_cases hi : i < s.accounts.size
  · exact h.1 i hi
  · unfold account
    rw [Array.getElem?_eq_none (by omega)]
    exact ⟨Nat.zero_le _, fun _ => Nat.zero_le _⟩

theorem metadata_request (s : State) (i : Nat) (h : PublicMetadata s) :
    AccountHistory s.book (request s i).account := by
  by_cases hi : i < s.requests.size
  · exact h.2 i hi
  · unfold request
    rw [Array.getElem?_eq_none (by omega)]
    exact ⟨Nat.zero_le _, fun _ => Nat.zero_le _⟩

theorem metadata_setUnits (s : State) (i units : Nat) (h : PublicMetadata s) :
    PublicMetadata (setAccount s i { account s i with units := units }) :=
  metadata_setAccount s i _ h (metadata_account s i h)

theorem metadata_setRequest (s : State) (i : Nat) (r : Request) (h : PublicMetadata s)
    (hr : AccountHistory s.book r.account) :
    PublicMetadata { s with requests := s.requests.set! i r } := by
  refine ⟨h.1, ?_⟩
  intro j hj
  have hj' : j < s.requests.size := by
    simpa only [Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hj
  change AccountHistory s.book ((s.requests.set! i r)[j]?.getD {}).account
  simp only [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
  split
  next heq =>
    subst j
    simpa only [hj', ite_true, Option.getD_some] using hr
  · exact h.2 j hj'

theorem metadata_pushRequest (s : State) (r : Request) (h : PublicMetadata s)
    (hr : AccountHistory s.book r.account) :
    PublicMetadata { s with requests := s.requests.push r } := by
  refine ⟨h.1, ?_⟩
  intro i hi
  change AccountHistory s.book ((s.requests.push r)[i]?.getD {}).account
  simp only [Array.getElem?_push]
  split
  · exact hr
  · exact metadata_request s i h

theorem moveUnits_metadata (s : State) (a b taken left : Nat) (h : PublicMetadata s) :
    PublicMetadata (moveUnits s a b taken left) :=
  metadata_setUnits _ b _ (metadata_setUnits s a left h)

theorem prepareTransfer_metadata (s : State) (a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (prepareTransfer s a b n) := by
  rw [prepareTransfer_eq]
  have ht := metadata_settleOwner (settleOwner s a) b (metadata_settleOwner s a h)
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
              · exact moveUnits_metadata _ a b _ _ ht
            · exact ht
      · exact ht
  · exact h

theorem finishTransfer_metadata (s : State) (a b n : Nat) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (finishTransfer s a b n) := by
  unfold finishTransfer
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem transfer_metadata (s : State) (a b n : Nat) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (transfer s a b n) := by
  rw [transfer_decomposition, onSuccess_bind]
  rintro ⟨next, moved⟩ heq
  have hn := onSuccess_of_eq (prepareTransfer_metadata s a b n h) heq
  exact finishTransfer_metadata next a b moved hn

theorem spend_metadata (s : State) (owner caller amount : Nat) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (spend s owner caller amount) := by
  unfold spend
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem cover_metadata (s : State) (amount : Nat) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (cover s amount) := by
  unfold cover
  split <;> trivial

theorem appendRequest_metadata (s : State) (owner escrow committed : Nat) (h : PublicMetadata s) :
    PublicMetadata (appendRequest s owner escrow committed) :=
  metadata_pushRequest s _ h ⟨le_rfl, fun _ => le_rfl⟩

theorem requestOutcome_metadata (s : State) (owner escrow : Nat) (value : Option (Nat × Nat))
    (h : PublicMetadata s) : OnSuccess PublicMetadata (requestOutcome s owner escrow value) := by
  cases value with
  | none => trivial
  | some pair =>
    exact appendRequest_metadata _ owner escrow pair.1 (metadata_setUnits s owner pair.2 h)

theorem commitRequest_metadata (s : State) (owner escrow amount : Nat) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (commitRequest s owner escrow amount) :=
  commitRequest_property PublicMetadata s owner escrow amount
    (requestOutcome_metadata s owner escrow _ h) (appendRequest_metadata s owner escrow 0 h)

theorem creditPosition_metadata (s : State) (key weight : Nat) (h : PublicMetadata s) :
    PublicMetadata (creditPosition s key weight).1 := by
  rw [creditPosition_state_factored]
  exact h

theorem creditCursor_metadata (s : State) (key : Nat) (h : PublicMetadata s) :
    PublicMetadata (creditCursor s key) := h

theorem creditSteps_metadata (fuel : Nat) (s : State) (h : PublicMetadata s) :
    PublicMetadata (creditSteps fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    change PublicMetadata (if s.batchTail ≤ s.batchCursor then s else creditSteps fuel (advanceCredit s))
    split
    · exact h
    · exact ih (advanceCredit s) (creditCursor_metadata _ _ (creditPosition_metadata s s.batchCursor _ h))

theorem closeCredit_metadata (s : State) (h : PublicMetadata s) :
    PublicMetadata (closeCredit s) := by
  unfold closeCredit
  split <;> exact h

theorem finishCredit_metadata (s : State) (h : PublicMetadata s) :
    PublicMetadata (finishCredit s) := closeCredit_metadata _ (creditSteps_metadata 64 s h)

theorem metadata_delever (s : State) (amount : Nat) (h : PublicMetadata s) :
    PublicMetadata { s with delever := amount } := h

theorem metadata_synth (s : State) (amount : Nat) (h : PublicMetadata s) :
    PublicMetadata { s with synth := amount } := h

theorem activeCredit_metadata (s : State) (h : PublicMetadata s) : PublicMetadata (activeCredit s) := by
  unfold activeCredit
  exact metadata_delever (creditPosition (setupCredit s) 0 s.activeRemaining).1 _
    (creditPosition_metadata (setupCredit s) 0 s.activeRemaining h)

theorem credit_metadata (s : State) (amount cost : Nat) (h : PublicMetadata s) :
    PublicMetadata (credit s amount cost) := by
  rw [credit_factored]
  let next := receiveCredit s amount cost
  have hn : PublicMetadata next := h
  change PublicMetadata (creditReceived next)
  unfold creditReceived
  split
  · split
    · exact hn
    · exact finishCredit_metadata (activeCredit next) (activeCredit_metadata next hn)
  · exact finishCredit_metadata next hn

theorem finishSettle_metadata (s : State) (i : Nat) (r : Request) (paid : Nat)
    (h : PublicMetadata s) (hr : AccountHistory s.book r.account) :
    PublicMetadata (finishSettle s i r paid).1 := by
  have hn := metadata_setRequest s i { r with claim := settleRedemption r.claim paid } h hr
  unfold finishSettle
  dsimp only
  split <;> exact hn

theorem settleOne_metadata (s : State) (h : PublicMetadata s) : PublicMetadata (settleOne s).1 := by
  unfold settleOne
  split
  · exact h
  · dsimp only
    by_cases hd : ((request s s.head).claim.debt == (request s s.head).claim.repaid) = true
    · simp only [hd, ite_true]
      exact finishSettle_metadata s s.head _ 0 h (metadata_request s s.head h)
    · simp only [hd]
      let p := pay s (s.head+1) ((request s s.head).claim.debt-(request s s.head).claim.repaid)
      have hp : PublicMetadata p.1 := pay_metadata s _ _ h
      have hr : request p.1 s.head = request s s.head := pay_request s _ _ s.head
      change PublicMetadata (finishSettle p.1 s.head (request s s.head) p.2.1).1
      rw [← hr]
      exact finishSettle_metadata p.1 s.head _ p.2.1 hp (metadata_request p.1 s.head hp)

theorem settleMany_metadata (fuel : Nat) (s : State) (h : PublicMetadata s) :
    PublicMetadata (settleMany fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    have hn := settleOne_metadata s h
    rcases heq : settleOne s with ⟨next, more⟩
    rw [heq] at hn
    simp only [settleMany, heq]
    split
    · exact ih next hn
    · exact hn

theorem compoundSale_metadata (s : State) (sold : Nat) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (compoundSale s sold) := by
  unfold compoundSale
  simp only [bind, pure, Except.bind, Except.pure]
  split
  · split
    · trivial
    · split
      · trivial
      · exact h
  · exact h

theorem fundCollateral_metadata (s : State) (minted returned feeAmount : Nat) (h : PublicMetadata s) :
    PublicMetadata (fundCollateral s minted returned feeAmount) := h

theorem bookFunding_metadata (s : State) (source protocol basis : Nat) (h : PublicMetadata s) :
    PublicMetadata { s with book := { s.book with source := source, protocol := protocol }, basis := basis } := by
  constructor
  · intro i hi
    exact h.1 i hi
  · intro i hi
    exact h.2 i hi

theorem reserveReward_metadata (s : State) (value : Nat) (h : PublicMetadata s) :
    PublicMetadata (reserveRewardState s value) := by
  exact bookFunding_metadata s _ s.book.protocol _ h

theorem compoundFinish_metadata (s : State) (out fresh sold reward service feeAmount cashBefore : Nat)
    (h : PublicMetadata s) :
    OnSuccess PublicMetadata (compoundFinish s out fresh sold reward service feeAmount cashBefore) := by
  unfold compoundFinish
  split
  · trivial
  · apply fundCollateral_metadata
    split
    · exact reserveReward_metadata s _ h
    · exact h

theorem compoundFunds_metadata (s : State) (out reward service feeAmount : Nat) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (compoundFunds s out reward service feeAmount) := by
  rw [compoundFunds_factored]
  dsimp only
  rw [onSuccess_bind]
  intro next heq
  have hn := onSuccess_of_eq (compoundSale_metadata s _ h) heq
  rw [compoundTail_eq]
  exact compoundFinish_metadata _ _ _ _ _ _ _ _
    (metadata_synth (pay next 0 0).1 s.synth (pay_metadata next 0 0 hn))

theorem unwindHead_metadata (s : State) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (unwindHead s) := by
  unfold unwindHead
  dsimp only
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · exact onSuccess_if _ _ _ _ trivial (unwindCommitted_metadata s _ h)

theorem startOne_metadata (s : State) (cursor : Nat) (h : PublicMetadata s) :
    OnSuccess PublicMetadata (startOne s cursor) := by
  have hn := unwindHead_metadata _ (checkpoint_metadata (withUnwind s cursor) zeroId zeroId h)
  rw [← startOne_cursor, onSuccess_map] at hn
  exact hn

theorem startMany_metadata (fuel : Nat) (s : State) (cursor : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (startMany fuel s cursor) := by
  induction fuel generalizing s cursor with
  | zero => exact h
  | succ fuel ih =>
    change OnSuccess _ (if s.requests.size ≤ cursor || s.time < (request s cursor).eligible then
      .ok (s, cursor) else startOne s cursor >>= fun next => startMany fuel next (cursor+1))
    split
    · exact h
    · rw [onSuccess_bind]
      intro next heq
      exact ih next (cursor+1) (onSuccess_of_eq (startOne_metadata s cursor h) heq)

end Juicer.PublicCalls
