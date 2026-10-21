import JuicerLean.Spec.Floor
import JuicerLean.FixedPoint.Refine

/-!
# Juicer — worked examples (spec-fidelity cross-check)

Concrete instantiations of the headline theorems on realistic Juicer parameters, so the abstract
claims can be read against real numbers (and so the hypotheses are demonstrably *satisfiable*, not
vacuous). Mirrors the plan's "confirm the Lean theorems' hypotheses match the tested states".

The example position: 1 ETH collateral at 2000 HOLLAR, Aave `ltColl = 0.80`, borrowed near max LTV
to `mainDebt = 980`; the synthetic reserve has `ltSynth = 0.98` and is minted to `synth = 1005`, so
`synth·ltSynth = 1005·0.98 = 984.9 = 980·1.005` — the spec's `1.005` buffer exactly.
-/

namespace Juicer
namespace Examples

open Juicer.State Juicer.FixedPoint

/-- A concrete, realistic Juicer Main position (loop fields irrelevant to the floor set to 0). -/
noncomputable def ethPosition : State where
  coll := 1
  price := 2000
  ltColl := 0.8
  ltvColl := 0.75
  synth := 1005
  ltSynth := 0.98
  ltvSynth := 0.01
  mainDebt := 980
  primeAmt := 0
  primePrice := 0
  ltPrime := 0
  subDebt := 0
  shares := 0
  escrowShares := 0

theorem ethPosition_wf : WellFormed ethPosition where
  coll_nonneg := by norm_num [ethPosition]
  price_nonneg := by norm_num [ethPosition]
  ltColl_nonneg := by norm_num [ethPosition]
  ltColl_le_one := by norm_num [ethPosition]
  ltSynth_pos := by norm_num [ethPosition]
  synth_nonneg := by norm_num [ethPosition]
  mainDebt_pos := by norm_num [ethPosition]
  ltvSynth_nonneg := by norm_num [ethPosition]

theorem ethPosition_floored : ethPosition.principalFloored :=
  peg_floored ethPosition 1.005 (by norm_num)
    (by norm_num [ethPosition]) (by norm_num [ethPosition])

/-- The headline, concretely: this position has `mainHF ≥ 1`. -/
theorem ethPosition_safe : 1 ≤ ethPosition.mainHF :=
  floor_main_hf ethPosition ethPosition_wf ethPosition_floored

/-- And it stays safe at a **total collateral wipeout** (`price = 0`): a bare max-LTV borrow would be
deep underwater here, but the synthetic floor keeps `mainHF ≥ 1`. -/
theorem ethPosition_safe_at_zero_price :
    1 ≤ ({ethPosition with price := 0} : State).mainHF :=
  never_liquidated_at_any_price ethPosition ethPosition_wf ethPosition_floored 0 (by norm_num)

/-! ### Integer re-peg: even one wei is covered -/

def dustyPosition : IState where
  synthWad := 0
  ltSynthBps := 9800
  mainDebtWad := 1

theorem dustyPosition_repeg_floored : dustyPosition.repegSynth.principalFloored :=
  repeg_principalFloored dustyPosition (by norm_num [dustyPosition])

theorem dustyPosition_mints_two : dustyPosition.repegSynth.synthWad = 2 := by
  norm_num [dustyPosition, IState.repegSynth, Runtime.buffered, Runtime.ceilDiv,
    Nat.ceilDiv_eq_add_pred_div]

/-! ### Solidity test-suite scenarios (cross-check)

The Solidity fuzz/unit tests exercise specific states; these examples confirm the Lean theorems cover
them one-to-one — `−99% ETH`, `deploy → subHF = 1.05`, and `full unwind returns principal`. -/

/-- "−99% ETH" crash test: at 1% of the deposit price the principal is still floored. -/
theorem ethPosition_safe_at_minus99 :
    1 ≤ ({ethPosition with price := 20} : State).mainHF :=
  never_liquidated_at_any_price ethPosition ethPosition_wf ethPosition_floored 20 (by norm_num)

/-- A concrete PRIME-loop position deployed at the target health factor `subHF = 1.05`
(`primeAmt·primePrice·ltPrime / subDebt = 1050·1·1 / 1000`). -/
noncomputable def loopPosition : State where
  coll := 1
  price := 2000
  ltColl := 0.8
  ltvColl := 0.75
  synth := 1005
  ltSynth := 0.98
  ltvSynth := 0.01
  mainDebt := 500
  primeAmt := 1050
  primePrice := 1
  ltPrime := 1
  subDebt := 1000
  shares := 0
  escrowShares := 0

/-- "deploy → HF 1.05": the loop sits exactly at the 1.05 deploy target. -/
theorem loopPosition_subHF : loopPosition.subHF = 1.05 := by
  norm_num [State.subHF, loopPosition]

theorem loopPosition_healthy : loopPosition.subLoopHealthy 1.05 := by
  unfold State.subLoopHealthy
  exact le_of_eq loopPosition_subHF.symm

/-- A matured loop (debt paid down to 200) whose value-stable equity now covers the Main debt:
`loopEquity = 1050·1 − 200 = 850 ≥ 500 = mainDebt`. -/
noncomputable def maturePosition : State := { loopPosition with subDebt := 200 }

theorem maturePosition_freedBacked : maturePosition.freedBacked := by
  simp only [State.freedBacked, State.loopEquity, maturePosition, loopPosition]
  norm_num

/-- "full unwind returns principal": on the matured, freed-backed position a full unwind returns at
least the deposited collateral. -/
theorem maturePosition_unwind : maturePosition.coll ≤ maturePosition.collateralReturned :=
  collateral_out_ge_in maturePosition maturePosition_freedBacked

end Examples
end Juicer
