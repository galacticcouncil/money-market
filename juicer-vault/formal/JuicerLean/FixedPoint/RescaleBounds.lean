import JuicerLean.FixedPoint.LazyOwnership

namespace Juicer.Runtime

variable {precision : ℕ}

theorem rescale_slack_remainder (l : LazyLedger precision) (k : ℕ) :
    (l.rescale k).slack ≤
      (l.total % 2 ^ k * precision + l.slack) / 2 ^ k + lazyWeight l.accounts := by
  have hd : 0 < 2 ^ k := by positivity
  have hw := Nat.mul_le_mul_left (lazyWeight l.accounts) (Nat.sub_le (2 ^ k) 1)
  calc
    _ ≤ (l.total % 2 ^ k * precision + l.slack + lazyWeight l.accounts * 2 ^ k) / 2 ^ k :=
      Nat.div_le_div_right (Nat.add_le_add_left hw _)
    _ = _ := Nat.add_mul_div_right _ _ hd

theorem rescale_slack_contracts (l : LazyLedger precision) (k : ℕ) :
    (l.rescale k).slack ≤ l.slack / 2 ^ k + precision + lazyWeight l.accounts := by
  let d := 2 ^ k
  have hd : 0 < d := by dsimp [d]; positivity
  have ht := Nat.mod_lt l.total hd
  have he := Nat.mod_lt l.slack hd
  have hdiv := Nat.div_add_mod l.slack d
  have htotal : l.total % d ≤ d - 1 := by omega
  have hweight : lazyWeight l.accounts * (d - 1) ≤ lazyWeight l.accounts * d :=
    Nat.mul_le_mul_left _ (Nat.sub_le _ _)
  have hprecision := Nat.mul_le_mul_right precision htotal
  have hden : d - 1 + 1 = d := by omega
  change (l.total % d * precision + l.slack + lazyWeight l.accounts * (d - 1)) / d ≤ _
  change (l.total % d * precision + l.slack + lazyWeight l.accounts * (d - 1)) / d ≤
    l.slack / d + precision + lazyWeight l.accounts
  apply (Nat.div_le_iff_le_mul hd).2
  have hbound : 1 ≤ (l.slack / d + precision + lazyWeight l.accounts) * d + d := by omega
  have hcancel := Nat.sub_add_cancel hbound
  nlinarith

theorem rescale_slack_uniform (l : LazyLedger precision) (k cap : ℕ)
    (hk : 0 < k) (hw : lazyWeight l.accounts ≤ cap)
    (he : l.slack ≤ 2 * (precision + cap)) :
    (l.rescale k).slack ≤ 2 * (precision + cap) := by
  have hd : 2 ≤ 2 ^ k := by
    calc
      2 = 2 ^ 1 := by norm_num
      _ ≤ 2 ^ k := Nat.pow_le_pow_right (by omega) hk
  have hmul := Nat.div_mul_le_self l.slack (2 ^ k)
  have hsmall : l.slack / 2 ^ k ≤ precision + cap := by nlinarith
  have hb := rescale_slack_contracts l k
  omega

inductive LazyLedger.BoundedStep (cap : ℕ) : LazyLedger precision → LazyLedger precision → Prop
  | ordinary {a b} (step : a.PlainStep b) : BoundedStep cap a b
  | rescale (a) (k : ℕ) (hk : 0 < k) (hw : lazyWeight a.accounts ≤ cap) :
      BoundedStep cap a (a.rescale k)
  | writeOff (a) : BoundedStep cap a a.writeOff

theorem bounded_step_is_step {cap : ℕ} {a b : LazyLedger precision}
    (step : LazyLedger.BoundedStep cap a b) : a.Step b := by
  cases step with
  | ordinary step => exact .ordinary step
  | rescale k _ _ => exact .rescale a k
  | writeOff => exact .writeOff a

theorem bounded_step_slack {cap : ℕ} {a b : LazyLedger precision}
    (step : LazyLedger.BoundedStep cap a b) (h : a.slack ≤ 2 * (precision + cap)) :
    b.slack ≤ 2 * (precision + cap) := by
  cases step with
  | ordinary step => simpa [lazy_plain_step_slack _ _ step] using h
  | rescale k hk hw => exact rescale_slack_uniform a k cap hk hw h
  | writeOff => simp [LazyLedger.writeOff]

theorem bounded_trace_slack {cap : ℕ} {a b : LazyLedger precision}
    (steps : Relation.ReflTransGen (LazyLedger.BoundedStep cap) a b)
    (h : a.slack ≤ 2 * (precision + cap)) : b.slack ≤ 2 * (precision + cap) := by
  induction steps with
  | refl => exact h
  | tail _ step ih => exact bounded_step_slack step ih

theorem bounded_genesis_claims (weights : List ℕ) (b : LazyLedger precision) (cap : ℕ)
    (hr : 0 < precision)
    (steps : Relation.ReflTransGen (LazyLedger.BoundedStep cap) (LazyLedger.genesis weights) b) :
    (b.accounts.map (LazyAccount.claim b.total b.index)).sum ≤
      b.total + (2 * (precision + cap)) / precision := by
  have hb : b.valid := by
    induction steps with
    | refl => exact lazy_genesis_valid weights
    | tail _ step ih => exact lazy_step_preserves _ _ ih (bounded_step_is_step step)
  have he := bounded_trace_slack steps (by simp [LazyLedger.genesis])
  exact (lazy_claims_bound b hb hr).trans (Nat.add_le_add_left (Nat.div_le_div_right he) _)

theorem bounded_genesis_funded (weights : List ℕ) (b : LazyLedger precision) (cap funded : ℕ)
    (hr : 0 < precision) (ht : 0 < b.total)
    (steps : Relation.ReflTransGen (LazyLedger.BoundedStep cap) (LazyLedger.genesis weights) b) :
    ((b.accounts.map (LazyAccount.claim b.total b.index)).map
      (fun u => funded * u / b.total)).sum ≤
      funded + funded * (2 * (precision + cap) / precision) / b.total :=
  pooled_claims_bound funded b.total _ _ ht (bounded_genesis_claims weights b cap hr steps)

theorem bounded_genesis_funded_no_overclaim (weights : List ℕ) (b : LazyLedger precision)
    (cap funded : ℕ) (hr : 0 < precision) (ht : 0 < b.total)
    (steps : Relation.ReflTransGen (LazyLedger.BoundedStep cap) (LazyLedger.genesis weights) b)
    (hgrain : funded * (2 * (precision + cap) / precision) < b.total) :
    ((b.accounts.map (LazyAccount.claim b.total b.index)).map
      (fun u => funded * u / b.total)).sum ≤ funded := by
  simpa [Nat.div_eq_of_lt hgrain] using bounded_genesis_funded weights b cap funded hr ht steps

theorem bounded_genesis_funded_no_overclaim_small (weights : List ℕ)
    (b : LazyLedger precision) (cap funded : ℕ) (hr : 0 < precision) (ht : 0 < b.total)
    (hc : cap ≤ precision)
    (steps : Relation.ReflTransGen (LazyLedger.BoundedStep cap) (LazyLedger.genesis weights) b)
    (hgrain : funded * 4 < b.total) :
    ((b.accounts.map (LazyAccount.claim b.total b.index)).map
      (fun u => funded * u / b.total)).sum ≤ funded := by
  have hextra : 2 * (precision + cap) / precision ≤ 4 := by
    apply Nat.div_le_of_le_mul
    nlinarith
  apply bounded_genesis_funded_no_overclaim weights b cap funded hr ht steps
  exact (Nat.mul_le_mul_left funded hextra).trans_lt hgrain

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
