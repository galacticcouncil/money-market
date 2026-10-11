import JuicerLean.FixedPoint.PublicInvariants
import JuicerLean.FixedPoint.RescaleBounds

namespace Juicer.PublicCalls

open Runtime

def publicSlack (s : State) : Nat :=
  lazyLiability s.book.index (publicLifecycle s 0 0).ledger.accounts - s.book.total * ray

def publicParked (s : State) : Nat :=
  wallet s vaultId - s.pending - s.queued + wallet s zeroId

def publicProjection (s : State) : Lifecycle ray :=
  publicLifecycle s (publicSlack s) (publicParked s)

def PublicInvariant (s : State) : Prop :=
  CollateralConserved s ∧
  (sourceProjection s).valid ∧
  (cashProjection s).valid ∧
  (publicProjection s).valid ∧
  publicSlack s < ray

instance (s : State) : Decidable (PublicInvariant s) := by
  unfold PublicInvariant CollateralConserved SourceClaims.valid CashBook.valid
    Lifecycle.valid LazyLedger.valid
  infer_instance

def certify (s : State) : Option { next : State // PublicInvariant next } :=
  if h : PublicInvariant s then some ⟨s, h⟩ else none

def certifiedExecute (s : State) (a : Action) :
    Option ({ next : State // PublicInvariant next } × Nat × Nat) := do
  let (next, code, value) := execute s a
  let checked ← certify next
  return (checked, code, value)

theorem certify_sound {s : State} {checked : { next : State // PublicInvariant next }}
    (h : certify s = some checked) : checked.val = s ∧ PublicInvariant s := by
  unfold certify at h
  split at h
  · simp only [Option.some.injEq] at h
    subst checked
    exact ⟨rfl, ‹PublicInvariant s›⟩
  · contradiction

theorem certifiedExecute_matches {s : State} {a : Action}
    {result : { next : State // PublicInvariant next } × Nat × Nat}
    (h : certifiedExecute s a = some result) :
    execute s a = (result.1.val, result.2) ∧ PublicInvariant result.1.val := by
  unfold certifiedExecute at h
  cases hc : certify (execute s a).1 with
  | none => simp [hc] at h
  | some checked =>
    simp [hc] at h
    subst result
    exact ⟨by rw [(certify_sound hc).1], checked.property⟩

theorem certified_failure_rolls_back (s : State) (a : Action) (code : Nat)
    (h : PublicInvariant s) (failed : runCall s a = .error code) :
    certifiedExecute s a = some (⟨s, h⟩, code, 0) := by
  simp [certifiedExecute, execute, failed, certify, h]

def certifiedReplay (s : State) : List Action → Option (List State)
  | [] => if PublicInvariant s then some [s] else none
  | a :: rest => do
    let (next, _, _) ← certifiedExecute s a
    let tail ← certifiedReplay next.val rest
    return s :: tail

def statesOf (s : State) : List Action → List State
  | [] => [s]
  | a :: rest => s :: statesOf (execute s a).1 rest

theorem certifiedReplay_matches {s : State} {actions : List Action} {states : List State}
    (h : certifiedReplay s actions = some states) : states = statesOf s actions := by
  induction actions generalizing s states with
  | nil =>
    simp only [certifiedReplay] at h
    split at h
    · simpa [statesOf] using h.symm
    · contradiction
  | cons a rest ih =>
    unfold certifiedReplay at h
    cases hc : certifiedExecute s a with
    | none => simp [hc] at h
    | some result =>
      simp only [hc] at h
      cases ht : certifiedReplay result.1.val rest with
      | none => simp [ht] at h
      | some tail =>
        simp [ht] at h
        subst states
        rw [statesOf, (certifiedExecute_matches hc).1, ih ht]

theorem certifiedReplay_preserves {s : State} {actions : List Action} {states : List State}
    (initial : PublicInvariant s) (h : certifiedReplay s actions = some states) :
    ∀ next ∈ states, PublicInvariant next := by
  induction actions generalizing s states with
  | nil =>
    simp [certifiedReplay, initial] at h
    subst states
    simpa using initial
  | cons a rest ih =>
    unfold certifiedReplay at h
    cases hc : certifiedExecute s a with
    | none => simp [hc] at h
    | some result =>
      simp only [hc] at h
      cases ht : certifiedReplay result.1.val rest with
      | none => simp [ht] at h
      | some tail =>
        simp [ht] at h
        subst states
        intro next hn
        rcases List.mem_cons.mp hn with rfl | hn
        · exact initial
        · exact ih result.1.property ht next hn

theorem certified_public_claims {s : State} (h : PublicInvariant s) :
    ((publicProjection s).ledger.accounts.map (LazyAccount.claim s.book.total s.book.index)).sum ≤ s.book.total := by
  have bound := lazy_claims_bound (publicProjection s).ledger h.2.2.2.1.1 (by norm_num [ray])
  simpa [publicProjection, publicLifecycle, Nat.div_eq_of_lt h.2.2.2.2] using bound

theorem certified_public_funded {s : State} (funded : Nat) (h : PublicInvariant s) :
    (((publicProjection s).ledger.accounts.map (LazyAccount.claim s.book.total s.book.index)).map
      (fun units => fundedOf funded s.book.total units)).sum ≤ funded := by
  by_cases ht : s.book.total = 0
  · simp [fundedOf, ht, Function.comp_def]
  · simpa [fundedOf, ht] using pooled_claims_bound funded s.book.total 0 _
      (Nat.pos_of_ne_zero ht) (certified_public_claims h)

theorem genesis_public_invariant (expanded : Bool) :
    PublicInvariant ({ expanded, feeBps := if expanded then 1000 else 0 } : State) := by
  norm_num [PublicInvariant, CollateralConserved, sourceProjection, cashProjection,
    SourceClaims.valid, CashBook.valid, publicProjection, publicSlack, publicParked,
    publicLifecycle, Lifecycle.valid, LazyLedger.valid, lazyLiability, lazyWeight,
    normalizeAccount, LazyAccount.numerator, account, wallet, vaultId, fundId, zeroId, actors, ray,
    List.range_succ, Function.comp_def]

theorem certificate_rejects_custody_corruption :
    (certify ({ assets := 1 } : State)).isSome = false := by decide

theorem certificate_rejects_source_corruption :
    (certify ({ outstanding := 1 } : State)).isSome = false := by decide

theorem certificate_rejects_cash_corruption :
    (certify ({ ownedCash := 1 } : State)).isSome = false := by decide

theorem certificate_rejects_share_corruption :
    (certify ({ supply := 1 } : State)).isSome = false := by decide

theorem certificate_rejects_liability_corruption :
    (certify ({ book := { total := 1 }, accounts := (Array.replicate actors {}).set! 0 { units := 2 } } : State)).isSome = false := by decide

theorem certificate_accepts_deposit :
    (certifiedExecute ({} : State) ⟨0, 0, 0, 0, 20 * 10 ^ 18⟩).isSome = true := by decide

end Juicer.PublicCalls
