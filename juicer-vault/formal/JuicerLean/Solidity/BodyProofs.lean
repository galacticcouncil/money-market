import JuicerLean.Solidity.GeneratedBodies
import JuicerLean.Solidity.GuardProofs
import JuicerLean.FixedPoint.PublicHarvestCapacityProofs

namespace Juicer.Solidity
open Runtime

theorem accountingShiftIndex_refines (index shift : Nat) (hi : index ≤ max256) (hs : shift ≤ max256) :
    eval accountingShiftIndex (pairInput index shift) = .ok (ceilShift index shift) := by
  have hzero : 0 ≤ max256 := Nat.zero_le _
  have hone : 1 ≤ max256 := by norm_num [max256]
  by_cases hz : index = 0
  · subst index
    simp only [accountingShiftIndex,eval,pairInput,checkWord,hzero,if_pos,checked_bind_ok,
      checked_pure,beq_self_eq_true,ceilShift_zero_value]
  · have hsub : 1 ≤ index := by omega
    have hshift := checked_shift_bounded (index-1) shift
    have hsum : checkedShift (index-1) shift+1 ≤ max256 := by omega
    rw [ceilShift_eq_safe,if_neg hz]
    simp only [accountingShiftIndex,eval,pairInput,checkWord,hi,hs,hzero,hone,if_pos,
      checked_bind_ok,checked_pure,beq_iff_eq,hz,ite_false,checkedSub,hsub,checkedAdd,hsum]
    rfl

theorem accountingShiftIndex_bounded (index shift : Nat) (hi : index ≤ max256) (hs : shift ≤ max256) :
    ceilShift index shift ≤ max256 :=
  eval_valid accountingShiftIndex (pairInput index shift) _ (accountingShiftIndex_refines index shift hi hs)

theorem accountingShiftIndex_wide (index shift : Nat) (hi : index ≤ max256)
    (hs : shift ≤ max256) (hwide : 256 ≤ shift) :
    eval accountingShiftIndex (pairInput index shift) = .ok (if index = 0 then 0 else 1) := by
  rw [accountingShiftIndex_refines index shift hi hs,ceilShift_eq_safe]
  have hr := checked_shift_ge_width (index-1) shift ((Nat.sub_le _ _).trans hi) hwide
  change (index-1) >>> shift = 0 at hr
  simp only [hr,Nat.zero_add]

def vaultDepositAction (caller receiver assets : Nat) : PublicCalls.Action :=
  ⟨0,caller,0,receiver,assets⟩

def vaultStartUnwindsAction (caller maximum : Nat) : PublicCalls.Action :=
  ⟨5,caller,0,0,maximum⟩

def vaultPokeSettleAction (caller : Nat) : PublicCalls.Action :=
  ⟨6,caller,0,0,0⟩

theorem selected_body_bindings :
    vaultDepositBody.semantic = .vaultDeposit ∧ vaultDepositBody.selector = 0x6e553f65 ∧
    accountingBeginHarvestBody.semantic = .accountingBeginHarvest ∧
      accountingBeginHarvestBody.selector = 0x1def7faa ∧
    accountingSplitHarvestBody.semantic = .accountingSplitHarvest ∧
      accountingSplitHarvestBody.selector = 0xad81f8c0 ∧
    vaultStartUnwindsBody.semantic = .vaultStartUnwinds ∧
      vaultStartUnwindsBody.selector = 0x1b727f39 ∧
    vaultPokeSettleBody.semantic = .vaultPokeSettle ∧
      vaultPokeSettleBody.selector = 0xe891ab49 := by decide

theorem selected_body_guard_prefixes :
    vaultDepositBody.guards = [vaultNonReentrant] ∧
    accountingBeginHarvestBody.guards = [accountingOnlyVault] ∧
    accountingSplitHarvestBody.guards = [accountingOnlyVault] ∧
    vaultStartUnwindsBody.guards = [vaultNonReentrant] ∧
    vaultPokeSettleBody.guards = [vaultNonReentrant] := by decide

theorem vaultDeposit_bound_model_preserves (caller receiver assets vault : Nat)
    (s : CallState PublicCalls.State) (h : PublicCalls.PublicInvariant s.data)
    (ha : PublicCalls.ValidSolidityAction s.data (vaultDepositAction caller receiver assets)) :
    DataPreserved PublicCalls.PublicInvariant
      (runGuards vaultDepositBody.guards caller vault s
        (rawPublicBody (vaultDepositAction caller receiver assets))) := by
  simpa only [BodyBinding.guards,vaultDepositBody] using
    guarded_raw_body_preserves .vault 0x6e553f65 caller vault s
      (vaultDepositAction caller receiver assets) h ha

