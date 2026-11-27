import JuicerLean.FixedPoint.PublicExitProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def sourceExitState (s : State) (active exit : MainPosition) (total slice basis claim : Nat)
    (vested : SourceFee) : State :=
  let next := setPosition s 0 active
  { next with
    positions := next.positions.push exit,mainUnits := total,held := s.held-slice,
    basis := s.basis-(if slice == 0 then 0 else basis),freed := s.freed+claim,outstanding := s.outstanding+claim,
    sourceFees := s.sourceFees.push vested,feeReserve := s.feeReserve+vested.feeLeft }

structure SourceExitFacts (s : State) (active exit : MainPosition) (total slice claim : Nat)
    (vested : SourceFee) : Prop where
  units : active.units+exit.units+(s.mainUnits-(position s 0).units) = total
  units_le : (position s 0).units ≤ s.mainUnits
  cash : active.cash+exit.cash = (position s 0).cash
  remaining : active.remaining = (position s 0).remaining
  claim_eq : exit.remaining = claim
  slice_le : slice ≤ s.held
  value_eq : claim = sourceValue s slice
  fee : vested.feeLeft ≤ vested.yieldLeft

theorem mainExit_facts (s : State) (shares slice claim : Nat) (vested : SourceFee)
    (h : OperationalInvariant s) (hs : shares ≤ activeSupply s) (hb : slice ≤ s.held)
    (hc : claim = sourceValue s slice) (hf : vested.feeLeft ≤ vested.yieldLeft) :
    SourceExitFacts s (mainExit (position s 0) s.mainUnits s.debt shares (activeSupply s) claim).1
      (mainExit (position s 0) s.mainUnits s.debt shares (activeSupply s) claim).2.1
      (mainExit (position s 0) s.mainUnits s.debt shares (activeSupply s) claim).2.2 slice claim vested := by
  have hi : 0 < s.positions.size := h.2.2.2.2.1
  have hu := map_value_le_sum MainPosition.units s.positions.toList (position s 0) (position_mem s 0 hi)
  have htotal : s.mainUnits = (s.positions.toList.map MainPosition.units).sum := h.2.2.2.2.2.2.2.1
  rw [← htotal] at hu
  exact ⟨mainExit_units_conserved _ _ _ _ _ _ hs hu,hu,mainExit_cash_conserved _ _ _ _ _ _ hs,rfl,rfl,hb,hc,hf⟩

theorem sourceExitState_source (s : State) (active exit : MainPosition) (total slice basis claim : Nat)
    (vested : SourceFee) (h : (sourceProjection s).valid) (hi : 0 < s.positions.size)
    (hf : SourceExitFacts s active exit total slice claim vested) :
    (sourceProjection (sourceExitState s active exit total slice basis claim vested)).valid := by
  have hr := position_sum_replace s 0 active MainPosition.remaining hi
  rw [hf.remaining] at hr
  have he := Nat.add_right_cancel hr
  change s.activeRemaining+(s.positions.toList.map MainPosition.remaining).sum = s.outstanding at h
  change s.activeRemaining+(((s.positions.set! 0 active).push exit).toList.map MainPosition.remaining).sum = s.outstanding+claim
  rw [Array.toList_push,List.map_append,List.sum_append,List.map_singleton,List.sum_singleton,hf.claim_eq,he]
  omega

theorem sourceExitState_cash (s : State) (active exit : MainPosition) (total slice basis claim : Nat)
    (vested : SourceFee) (h : (cashProjection s).valid) (hi : 0 < s.positions.size)
    (hf : SourceExitFacts s active exit total slice claim vested) :
    (cashProjection (sourceExitState s active exit total slice basis claim vested)).valid := by
  have hr := position_sum_replace s 0 active MainPosition.cash hi
  change (s.positions.toList.map MainPosition.cash).sum+s.unallocated = s.ownedCash at h
  change (((s.positions.set! 0 active).push exit).toList.map MainPosition.cash).sum+s.unallocated = s.ownedCash
  rw [Array.toList_push,List.map_append,List.sum_append,List.map_singleton,List.sum_singleton]
  have hc := hf.cash
  omega

theorem sourceExitState_operational (s : State) (active exit : MainPosition) (total slice basis claim : Nat)
    (vested : SourceFee) (h : OperationalInvariant s) (hf : SourceExitFacts s active exit total slice claim vested) :
    OperationalInvariant (sourceExitState s active exit total slice basis claim vested) := by
  rcases h with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  have hunits := position_sum_replace s 0 active MainPosition.units hpos
  refine ⟨hw,ha,hc,hap,?_,hu,hsupply,?_,?_,?_,?_,?_,?_,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  · simp only [sourceExitState,Array.size_push]
    omega
  · change total = (((s.positions.set! 0 active).push exit).toList.map MainPosition.units).sum
    rw [Array.toList_push,List.map_append,List.sum_append,List.map_singleton,List.sum_singleton]
    have hh := hf.units
    have hb := hf.units_le
    omega
  · change (s.freed+claim)+s.unallocated+s.unallocatedCost = s.outstanding+claim
    omega
  · simpa only [sourceExitState,setPosition,Array.size_push,Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using congrArg (fun n => n+1) hfs
  · change s.feeReserve+vested.feeLeft = ((s.sourceFees.push vested).toList.map SourceFee.feeLeft).sum
    rw [Array.toList_push,List.map_append,List.sum_append,List.map_singleton,List.sum_singleton,hfr]
  · intro f hmem
    change f ∈ (s.sourceFees.push vested).toList at hmem
    rw [Array.toList_push,List.mem_append,List.mem_singleton] at hmem
    rcases hmem with hold | rfl
    · exact hfee f hold
    · exact hf.fee
  · intro hex
    have hs := sourceValue_split s slice hf.slice_le
    have hc := hsourceCash hex
    change sourceValue s (s.held-slice)+(s.freed+claim) ≤ s.sourceCash
    rw [hf.value_eq]
    omega

theorem sourceExitState_liability (s : State) (active exit : MainPosition) (total slice basis claim : Nat)
    (vested : SourceFee) :
    publicLiability (advanceWaiting (sourceExitState s active exit total slice basis claim vested)) =
      publicLiability (advanceWaiting s) := by
  rw [publicLiability_parts,publicLiability_parts]
  rfl

end Juicer.PublicCalls
