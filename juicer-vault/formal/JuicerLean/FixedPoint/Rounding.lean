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

theorem take_displayed_exact (f t u s x left : ℕ)
    (h : take f t u s = some (x, left)) :
    fundedOf f t u - fundedOf f t left = s := by
  have hu : u ≠ 0 := by intro hz; simp [take, hz] at h
  simp only [take, beq_iff_eq, hu, ↓reduceIte] at h
  split at h
  · contradiction
  next hg =>
    split at h
    · contradiction
    next he =>
      simp only [Option.some.injEq, Prod.mk.injEq] at h
      rcases h with ⟨hx, hl⟩
      simp only [Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq, not_or] at hg
      simp only [bne_iff_ne, not_not] at he
      rw [hl] at he
      omega

theorem take_full_slice (f t u : ℕ) (hs : 0 < fundedOf f t u) :
    take f t u (fundedOf f t u) = some (u, 0) := by
  have hu : u ≠ 0 := by intro h; simp [fundedOf, h] at hs
  have hc : ceilDiv (u * fundedOf f t u) (fundedOf f t u) = u := by
    simpa [ceilDiv, Nat.mul_comm] using (smul_ceilDiv hs u)
  have hz : ceilDiv 0 f = 0 := by simp [ceilDiv]
  have hfz : fundedOf f t 0 = 0 := by simp [fundedOf]
  simp [take, hu, Nat.ne_of_gt hs, hc, hz, hfz]

theorem remaining_units_bound (f t u s : ℕ) (hf : 0 < f) :
    ceilDiv ((f * u / t - s) * t) f ≤ u := by
  apply (ceilDiv_le_iff_le_smul hf).2
  change (f * u / t - s) * t ≤ f * u
  exact (Nat.mul_le_mul_right t (Nat.sub_le _ _)).trans (Nat.div_mul_le_self _ _)

theorem fine_remaining_exact (f t k : ℕ) (hf : 0 < f) (hft : f ≤ t) :
    f * ceilDiv (k * t) f / t = k := by
  have ht : 0 < t := lt_of_lt_of_le hf hft
  have hb := ceilDiv_bounds (k * t) f hf
  apply Nat.le_antisymm
  · apply Nat.le_of_lt_succ
    apply (Nat.div_lt_iff_lt_mul ht).2
    nlinarith
  · apply (Nat.le_div_iff_mul_le ht).2
    nlinarith

theorem proportional_remaining_bound (f t u s : ℕ) (ht : 0 < t)
    (hs : 0 < f * u / t) (hreq : s ≤ f * u / t) :
    f * (u - ceilDiv (u * s) (f * u / t)) / t ≤ f * u / t - s := by
  let q := f * u / t
  let x := ceilDiv (u * s) q
  have hq : 0 < q := hs
  have hs' : s ≤ q := hreq
  have hx : x ≤ u := by
    apply (ceilDiv_le_iff_le_smul hq).2
    change u * s ≤ q * u
    nlinarith
  have hb := ceilDiv_bounds (u * s) q hq
  change u * s ≤ x * q ∧ x * q < u * s + q at hb
  have hf := mulDiv_bounds f u t ht
  have he : (u - x) + x = u := Nat.sub_add_cancel hx
  have heq : (q - s) + s = q := Nat.sub_add_cancel hs'
  have h1 : (f * (u - x)) * q ≤ (f * u) * (q - s) := by
    nlinarith [Nat.mul_le_mul_left f hb.1,
      congrArg (fun n => f * n * q) he, congrArg (fun n => f * u * n) heq]
  have h2 : (f * u) * (q - s) < ((q - s + 1) * t) * q := by
    by_cases hz : q - s = 0
    · simpa only [hz, mul_zero, zero_add, one_mul] using Nat.mul_pos ht hq
    · have hm := Nat.mul_lt_mul_of_pos_right hf.2 (Nat.pos_of_ne_zero hz)
      change f * u * (q - s) < (q + 1) * t * (q - s) at hm
      nlinarith [congrArg (fun n => n * t) heq]
  have h3 : f * (u - x) < (q - s + 1) * t := by
    nlinarith
  apply Nat.le_of_lt_succ
  exact (Nat.div_lt_iff_lt_mul ht).2 h3

