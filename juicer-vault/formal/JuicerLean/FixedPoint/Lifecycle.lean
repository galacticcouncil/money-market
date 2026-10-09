import JuicerLean.FixedPoint.LazyRefinement
import JuicerLean.FixedPoint.PolicyQueue

namespace Juicer.Runtime

variable {precision : ℕ}

structure Lifecycle (precision : ℕ) where
  ledger : LazyLedger precision
  supply : ℕ
  funded : ℕ
  queued : ℕ
  parked : ℕ
  deriving Repr

def Lifecycle.valid (s : Lifecycle precision) : Prop :=
  s.ledger.valid ∧ lazyWeight s.ledger.accounts + s.funded + s.queued + s.parked = s.supply

def Lifecycle.outside (s : Lifecycle precision) : ℕ := s.supply - s.queued - s.funded

theorem lifecycle_weight_derived (s : Lifecycle precision) (h : s.valid) :
    lazyWeight s.ledger.accounts ≤ s.outside := by
  unfold Lifecycle.outside
  have := h.2
  omega

def Lifecycle.genesis (wallets : List ℕ) : Lifecycle precision :=
  ⟨LazyLedger.genesis wallets, wallets.sum, 0, 0, 0⟩

theorem lifecycle_genesis_valid (wallets : List ℕ) :
    (Lifecycle.genesis (precision := precision) wallets).valid := by
  constructor
  · exact lazy_genesis_valid wallets
  · simp [Lifecycle.genesis, LazyLedger.genesis, lazyWeight, List.map_map, Function.comp_def]

def exitOwned (t i : ℕ) (a request : LazyAccount precision) : ℕ :=
  min t (a.claim t i + request.weight * (i - request.index) / precision)

def exitTaken (t i : ℕ) (a request : LazyAccount precision) : ℕ :=
  exitOwned t i a request * request.weight / (a.weight + request.weight)

def exitBurned (t i : ℕ) (a request : LazyAccount precision) : ℕ :=
  min t (request.units + exitTaken t i a request)

def exitOwner (t i : ℕ) (a request : LazyAccount precision) : LazyAccount precision :=
  ⟨exitOwned t i a request - exitTaken t i a request, i, a.weight⟩

theorem exit_taken_bounded (t i : ℕ) (a request : LazyAccount precision) :
    exitTaken t i a request ≤ exitOwned t i a request :=
  proportional_le _ _ _ (by omega)

theorem exit_liability_consumed (t i : ℕ) (a request : LazyAccount precision) :
    (exitOwner t i a request).numerator i + exitBurned t i a request * precision ≤
      a.numerator i + request.numerator i := by
  have ha := lazy_claim_bound t i a
  have hr := Nat.div_mul_le_self (request.weight * (i - request.index)) precision
  have ho := Nat.mul_le_mul_right precision (min_le_right t
    (a.claim t i + request.weight * (i - request.index) / precision))
  have hb := Nat.mul_le_mul_right precision (min_le_right t (request.units + exitTaken t i a request))
  have hx := congrArg (fun n => n * precision)
    (Nat.sub_add_cancel (exit_taken_bounded t i a request))
  simp only [Nat.add_mul] at hx
  simp only [exitOwner, LazyAccount.numerator, Nat.sub_self, Nat.mul_zero, Nat.add_zero]
  change exitOwned t i a request * precision ≤ _ at ho
  change exitBurned t i a request * precision ≤ _ at hb
  dsimp only [LazyAccount.numerator] at ha
  nlinarith

theorem exit_ledger_preserves (t i e : ℕ) (a request : LazyAccount precision)
    (rest : List (LazyAccount precision)) (h : (LazyLedger.mk t i e (a :: request :: rest)).valid) :
    (LazyLedger.mk (t - exitBurned t i a request) i e (exitOwner t i a request :: rest)).valid := by
  constructor
  · intro c hc
    rcases List.mem_cons.mp hc with rfl | hc
    · exact le_rfl
    · exact h.1 c (by simp [hc])
  · have hb : exitBurned t i a request ≤ t := min_le_left _ _
    have hn := exit_liability_consumed t i a request
    have ht := congrArg (fun n => n * precision) (Nat.sub_add_cancel hb)
    simp only [Nat.add_mul] at ht
    have hv := h.2
    simp only [lazyLiability_cons] at hv ⊢
    nlinarith

theorem escrow_ledger_preserves (t i e : ℕ) (a : LazyAccount precision)
    (rest : List (LazyAccount precision)) (shares taken : ℕ)
    (hu : taken ≤ a.claim t i) (h : (LazyLedger.mk t i e (a :: rest)).valid) :
    (LazyLedger.mk t i e (⟨a.claim t i - taken, i, a.weight - shares⟩ ::
      ⟨taken, i, shares⟩ :: rest)).valid := by
  constructor
  · intro c hc
    simp only [List.mem_cons] at hc
    rcases hc with rfl | rfl | hc
    · exact le_rfl
    · exact le_rfl
    · exact h.1 c (by simp [hc])
  · have hn := lazy_claim_bound t i a
    have he := congrArg (fun n => n * precision) (Nat.sub_add_cancel hu)
    simp only [Nat.add_mul] at he
    have hv := h.2
    simp only [lazyLiability_cons, numerator_at_index] at hv ⊢
    omega

