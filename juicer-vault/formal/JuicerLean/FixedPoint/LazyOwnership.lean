import JuicerLean.FixedPoint.YieldTransitions

namespace Juicer.Runtime

structure LazyAccount (precision : ℕ) where
  units : ℕ
  index : ℕ
  weight : ℕ
  deriving Repr, BEq

variable {precision : ℕ}

def LazyAccount.numerator (current : ℕ) (a : LazyAccount precision) : ℕ :=
  a.units * precision + a.weight * (current - a.index)

def LazyAccount.claim (total current : ℕ) (a : LazyAccount precision) : ℕ :=
  min total (a.units + a.weight * (current - a.index) / precision)

def LazyAccount.settled (total current : ℕ) (a : LazyAccount precision) : LazyAccount precision :=
  ⟨a.claim total current, current, a.weight⟩

def LazyAccount.shift (k : ℕ) (a : LazyAccount precision) : LazyAccount precision :=
  ⟨a.units >>> k, a.index >>> k, a.weight⟩

def lazyLiability (current : ℕ) (accounts : List (LazyAccount precision)) : ℕ :=
  (accounts.map (LazyAccount.numerator current)).sum

def lazyWeight (accounts : List (LazyAccount precision)) : ℕ :=
  (accounts.map LazyAccount.weight).sum

theorem lazy_claim_bound (t i : ℕ) (a : LazyAccount precision) :
    a.claim t i * precision ≤ a.numerator i := by
  have h := Nat.div_mul_le_self (a.weight * (i - a.index)) precision
  have hc := Nat.mul_le_mul_right precision (min_le_right t
    (a.units + a.weight * (i - a.index) / precision))
  dsimp [LazyAccount.claim, LazyAccount.numerator]
  nlinarith

theorem lazy_settlement_reduces_liability (t i : ℕ) (a : LazyAccount precision) :
    (a.settled t i).numerator i ≤ a.numerator i := by
  simpa [LazyAccount.settled, LazyAccount.numerator] using lazy_claim_bound t i a

theorem lazy_accrual_numerator (i delta : ℕ) (a : LazyAccount precision) (h : a.index ≤ i) :
    a.numerator (i + delta) = a.numerator i + a.weight * delta := by
  have hd : i + delta - a.index = (i - a.index) + delta := by omega
  simp only [LazyAccount.numerator, hd, Nat.mul_add]
  omega

theorem lazy_allocation_liability (i delta : ℕ) (accounts : List (LazyAccount precision))
    (h : ∀ a ∈ accounts, a.index ≤ i) :
    lazyLiability (i + delta) accounts = lazyLiability i accounts + lazyWeight accounts * delta := by
  induction accounts with
  | nil => simp [lazyLiability, lazyWeight]
  | cons a rest ih =>
    have ha := lazy_accrual_numerator i delta a (h a (by simp))
    have ht := ih (by intro a ha; exact h a (by simp [ha]))
    simp only [lazyLiability, lazyWeight, List.map_cons, List.sum_cons] at *
    nlinarith

theorem lazy_rescale_numerator (i k : ℕ) (a : LazyAccount precision) (h : a.index ≤ i) :
    (a.shift k).numerator (i >>> k) * 2 ^ k ≤
      a.numerator i + a.weight * (2 ^ k - 1) := by
  have hd : 0 < 2 ^ k := by positivity
  have hu := Nat.div_mul_le_self a.units (2 ^ k)
  have hi := Nat.div_mul_le_self i (2 ^ k)
  have hp := Nat.mod_lt a.index hd
  have hp' := Nat.div_add_mod a.index (2 ^ k)
  have ho := Nat.div_le_div_right (c := 2 ^ k) h
  have hs := Nat.sub_add_cancel ho
  have hdelta : (i / 2 ^ k - a.index / 2 ^ k) * 2 ^ k ≤ i - a.index + (2 ^ k - 1) := by
    have hsub := Nat.sub_add_cancel h
    have hsd := congrArg (fun n => n * 2 ^ k) hs
    have hd' : 2 ^ k - 1 + 1 = 2 ^ k := by omega
    nlinarith
  have h1 := Nat.mul_le_mul_right precision hu
  have h2 := Nat.mul_le_mul_left a.weight hdelta
  dsimp [LazyAccount.shift, LazyAccount.numerator]
  simp only [Nat.shiftRight_eq_div_pow]
  nlinarith

