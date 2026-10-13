import JuicerLean.FixedPoint.PublicDepositProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem sourceValue_split (s : State) (amount : Nat) (h : amount ≤ s.held) :
    sourceValue s (s.held-amount)+sourceValue s amount ≤ sourceValue s s.held := by
  unfold sourceValue
  have hh := Nat.div_add_div_le_add_div (x := (s.held-amount)*s.sourceRate)
    (y := amount*s.sourceRate) (z := wad)
  rwa [← Nat.add_mul,Nat.sub_add_cancel h] at hh

theorem sourceValue_mint (s : State) (amount : Nat) :
    sourceValue s (s.held+amount*wad/s.sourceRate) ≤ sourceValue s s.held+amount := by
  have hh : amount*wad/s.sourceRate*s.sourceRate ≤ amount*wad := Nat.div_mul_le_self _ _
  unfold sourceValue
  calc
    (s.held+amount*wad/s.sourceRate)*s.sourceRate/wad ≤
        (s.held*s.sourceRate+amount*wad)/wad := by
      apply Nat.div_le_div_right
      rw [Nat.add_mul]
      exact Nat.add_le_add_left hh _
    _ = s.held*s.sourceRate/wad+amount := by
      rw [Nat.add_mul_div_right _ _ (by decide : 0 < wad)]

def ZeroActiveFee (s : State) : Prop := s.activeRemaining = 0 → (fee s 0).feeLeft = 0

instance (s : State) : Decidable (ZeroActiveFee s) := by unfold ZeroActiveFee; infer_instance