inductive Lifecycle.Step : Lifecycle precision → Lifecycle precision → Prop
  | allocate (s : Lifecycle precision) (minted : ℕ) :
      Step s { s with ledger := s.ledger.allocate minted s.outside }
  | rescale (s : Lifecycle precision) (k : ℕ) :
      Step s { s with ledger := s.ledger.rescale k }
  | writeOff (s : Lifecycle precision) :
      Step s { s with ledger := s.ledger.writeOff }
  | reorder (s : Lifecycle precision) (accounts : List (LazyAccount precision))
      (hp : s.ledger.accounts.Perm accounts) :
      Step s { s with ledger := { s.ledger with accounts } }
  | join (s : Lifecycle precision) :
      Step s { s with ledger := { s.ledger with accounts := ⟨0, s.ledger.index, 0⟩ :: s.ledger.accounts } }
  | deposit (t i e supply f q p minted : ℕ) (a : LazyAccount precision)
      (rest : List (LazyAccount precision)) :
      Step ⟨⟨t, i, e, a :: rest⟩, supply, f, q, p⟩
        ⟨⟨t, i, e, { a.settled t i with weight := a.weight + minted } :: rest⟩,
          supply + minted, f, q, p⟩
  | transfer (t i e supply f q p shares taken : ℕ) (a b : LazyAccount precision)
      (rest : List (LazyAccount precision)) (hw : shares ≤ a.weight) (hu : taken ≤ a.claim t i) :
      Step ⟨⟨t, i, e, a :: b :: rest⟩, supply, f, q, p⟩
        ⟨⟨t, i, e, ⟨a.claim t i - taken, i, a.weight - shares⟩ ::
          ⟨b.claim t i + taken, i, b.weight + shares⟩ :: rest⟩, supply, f, q, p⟩
  | escrow (t i e supply f q p shares taken : ℕ) (a : LazyAccount precision)
      (rest : List (LazyAccount precision)) (hw : shares ≤ a.weight) (hu : taken ≤ a.claim t i) :
      Step ⟨⟨t, i, e, a :: rest⟩, supply, f, q, p⟩
        ⟨⟨t, i, e, ⟨a.claim t i - taken, i, a.weight - shares⟩ ::
          ⟨taken, i, shares⟩ :: rest⟩, supply, f, q, p⟩
  | start (t i e supply f q p : ℕ) (a request : LazyAccount precision)
      (rest : List (LazyAccount precision)) :
      Step ⟨⟨t, i, e, a :: request :: rest⟩, supply, f, q, p⟩
        ⟨⟨t - exitBurned t i a request, i, e, exitOwner t i a request :: rest⟩,
          supply, f - fundedOf f t (exitBurned t i a request),
          q + request.weight + fundedOf f t (exitBurned t i a request), p⟩
  | claim (s : Lifecycle precision) (burn : ℕ) (hb : burn ≤ s.queued) :
      Step s { s with supply := s.supply - burn, queued := s.queued - burn }
  | fundMint (s : Lifecycle precision) (shares : ℕ) :
      Step s { s with supply := s.supply + shares, funded := s.funded + shares }
  | parkMint (s : Lifecycle precision) (shares : ℕ) :
      Step s { s with supply := s.supply + shares, parked := s.parked + shares }
  | donate (t i e supply f q p shares : ℕ) (a : LazyAccount precision)
      (rest : List (LazyAccount precision)) (hw : shares ≤ a.weight) :
      Step ⟨⟨t, i, e, a :: rest⟩, supply, f, q, p⟩
        ⟨⟨t, i, e, { a.settled t i with weight := a.weight - shares } :: rest⟩,
          supply, f + shares, q, p⟩
  | park (t i e supply f q p shares : ℕ) (a : LazyAccount precision)
      (rest : List (LazyAccount precision)) (hw : shares ≤ a.weight) :
      Step ⟨⟨t, i, e, a :: rest⟩, supply, f, q, p⟩
        ⟨⟨t, i, e, { a with weight := a.weight - shares } :: rest⟩,
          supply, f, q, p + shares⟩