theorem lazy_rescale_liability (i k : ℕ) (accounts : List (LazyAccount precision))
    (h : ∀ a ∈ accounts, a.index ≤ i) :
    lazyLiability (i >>> k) (accounts.map (LazyAccount.shift k)) * 2 ^ k ≤
      lazyLiability i accounts + lazyWeight accounts * (2 ^ k - 1) := by
  induction accounts with
  | nil => simp [lazyLiability, lazyWeight]
  | cons a rest ih =>
    have ha := lazy_rescale_numerator i k a (h a (by simp))
    have ht := ih (by intro a ha; exact h a (by simp [ha]))
    simp only [lazyLiability, lazyWeight, List.map_cons, List.sum_cons] at *
    nlinarith

structure LazyLedger (precision : ℕ) where
  total : ℕ
  index : ℕ
  slack : ℕ
  accounts : List (LazyAccount precision)
  deriving Repr

def LazyLedger.valid (l : LazyLedger precision) : Prop :=
  (∀ a ∈ l.accounts, a.index ≤ l.index) ∧
  lazyLiability l.index l.accounts ≤ l.total * precision + l.slack

def LazyLedger.allocate (l : LazyLedger precision) (minted supply : ℕ) : LazyLedger precision :=
  { l with total := l.total + minted, index := l.index + minted * precision / supply }

def LazyLedger.rescale (l : LazyLedger precision) (k : ℕ) : LazyLedger precision :=
  let divisor := 2 ^ k
  { total := l.total >>> k
    index := l.index >>> k
    slack := (l.total % divisor * precision + l.slack + lazyWeight l.accounts * (divisor - 1)) / divisor
    accounts := l.accounts.map (LazyAccount.shift k) }

theorem lazy_allocation_preserves (l : LazyLedger precision) (m s : ℕ) (h : l.valid)
    (hw : lazyWeight l.accounts ≤ s) : (l.allocate m s).valid := by
  constructor
  · intro a ha
    exact (h.1 a ha).trans (Nat.le_add_right _ _)
  · have hi := Nat.div_mul_le_self (m * precision) s
    have hm := Nat.mul_le_mul_right (m * precision / s) hw
    have he := lazy_allocation_liability l.index (m * precision / s) l.accounts h.1
    change lazyLiability (l.index + m * precision / s) l.accounts ≤ (l.total + m) * precision + l.slack
    rw [he]
    have hb := h.2
    nlinarith

theorem lazy_rescale_preserves (l : LazyLedger precision) (k : ℕ) (h : l.valid) :
    (l.rescale k).valid := by
  constructor
  · intro a ha
    obtain ⟨old, ho, rfl⟩ := List.mem_map.mp ha
    simpa [LazyAccount.shift, LazyLedger.rescale, Nat.shiftRight_eq_div_pow] using
      Nat.div_le_div_right (c := 2 ^ k) (h.1 old ho)
  · have hd : 0 < 2 ^ k := by positivity
    have hl := lazy_rescale_liability l.index k l.accounts h.1
    have hb := h.2
    have ht := Nat.div_add_mod l.total (2 ^ k)
    let remainder := l.total % 2 ^ k * precision + l.slack + lazyWeight l.accounts * (2 ^ k - 1)
    have he := Nat.div_add_mod remainder (2 ^ k)
    have hr := Nat.mod_lt remainder hd
    change lazyLiability (l.index >>> k) (l.accounts.map (LazyAccount.shift k)) ≤
      (l.total >>> k) * precision + remainder / 2 ^ k
    simp only [Nat.shiftRight_eq_div_pow] at hl ⊢
    dsimp only [remainder] at he hr ⊢
    nlinarith

theorem lazy_claims_bound (l : LazyLedger precision) (h : l.valid) (hr : 0 < precision) :
    (l.accounts.map (LazyAccount.claim l.total l.index)).sum ≤ l.total + l.slack / precision := by
  have hb : ∀ accounts : List (LazyAccount precision),
      (accounts.map (LazyAccount.claim l.total l.index)).sum * precision ≤ lazyLiability l.index accounts := by
    intro accounts
    induction accounts with
    | nil => simp [lazyLiability]
    | cons a rest ih =>
      have ha := lazy_claim_bound l.total l.index a
      simp only [List.map_cons, List.sum_cons, lazyLiability] at *
      nlinarith
  have hl := hb l.accounts
  have he := Nat.div_add_mod l.slack precision
  have hm := Nat.mod_lt l.slack hr
  have hv := h.2
  nlinarith

