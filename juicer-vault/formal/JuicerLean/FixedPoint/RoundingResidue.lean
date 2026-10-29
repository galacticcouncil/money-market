import JuicerLean.FixedPoint.RescaleBounds
import JuicerLean.FixedPoint.LifecycleRefinement

namespace Juicer.Runtime

variable {precision : ℕ}

theorem lazy_rescale_loss (i k : ℕ) (a : LazyAccount precision) :
    a.numerator i ≤ (a.shift i k).numerator (i >>> k) * 2 ^ k +
      (2 ^ k - 1) * (precision + 2 * a.weight) := by
  have hd : 0 < 2 ^ k := by positivity
  have hu := Nat.div_add_mod a.units (2 ^ k)
  have hur := Nat.mod_lt a.units hd
  have hi := Nat.div_add_mod i (2 ^ k)
  have hir := Nat.mod_lt i hd
  simp only [Nat.mul_comm (2 ^ k)] at hu hi
  have hp := (ceilDiv_bounds a.index (2 ^ k) hd).2
  have hdelta : i - a.index ≤
      (i / 2 ^ k - min (i / 2 ^ k) (ceilShift a.index k)) * 2 ^ k + 2 * (2 ^ k - 1) := by
    dsimp [ceilShift] at *
    by_cases hc : i / 2 ^ k ≤ ceilDiv a.index (2 ^ k)
    · rw [min_eq_left hc, Nat.sub_self, Nat.zero_mul]
      have hm := Nat.mul_le_mul_right (2 ^ k) hc
      omega
    · have hc' : ceilDiv a.index (2 ^ k) ≤ i / 2 ^ k := by omega
      rw [min_eq_right hc']
      have hm := congrArg (fun n => n * 2 ^ k) (Nat.sub_add_cancel hc')
      simp only [Nat.add_mul] at hm
      omega
  have hw := Nat.mul_le_mul_left a.weight hdelta
  have hum : a.units ≤ a.units / 2 ^ k * 2 ^ k + (2 ^ k - 1) := by omega
  have hum' := Nat.mul_le_mul_right precision hum
  simp only [LazyAccount.numerator, LazyAccount.shift, Nat.shiftRight_eq_div_pow]
  nlinarith

theorem lazy_rescale_loss_sum (i k : ℕ) (accounts : List (LazyAccount precision)) :
    lazyLiability i accounts ≤
      lazyLiability (i >>> k) (accounts.map (LazyAccount.shift i k)) * 2 ^ k +
        (2 ^ k - 1) * (accounts.length * precision + 2 * lazyWeight accounts) := by
  induction accounts with
  | nil => simp [lazyLiability, lazyWeight]
  | cons a rest ih =>
    have ha := lazy_rescale_loss i k a
    simp only [lazyLiability, lazyWeight, List.map_cons, List.sum_cons, List.length_cons] at *
    nlinarith

def LazyLedger.ResidueBound (l : LazyLedger precision) (budget : ℕ) : Prop :=
  l.total * precision ≤ lazyLiability l.index l.accounts + budget

def LazyLedger.rescaleBudget (l : LazyLedger precision) (k budget : ℕ) : ℕ :=
  (budget + (2 ^ k - 1) * (l.accounts.length * precision + 2 * lazyWeight l.accounts)) / 2 ^ k

theorem rescale_residue_bound (l : LazyLedger precision) (k budget : ℕ)
    (h : l.ResidueBound budget) : (l.rescale k).ResidueBound (l.rescaleBudget k budget) := by
  have hd : 0 < 2 ^ k := by positivity
  have hl := lazy_rescale_loss_sum l.index k l.accounts
  have ht := Nat.mul_le_mul_right precision (Nat.div_mul_le_self l.total (2 ^ k))
  have he := Nat.div_add_mod
    (budget + (2 ^ k - 1) * (l.accounts.length * precision + 2 * lazyWeight l.accounts)) (2 ^ k)
  have hr := Nat.mod_lt
    (budget + (2 ^ k - 1) * (l.accounts.length * precision + 2 * lazyWeight l.accounts)) hd
  dsimp [LazyLedger.ResidueBound] at h ⊢
  simp only [LazyLedger.rescale, LazyLedger.rescaleBudget, Nat.shiftRight_eq_div_pow] at hl ⊢
  nlinarith

theorem lazy_claim_rounding (t i : ℕ) (a : LazyAccount precision) (hr : 0 < precision)
    (h : a.numerator i < (t + 1) * precision) :
    a.numerator i ≤ a.claim t i * precision + (precision - 1) := by
  have hd := Nat.div_add_mod (a.weight * (i - a.index)) precision
  have hm := Nat.mod_lt (a.weight * (i - a.index)) hr
  have hpred : precision - 1 + 1 = precision := by omega
  have hc : a.units + a.weight * (i - a.index) / precision ≤ t := by
    apply Nat.le_of_lt_succ
    apply (Nat.mul_lt_mul_right hr).mp
    calc
      _ ≤ a.numerator i := by
        simpa only [Nat.add_mul, LazyAccount.numerator] using
          Nat.add_le_add_left (Nat.div_mul_le_self (a.weight * (i - a.index)) precision)
            (a.units * precision)
      _ < (t + 1) * precision := h
  simp only [LazyAccount.claim, min_eq_right hc, LazyAccount.numerator]
  nlinarith

theorem liability_head_lt (l : LazyLedger precision) (a : LazyAccount precision)
    (ha : a ∈ l.accounts) (hv : l.valid) (he : l.slack < precision) :
    a.numerator l.index < (l.total + 1) * precision := by
  have hm : a.numerator l.index ≤ lazyLiability l.index l.accounts := by
    exact List.single_le_sum (fun _ _ => Nat.zero_le _) _ (List.mem_map.mpr ⟨a, ha, rfl⟩)
  have h := hv.2
  nlinarith

def LazyLedger.allocationBudget (l : LazyLedger precision) (minted supply budget : ℕ) : ℕ :=
  budget + (minted * precision - lazyWeight l.accounts * (minted * precision / supply))

theorem allocation_residue_bound (l : LazyLedger precision) (minted supply budget : ℕ)
    (h : l.ResidueBound budget) (hi : ∀ a ∈ l.accounts, a.index ≤ l.index)
    (hw : lazyWeight l.accounts ≤ supply) :
    (l.allocate minted supply).ResidueBound (l.allocationBudget minted supply budget) := by
  have he := lazy_allocation_liability l.index (minted * precision / supply) l.accounts hi
  have hm : lazyWeight l.accounts * (minted * precision / supply) ≤ minted * precision := by
    calc
      _ ≤ supply * (minted * precision / supply) := Nat.mul_le_mul_right _ hw
      _ = (minted * precision / supply) * supply := Nat.mul_comm _ _
      _ ≤ minted * precision := Nat.div_mul_le_self _ _
  dsimp [LazyLedger.ResidueBound, LazyLedger.allocate, LazyLedger.allocationBudget] at h ⊢
  rw [he]
  nlinarith [Nat.sub_add_cancel hm]

theorem allocation_residue_charge (l : LazyLedger precision) (minted supply budget : ℕ)
    (hw : lazyWeight l.accounts ≤ supply) :
    l.allocationBudget minted supply budget = budget +
      (supply - lazyWeight l.accounts) * (minted * precision / supply) + (minted * precision) % supply := by
  have hd := Nat.div_add_mod (minted * precision) supply
  have hm := congrArg (fun n => n * (minted * precision / supply)) (Nat.sub_add_cancel hw)
  simp only [Nat.add_mul] at hm
  dsimp [LazyLedger.allocationBudget]
  omega

theorem settlement_residue_bound (t i e budget : ℕ) (a : LazyAccount precision)
    (rest : List (LazyAccount precision)) (weight : ℕ) (hr : 0 < precision)
    (hv : (LazyLedger.mk t i e (a :: rest)).valid) (he : e < precision)
    (h : (LazyLedger.mk t i e (a :: rest)).ResidueBound budget) :
    (LazyLedger.mk t i e ({ a.settled t i with weight } :: rest)).ResidueBound
      (budget + (precision - 1)) := by
  have ha := lazy_claim_rounding t i a hr (liability_head_lt _ a (by simp) hv he)
  simp only [LazyLedger.ResidueBound, lazyLiability_cons, LazyAccount.settled, numerator_at_index] at h ⊢
  omega

theorem escrow_residue_bound (t i e budget shares taken : ℕ) (a : LazyAccount precision)
    (rest : List (LazyAccount precision)) (hr : 0 < precision)
    (hv : (LazyLedger.mk t i e (a :: rest)).valid) (he : e < precision)
    (ht : taken ≤ a.claim t i) (h : (LazyLedger.mk t i e (a :: rest)).ResidueBound budget) :
    (LazyLedger.mk t i e (⟨a.claim t i - taken, i, a.weight - shares⟩ ::
      ⟨taken, i, shares⟩ :: rest)).ResidueBound (budget + (precision - 1)) := by
  have ha := lazy_claim_rounding t i a hr (liability_head_lt _ a (by simp) hv he)
  have hm := congrArg (fun n => n * precision) (Nat.sub_add_cancel ht)
  simp only [Nat.add_mul] at hm
  simp only [LazyLedger.ResidueBound, lazyLiability_cons, numerator_at_index] at h ⊢
  omega

inductive PlainResidueBudget : {a b : LazyLedger precision} → a.PlainStep b → ℕ → ℕ → Prop
  | allocate (l : LazyLedger precision) (m s budget : ℕ) (hw : lazyWeight l.accounts ≤ s) :
      PlainResidueBudget (.allocate l m s hw) budget (l.allocationBudget m s budget)
  | settle (t i e budget : ℕ) (a : LazyAccount precision) (rest : List (LazyAccount precision)) (w : ℕ) :
      PlainResidueBudget (.settle t i e a rest w) budget (budget + (precision - 1))
  | join (l : LazyLedger precision) (w budget : ℕ) : PlainResidueBudget (.join l w) budget budget
  | move (t i e budget : ℕ) (a b : LazyAccount precision) (rest : List (LazyAccount precision))
      (x : ℕ) (hx : x ≤ a.claim t i) :
      PlainResidueBudget (.move t i e a b rest x hx) budget (budget + 2 * (precision - 1))
  | burn (t i e budget : ℕ) (a : LazyAccount precision) (rest : List (LazyAccount precision))
      (x : ℕ) (hx : x ≤ a.claim t i) :
      PlainResidueBudget (.burn t i e a rest x hx) budget (budget + (precision - 1))
  | reorder (l : LazyLedger precision) (accounts : List (LazyAccount precision)) (budget : ℕ)
      (hp : l.accounts.Perm accounts) : PlainResidueBudget (.reorder l accounts hp) budget budget

theorem plain_step_residue_bound {a b : LazyLedger precision} (step : a.PlainStep b)
    (budget next : ℕ) (hc : PlainResidueBudget step budget next)
    (hr : 0 < precision) (hv : a.valid) (he : a.slack < precision)
    (h : a.ResidueBound budget) : b.ResidueBound next := by
  cases hc with
  | allocate _ m s budget hw => exact allocation_residue_bound a m s budget h hv.1 hw
  | settle t i e budget a rest w => exact settlement_residue_bound t i e budget a rest w hr hv he h
  | join _ w budget => simpa [LazyLedger.ResidueBound, lazyLiability_cons,
      LazyAccount.numerator] using h
  | move t i e budget a b rest x hx =>
    have ha := lazy_claim_rounding t i a hr (liability_head_lt _ a (by simp) hv he)
    have hb := lazy_claim_rounding t i b hr (liability_head_lt _ b (by simp) hv he)
    have hm := congrArg (fun n => n * precision) (Nat.sub_add_cancel hx)
    simp only [Nat.add_mul] at hm
    simp only [LazyLedger.ResidueBound, lazyLiability_cons, numerator_at_index] at h ⊢
    nlinarith
  | burn t i e budget a rest x hx =>
    have ha := lazy_claim_rounding t i a hr (liability_head_lt _ a (by simp) hv he)
    have hm := congrArg (fun n => n * precision) (Nat.sub_add_cancel hx)
    have ht := congrArg (fun n => n * precision) (Nat.sub_add_cancel (hx.trans (min_le_left _ _)))
    simp only [Nat.add_mul] at hm ht
    simp only [LazyLedger.ResidueBound, lazyLiability_cons, numerator_at_index] at h ⊢
    omega
  | reorder _ accounts budget hp =>
    simpa only [LazyLedger.ResidueBound, lazyLiability,
      (hp.map (LazyAccount.numerator a.index)).sum_eq] using h

theorem exit_rounding_loss (t i : ℕ) (a request : LazyAccount precision)
    (hr : 0 < precision) (h : a.numerator i + request.numerator i < (t + 1) * precision) :
    a.numerator i + request.numerator i ≤
      (exitOwner t i a request).numerator i + exitBurned t i a request * precision + 2 * (precision - 1) := by
  have ha := lazy_claim_rounding t i a hr (by omega)
  have hd := Nat.div_add_mod (request.weight * (i - request.index)) precision
  have hm := Nat.mod_lt (request.weight * (i - request.index)) hr
  have hp : precision - 1 + 1 = precision := by omega
  have hu := lazy_claim_bound t i a
  have hrequest := Nat.div_mul_le_self (request.weight * (i - request.index)) precision
  have hsum : request.units + a.claim t i + request.weight * (i - request.index) / precision ≤ t := by
    apply Nat.le_of_lt_succ
    apply (Nat.mul_lt_mul_right hr).mp
    calc
      _ ≤ a.numerator i + request.numerator i := by
        dsimp only [LazyAccount.numerator] at hu ⊢
        nlinarith
      _ < (t + 1) * precision := h
  have ho : exitOwned t i a request = a.claim t i + request.weight * (i - request.index) / precision := by
    exact min_eq_right (by omega)
  have hx := exit_taken_bounded t i a request
  have hb : exitBurned t i a request = request.units + exitTaken t i a request := by
    exact min_eq_right (by omega)
  have heq := congrArg (fun n => n * precision) (Nat.sub_add_cancel hx)
  simp only [Nat.add_mul] at heq
  simp only [exitOwner, numerator_at_index, hb]
  dsimp only [LazyAccount.numerator] at h ha hu ⊢
  rw [ho] at heq ⊢
  nlinarith

theorem exit_residue_bound (t i e budget : ℕ) (a request : LazyAccount precision)
    (rest : List (LazyAccount precision)) (hr : 0 < precision)
    (hv : (LazyLedger.mk t i e (a :: request :: rest)).valid) (he : e < precision)
    (h : (LazyLedger.mk t i e (a :: request :: rest)).ResidueBound budget) :
    (LazyLedger.mk (t - exitBurned t i a request) i e (exitOwner t i a request :: rest)).ResidueBound
      (budget + 2 * (precision - 1)) := by
  have hp := hv.2
  simp only [lazyLiability_cons] at hp
  have hl := exit_rounding_loss t i a request hr (by nlinarith)
  have ht := congrArg (fun n => n * precision)
    (Nat.sub_add_cancel (min_le_left t (request.units + exitTaken t i a request)))
  change (t - exitBurned t i a request + exitBurned t i a request) * precision = t * precision at ht
  simp only [Nat.add_mul] at ht
  simp only [LazyLedger.ResidueBound, lazyLiability_cons] at h ⊢
  omega

inductive ResidueStep : (LazyLedger precision × ℕ) → (LazyLedger precision × ℕ) → Prop
  | ordinary {a b} (step : a.PlainStep b) (budget next : ℕ)
      (hc : PlainResidueBudget step budget next) : ResidueStep (a, budget) (b, next)
  | rescale (a : LazyLedger precision) (k budget : ℕ) :
      ResidueStep (a, budget) (a.rescale k, a.rescaleBudget k budget)
  | escrow (t i e budget shares taken : ℕ) (a : LazyAccount precision)
      (rest : List (LazyAccount precision)) (ht : taken ≤ a.claim t i) :
      ResidueStep (⟨t, i, e, a :: rest⟩, budget)
        (⟨t, i, e, ⟨a.claim t i - taken, i, a.weight - shares⟩ :: ⟨taken, i, shares⟩ :: rest⟩,
          budget + (precision - 1))
  | start (t i e budget : ℕ) (a request : LazyAccount precision) (rest : List (LazyAccount precision)) :
      ResidueStep (⟨t, i, e, a :: request :: rest⟩, budget)
        (⟨t - exitBurned t i a request, i, e, exitOwner t i a request :: rest⟩, budget + 2 * (precision - 1))
  | writeOff (a : LazyLedger precision) (budget : ℕ) : ResidueStep (a, budget) (a.writeOff, 0)

theorem residue_step_preserves {a b : LazyLedger precision × ℕ} (step : ResidueStep a b)
    (hr : 0 < precision) (h : a.1.valid ∧ a.1.slack < precision ∧ a.1.ResidueBound a.2) :
    b.1.valid ∧ b.1.slack < precision ∧ b.1.ResidueBound b.2 := by
  rcases h with ⟨hv, he, hb⟩
  cases step with
  | ordinary step budget next hc => exact ⟨lazy_plain_step_preserves _ _ hv step,
      by simpa [lazy_plain_step_slack _ _ step] using he, plain_step_residue_bound step budget next hc hr hv he hb⟩
  | rescale a k budget => exact ⟨lazy_rescale_preserves a k hv, rescale_slack_lt_precision a k he,
      rescale_residue_bound a k budget hb⟩
  | escrow t i e budget shares taken a rest ht => exact ⟨escrow_ledger_preserves _ _ _ _ _ _ _ ht hv, he,
      escrow_residue_bound _ _ _ _ _ _ _ _ hr hv he ht hb⟩
  | start t i e budget a request rest => exact ⟨exit_ledger_preserves _ _ _ _ _ _ hv, he,
      exit_residue_bound _ _ _ _ _ _ _ hr hv he hb⟩
  | writeOff a budget => exact ⟨lazy_writeOff_valid a, hr, by simp [LazyLedger.ResidueBound, LazyLedger.writeOff]⟩

theorem residue_trace_bound (weights : List ℕ) {b : LazyLedger precision × ℕ} (hr : 0 < precision)
    (steps : Relation.ReflTransGen ResidueStep (LazyLedger.genesis weights, 0) b) :
    b.1.valid ∧ b.1.slack < precision ∧ b.1.ResidueBound b.2 := by
  induction steps with
  | refl => exact ⟨lazy_genesis_valid weights, hr, by simp [LazyLedger.ResidueBound, LazyLedger.genesis]⟩
  | tail _ step ih => exact residue_step_preserves step hr ih

theorem lazy_claims_rounding (t i : ℕ) (accounts : List (LazyAccount precision)) (hr : 0 < precision)
    (h : ∀ a ∈ accounts, a.numerator i < (t + 1) * precision) :
    lazyLiability i accounts ≤ (accounts.map (LazyAccount.claim t i)).sum * precision +
      accounts.length * (precision - 1) := by
  induction accounts with
  | nil => simp [lazyLiability]
  | cons a rest ih =>
    have ha := lazy_claim_rounding t i a hr (h a (by simp))
    have hb := ih (by intro b hb; exact h b (by simp [hb]))
    simp only [lazyLiability_cons, List.map_cons, List.sum_cons, List.length_cons]
    nlinarith

theorem lazy_units_residue (l : LazyLedger precision) (budget : ℕ) (hr : 0 < precision)
    (hv : l.valid) (he : l.slack < precision) (h : l.ResidueBound budget) :
    l.total ≤ (l.accounts.map (LazyAccount.claim l.total l.index)).sum +
      (budget + l.accounts.length * (precision - 1)) / precision := by
  have hc := lazy_claims_rounding l.total l.index l.accounts hr (fun a ha => liability_head_lt l a ha hv he)
  have hd := Nat.div_add_mod (budget + l.accounts.length * (precision - 1)) precision
  have hm := Nat.mod_lt (budget + l.accounts.length * (precision - 1)) hr
  dsimp [LazyLedger.ResidueBound] at h
  nlinarith

theorem pooled_claims_residue (funded total : ℕ) (owned : List ℕ) (ht : 0 < total) :
    funded * owned.sum ≤ (owned.map (fun u => funded * u / total)).sum * total +
      owned.length * (total - 1) := by
  induction owned with
  | nil => simp
  | cons u rest ih =>
    have hd := Nat.div_add_mod (funded * u) total
    have hm := Nat.mod_lt (funded * u) ht
    have hp : total - 1 + 1 = total := by omega
    simp only [List.map_cons, List.sum_cons, List.length_cons]
    nlinarith

theorem funded_residue_bound (funded total missing : ℕ) (owned : List ℕ) (ht : 0 < total)
    (h : total ≤ owned.sum + missing) :
    (funded - (owned.map (fun u => funded * u / total)).sum) * total ≤
      funded * missing + owned.length * (total - 1) := by
  have hp := pooled_claims_residue funded total owned ht
  have hm := Nat.mul_le_mul_left funded h
  by_cases hc : (owned.map (fun u => funded * u / total)).sum ≤ funded
  · have hs := congrArg (fun n => n * total) (Nat.sub_add_cancel hc)
    simp only [Nat.add_mul] at hs
    nlinarith
  · rw [Nat.sub_eq_zero_of_le (Nat.le_of_not_ge hc)]
    simp

theorem lazy_funded_residue (l : LazyLedger precision) (budget funded : ℕ)
    (hr : 0 < precision) (ht : 0 < l.total) (hv : l.valid) (he : l.slack < precision)
    (h : l.ResidueBound budget) :
    (funded - ((l.accounts.map (LazyAccount.claim l.total l.index)).map
      (fun units => funded * units / l.total)).sum) * l.total ≤
      funded * ((budget + l.accounts.length * (precision - 1)) / precision) +
        l.accounts.length * (l.total - 1) := by
  simpa using funded_residue_bound funded l.total _ _ ht (lazy_units_residue l budget hr hv he h)

theorem normalized_ledger_rescale (b : Book) (accounts : List (Account × ℕ)) (slack k : ℕ)
    (hs : ∀ p ∈ accounts, p.1.epoch = b.epoch → p.1.scale ≤ b.scale) :
    normalizeLedger { b with total := b.total >>> k, index := b.index >>> k, scale := b.scale + k }
      accounts ((b.total % 2 ^ k * ray + slack) / 2 ^ k) = (normalizeLedger b accounts slack).rescale k := by
  simp only [normalizeLedger, LazyLedger.rescale, List.map_map, Function.comp_def]
  congr 1
  apply List.map_congr_left
  intro p hp
  exact normalized_rescale b p.1 p.2 k (hs p hp)

theorem runtime_rescale_residue (b : Book) (accounts : List (Account × ℕ)) (slack k budget : ℕ)
    (hs : ∀ p ∈ accounts, p.1.epoch = b.epoch → p.1.scale ≤ b.scale)
    (h : (normalizeLedger b accounts slack).ResidueBound budget) :
    (normalizeLedger { b with total := b.total >>> k, index := b.index >>> k, scale := b.scale + k }
      accounts ((b.total % 2 ^ k * ray + slack) / 2 ^ k)).ResidueBound
        ((normalizeLedger b accounts slack).rescaleBudget k budget) := by
  rw [normalized_ledger_rescale b accounts slack k hs]
  exact rescale_residue_bound _ k budget h

end Juicer.Runtime
