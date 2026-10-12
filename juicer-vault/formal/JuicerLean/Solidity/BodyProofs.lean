import JuicerLean.Solidity.GeneratedBodies

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

end Juicer.Solidity
