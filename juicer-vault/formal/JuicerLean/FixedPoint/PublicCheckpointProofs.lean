import JuicerLean.FixedPoint.PublicAllocationProofs

set_option maxRecDepth 4000
set_option maxHeartbeats 500000

namespace Juicer.PublicCalls
open Runtime

def publicStoredAccounts (s : State) : List (Account × Nat) :=
  ((List.range 5).map fun i => (account s i,wallet s i)) ++
    ((List.range (s.requests.size-s.unwind)).map fun i =>
      ((request s (s.unwind+i)).account,(request s (s.unwind+i)).claim.shares))

theorem publicStored_liability (s : State) :
    normalizedLiability s.book (publicStoredAccounts s) = publicLiability s := by
  simp only [normalizedLiability, publicStoredAccounts, publicLiability, publicLifecycle,
    List.map_append, List.map_map, Function.comp_def]

theorem publicStored_weight (s : State) :
    ((publicStoredAccounts s).map Prod.snd).sum = lazyWeight (publicProjection s).ledger.accounts := by
  simp [publicStoredAccounts, publicProjection, publicLifecycle, lazyWeight, normalizeAccount,
    Function.comp_def]

theorem publicStored_histories (s : State) (h : PublicMetadata s) (ha : s.accounts.size = actors) :
    HistoriesValid s.book (publicStoredAccounts s) := by
  intro p hp
  simp only [publicStoredAccounts, List.mem_append, List.mem_map] at hp
  rcases hp with hm | hm
  · obtain ⟨i,hi,rfl⟩ := hm
    exact h.1 i (by rw [ha]; have := List.mem_range.mp hi; simp only [actors]; omega)
  · obtain ⟨i,hi,rfl⟩ := hm
    exact h.2 (s.unwind+i) (by have := List.mem_range.mp hi; omega)

theorem publicStored_outside (s : State) (h : PublicInvariant s) :
    ((publicStoredAccounts s).map Prod.snd).sum ≤ (allocationInput s).supply-(allocationInput s).funded := by
  rw [publicStored_weight]
  have hw := lifecycle_weight_derived (publicProjection s) h.2.2.2.1
  exact hw

def allocateState (s : State) : State :=
  let v := allocationInput s
  let added := allocationFresh s.book v
  let released := if v.held != 0 && v.supply != 0 && added != 0 then
    min (added*v.equity/v.held) (v.basis-v.required) else 0
  { s with book := allocate s.book v, basis := s.basis-released }

theorem allocateState_operational (s : State) (h : OperationalInvariant s) :
    OperationalInvariant (allocateState s) := h

theorem allocateState_stored (s : State) : publicStoredAccounts (allocateState s) = publicStoredAccounts s := rfl

theorem allocateState_public (s : State) (h : PublicInvariant s) (hm : PublicMetadata s) :
    PublicInvariant (allocateState s) := by
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · apply (publicSlack_lt_iff _).2
    rw [← publicStored_liability, allocateState_stored]
    have hs : NormalizedSafe s.book (publicStoredAccounts s) := by
      unfold NormalizedSafe
      rw [publicStored_liability]
      exact (publicSlack_lt_iff s).1 h.2.2.2.2.1
    exact allocate_safe s.book (allocationInput s) (publicStoredAccounts s)
      (publicStored_histories s hm h.2.2.2.2.2.2.1) hs (publicStored_outside s h)
  · exact allocateState_operational s h.2.2.2.2.2

theorem allocateState_metadata (s : State) (h : PublicMetadata s) : PublicMetadata (allocateState s) :=
  metadata_bookProgress s (allocate s.book (allocationInput s)) h (allocate_progress s.book (allocationInput s))

theorem checkpoint_factored (s : State) (a b : Nat) :
    checkpoint s a b =
      let next := settleOwner (if !pendingAccounting s then allocateState s else s) a
      if a == b then next else settleOwner next b := by
  by_cases hp : (!pendingAccounting s) = true
  all_goals
    by_cases hab : (a == b) = true
    all_goals simp only [checkpoint, Id.run, bind, pure, if_pos, hp, hab]
    all_goals rfl

theorem checkpoint_public (s : State) (a b : Nat) (h : PublicInvariant s) (hm : PublicMetadata s) :
    PublicInvariant (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hp : PublicInvariant (if !pendingAccounting s then allocateState s else s) := by
    split
    · exact allocateState_public s h hm
    · exact h
  split
  · exact settleOwner_public _ a hp
  · exact settleOwner_public _ b (settleOwner_public _ a hp)

theorem checkpoint_metadata (s : State) (a b : Nat) (hm : PublicMetadata s) :
    PublicMetadata (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hp : PublicMetadata (if !pendingAccounting s then allocateState s else s) := by
    split
    · exact allocateState_metadata s hm
    · exact hm
  split
  · exact metadata_settleOwner _ a hp
  · exact metadata_settleOwner _ b (metadata_settleOwner _ a hp)

theorem raw_sync_public (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) (hm : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rawRunCall s ⟨8,caller,a,b,n⟩) := by
  change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
    else .ok (checkpoint s zeroId zeroId, harvestable (checkpoint s zeroId zeroId)))
  split
  · trivial
  · exact checkpoint_public s zeroId zeroId h hm

end Juicer.PublicCalls

