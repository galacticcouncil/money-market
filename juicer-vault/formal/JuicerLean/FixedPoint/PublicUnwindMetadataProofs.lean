import JuicerLean.FixedPoint.PublicUnwindProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def WaitingOwners (s : State) : Prop := ∀ r ∈ waitingRequests s, r.owner < 5

instance (s : State) : Decidable (WaitingOwners s) := by
  unfold WaitingOwners
  infer_instance

def UnwindReady (s : State) : Prop :=
  PublicMetadata s ∧ QueueBacking s ∧ WaitingOwners s ∧ s.feeBps ≤ 10000

instance (s : State) : Decidable (UnwindReady s) := by
  unfold UnwindReady
  infer_instance

theorem checkpoint_zero_factored (s : State) :
    checkpoint s zeroId zeroId = if !pendingAccounting s then allocateState s else s := by
  rw [checkpoint_factored]
  simp only [beq_self_eq_true,ite_true,settleOwner,special,Bool.or_true]

theorem checkpoint_unwindReady (s : State) (h : UnwindReady s) :
    UnwindReady (checkpoint s zeroId zeroId) := by
  refine ⟨checkpoint_metadata s zeroId zeroId h.1,?_⟩
  rw [checkpoint_zero_factored]
  split
  · exact h.2
  · exact h.2

theorem checkpoint_unwind_requests (s : State) :
    (checkpoint s zeroId zeroId).requests = s.requests ∧
      (checkpoint s zeroId zeroId).unwind = s.unwind ∧
      pendingAccounting (checkpoint s zeroId zeroId) = pendingAccounting s ∧
      (checkpoint s zeroId zeroId).held = s.held := by
  rw [checkpoint_zero_factored]
  split <;> exact ⟨rfl,rfl,rfl,rfl⟩

theorem commitExitAccount_metadata (s : State) (h : PublicMetadata s) :
    PublicMetadata (commitExitAccount s) := by
  have ha := metadata_setAccount s (request s s.unwind).owner
    ⟨(waitingExit s).owned,s.book.index,s.book.epoch,s.book.scale⟩ h ⟨le_rfl,fun _ => le_rfl⟩
  apply metadata_bookProgress _ (waitingExit s).book ha
  constructor
  · simp only [setAccount,waitingExit,startExit_epoch]
    exact le_rfl
  · intro _
    simp only [setAccount,waitingExit,startExit_scale]
    exact le_rfl

theorem prepareExitOwnership_metadata (s : State) (h : PublicMetadata s) :
    PublicMetadata (prepareExitOwnership s) := commitExitAccount_metadata s h

theorem activateWaiting_metadata (s : State) (shares owed debt synth : Nat) (h : PublicMetadata s) :
    PublicMetadata (activateWaiting s shares owed debt synth) := by
  refine ⟨h.1,?_⟩
  intro i hi
  have hi' : i < s.requests.size := by
    simpa only [activateWaiting,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hi
  change AccountHistory s.book ((s.requests.set! s.unwind
    (activatedRequest (request s s.unwind) shares owed debt synth))[i]?.getD {}).account
  simp only [Array.set!_eq_setIfInBounds,Array.getElem?_setIfInBounds]
  split
  next heq =>
    subst i
    simp only [hi',ite_true,Option.getD_some,activatedRequest,AccountHistory]
    exact ⟨Nat.zero_le _,fun _ => Nat.zero_le _⟩
  · exact h.2 i hi'

theorem unwindCommitted_metadata (s : State) (q : UnwindNumbers) (h : PublicMetadata s) :
    PublicMetadata (unwindCommitted s q) := by
  apply activateWaiting_metadata
  simpa only [PublicMetadata,AccountHistory,account,request,unwindCovered,coverExit,unwindBooked,
    sourceExitState,setPosition] using prepareExitOwnership_metadata s h

theorem unwindCommitted_waitingOwners (s : State) (q : UnwindNumbers) (h : WaitingOwners s)
    (hi : s.unwind < s.requests.size) : WaitingOwners (unwindCommitted s q) := by
  intro r hr
  rw [unwindCommitted,waitingRequests_activate] at hr
  have hm : r ∈ s.requests.toList.drop (s.unwind+1) := by
    simpa only [unwindCovered,coverExit,unwindBooked,sourceExitState,setPosition,prepareExitOwnership,
      foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount] using hr
  apply h r
  rw [waiting_head s hi]
  exact List.mem_cons_of_mem _ hm

theorem unwindCommitted_ready (s : State) (q : UnwindNumbers) (h : UnwindReady s)
    (hi : s.unwind < s.requests.size) (hq : UnwindFacts s q) : UnwindReady (unwindCommitted s q) := by
  refine ⟨unwindCommitted_metadata s q h.1,unwindCommitted_queueBacking s q h.2.1 hq,
    unwindCommitted_waitingOwners s q h.2.2.1 hi,?_⟩
  simpa only [unwindCommitted,activateWaiting,unwindCovered,coverExit,unwindBooked,sourceExitState,
    setPosition,prepareExitOwnership,foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount]
    using h.2.2.2

theorem unwindHead_preserves (s : State) (h : PublicInvariant s) (hr : UnwindReady s)
    (hi : s.unwind < s.requests.size)
    (hb : pendingAccounting s = false → s.book.source+s.book.protocol ≤ s.held) :
    OnSuccess (fun next => PublicInvariant next ∧ UnwindReady next) (unwindHead s) := by
  have ho : (request s s.unwind).owner < 5 := by
    apply hr.2.2.1
    rw [waiting_head s hi]
    exact List.mem_cons_self
  unfold unwindHead
  dsimp only
  split
  · trivial
  next hzero =>
    split
    · trivial
    next hpending =>
      split
      · trivial
      next hdebt =>
        split
        · trivial
        next hreserve =>
          have hpositive := unwindNumbers_redemption s hzero
          have hbudget : (unwindNumbers s).rounding ≤ s.reserve := by omega
          have facts := unwindNumbers_facts s h hr.2.1 hi (hb (Bool.eq_false_iff.mpr hpending)) hpositive hbudget
          exact ⟨unwindCommitted_public s _ h hi ho facts,unwindCommitted_ready s _ hr hi facts⟩

theorem checkpoint_unwindHead_preserves (s : State) (h : PublicInvariant s) (hr : UnwindReady s)
    (hi : s.unwind < s.requests.size) :
    OnSuccess (fun next => PublicInvariant next ∧ UnwindReady next)
      (unwindHead (checkpoint s zeroId zeroId)) := by
  have frame := checkpoint_unwind_requests s
  apply unwindHead_preserves _ (checkpoint_public s zeroId zeroId h hr.1) (checkpoint_unwindReady s hr)
  · simpa only [frame.1,frame.2.1] using hi
  · intro hp
    rw [frame.2.2.1] at hp
    rw [frame.2.2.2]
    exact checkpoint_reserved s hp hr.2.2.2

end Juicer.PublicCalls