theorem capped_remaining_exact (f t u s : ℕ) (hf : 0 < f) (ht : 0 < t)
    (hs : 0 < f * u / t) (hreq : s ≤ f * u / t)
    (hrep : f * ceilDiv ((f * u / t - s) * t) f / t = f * u / t - s) :
    f * (u - min (u - ceilDiv ((f * u / t - s) * t) f)
      (ceilDiv (u * s) (f * u / t))) / t = f * u / t - s := by
  have hb := remaining_units_bound f t u s hf
  have hp := proportional_remaining_bound f t u s ht hs hreq
  by_cases hcmp : u - ceilDiv ((f * u / t - s) * t) f ≤ ceilDiv (u * s) (f * u / t)
  · rw [min_eq_left hcmp, Nat.sub_sub_self hb]
    exact hrep
  · rw [min_eq_right (by omega : ceilDiv (u * s) (f * u / t) ≤
        u - ceilDiv ((f * u / t - s) * t) f)]
    have hr : ceilDiv ((f * u / t - s) * t) f ≤ u - ceilDiv (u * s) (f * u / t) := by omega
    have hm := Nat.div_le_div_right (Nat.mul_le_mul_left f hr) (c := t)
    omega

theorem take_representable (f t u s : ℕ) (hf : 0 < f) (ht : 0 < t)
    (hs : 0 < f * u / t) (hreq : s ≤ f * u / t)
    (hrep : f * ceilDiv ((f * u / t - s) * t) f / t = f * u / t - s) :
    (take f t u s).isSome = true := by
  have hu : u ≠ 0 := by intro hz; simp [hz] at hs
  have he := capped_remaining_exact f t u s hf ht hs hreq hrep
  simp [take, fundedOf, hu, Nat.ne_of_gt ht, Nat.ne_of_gt hs, Nat.not_lt.mpr hreq, he]

theorem take_fine_available (f t u s : ℕ) (hf : 0 < f) (hft : f ≤ t)
    (hs : 0 < f * u / t) (hreq : s ≤ f * u / t) :
    (take f t u s).isSome = true := by
  exact take_representable f t u s hf (lt_of_lt_of_le hf hft) hs hreq
    (fine_remaining_exact f t (f * u / t - s) hf hft)

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

theorem take_credit_allowance_bound (f t u v s x left : ℕ) (ht : 0 < t)
    (h : take f t u s = some (x, left)) :
    let credit := f * (v + x) / t - f * v / t
    s ≤ credit + 1 ∧ credit ≤ s + 1 := by
  have hc := take_conserves f t u s x left h
  have hd := take_displayed_exact f t u s x left h
  have hx : x ≤ u := by omega
  have hl : left = u - x := by omega
  have hb := transfer_discrepancy_at_most_one f t u v x ht hx
  have he : f * u / t - f * (u - x) / t = s := by
    simpa [fundedOf, Nat.ne_of_gt ht, hl] using hd
  simpa only [he] using hb

theorem coarse_partial_rejected (f s : ℕ) (hs : 0 < s) (hf : s < f) :
    take f 1 1 s = none := by
  have hp : 0 < f := by omega
  have hr : ceilDiv (f - s) f = 1 := by
    apply Nat.le_antisymm
    · apply (ceilDiv_le_iff_le_smul hp).2
      change f - s ≤ f * 1
      omega
    · have hb := (ceilDiv_bounds (f - s) f hp).1
      by_contra h
      have hz : ceilDiv (f - s) f = 0 := by omega
      simp [hz] at hb
      omega
  simp [take, fundedOf, Nat.ne_of_gt hp, show ¬f < s by omega, hr]
  omega

end Juicer.Runtime
