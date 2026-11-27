import JuicerLean.FixedPoint.Uint256
import JuicerLean.Spec.Floor
import JuicerLean.Spec.SubLoop

/-!
# Juicer — fixed-point refinement (Phase 3)

The bridge between the on-chain integer guard and the real-valued safety spec.

`principalFloored_refines` — if the **integer** `principalFloored` check (flooring
mul-div) passes, then the **real** `principalFloored` holds on the embedded state.
Floor division *underestimates* the synthetic's value, so satisfying the on-chain
guard is strictly stronger than the real inequality: rounding is conservative, and
the floor never rounds the wrong way.

`refined_floor_hf` — therefore the integer guard, via the real floor theorem,
delivers `mainHF ≥ 1` (modulo the real `WellFormed` side-conditions).
-/

namespace Juicer
namespace FixedPoint

open Juicer.State

theorem principalFloored_refines (s : IState) (h : s.principalFloored) :
    (s.toReal).principalFloored := by
  have hBps : (0 : ℝ) < (Bps : ℝ) := by norm_num [Bps]
  have hWad : (0 : ℝ) < (Wad : ℝ) := by norm_num [Wad]
  -- unpack the integer guard, cast through the flooring mul-div conservatively
  unfold IState.principalFloored IState.synthValueWad at h
  have H : (s.mainDebtWad : ℝ) ≤ (s.synthWad * s.ltSynthBps : ℝ) / (Bps : ℝ) := by
    calc (s.mainDebtWad : ℝ)
        ≤ ((s.synthWad * s.ltSynthBps / Bps : ℕ) : ℝ) := by exact_mod_cast h
      _ ≤ ((s.synthWad * s.ltSynthBps : ℕ) : ℝ) / (Bps : ℝ) := Nat.cast_div_le
      _ = (s.synthWad * s.ltSynthBps : ℝ) / (Bps : ℝ) := by push_cast; ring
  -- mainDebtWad * Bps ≤ synthWad * ltSynthBps  (clear the floor's denominator)
  rw [le_div_iff₀ hBps] at H
  have hWne : (Wad : ℝ) ≠ 0 := ne_of_gt hWad
  -- goal: real principalFloored on toReal
  show ((s.mainDebtWad : ℝ) / Wad) ≤ ((s.synthWad : ℝ) / Wad) * ((s.ltSynthBps : ℝ) / Bps)
  rw [div_mul_div_comm, le_div_iff₀ (by positivity : (0 : ℝ) < (Wad : ℝ) * (Bps : ℝ))]
  -- goal: (mainDebtWad/Wad) * (Wad*Bps) ≤ synthWad*ltSynthBps ; cancel Wad on the left
  have hcancel :
      (s.mainDebtWad : ℝ) / Wad * ((Wad : ℝ) * (Bps : ℝ)) = (s.mainDebtWad : ℝ) * Bps := by
    rw [div_mul_eq_mul_div, mul_comm (Wad : ℝ) (Bps : ℝ), ← mul_assoc, mul_div_assoc,
        div_self hWne, mul_one]
  rw [hcancel]
  exact H

/-- The integer guard implies the real Main health-factor floor, given the real-side
well-formedness conditions on the embedded state. -/
theorem refined_floor_hf (s : IState) (wf : WellFormed s.toReal)
    (h : s.principalFloored) :
    1 ≤ (s.toReal).mainHF :=
  floor_main_hf _ wf (principalFloored_refines s h)

/-! ## Loop-side refinement (`freedBacked`, `accrueLoop`)

The same conservative-rounding bridge for the loop: the on-chain loop-collateral value uses a
**flooring** WAD mul-div, which *underestimates* the true `primeAmt·primePrice`, so passing the
integer `freedBacked` predicate is strictly stronger than the real inequality. And the on-chain
`accrueLoop` (integer add to `primeAmtWad`) **refines** the spec's `State.accrueLoop` exactly: the
embedding commutes, `(s.accrueLoop g).toReal = (s.toReal).accrueLoop (g/Wad)`. -/

theorem freedBacked_refines (s : IState) (h : s.freedBacked) : (s.toReal).freedBacked := by
  have hWad : (0 : ℝ) < (Wad : ℝ) := by norm_num [Wad]
  unfold IState.freedBacked IState.loopCollWad at h
  -- cast the floored product up, conservatively: floor ≤ real quotient
  have H : (s.mainDebtWad : ℝ) + (s.subDebtWad : ℝ)
      ≤ (s.primeAmtWad : ℝ) * (s.primePriceWad : ℝ) / Wad := by
    calc (s.mainDebtWad : ℝ) + (s.subDebtWad : ℝ)
        = ((s.mainDebtWad + s.subDebtWad : ℕ) : ℝ) := by push_cast; ring
      _ ≤ ((s.primeAmtWad * s.primePriceWad / Wad : ℕ) : ℝ) := by exact_mod_cast h
      _ ≤ ((s.primeAmtWad * s.primePriceWad : ℕ) : ℝ) / Wad := Nat.cast_div_le
      _ = (s.primeAmtWad : ℝ) * (s.primePriceWad : ℝ) / Wad := by push_cast; ring
  -- goal: real freedBacked on the embedded state
  show ((s.mainDebtWad : ℝ) / Wad)
      ≤ ((s.primeAmtWad : ℝ) / Wad) * ((s.primePriceWad : ℝ) / Wad) - (s.subDebtWad : ℝ) / Wad
  rw [le_sub_iff_add_le, ← add_div, div_mul_div_comm, ← div_div]
  gcongr

/-- **The on-chain `accrueLoop` refines the spec's.** Crediting `gWad` aPRIME on the integer state,
then embedding, equals embedding then crediting `gWad/Wad` aPRIME in the real spec — the refinement
diagram commutes. -/
theorem accrueLoop_toReal (s : IState) (gWad : ℕ) :
    (s.accrueLoop gWad).toReal = (s.toReal).accrueLoop ((gWad : ℝ) / Wad) := by
  unfold IState.accrueLoop IState.toReal State.accrueLoop
  congr 1
  push_cast
  ring

/-- **Loop refinement payoff.** If the integer `freedBacked` predicate passes after on-chain yield, the
real spec state after the corresponding yield is `freedBacked`. -/
theorem accrueLoop_freedBacked_refines (s : IState) (gWad : ℕ)
    (h : (s.accrueLoop gWad).freedBacked) :
    ((s.toReal).accrueLoop ((gWad : ℝ) / Wad)).freedBacked := by
  rw [← accrueLoop_toReal]
  exact freedBacked_refines _ h

/-! ## Current synthetic mint: ceil coverage, then add the buffer -/

theorem repeg_principalFloored (s : IState) (hL : 0 < s.ltSynthBps) :
    s.repegSynth.principalFloored := by
  exact Juicer.Runtime.buffered_floors s.mainDebtWad s.ltSynthBps hL

theorem repeg_floor_refines (s : IState) (hL : 0 < s.ltSynthBps) :
    s.repegSynth.toReal.principalFloored :=
  principalFloored_refines _ (repeg_principalFloored s hL)

/-! ## Sub-loop health refinement (`subLoopHealthy`)

The loop's liquidation check, the last dividing invariant. The on-chain guard is the **cleared** form
`tBps·subDebtWad ≤ loopColl·ltPrimeBps` (one floor on `loopColl`); passing it implies the real
`t ≤ subHF` with `t = tBps/Bps`, since the floored loop collateral *underestimates* the true value. -/

theorem subLoopHealthy_refines (s : IState) (tBps : ℕ)
    (hSub : 0 < s.subDebtWad) (h : s.subLoopHealthy tBps) :
    (s.toReal).subLoopHealthy ((tBps : ℝ) / Bps) := by
  have hWad : (0 : ℝ) < (Wad : ℝ) := by norm_num [Wad]
  have hBps : (0 : ℝ) < (Bps : ℝ) := by norm_num [Bps]
  have hWne : (Wad : ℝ) ≠ 0 := hWad.ne'
  have hSubR : (0 : ℝ) < (s.subDebtWad : ℝ) := by exact_mod_cast hSub
  unfold IState.subLoopHealthy IState.loopCollWad at h
  -- step 1: cast the integer guard, underestimating via the floor
  have hcast : ((s.primeAmtWad * s.primePriceWad / Wad : ℕ) : ℝ)
      ≤ (s.primeAmtWad : ℝ) * s.primePriceWad / Wad := by
    calc ((s.primeAmtWad * s.primePriceWad / Wad : ℕ) : ℝ)
        ≤ ((s.primeAmtWad * s.primePriceWad : ℕ) : ℝ) / Wad := Nat.cast_div_le
      _ = (s.primeAmtWad : ℝ) * s.primePriceWad / Wad := by push_cast; ring
  have Hr : (tBps : ℝ) * s.subDebtWad
      ≤ (s.primeAmtWad : ℝ) * s.primePriceWad / Wad * s.ltPrimeBps := by
    calc (tBps : ℝ) * s.subDebtWad = ((tBps * s.subDebtWad : ℕ) : ℝ) := by push_cast; ring
      _ ≤ ((s.primeAmtWad * s.primePriceWad / Wad * s.ltPrimeBps : ℕ) : ℝ) := by exact_mod_cast h
      _ = ((s.primeAmtWad * s.primePriceWad / Wad : ℕ) : ℝ) * s.ltPrimeBps := by push_cast; ring
      _ ≤ (s.primeAmtWad : ℝ) * s.primePriceWad / Wad * s.ltPrimeBps :=
            mul_le_mul_of_nonneg_right hcast (Nat.cast_nonneg _)
  -- step 2: clear the /Wad
  have Hclear : (tBps : ℝ) * s.subDebtWad * Wad
      ≤ (s.primeAmtWad : ℝ) * s.primePriceWad * s.ltPrimeBps := by
    have h2 := mul_le_mul_of_nonneg_right Hr hWad.le
    have e : (s.primeAmtWad : ℝ) * s.primePriceWad / Wad * s.ltPrimeBps * Wad
        = (s.primeAmtWad : ℝ) * s.primePriceWad * s.ltPrimeBps := by field_simp
    calc (tBps : ℝ) * s.subDebtWad * Wad
        = (tBps : ℝ) * s.subDebtWad * Wad := rfl
      _ ≤ (s.primeAmtWad : ℝ) * s.primePriceWad / Wad * s.ltPrimeBps * Wad := by
            have hcomm : (tBps : ℝ) * s.subDebtWad * Wad = ((tBps : ℝ) * s.subDebtWad) * Wad := by
              ring
            rw [hcomm]; exact h2
      _ = (s.primeAmtWad : ℝ) * s.primePriceWad * s.ltPrimeBps := e
  -- step 3: discharge the real division
  show (tBps : ℝ) / Bps ≤ (s.toReal).subHF
  simp only [State.subHF, IState.toReal]
  rw [le_div_iff₀ (div_pos hSubR hWad), div_mul_div_comm, div_mul_div_comm, div_mul_div_comm,
      div_le_iff₀ (mul_pos hBps hWad), div_mul_eq_mul_div,
      le_div_iff₀ (mul_pos (mul_pos hWad hWad) hBps)]
  nlinarith [mul_le_mul_of_nonneg_right Hclear (mul_nonneg hWad.le hBps.le)]

end FixedPoint
end Juicer
