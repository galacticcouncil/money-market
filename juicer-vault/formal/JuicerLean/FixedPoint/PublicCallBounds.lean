import JuicerLean.FixedPoint.PublicStartLoopProofs
import JuicerLean.FixedPoint.PublicDepositProofs
import JuicerLean.FixedPoint.PublicRebalanceProofs
import JuicerLean.FixedPoint.PublicHarvestProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 100000

namespace Juicer.PublicCalls
open Runtime

def RequestOwners (s : State) : Prop :=
  ∀ i < s.requests.size, (request s i).owner < 5

def PublicCallBounds (s : State) : Prop :=
  SourcePullBounds s ∧ s.feeBps ≤ 10000 ∧ RequestOwners s

instance (s : State) : Decidable (PublicCallBounds s) := by
  unfold PublicCallBounds RequestOwners
  infer_instance

theorem callBounds_genesis : PublicCallBounds ({} : State) := by decide

theorem callBounds_setUnits (s : State) (i units : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (setAccount s i { account s i with units := units }) := h

theorem callBounds_setRequest (s : State) (i : Nat) (r : Request) (h : PublicCallBounds s)
    (hr : i < s.requests.size → r.owner < 5) :
    PublicCallBounds { s with requests := s.requests.set! i r } := by
  refine ⟨h.1, h.2.1, ?_⟩
  intro j hj
  have hj' : j < s.requests.size := by
    simpa only [Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hj
  change ((s.requests.set! i r)[j]?.getD {}).owner < 5
  simp only [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
  split
  next heq =>
    subst j
    simpa only [hj', ite_true, Option.getD_some] using hr hj'
  · exact h.2.2 j hj'

theorem callBounds_pushRequest (s : State) (r : Request) (h : PublicCallBounds s)
    (hr : r.owner < 5) : PublicCallBounds { s with requests := s.requests.push r } := by
  refine ⟨h.1, h.2.1, ?_⟩
  intro i hi
  have hi' : i < s.requests.size+1 := by simpa only [Array.size_push] using hi
  change ((s.requests.push r)[i]?.getD {}).owner < 5
  simp only [Array.getElem?_push]
  split
  · exact hr
  next hne => exact h.2.2 i (by omega)

theorem callBounds_waitingOwners (s : State) (h : PublicCallBounds s) : WaitingOwners s := by
  intro r hr
  have hm : r ∈ s.requests.toList := List.mem_of_mem_drop hr
  obtain ⟨i, hi, heq⟩ := List.getElem_of_mem hm
  have hi' : i < s.requests.size := by simpa only [Array.length_toList] using hi
  have ho := h.2.2 i hi'
  simpa only [request, Array.getElem?_eq_getElem hi', Option.getD_some,
    ← Array.getElem_toList, heq] using ho

theorem settleOwner_callBounds (s : State) (i : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (settleOwner s i) := by
  unfold settleOwner
  split <;> exact h

theorem checkpoint_callBounds (s : State) (a b : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hn : PublicCallBounds (if !pendingAccounting s then allocateState s else s) := by
    split <;> exact h
  split
  · exact settleOwner_callBounds _ a hn
  · exact settleOwner_callBounds _ b (settleOwner_callBounds _ a hn)

theorem pay_callBounds (s : State) (key limit : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (pay s key limit).1 := by
  rw [pay_state_factored]
  exact h

theorem moveUnits_callBounds (s : State) (a b taken left : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (moveUnits s a b taken left) := h

theorem prepareTransfer_callBounds (s : State) (a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (prepareTransfer s a b n) := by
  rw [prepareTransfer_eq]
  have ht := settleOwner_callBounds (settleOwner s a) b (settleOwner_callBounds s a h)
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
            · exact moveUnits_callBounds _ a b _ _ ht
          · exact ht
    · exact ht
  · exact h

theorem finishTransfer_callBounds (s : State) (a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (finishTransfer s a b n) := by
  unfold finishTransfer
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem transfer_callBounds (s : State) (a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (transfer s a b n) := by
  rw [transfer_decomposition, onSuccess_bind]
  rintro ⟨next, moved⟩ heq
  have hn := onSuccess_of_eq (prepareTransfer_callBounds s a b n h) heq
  exact finishTransfer_callBounds next a b moved hn

theorem spend_callBounds (s : State) (owner caller amount : Nat) (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (spend s owner caller amount) := by
  unfold spend
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem cover_callBounds (s : State) (amount : Nat) (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (cover s amount) := by
  unfold cover
  split <;> trivial

theorem appendRequest_callBounds (s : State) (owner escrow committed : Nat)
    (h : PublicCallBounds s) (ho : owner < 5) : PublicCallBounds (appendRequest s owner escrow committed) :=
  callBounds_pushRequest s _ h ho

theorem requestOutcome_callBounds (s : State) (owner escrow : Nat) (value : Option (Nat × Nat))
    (h : PublicCallBounds s) (ho : owner < 5) : OnSuccess PublicCallBounds (requestOutcome s owner escrow value) := by
  cases value with
  | none => trivial
  | some pair =>
    exact appendRequest_callBounds _ owner escrow pair.1 (callBounds_setUnits s owner pair.2 h) ho

theorem commitRequest_callBounds (s : State) (owner escrow amount : Nat)
    (h : PublicCallBounds s) (ho : owner < 5) :
    OnSuccess PublicCallBounds (commitRequest s owner escrow amount) :=
  commitRequest_property PublicCallBounds s owner escrow amount
    (requestOutcome_callBounds s owner escrow _ h ho) (appendRequest_callBounds s owner escrow 0 h ho)

theorem creditPosition_callBounds (s : State) (key weight : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (creditPosition s key weight).1 := by
  rw [creditPosition_state_factored]
  exact h

theorem creditCursor_callBounds (s : State) (key : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (creditCursor s key) := h

theorem creditSteps_callBounds (fuel : Nat) (s : State) (h : PublicCallBounds s) :
    PublicCallBounds (creditSteps fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    change PublicCallBounds (if s.batchTail ≤ s.batchCursor then s else creditSteps fuel (advanceCredit s))
    split
    · exact h
    · exact ih (advanceCredit s) (creditCursor_callBounds _ _ (creditPosition_callBounds s s.batchCursor _ h))

theorem closeCredit_callBounds (s : State) (h : PublicCallBounds s) :
    PublicCallBounds (closeCredit s) := by
  unfold closeCredit
  split <;> exact h

theorem finishCredit_callBounds (s : State) (h : PublicCallBounds s) :
    PublicCallBounds (finishCredit s) := closeCredit_callBounds _ (creditSteps_callBounds 64 s h)

theorem callBounds_delever (s : State) (amount : Nat) (h : PublicCallBounds s) :
    PublicCallBounds { s with delever := amount } := h

theorem callBounds_synth (s : State) (amount : Nat) (h : PublicCallBounds s) :
    PublicCallBounds { s with synth := amount } := h

theorem activeCredit_callBounds (s : State) (h : PublicCallBounds s) : PublicCallBounds (activeCredit s) := by
  unfold activeCredit
  exact callBounds_delever (creditPosition (setupCredit s) 0 s.activeRemaining).1 _
    (creditPosition_callBounds (setupCredit s) 0 s.activeRemaining h)

theorem credit_callBounds (s : State) (amount cost : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (credit s amount cost) := by
  rw [credit_factored]
  let next := receiveCredit s amount cost
  have hn : PublicCallBounds next := h
  change PublicCallBounds (creditReceived next)
  unfold creditReceived
  split
  · split
    · exact hn
    · exact finishCredit_callBounds (activeCredit next) (activeCredit_callBounds next hn)
  · exact finishCredit_callBounds next hn

theorem finishSettle_callBounds (s : State) (i : Nat) (r : Request) (paid : Nat)
    (h : PublicCallBounds s) (hr : i < s.requests.size → r.owner < 5) :
    PublicCallBounds (finishSettle s i r paid).1 := by
  have hn := callBounds_setRequest s i { r with claim := settleRedemption r.claim paid } h hr
  unfold finishSettle
  dsimp only
  split <;> exact hn

theorem settleOne_callBounds (s : State) (h : PublicCallBounds s) : PublicCallBounds (settleOne s).1 := by
  unfold settleOne
  split
  · exact h
  · dsimp only
    by_cases hd : ((request s s.head).claim.debt == (request s s.head).claim.repaid) = true
    · simp only [hd, ite_true]
      exact finishSettle_callBounds s s.head _ 0 h (h.2.2 s.head)
    · simp only [hd]
      let p := pay s (s.head+1) ((request s s.head).claim.debt-(request s s.head).claim.repaid)
      have hp : PublicCallBounds p.1 := pay_callBounds s _ _ h
      have hr : request p.1 s.head = request s s.head := pay_request s _ _ s.head
      change PublicCallBounds (finishSettle p.1 s.head (request s s.head) p.2.1).1
      rw [← hr]
      exact finishSettle_callBounds p.1 s.head _ p.2.1 hp (hp.2.2 s.head)

theorem settleMany_callBounds (fuel : Nat) (s : State) (h : PublicCallBounds s) :
    PublicCallBounds (settleMany fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    have hn := settleOne_callBounds s h
    rcases heq : settleOne s with ⟨next, more⟩
    rw [heq] at hn
    simp only [settleMany, heq]
    split
    · exact ih next hn
    · exact hn

theorem compoundSale_callBounds (s : State) (sold : Nat) (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (compoundSale s sold) := by
  unfold compoundSale
  simp only [bind, pure, Except.bind, Except.pure]
  split
  · split
    · trivial
    · split
      · trivial
      · exact h
  · exact h

theorem fundCollateral_callBounds (s : State) (minted returned feeAmount : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (fundCollateral s minted returned feeAmount) := h

theorem bookFunding_callBounds (s : State) (source protocol basis : Nat) (h : PublicCallBounds s) :
    PublicCallBounds { s with book := { s.book with source := source, protocol := protocol }, basis := basis } := h

theorem reserveReward_callBounds (s : State) (value : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (reserveRewardState s value) := by
  exact bookFunding_callBounds s _ s.book.protocol _ h

theorem compoundFinish_callBounds (s : State) (out fresh sold reward service feeAmount cashBefore : Nat)
    (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (compoundFinish s out fresh sold reward service feeAmount cashBefore) := by
  unfold compoundFinish
  split
  · trivial
  · apply fundCollateral_callBounds
    split
    · exact reserveReward_callBounds s _ h
    · exact h

theorem compoundFunds_callBounds (s : State) (out reward service feeAmount : Nat) (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (compoundFunds s out reward service feeAmount) := by
  rw [compoundFunds_factored]
  dsimp only
  rw [onSuccess_bind]
  intro next heq
  have hn := onSuccess_of_eq (compoundSale_callBounds s _ h) heq
  rw [compoundTail_eq]
  exact compoundFinish_callBounds _ _ _ _ _ _ _ _
    (callBounds_synth (pay next 0 0).1 s.synth (pay_callBounds next 0 0 hn))

theorem activateWaiting_callBounds (s : State) (shares owed debt synth : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (activateWaiting s shares owed debt synth) :=
  callBounds_setRequest s s.unwind _ h (h.2.2 s.unwind)

theorem unwindCommitted_callBounds (s : State) (q : UnwindNumbers) (h : PublicCallBounds s) :
    PublicCallBounds (unwindCommitted s q) := by
  apply activateWaiting_callBounds
  simpa only [PublicCallBounds, SourcePullBounds, RequestOwners, request, unwindCovered, coverExit,
    unwindBooked, sourceExitState, setPosition, prepareExitOwnership, foldExitWallets, moveWallets,
    setWallet, commitExitAccount, setAccount] using h

theorem unwindHead_callBounds (s : State) (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (unwindHead s) := by
  unfold unwindHead
  dsimp only
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · exact onSuccess_if _ _ _ _ trivial (unwindCommitted_callBounds s _ h)

theorem startOne_callBounds (s : State) (cursor : Nat) (h : PublicCallBounds s) :
    OnSuccess PublicCallBounds (startOne s cursor) := by
  have hn := unwindHead_callBounds _ (checkpoint_callBounds (withUnwind s cursor) zeroId zeroId h)
  rw [← startOne_cursor, onSuccess_map] at hn
  exact hn

theorem startMany_callBounds (fuel : Nat) (s : State) (cursor : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (startMany fuel s cursor) := by
  induction fuel generalizing s cursor with
  | zero => exact h
  | succ fuel ih =>
    change OnSuccess _ (if s.requests.size ≤ cursor || s.time < (request s cursor).eligible then
      .ok (s, cursor) else startOne s cursor >>= fun next => startMany fuel next (cursor+1))
    split
    · exact h
    · rw [onSuccess_bind]
      intro next heq
      exact ih next (cursor+1) (onSuccess_of_eq (startOne_callBounds s cursor h) heq)

end Juicer.PublicCalls