theorem lifecycle_step_preserves (s s' : Lifecycle precision) (h : s.valid)
    (step : s.Step s') : s'.valid := by
  cases step with
  | allocate s m =>
    exact ⟨lazy_allocation_preserves _ _ _ h.1 (lifecycle_weight_derived s h), h.2⟩
  | rescale s k =>
    refine ⟨lazy_rescale_preserves _ _ h.1, ?_⟩
    simpa [LazyLedger.rescale, lazyWeight, LazyAccount.shift, List.map_map, Function.comp_def] using h.2
  | writeOff s =>
    refine ⟨lazy_writeOff_valid _, ?_⟩
    simpa [LazyLedger.writeOff, lazyWeight, List.map_map, Function.comp_def] using h.2
  | reorder s accounts hp =>
    refine ⟨lazy_plain_step_preserves _ _ h.1 (.reorder _ _ hp), ?_⟩
    simpa only [lazyWeight, (hp.map LazyAccount.weight).sum_eq] using h.2
  | join s =>
    refine ⟨lazy_plain_step_preserves _ _ h.1 (.join _ 0), ?_⟩
    simpa [lazyWeight] using h.2
  | deposit t i e supply f q p m a rest =>
    refine ⟨lazy_plain_step_preserves _ _ h.1 (.settle _ _ _ _ _ _), ?_⟩
    have := h.2
    simp only [lazyWeight, List.map_cons, List.sum_cons, LazyAccount.settled] at this ⊢
    omega
  | transfer t i e supply f q p shares taken a b rest hw hu =>
    constructor
    · have hm := lazy_move_preserves t i e a b rest taken hu h.1
      simpa [LazyLedger.valid, lazyLiability, LazyAccount.numerator] using hm
    · have := h.2
      simp only [lazyWeight, List.map_cons, List.sum_cons] at this ⊢
      omega
  | escrow t i e supply f q p shares taken a rest hw hu =>
    refine ⟨escrow_ledger_preserves _ _ _ _ _ _ _ hu h.1, ?_⟩
    have := h.2
    simp only [lazyWeight, List.map_cons, List.sum_cons] at this ⊢
    omega
  | start t i e supply f q p a request rest =>
    refine ⟨exit_ledger_preserves _ _ _ _ _ _ h.1, ?_⟩
    have hf := fundedOf_le f t (exitBurned t i a request) (min_le_left _ _)
    have := h.2
    simp only [lazyWeight, List.map_cons, List.sum_cons, exitOwner] at this ⊢
    omega
  | claim s burn hb => exact ⟨h.1, by have := h.2; dsimp; omega⟩
  | fundMint s shares => exact ⟨h.1, by have := h.2; dsimp; omega⟩
  | parkMint s shares => exact ⟨h.1, by have := h.2; dsimp; omega⟩
  | donate t i e supply f q p shares a rest hw =>
    refine ⟨lazy_plain_step_preserves _ _ h.1 (.settle _ _ _ _ _ _), ?_⟩
    have := h.2
    simp only [lazyWeight, List.map_cons, List.sum_cons, LazyAccount.settled] at this ⊢
    omega
  | park t i e supply f q p shares a rest hw =>
    constructor
    · apply lazy_replace_head t i e a { a with weight := a.weight - shares } rest h.1
        (h.1.1 a (by simp))
      exact Nat.add_le_add_left (Nat.mul_le_mul_right _ (Nat.sub_le _ _)) _
    · have := h.2
      simp only [lazyWeight, List.map_cons, List.sum_cons] at this ⊢
      omega

theorem lifecycle_trace_preserves (s s' : Lifecycle precision) (h : s.valid)
    (steps : Relation.ReflTransGen Lifecycle.Step s s') : s'.valid := by
  induction steps with
  | refl => exact h
  | tail steps step ih => exact lifecycle_step_preserves _ _ ih step

theorem lifecycle_reachable_weight (wallets : List ℕ) (s : Lifecycle precision)
    (steps : Relation.ReflTransGen Lifecycle.Step (Lifecycle.genesis wallets) s) :
    lazyWeight s.ledger.accounts ≤ s.outside :=
  lifecycle_weight_derived s (lifecycle_trace_preserves _ _ (lifecycle_genesis_valid wallets) steps)

theorem lifecycle_reachable_claims (wallets : List ℕ) (s : Lifecycle precision) (hr : 0 < precision)
    (steps : Relation.ReflTransGen Lifecycle.Step (Lifecycle.genesis wallets) s) :
    (s.ledger.accounts.map (LazyAccount.claim s.ledger.total s.ledger.index)).sum ≤
      s.ledger.total + s.ledger.slack / precision :=
  lazy_claims_bound _ (lifecycle_trace_preserves _ _ (lifecycle_genesis_valid wallets) steps).1 hr

theorem lifecycle_reachable_funding (wallets : List ℕ) (s : Lifecycle precision) (hr : 0 < precision)
    (ht : 0 < s.ledger.total)
    (steps : Relation.ReflTransGen Lifecycle.Step (Lifecycle.genesis wallets) s) :
    (s.ledger.accounts.map (fun a => s.funded * a.claim s.ledger.total s.ledger.index / s.ledger.total)).sum ≤
      s.funded + s.funded * (s.ledger.slack / precision) / s.ledger.total := by
  simpa only [List.map_map, Function.comp_def] using
    lazy_funded_claims_bound _ s.funded
      (lifecycle_trace_preserves _ _ (lifecycle_genesis_valid wallets) steps).1 hr ht

end Juicer.Runtime