theorem checkpoint_zeroActiveFee (s : State) (a b : Nat) (h : ZeroActiveFee s) :
    ZeroActiveFee (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hs (s : State) (a : Nat) (h : ZeroActiveFee s) : ZeroActiveFee (settleOwner s a) := by
    unfold settleOwner
    split <;> exact h
  have hn : ZeroActiveFee (if !pendingAccounting s then allocateState s else s) := by
    split <;> exact h
  split
  · exact hs _ a hn
  · exact hs _ b (hs _ a hn)

def mintMainPosition (s : State) (units principal : Nat) : State :=
  setPosition { s with mainUnits := s.mainUnits+units } 0
    { position s 0 with units := (position s 0).units+units,principal := (position s 0).principal+principal }

theorem mintMainPosition_public (s : State) (units principal : Nat) (h : PublicInvariant s) :
    PublicInvariant (mintMainPosition s units principal) := by
  have hi : 0 < s.positions.size := h.2.2.2.2.2.2.2.2.2.1
  let p := { position s 0 with units := (position s 0).units+units,principal := (position s 0).principal+principal }
  have hu := position_sum_replace s 0 p MainPosition.units hi
  have hr := position_sum_replace s 0 p MainPosition.remaining hi
  have hc := position_sum_replace s 0 p MainPosition.cash hi
  rcases h with ⟨hcoll,hsource,hcash,hl,he,ho⟩
  refine ⟨hcoll,?_,?_,hl,he,?_⟩
  · change s.activeRemaining+(sourceProjection (mintMainPosition s units principal)).exits.sum = s.outstanding
    change s.activeRemaining+(sourceProjection s).exits.sum = s.outstanding at hsource
    change (sourceProjection (mintMainPosition s units principal)).exits.sum+(position s 0).remaining =
      (sourceProjection s).exits.sum+(position s 0).remaining at hr
    omega
  · change (cashProjection (mintMainPosition s units principal)).cohorts.sum+s.unallocated = s.ownedCash
    change (cashProjection s).cohorts.sum+s.unallocated = s.ownedCash at hcash
    change (cashProjection (mintMainPosition s units principal)).cohorts.sum+(position s 0).cash =
      (cashProjection s).cohorts.sum+(position s 0).cash at hc
    omega
  · rcases ho with ⟨hw,ha,hc,hap,hpos,hunwind,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨hw,ha,hc,hap,?_,hunwind,hsupply,?_,hout,?_,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    · simpa only [mintMainPosition,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hpos
    · change s.mainUnits+units = ((mintMainPosition s units principal).positions.toList.map MainPosition.units).sum
      change ((mintMainPosition s units principal).positions.toList.map MainPosition.units).sum+(position s 0).units =
        (s.positions.toList.map MainPosition.units).sum+((position s 0).units+units) at hu
      omega
    · simpa only [mintMainPosition,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hfs

def depositSourceState (s : State) (shares amount : Nat) : State :=
  { s with
    held := s.held+shares,sourceCash := s.sourceCash+amount,
    basis := s.basis+amount,reinvest := 0 }

theorem depositSourceState_public (s : State) (shares amount : Nat) (h : PublicInvariant s)
    (hg : sourceValue s (s.held+shares) ≤ sourceValue s s.held+amount) :
    PublicInvariant (depositSourceState s shares amount) := by
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · exact h.2.2.2.2.1
  · rcases h.2.2.2.2.2 with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,?_,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    intro hex
    have hb := hsourceCash hex
    change sourceValue s (s.held+shares)+s.freed ≤ s.sourceCash+amount
    calc
      _ ≤ (sourceValue s s.held+amount)+s.freed := Nat.add_le_add_right hg _
      _ = (sourceValue s s.held+s.freed)+amount := Nat.add_right_comm _ _ _
      _ ≤ s.sourceCash+amount := Nat.add_le_add_right hb _

def depositSource (s : State) (amount : Nat) : State :=
  depositSourceState s (amount*wad/s.sourceRate) amount

theorem depositSource_public (s : State) (amount : Nat) (h : PublicInvariant s) :
    PublicInvariant (depositSource s amount) :=
  depositSourceState_public s _ amount h (sourceValue_mint s amount)

def borrowSource (s : State) (amount supplied : Nat) : State :=
  let borrowed := amount-s.borrowLoss
  let minted := if s.mainUnits == 0 then borrowed*wad else ceilDiv (borrowed*s.mainUnits) s.debt
  let next := depositSource (mintMainPosition s minted borrowed) amount
  { next with debt := s.debt+borrowed,synth := supplied }

theorem debtSynth_public (s : State) (debt synth : Nat) (h : PublicInvariant s) :
    PublicInvariant { s with debt,synth } := h

theorem borrowSource_public (s : State) (amount supplied : Nat) (h : PublicInvariant s) :
    PublicInvariant (borrowSource s amount supplied) :=
  debtSynth_public _ _ supplied (depositSource_public _ amount (mintMainPosition_public s _ _ h))

def addActiveFee (s : State) (f : SourceFee) : State :=
  { s with sourceFees := s.sourceFees.set! 0 f,feeReserve := s.feeReserve+f.feeLeft }

theorem addActiveFee_public (s : State) (f : SourceFee) (h : PublicInvariant s)
    (hzero : (fee s 0).feeLeft = 0) (hf : f.feeLeft ≤ f.yieldLeft) :
    PublicInvariant (addActiveFee s f) := by
  have hi : 0 < s.sourceFees.size := by
    have hp : 0 < s.positions.size := h.2.2.2.2.2.2.2.2.2.1
    have hs : s.sourceFees.size = s.positions.size := h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
    omega
  have hsum := list_sum_map_set s.sourceFees.toList 0 f {} SourceFee.feeLeft (by simpa using hi)
  simp only [Array.getElem?_toList] at hsum
  change ((s.sourceFees.toList.set 0 f).map SourceFee.feeLeft).sum+(fee s 0).feeLeft =
    (s.sourceFees.toList.map SourceFee.feeLeft).sum+f.feeLeft at hsum
  rw [hzero,Nat.add_zero] at hsum
  rcases h with ⟨hc,hs,hm,hl,he,ho⟩
  refine ⟨hc,hs,hm,hl,he,?_⟩
  rcases ho with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  refine ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,?_,?_,?_,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  · simpa only [addActiveFee,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hfs
  · change s.feeReserve+f.feeLeft = ((s.sourceFees.set! 0 f).toList.map SourceFee.feeLeft).sum
    rw [Array.set!_eq_setIfInBounds,Array.toList_setIfInBounds,hsum,hfr]
  · intro fee hmem
    change fee ∈ (s.sourceFees.set! 0 f).toList at hmem
    rw [Array.set!_eq_setIfInBounds,Array.toList_setIfInBounds] at hmem
    rcases List.mem_or_eq_of_mem_set hmem with hm | rfl
    · exact hfee fee hm
    · exact hf

def unwindActiveSource (s : State) (slice basis : Nat) : State :=
  let claim := sourceValue s slice
  { s with
    held := s.held-slice,basis := s.basis-basis,freed := s.freed+claim,
    outstanding := s.outstanding+claim,activeRemaining := claim,delever := claim }

theorem unwindActiveSource_public (s : State) (slice basis : Nat) (h : PublicInvariant s)
    (hzero : s.activeRemaining = 0) (hslice : slice ≤ s.held) :
    PublicInvariant (unwindActiveSource s slice basis) := by
  rcases h with ⟨hc,hs,hm,hl,he,ho⟩
  refine ⟨hc,?_,hm,hl,he,?_⟩
  · change sourceValue s slice+(s.positions.toList.map MainPosition.remaining).sum =
      s.outstanding+sourceValue s slice
    change s.activeRemaining+(s.positions.toList.map MainPosition.remaining).sum = s.outstanding at hs
    omega
  · rcases ho with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,?_,hfs,hfr,hfee,?_,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    · change s.freed+sourceValue s slice+s.unallocated+s.unallocatedCost = s.outstanding+sourceValue s slice
      omega
    · intro hex
      have hb := hsourceCash hex
      have hh := sourceValue_split s slice hslice
      change sourceValue s (s.held-slice)+(s.freed+sourceValue s slice) ≤ s.sourceCash
      calc
        _ = (sourceValue s (s.held-slice)+sourceValue s slice)+s.freed := by
          rw [Nat.add_left_comm,Nat.add_comm s.freed,Nat.add_assoc]
        _ ≤ sourceValue s s.held+s.freed := Nat.add_le_add_right hh _
        _ ≤ s.sourceCash := hb

end Juicer.PublicCalls