theorem vaultStartUnwinds_bound_model_preserves (caller maximum vault : Nat)
    (s : CallState PublicCalls.State) (h : PublicCalls.PublicInvariant s.data)
    (ha : PublicCalls.ValidSolidityAction s.data (vaultStartUnwindsAction caller maximum)) :
    DataPreserved PublicCalls.PublicInvariant
      (runGuards vaultStartUnwindsBody.guards caller vault s
        (rawPublicBody (vaultStartUnwindsAction caller maximum))) := by
  simpa only [BodyBinding.guards,vaultStartUnwindsBody] using
    guarded_raw_body_preserves .vault 0x1b727f39 caller vault s
      (vaultStartUnwindsAction caller maximum) h ha

theorem vaultPokeSettle_bound_model_preserves (caller vault : Nat)
    (s : CallState PublicCalls.State) (h : PublicCalls.PublicInvariant s.data)
    (ha : PublicCalls.ValidSolidityAction s.data (vaultPokeSettleAction caller)) :
    DataPreserved PublicCalls.PublicInvariant
      (runGuards vaultPokeSettleBody.guards caller vault s
        (rawPublicBody (vaultPokeSettleAction caller))) := by
  simpa only [BodyBinding.guards,vaultPokeSettleBody] using
    guarded_raw_body_preserves .vault 0xe891ab49 caller vault s
      (vaultPokeSettleAction caller) h ha

structure BeginHarvestOutput where
  harvestUnits : Nat
  rewardUnits : Nat
  protocolUnits : Nat
  source : Nat
  protocol : Nat
  deriving DecidableEq, Repr

def beginHarvestOutput (available source protocol burned : Nat) : BeginHarvestOutput :=
  let slice := PublicCalls.harvestSlice available source protocol burned
  ⟨burned,slice.1,slice.2,source-slice.1,protocol-slice.2⟩

def beginHarvestTransition (openUnits available source protocol burned : Nat) : Option BeginHarvestOutput :=
  if openUnits != 0 || burned == 0 || available < burned then none
  else some (beginHarvestOutput available source protocol burned)

theorem accountingBeginHarvest_exact (available source protocol burned : Nat)
    (hburn : 0 < burned) (havailable : burned ≤ available) :
    beginHarvestTransition 0 available source protocol burned =
      some (beginHarvestOutput available source protocol burned) := by
  simp [beginHarvestTransition,Nat.ne_of_gt hburn,not_lt.mpr havailable]

theorem accountingBeginHarvest_reserve_bounds (available source protocol burned : Nat)
    (havailable : burned ≤ available) :
    let output := beginHarvestOutput available source protocol burned
    output.rewardUnits ≤ source ∧ output.protocolUnits ≤ protocol ∧
      output.source + output.rewardUnits = source ∧
      output.protocol + output.protocolUnits = protocol := by
  have hslice := PublicCalls.harvestSlice_bounds available source protocol burned havailable
  dsimp only [beginHarvestOutput]
  rw [Nat.sub_add_cancel hslice.1, Nat.sub_add_cancel hslice.2.1]
  exact ⟨hslice.1,hslice.2.1,rfl,rfl⟩

theorem accountingSplitHarvest_exact (collateral harvested rewards protocol fee : Nat) :
    let output := splitHarvest collateral harvested rewards protocol fee
    output = (collateral*rewards/harvested,
      collateral-collateral*rewards/harvested-collateral*protocol/harvested-
        (collateral-collateral*rewards/harvested-collateral*protocol/harvested)*fee/10000,
      collateral*protocol/harvested+
        (collateral-collateral*rewards/harvested-collateral*protocol/harvested)*fee/10000) := by
  rfl

theorem accountingSplitHarvest_bound_conserved (collateral harvested rewards protocol fee : Nat)
    (hr : rewards + protocol ≤ harvested) (hf : fee ≤ 10000) :
    let output := splitHarvest collateral harvested rewards protocol fee
    output.1 + output.2.1 + output.2.2 = collateral :=
  splitHarvest_conserved collateral harvested rewards protocol fee hr hf

end Juicer.Solidity