theorem lazy_zero_slack_no_overclaim (l : LazyLedger precision) (h : l.valid) (he : l.slack = 0)
    (hr : 0 < precision) :
    (l.accounts.map (LazyAccount.claim l.total l.index)).sum ≤ l.total := by
  simpa [he] using lazy_claims_bound l h hr

inductive LazyLedger.PlainStep : LazyLedger precision → LazyLedger precision → Prop
  | allocate (l : LazyLedger precision) (m s : ℕ) (hw : lazyWeight l.accounts ≤ s) :
      PlainStep l (l.allocate m s)
  | settle (t i e : ℕ) (a : LazyAccount precision) (rest : List (LazyAccount precision)) (weight : ℕ) :
      PlainStep ⟨t, i, e, a :: rest⟩
        ⟨t, i, e, { a.settled t i with weight } :: rest⟩
  | join (l : LazyLedger precision) (weight : ℕ) :
      PlainStep l { l with accounts := ⟨0, l.index, weight⟩ :: l.accounts }
  | move (t i e : ℕ) (a b : LazyAccount precision) (rest : List (LazyAccount precision))
      (x : ℕ) (hx : x ≤ a.claim t i) :
      PlainStep ⟨t, i, e, a :: b :: rest⟩
        ⟨t, i, e, ⟨a.claim t i - x, i, a.weight⟩ :: ⟨b.claim t i + x, i, b.weight⟩ :: rest⟩
  | burn (t i e : ℕ) (a : LazyAccount precision) (rest : List (LazyAccount precision))
      (x : ℕ) (hx : x ≤ a.claim t i) :
      PlainStep ⟨t, i, e, a :: rest⟩
        ⟨t - x, i, e, ⟨a.claim t i - x, i, a.weight⟩ :: rest⟩
  | reorder (l : LazyLedger precision) (accounts : List (LazyAccount precision)) (hp : l.accounts.Perm accounts) :
      PlainStep l { l with accounts }

theorem lazy_replace_head (t i e : ℕ) (a b : LazyAccount precision) (rest : List (LazyAccount precision))
    (h : (LazyLedger.mk t i e (a :: rest)).valid) (hi : b.index ≤ i)
    (hn : b.numerator i ≤ a.numerator i) : (LazyLedger.mk t i e (b :: rest)).valid := by
  constructor
  · intro c hc
    rcases List.mem_cons.mp hc with rfl | hc
    · exact hi
    · exact h.1 c (List.mem_cons_of_mem a hc)
  · change b.numerator i + lazyLiability i rest ≤ t * precision + e
    exact (Nat.add_le_add_right hn _).trans h.2

theorem lazyLiability_cons (i : ℕ) (a : LazyAccount precision) (rest : List (LazyAccount precision)) :
    lazyLiability i (a :: rest) = a.numerator i + lazyLiability i rest := rfl

theorem numerator_at_index (u i w : ℕ) :
    (LazyAccount.mk (precision := precision) u i w).numerator i = u * precision := by
  simp [LazyAccount.numerator]

theorem lazy_move_preserves (t i e : ℕ) (a b : LazyAccount precision) (rest : List (LazyAccount precision))
    (x : ℕ) (hx : x ≤ a.claim t i) (h : (LazyLedger.mk t i e (a :: b :: rest)).valid) :
    (LazyLedger.mk t i e (⟨a.claim t i - x, i, a.weight⟩ ::
      ⟨b.claim t i + x, i, b.weight⟩ :: rest)).valid := by
  constructor
  · intro c hc
    rcases List.mem_cons.mp hc with rfl | hc
    · exact le_rfl
    rcases List.mem_cons.mp hc with rfl | hc
    · exact le_rfl
    · exact h.1 c (List.mem_cons_of_mem a (List.mem_cons_of_mem b hc))
  · have hm := congrArg (fun n => n * precision) (transfer_pair_conserved (a.claim t i) (b.claim t i) x hx)
    simp only [Nat.add_mul] at hm
    change lazyLiability i _ ≤ t * precision + e
    rw [lazyLiability_cons, lazyLiability_cons, numerator_at_index, numerator_at_index,
      ← Nat.add_assoc, Nat.add_mul (b.claim t i) x precision, hm, Nat.add_assoc]
    exact (Nat.add_le_add (lazy_claim_bound t i a)
      (Nat.add_le_add_right (lazy_claim_bound t i b) _)).trans h.2

