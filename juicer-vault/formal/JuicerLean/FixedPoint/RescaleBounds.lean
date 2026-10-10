import JuicerLean.FixedPoint.LazyOwnership

namespace Juicer.Runtime

variable {precision : ℕ}

theorem rescale_slack_recurrence (l : LazyLedger precision) (k : ℕ) :
    (l.rescale k).slack =
      (l.total % 2 ^ k * precision + l.slack) / 2 ^ k := by
  rfl

theorem rescale_slack_lt_precision (l : LazyLedger precision) (k : ℕ)
    (he : l.slack < precision) :
    (l.rescale k).slack < precision := by
  have hd : 0 < 2 ^ k := by positivity
  have ht := Nat.mod_lt l.total hd
  rw [rescale_slack_recurrence]
  apply (Nat.div_lt_iff_lt_mul hd).2
  nlinarith

theorem lazy_step_slack_lt_precision {a b : LazyLedger precision}
    (step : a.Step b) (hr : 0 < precision) (h : a.slack < precision) :
    b.slack < precision := by
  cases step with
  | ordinary step => simpa [lazy_plain_step_slack _ _ step] using h
  | rescale k => exact rescale_slack_lt_precision a k h
  | writeOff => simpa [LazyLedger.writeOff] using hr

theorem lazy_trace_slack_lt_precision {a b : LazyLedger precision}
    (steps : Relation.ReflTransGen LazyLedger.Step a b)
    (hr : 0 < precision) (h : a.slack < precision) : b.slack < precision := by
  induction steps with
  | refl => exact h
  | tail _ step ih => exact lazy_step_slack_lt_precision step hr ih

theorem lazy_genesis_trace_no_overclaim (weights : List ℕ) (b : LazyLedger precision)
    (hr : 0 < precision)
    (steps : Relation.ReflTransGen LazyLedger.Step (LazyLedger.genesis weights) b) :
    (b.accounts.map (LazyAccount.claim b.total b.index)).sum ≤ b.total := by
  have hb := lazy_trace_preserves _ _ (lazy_genesis_valid weights) steps
  have he := lazy_trace_slack_lt_precision steps hr (by simpa [LazyLedger.genesis] using hr)
  have hc := lazy_claims_bound b hb hr
  simpa [Nat.div_eq_of_lt he] using hc

theorem lazy_genesis_funded_no_overclaim (weights : List ℕ) (b : LazyLedger precision)
    (funded : ℕ) (hr : 0 < precision) (ht : 0 < b.total)
    (steps : Relation.ReflTransGen LazyLedger.Step (LazyLedger.genesis weights) b) :
    ((b.accounts.map (LazyAccount.claim b.total b.index)).map
      (fun u => funded * u / b.total)).sum ≤ funded := by
  simpa using pooled_claims_bound funded b.total 0 _ ht
    (lazy_genesis_trace_no_overclaim weights b hr steps)

theorem one_rescale_allocation_floor (total outside denominator : ℕ)
    (hd : 0 < denominator)
    (htrigger : 2 ^ 160 * denominator / max denominator outside < total) :
    2 ^ 96 ≤ total / 2 ^ 64 + outside * (total / 2 ^ 64 + 1) / denominator := by
  have hshift : 0 < 2 ^ 64 := by positivity
  by_cases ho : outside ≤ denominator
  · rw [max_eq_left ho] at htrigger
    have hlimit : 2 ^ 160 * denominator / denominator = 2 ^ 160 := by
      exact Nat.mul_div_left (2 ^ 160) hd
    rw [hlimit] at htrigger
    have hpow : 2 ^ 96 * 2 ^ 64 = 2 ^ 160 := by norm_num [Nat.pow_add]
    have hq : 2 ^ 96 ≤ total / 2 ^ 64 := by
      apply (Nat.le_div_iff_mul_le hshift).2
      rw [hpow]
      exact htrigger.le
    exact hq.trans (Nat.le_add_right _ _)
  · have hdo : denominator < outside := Nat.lt_of_not_ge ho
    rw [max_eq_right hdo.le] at htrigger
    have hproduct : 2 ^ 160 * denominator < total * outside :=
      (Nat.div_lt_iff_lt_mul (by omega : 0 < outside)).1 htrigger
    have hnext := Nat.lt_div_mul_add (a := total) (b := 2 ^ 64) hshift
    have hpow : 2 ^ 160 = 2 ^ 96 * 2 ^ 64 := by norm_num [Nat.pow_add]
    have hm : 2 ^ 96 * denominator ≤ outside * (total / 2 ^ 64 + 1) := by
      rw [hpow] at hproduct
      nlinarith
    have hmint : 2 ^ 96 ≤ outside * (total / 2 ^ 64 + 1) / denominator :=
      (Nat.le_div_iff_mul_le hd).2 hm
    exact hmint.trans (Nat.le_add_left _ _)

end Juicer.Runtime
