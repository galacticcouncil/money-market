import JuicerLean.FixedPoint.Runtime

namespace Juicer.Runtime

theorem mulDiv_bounds (a b d : ℕ) (hd : 0 < d) :
    (a * b / d) * d ≤ a * b ∧ a * b < (a * b / d + 1) * d := by
  exact ⟨Nat.div_mul_le_self _ _, by simpa [Nat.mul_comm] using Nat.lt_mul_div_succ (a * b) hd⟩

theorem ceilDiv_bounds (a d : ℕ) (hd : 0 < d) :
    a ≤ ceilDiv a d * d ∧ ceilDiv a d * d < a + d := by
  constructor
  · simpa [ceilDiv, Nat.mul_comm] using (le_smul_ceilDiv (b := a) hd)
  · have h := Nat.div_mul_le_self (a + d - 1) d
    simp only [ceilDiv, Nat.ceilDiv_eq_add_pred_div]
    omega

theorem take_exact_units (f t u s : ℕ) (hs : 0 < f * u / t) (h : s ≤ f * u / t) :
    take f t u s = some (ceilDiv (u * s) (f * u / t),
      u - ceilDiv (u * s) (f * u / t)) := by
  have hu : u ≠ 0 := by intro he; simp [he] at hs
  have hc : ceilDiv (u * s) (f * u / t) ≤ u := by
    apply (ceilDiv_le_iff_le_smul hs).2
    change u * s ≤ (f * u / t) * u
    nlinarith
  simp [take, fundedOf, hu, Nat.ne_of_gt hs]
  split <;> simp_all

theorem transfer_debit_refines (f t u x : ℕ) (ht : 0 < t) (hx : x ≤ u) :
    f * x / t ≤ f * u / t - f * (u - x) / t ∧
    f * u / t - f * (u - x) / t ≤ ceilDiv (f * x) t := by
  have h1 := mulDiv_bounds f u t ht
  have h2 := mulDiv_bounds f (u - x) t ht
  have h3 := mulDiv_bounds f x t ht
  have h4 := (ceilDiv_bounds (f * x) t ht).1
  have he : f * (u - x) + f * x = f * u := by rw [← Nat.mul_add, Nat.sub_add_cancel hx]
  have hm := Nat.div_le_div_right (Nat.mul_le_mul_left f (Nat.sub_le u x)) (c := t)
  have hd := Nat.sub_add_cancel hm
  constructor <;> nlinarith

theorem transfer_credit_refines (f t v x : ℕ) (ht : 0 < t) :
    f * x / t ≤ f * (v + x) / t - f * v / t ∧
    f * (v + x) / t - f * v / t ≤ ceilDiv (f * x) t := by
  simpa using transfer_debit_refines f t (v + x) x ht (by omega)

theorem transfer_discrepancy_at_most_one (f t u v x : ℕ) (ht : 0 < t) (hx : x ≤ u) :
    let debit := f * u / t - f * (u - x) / t
    let credit := f * (v + x) / t - f * v / t
    debit ≤ credit + 1 ∧ credit ≤ debit + 1 := by
  have h1 := transfer_debit_refines f t u x ht hx
  have h2 := transfer_credit_refines f t v x ht
  have hc : ceilDiv (f * x) t ≤ f * x / t + 1 := by
    apply (ceilDiv_le_iff_le_smul ht).2
    change f * x ≤ t * (f * x / t + 1)
    exact Nat.le_of_lt (Nat.lt_mul_div_succ _ ht)
  dsimp
  omega

theorem mulDiv_real_refines (a b d : ℕ) (hd : 0 < d) :
    (a * b / d : ℕ) ≤ (a : ℝ) * b / d ∧
    (a : ℝ) * b / d < (a * b / d : ℕ) + 1 := by
  have h := mulDiv_bounds a b d hd
  have hdR : (0 : ℝ) < d := by exact_mod_cast hd
  constructor
  · apply (le_div_iff₀ hdR).2
    exact_mod_cast h.1
  · apply (div_lt_iff₀ hdR).2
    exact_mod_cast h.2

theorem take_displayed_bound (f t u s x left : ℕ) (ht : 0 < t)
    (h : take f t u s = some (x, left)) :
    f * x / t ≤ f * u / t - f * left / t ∧
      f * u / t - f * left / t ≤ ceilDiv (f * x) t := by
  have hc := take_conserves f t u s x left h
  have hx : x ≤ u := by omega
  have hl : left = u - x := by omega
  rw [hl]
  exact transfer_debit_refines f t u x ht hx

theorem unit_granularity_unbounded (f : ℕ) (hf : 0 < f) :
    take f 1 1 1 = some (1, 0) ∧ fundedOf f 1 1 - fundedOf f 1 0 = f := by
  have hc : ceilDiv 1 f = 1 := by
    simp only [ceilDiv, Nat.ceilDiv_eq_add_pred_div]
    simpa using Nat.div_self hf
  simp [take, fundedOf, hc, Nat.ne_of_gt hf, show ¬ f < 1 by omega]

end Juicer.Runtime