theorem lazy_burn_preserves (t i e : ℕ) (a : LazyAccount precision) (rest : List (LazyAccount precision))
    (x : ℕ) (hx : x ≤ a.claim t i) (h : (LazyLedger.mk t i e (a :: rest)).valid) :
    (LazyLedger.mk (t - x) i e (⟨a.claim t i - x, i, a.weight⟩ :: rest)).valid := by
  constructor
  · intro c hc
    rcases List.mem_cons.mp hc with rfl | hc
    · exact le_rfl
    · exact h.1 c (List.mem_cons_of_mem a hc)
  · have ht : x ≤ t := hx.trans (min_le_left _ _)
    change (a.claim t i - x) * precision + a.weight * (i - i) + lazyLiability i rest ≤ (t - x) * precision + e
    simp only [Nat.sub_self, Nat.mul_zero, Nat.add_zero]
    apply Nat.le_of_add_le_add_right (b := x * precision)
    calc
      (a.claim t i - x) * precision + lazyLiability i rest + x * precision =
          a.claim t i * precision + lazyLiability i rest := by
        rw [Nat.add_right_comm, ← Nat.add_mul, Nat.sub_add_cancel hx]
      _ ≤ a.numerator i + lazyLiability i rest := Nat.add_le_add_right (lazy_claim_bound t i a) _
      _ ≤ t * precision + e := h.2
      _ = (t - x) * precision + e + x * precision := by
        rw [Nat.add_right_comm, ← Nat.add_mul, Nat.sub_add_cancel ht]

theorem lazy_plain_step_preserves (a b : LazyLedger precision) (h : a.valid)
    (step : a.PlainStep b) : b.valid := by
  cases step with
  | allocate _ m s hw => exact lazy_allocation_preserves a m s h hw
  | settle t i e a rest w =>
    apply lazy_replace_head t i e a _ rest h le_rfl
    simpa [LazyAccount.settled, LazyAccount.numerator] using lazy_claim_bound t i a
  | join _ w =>
    simpa [LazyLedger.valid, lazyLiability, LazyAccount.numerator] using h
  | move t i e a b rest x hx => exact lazy_move_preserves t i e a b rest x hx h
  | burn t i e a rest x hx => exact lazy_burn_preserves t i e a rest x hx h
  | reorder _ accounts hp =>
    constructor
    · intro c hc
      exact h.1 c (hp.mem_iff.mpr hc)
    · simpa only [lazyLiability, (hp.map (LazyAccount.numerator a.index)).sum_eq] using h.2

theorem lazy_plain_step_slack (a b : LazyLedger precision) (step : a.PlainStep b) : b.slack = a.slack := by
  cases step <;> rfl

def LazyLedger.writeOff (l : LazyLedger precision) : LazyLedger precision :=
  ⟨0, 0, 0, l.accounts.map (fun a => ⟨0, 0, a.weight⟩)⟩

theorem lazy_writeOff_valid (l : LazyLedger precision) : l.writeOff.valid := by
  simp [LazyLedger.writeOff, LazyLedger.valid, lazyLiability, List.map_map,
    Function.comp_def, LazyAccount.numerator]

inductive LazyLedger.Step : LazyLedger precision → LazyLedger precision → Prop
  | ordinary {a b : LazyLedger precision} (step : a.PlainStep b) : Step a b
  | rescale (a : LazyLedger precision) (k : ℕ) : Step a (a.rescale k)
  | writeOff (a : LazyLedger precision) : Step a a.writeOff

theorem lazy_step_preserves (a b : LazyLedger precision) (h : a.valid) (step : a.Step b) : b.valid := by
  cases step with
  | ordinary step => exact lazy_plain_step_preserves a b h step
  | rescale k => exact lazy_rescale_preserves a k h
  | writeOff => exact lazy_writeOff_valid a

theorem lazy_trace_preserves (a b : LazyLedger precision) (h : a.valid)
    (steps : Relation.ReflTransGen LazyLedger.Step a b) : b.valid := by
  induction steps with
  | refl => exact h
  | tail steps step ih => exact lazy_step_preserves _ _ ih step

