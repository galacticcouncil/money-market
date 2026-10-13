import JuicerLean.FixedPoint.PublicStartLoopProofs
import JuicerLean.FixedPoint.PublicDepositProofs
import JuicerLean.FixedPoint.PublicRebalanceProofs
import JuicerLean.FixedPoint.PublicHarvestProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def InitializationSafe (s : State) : Prop :=
  InitialMintSafe s ∧ (s.supply = 0 ∨ 0 < wallet s 4) ∧ 4 < s.wallets.size

instance (s : State) : Decidable (InitializationSafe s) := by
  unfold InitializationSafe; infer_instance

theorem initializationSafe_genesis : InitializationSafe ({} : State) := by decide

theorem wallet_set_other (s : State) (i value : Nat) (hi : i ≠ 4) :
    wallet (setWallet s i value) 4 = wallet s 4 := by
  simp only [wallet, setWallet, Array.set!_eq_setIfInBounds,
    Array.getElem?_setIfInBounds, if_neg hi]

theorem moveWallets_locked (s : State) (a b n : Nat) (ha : a ≠ 4) (hs : 4 < s.wallets.size) :
    wallet s 4 ≤ wallet (moveWallets s a b n) 4 := by
  unfold moveWallets
  by_cases hb : b = 4
  · subst b
    rw [wallet_setWallet _ 4 _ 4 (by simpa only [setWallet, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using hs)]
    simp only [ite_true, beq_eq_false_iff_ne.mpr ha, Bool.false_eq_true, ite_false]
    exact Nat.le_add_right _ _
  · rw [wallet_set_other _ b _ hb, wallet_set_other s a _ ha]

theorem moveWallets_initializationSafe (s : State) (a b n : Nat)
    (h : InitializationSafe s) (ha : a ≠ 4) : InitializationSafe (moveWallets s a b n) := by
  refine ⟨h.1, ?_, ?_⟩
  · rcases h.2.1 with hz | hp
    · exact Or.inl hz
    · exact Or.inr (hp.trans_le (moveWallets_locked s a b n ha h.2.2))
  · simpa only [moveWallets, setWallet, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using h.2.2

theorem initializationSafe_setUnits (s : State) (i units : Nat) (h : InitializationSafe s) :
    InitializationSafe (setAccount s i { account s i with units := units }) := h

theorem settleOwner_initializationSafe (s : State) (i : Nat) (h : InitializationSafe s) :
    InitializationSafe (settleOwner s i) := by
  unfold settleOwner
  split <;> exact h

theorem checkpoint_initializationSafe (s : State) (a b : Nat) (h : InitializationSafe s) :
    InitializationSafe (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hn : InitializationSafe (if !pendingAccounting s then allocateState s else s) := by
    split
    · exact ⟨allocateState_initialMintSafe s h.1, h.2⟩
    · exact h
  split
  · exact settleOwner_initializationSafe _ a hn
  · exact settleOwner_initializationSafe _ b (settleOwner_initializationSafe _ a hn)

theorem pay_initializationSafe (s : State) (key limit : Nat) (h : InitializationSafe s) :
    InitializationSafe (pay s key limit).1 := by
  rw [pay_state_factored]
  exact h

theorem moveUnits_initializationSafe (s : State) (a b taken left : Nat) (h : InitializationSafe s) :
    InitializationSafe (moveUnits s a b taken left) := h

theorem prepareTransfer_initializationSafe (s : State) (a b n : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (prepareTransfer s a b n) := by
  rw [prepareTransfer_eq]
  have ht := settleOwner_initializationSafe (settleOwner s a) b (settleOwner_initializationSafe s a h)
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
              · exact moveUnits_initializationSafe _ a b _ _ ht
            · exact ht
      · exact ht
  · exact h

theorem finishTransfer_initializationSafe (s : State) (a b n : Nat)
    (h : InitializationSafe s) (ha : a ≠ 4) :
    OnSuccess InitializationSafe (finishTransfer s a b n) := by
  unfold finishTransfer
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> first | trivial | exact moveWallets_initializationSafe s a b n h ha

theorem transfer_initializationSafe (s : State) (a b n : Nat) (h : InitializationSafe s) (ha : a ≠ 4) :
    OnSuccess InitializationSafe (transfer s a b n) := by
  rw [transfer_decomposition, onSuccess_bind]
  rintro ⟨next, moved⟩ heq
  have hn := onSuccess_of_eq (prepareTransfer_initializationSafe s a b n h) heq
  exact finishTransfer_initializationSafe next a b moved hn ha

theorem spend_initializationSafe (s : State) (owner caller amount : Nat) (h : InitializationSafe s) :
    OnSuccess InitializationSafe (spend s owner caller amount) := by
  unfold spend
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> trivial

theorem cover_initializationSafe (s : State) (amount : Nat) (h : InitializationSafe s) :
    OnSuccess InitializationSafe (cover s amount) := by
  unfold cover
  split <;> trivial

theorem appendRequest_initializationSafe (s : State) (owner escrow committed : Nat) (h : InitializationSafe s) :
    InitializationSafe (appendRequest s owner escrow committed) := h

theorem requestOutcome_initializationSafe (s : State) (owner escrow : Nat) (value : Option (Nat × Nat))
    (h : InitializationSafe s) : OnSuccess InitializationSafe (requestOutcome s owner escrow value) := by
  cases value with
  | none => trivial
  | some pair =>
    exact appendRequest_initializationSafe _ owner escrow pair.1 (initializationSafe_setUnits s owner pair.2 h)

theorem commitRequest_initializationSafe (s : State) (owner escrow amount : Nat) (h : InitializationSafe s) :
    OnSuccess InitializationSafe (commitRequest s owner escrow amount) :=
  commitRequest_property InitializationSafe s owner escrow amount
    (requestOutcome_initializationSafe s owner escrow _ h) (appendRequest_initializationSafe s owner escrow 0 h)

theorem creditPosition_initializationSafe (s : State) (key weight : Nat) (h : InitializationSafe s) :
    InitializationSafe (creditPosition s key weight).1 := by
  rw [creditPosition_state_factored]
  exact h

theorem creditCursor_initializationSafe (s : State) (key : Nat) (h : InitializationSafe s) :
    InitializationSafe (creditCursor s key) := h

theorem creditSteps_initializationSafe (fuel : Nat) (s : State) (h : InitializationSafe s) :
    InitializationSafe (creditSteps fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    change InitializationSafe (if s.batchTail ≤ s.batchCursor then s else creditSteps fuel (advanceCredit s))
    split
    · exact h
    · exact ih (advanceCredit s) (creditCursor_initializationSafe _ _ (creditPosition_initializationSafe s s.batchCursor _ h))

theorem closeCredit_initializationSafe (s : State) (h : InitializationSafe s) :
    InitializationSafe (closeCredit s) := by
  unfold closeCredit
  split <;> exact h

theorem finishCredit_initializationSafe (s : State) (h : InitializationSafe s) :
    InitializationSafe (finishCredit s) := closeCredit_initializationSafe _ (creditSteps_initializationSafe 64 s h)

theorem initializationSafe_delever (s : State) (amount : Nat) (h : InitializationSafe s) :
    InitializationSafe { s with delever := amount } := h

theorem initializationSafe_synth (s : State) (amount : Nat) (h : InitializationSafe s) :
    InitializationSafe { s with synth := amount } := h

theorem activeCredit_initializationSafe (s : State) (h : InitializationSafe s) : InitializationSafe (activeCredit s) := by
  unfold activeCredit
  exact initializationSafe_delever (creditPosition (setupCredit s) 0 s.activeRemaining).1 _
    (creditPosition_initializationSafe (setupCredit s) 0 s.activeRemaining h)

theorem credit_initializationSafe (s : State) (amount cost : Nat) (h : InitializationSafe s) :
    InitializationSafe (credit s amount cost) := by
  rw [credit_factored]
  let next := receiveCredit s amount cost
  have hn : InitializationSafe next := h
  change InitializationSafe (creditReceived next)
  unfold creditReceived
  split
  · split
    · exact hn
    · exact finishCredit_initializationSafe (activeCredit next) (activeCredit_initializationSafe next hn)
  · exact finishCredit_initializationSafe next hn

theorem finishSettle_initializationSafe (s : State) (i : Nat) (r : Request) (paid : Nat)
    (h : InitializationSafe s) :
    InitializationSafe (finishSettle s i r paid).1 := by
  have hn : InitializationSafe (settleRecord s i r (settleRedemption r.claim paid)) := h
  unfold finishSettle
  dsimp only
  split <;> exact hn

theorem settleOne_initializationSafe (s : State) (h : InitializationSafe s) : InitializationSafe (settleOne s).1 := by
  unfold settleOne
  split
  · exact h
  · dsimp only
    by_cases hd : ((request s s.head).claim.debt == (request s s.head).claim.repaid) = true
    · simp only [hd, ite_true]
      exact finishSettle_initializationSafe s s.head _ 0 h
    · simp only [hd]
      let p := pay s (s.head+1) ((request s s.head).claim.debt-(request s s.head).claim.repaid)
      have hp : InitializationSafe p.1 := pay_initializationSafe s _ _ h
      have hr : request p.1 s.head = request s s.head := pay_request s _ _ s.head
      change InitializationSafe (finishSettle p.1 s.head (request s s.head) p.2.1).1
      rw [← hr]
      exact finishSettle_initializationSafe p.1 s.head _ p.2.1 hp

theorem settleMany_initializationSafe (fuel : Nat) (s : State) (h : InitializationSafe s) :
    InitializationSafe (settleMany fuel s) := by
  induction fuel generalizing s with
  | zero => exact h
  | succ fuel ih =>
    have hn := settleOne_initializationSafe s h
    rcases heq : settleOne s with ⟨next, more⟩
    rw [heq] at hn
    simp only [settleMany, heq]
    split
    · exact ih next hn
    · exact hn

theorem compoundSale_initializationSafe (s : State) (sold : Nat) (h : InitializationSafe s) :
    OnSuccess InitializationSafe (compoundSale s sold) := by
  unfold compoundSale
  simp only [bind, pure, Except.bind, Except.pure]
  split
  · split
    · trivial
    · split
      · trivial
      · exact h
  · exact h

theorem fundCollateral_initializationSafe (s : State) (minted returned feeAmount : Nat)
    (h : InitializationSafe s) (hm : s.supply = 0 → minted = 0) :
    InitializationSafe (fundCollateral s minted returned feeAmount) := by
  refine ⟨?_, ?_, ?_⟩
  · intro hz
    change s.supply + minted = 0 at hz
    exact h.1 (by omega)
  · rcases h.2.1 with hz | hp
    · exact Or.inl (by change s.supply + minted = 0; rw [hz, hm hz])
    · apply Or.inr
      change 0 < wallet (setWallet s fundId (wallet s fundId+minted)) 4
      rw [wallet_set_other s fundId _ (by decide)]
      exact hp
  · simpa only [fundCollateral, setWallet, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using h.2.2

theorem bookFunding_initializationSafe (s : State) (source protocol basis : Nat) (h : InitializationSafe s) :
    InitializationSafe { s with book := { s.book with source := source, protocol := protocol }, basis := basis } := h

theorem reserveReward_initializationSafe (s : State) (value : Nat) (h : InitializationSafe s) :
    InitializationSafe (reserveRewardState s value) := by
  exact bookFunding_initializationSafe s _ s.book.protocol _ h

theorem compoundFinish_initializationSafe (s : State) (out fresh sold reward service feeAmount cashBefore : Nat)
    (h : InitializationSafe s) :
    OnSuccess InitializationSafe (compoundFinish s out fresh sold reward service feeAmount cashBefore) := by
  unfold compoundFinish
  split
  · trivial
  · apply fundCollateral_initializationSafe
    · split
      · exact reserveReward_initializationSafe s _ h
      · exact h
    · intro hz
      simp only [activeSupply, hz, Nat.zero_sub, Nat.mul_zero, Nat.zero_div]

theorem compoundFunds_initializationSafe (s : State) (out reward service feeAmount : Nat) (h : InitializationSafe s) :
    OnSuccess InitializationSafe (compoundFunds s out reward service feeAmount) := by
  rw [compoundFunds_factored]
  dsimp only
  rw [onSuccess_bind]
  intro next heq
  have hn := onSuccess_of_eq (compoundSale_initializationSafe s _ h) heq
  rw [compoundTail_eq]
  exact compoundFinish_initializationSafe _ _ _ _ _ _ _ _
    (initializationSafe_synth (pay next 0 0).1 s.synth (pay_initializationSafe next 0 0 hn))

theorem unwindCommitted_initializationSafe (s : State) (q : UnwindNumbers)
    (h : InitializationSafe s) : InitializationSafe (unwindCommitted s q) := by
  have hn : InitializationSafe (commitExitAccount s) := by
    simpa only [InitializationSafe, InitialMintSafe, commitExitAccount, setAccount,
      waitingExit, startExit] using h
  have hw := moveWallets_initializationSafe (commitExitAccount s) fundId vaultId
    (waitingExit s).folded hn (by decide)
  exact hw

theorem unwindHead_initializationSafe (s : State) (h : InitializationSafe s) :
    OnSuccess InitializationSafe (unwindHead s) := by
  unfold unwindHead
  dsimp only
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · exact onSuccess_if _ _ _ _ trivial (unwindCommitted_initializationSafe s _ h)

theorem startOne_initializationSafe (s : State) (cursor : Nat) (h : InitializationSafe s) :
    OnSuccess InitializationSafe (startOne s cursor) := by
  have hn := unwindHead_initializationSafe _ (checkpoint_initializationSafe (withUnwind s cursor) zeroId zeroId h)
  rw [← startOne_cursor, onSuccess_map] at hn
  exact hn

theorem startMany_initializationSafe (fuel : Nat) (s : State) (cursor : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (startMany fuel s cursor) := by
  induction fuel generalizing s cursor with
  | zero => exact h
  | succ fuel ih =>
    change OnSuccess _ (if s.requests.size ≤ cursor || s.time < (request s cursor).eligible then
      .ok (s, cursor) else startOne s cursor >>= fun next => startMany fuel next (cursor+1))
    split
    · exact h
    · rw [onSuccess_bind]
      intro next heq
      exact ih next (cursor+1) (onSuccess_of_eq (startOne_initializationSafe s cursor h) heq)

end Juicer.PublicCalls