theorem lazy_trace_claims_bound (a b : LazyLedger precision) (h : a.valid) (hr : 0 < precision)
    (steps : Relation.ReflTransGen LazyLedger.Step a b) :
    (b.accounts.map (LazyAccount.claim b.total b.index)).sum ≤ b.total + b.slack / precision :=
  lazy_claims_bound b (lazy_trace_preserves a b h steps) hr

theorem lazy_unscaled_trace_no_overclaim (a b : LazyLedger precision) (h : a.valid) (he : a.slack = 0)
    (hr : 0 < precision)
    (steps : Relation.ReflTransGen LazyLedger.PlainStep a b) :
    (b.accounts.map (LazyAccount.claim b.total b.index)).sum ≤ b.total := by
  have hi : b.valid ∧ b.slack = 0 := by
    induction steps with
    | refl => exact ⟨h, he⟩
    | tail steps step ih => exact ⟨lazy_plain_step_preserves _ _ ih.1 step,
        (lazy_plain_step_slack _ _ step).trans ih.2⟩
  exact lazy_zero_slack_no_overclaim b hi.1 hi.2 hr

def LazyLedger.genesis (weights : List ℕ) : LazyLedger precision :=
  ⟨0, 0, 0, weights.map (fun w => ⟨0, 0, w⟩)⟩

theorem lazy_genesis_valid (weights : List ℕ) :
    (LazyLedger.genesis (precision := precision) weights).valid := by
  simp [LazyLedger.genesis, LazyLedger.valid, lazyLiability, List.map_map,
    Function.comp_def, LazyAccount.numerator]

theorem lazy_genesis_unscaled_trace (weights : List ℕ) (b : LazyLedger precision)
    (hr : 0 < precision)
    (steps : Relation.ReflTransGen LazyLedger.PlainStep (LazyLedger.genesis weights) b) :
    (b.accounts.map (LazyAccount.claim b.total b.index)).sum ≤ b.total :=
  lazy_unscaled_trace_no_overclaim _ b (lazy_genesis_valid weights) rfl hr steps

theorem pooled_claims_mul_bound (funded total : ℕ) (owned : List ℕ) :
    (owned.map (fun u => funded * u / total)).sum * total ≤ funded * owned.sum := by
  induction owned with
  | nil => simp
  | cons u rest ih =>
    have hu := Nat.div_mul_le_self (funded * u) total
    simp only [List.map_cons, List.sum_cons]
    nlinarith

theorem pooled_claims_bound (funded total extra : ℕ) (owned : List ℕ)
    (ht : 0 < total) (h : owned.sum ≤ total + extra) :
    (owned.map (fun u => funded * u / total)).sum ≤ funded + funded * extra / total := by
  calc
    _ ≤ funded * owned.sum / total :=
      (Nat.le_div_iff_mul_le ht).2 (pooled_claims_mul_bound funded total owned)
    _ ≤ funded * (total + extra) / total :=
      Nat.div_le_div_right (Nat.mul_le_mul_left funded h)
    _ = funded + funded * extra / total := by
      rw [Nat.mul_add, Nat.add_comm (funded * total), Nat.add_mul_div_right _ _ ht, Nat.add_comm]

theorem lazy_funded_claims_bound (l : LazyLedger precision) (funded : ℕ)
    (h : l.valid) (hr : 0 < precision) (ht : 0 < l.total) :
    ((l.accounts.map (LazyAccount.claim l.total l.index)).map
      (fun u => funded * u / l.total)).sum ≤ funded + funded * (l.slack / precision) / l.total :=
  pooled_claims_bound funded l.total (l.slack / precision) _ ht (lazy_claims_bound l h hr)

theorem lazy_funded_no_overclaim (l : LazyLedger precision) (funded : ℕ)
    (h : l.valid) (hr : 0 < precision) (ht : 0 < l.total)
    (hgrain : funded * (l.slack / precision) < l.total) :
    ((l.accounts.map (LazyAccount.claim l.total l.index)).map (fun u => funded * u / l.total)).sum ≤ funded := by
  simpa [Nat.div_eq_of_lt hgrain] using lazy_funded_claims_bound l funded h hr ht

end Juicer.Runtime
