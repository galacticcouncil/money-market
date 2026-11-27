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

def activeRequests (s : State) : List Request := s.requests.toList.take s.unwind

def waitingRequests (s : State) : List Request := s.requests.toList.drop s.unwind

def OperationalInvariant (s : State) : Prop :=
  s.wallets.size = actors ∧ s.accounts.size = actors ∧ s.collateral.size = actors ∧
  s.approvals.size = 16 ∧ 0 < s.positions.size ∧ s.unwind ≤ s.requests.size ∧
  s.supply = s.wallets.toList.sum ∧
  s.mainUnits = (s.positions.toList.map MainPosition.units).sum ∧
  s.freed + s.unallocated + s.unallocatedCost = s.outstanding ∧
  s.sourceFees.size = s.positions.size ∧
  s.feeReserve = (s.sourceFees.toList.map SourceFee.feeLeft).sum ∧
  (∀ fee ∈ s.sourceFees.toList, fee.feeLeft ≤ fee.yieldLeft) ∧
  (s.expanded = true → sourceValue s s.held + s.freed ≤ s.sourceCash) ∧
  (∀ r ∈ activeRequests s, r.claim.valid) ∧
  s.pending = ((waitingRequests s).map fun r => r.claim.shares).sum ∧
  s.queued = ((activeRequests s).map fun r => r.claim.shares - r.claim.burned).sum ∧
  s.owed = ((activeRequests s).map fun r => r.claim.owed - r.claim.claimed).sum ∧
  s.queuedDebt = ((activeRequests s).map fun r => r.claim.debt - r.claim.repaid).sum ∧
  s.pending + s.queued ≤ wallet s vaultId ∧
  (((activeRequests s).map fun r => r.claim.settled).sum ≤ s.assets) ∧
  (((activeRequests s).map fun r => r.claim.settled).sum ≤ s.liquid)

def PublicInvariant (s : State) : Prop :=
  CollateralConserved s ∧
  (sourceProjection s).valid ∧
  (cashProjection s).valid ∧
  (publicProjection s).valid ∧
  publicSlack s < ray ∧
  OperationalInvariant s

instance (s : State) : Decidable (CollateralConserved s) := by
  unfold CollateralConserved
  infer_instance

instance (s : SourceClaims) : Decidable s.valid := by
  unfold SourceClaims.valid
  infer_instance

instance (s : CashBook) : Decidable s.valid := by
  unfold CashBook.valid
  infer_instance

instance {precision : Nat} (s : LazyLedger precision) : Decidable s.valid := by
  unfold LazyLedger.valid
  infer_instance

instance {precision : Nat} (s : Lifecycle precision) : Decidable s.valid := by
  unfold Lifecycle.valid
  infer_instance

instance (s : State) : Decidable (OperationalInvariant s) := by
  unfold OperationalInvariant activeRequests waitingRequests RedemptionState.valid claimEntitlement
  infer_instance

instance (s : State) : Decidable (PublicInvariant s) := by
  unfold PublicInvariant CollateralConserved SourceClaims.valid CashBook.valid
    Lifecycle.valid LazyLedger.valid OperationalInvariant activeRequests waitingRequests
    RedemptionState.valid claimEntitlement
  infer_instance

def certify (s : State) : Option { next : State // PublicInvariant next } :=
  if h : PublicInvariant s then some ⟨s, h⟩ else none

def invariantViolationCode : Nat := 98

def runCall (input : State) (action : Action) : Result :=
  match rawRunCall input action with
  | .error code => .error code
  | .ok (next, value) =>
    if PublicInvariant next then .ok (next, value) else .error invariantViolationCode

def execute (s : State) (a : Action) : State × Nat × Nat :=
  match runCall s a with
  | .ok (next, value) => (next, 0, value)
  | .error code => (s, code, 0)

theorem runCall_success_preserves {s next : State} {a : Action} {value : Nat}
    (h : runCall s a = .ok (next, value)) : PublicInvariant next := by
  unfold runCall at h
  cases hr : rawRunCall s a with
  | error code => simp [hr] at h
  | ok result =>
    rcases result with ⟨rawNext, rawValue⟩
    simp only [hr] at h
    split at h
    · simp only [Except.ok.injEq, Prod.mk.injEq] at h
      rcases h with ⟨rfl, rfl⟩
      exact ‹PublicInvariant rawNext›
    · contradiction

theorem runCall_success_matches_raw {s next : State} {a : Action} {value : Nat}
    (h : runCall s a = .ok (next, value)) : rawRunCall s a = .ok (next, value) := by
  unfold runCall at h
  cases hr : rawRunCall s a with
  | error code => simp [hr] at h
  | ok result =>
    rcases result with ⟨rawNext, rawValue⟩
    simp only [hr] at h
    split at h
    · simpa only [Except.ok.injEq, Prod.mk.injEq] using h
    · contradiction

theorem runCall_accepts {s next : State} {a : Action} {value : Nat}
    (raw : rawRunCall s a = .ok (next, value)) (h : PublicInvariant next) :
    runCall s a = .ok (next, value) := by
  simp [runCall, raw, h]

theorem runCall_rejects {s next : State} {a : Action} {value : Nat}
    (raw : rawRunCall s a = .ok (next, value)) (h : ¬ PublicInvariant next) :
    runCall s a = .error invariantViolationCode := by
  simp [runCall, raw, h]

theorem failure_rolls_back (s : State) (a : Action) (code : Nat)
    (h : runCall s a = .error code) : execute s a = (s, code, 0) := by
  simp [execute, h]

theorem execute_preserves (s : State) (a : Action) (h : PublicInvariant s) :
    PublicInvariant (execute s a).1 := by
  unfold execute
  cases hc : runCall s a with
  | error code => simpa [hc] using h
  | ok result =>
    rcases result with ⟨next, value⟩
    simpa [hc] using runCall_success_preserves hc

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

theorem certifiedExecute_total (s : State) (a : Action) (h : PublicInvariant s) :
    (certifiedExecute s a).isSome = true := by
  unfold certifiedExecute
  have hp := execute_preserves s a h
  simp [certify, hp]

def certifiedReplay (s : State) : List Action → Option (List State)
  | [] => if PublicInvariant s then some [s] else none
  | a :: rest => do
    let (next, _, _) ← certifiedExecute s a
    let tail ← certifiedReplay next.val rest
    return s :: tail

theorem certifiedReplay_total (s : State) (actions : List Action) (h : PublicInvariant s) :
    (certifiedReplay s actions).isSome = true := by
  induction actions generalizing s with
  | nil => simp [certifiedReplay, h]
  | cons a rest ih =>
    unfold certifiedReplay
    cases hc : certifiedExecute s a with
    | none =>
      have ht := certifiedExecute_total s a h
      simp [hc] at ht
    | some result =>
      have ht := ih result.1.val result.1.property
      cases hr : certifiedReplay result.1.val rest with
      | none => simp [hr] at ht
      | some states => simp [hr]

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
  simpa [publicProjection, publicLifecycle, Nat.div_eq_of_lt h.2.2.2.2.1] using bound

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
    OperationalInvariant, activeRequests, waitingRequests, sourceValue, normalizeAccount,
    LazyAccount.numerator, account, wallet, vaultId, fundId, zeroId, actors, ray,
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

def orphanClaim : Request :=
  { owner := 0, claim := {
      shares := 1, owed := 1, debt := 0, repaid := 0,
      settled := 1, burned := 0, claimed := 0, active := true } }

def orphanClaimState : State :=
  { requests := #[orphanClaim], head := 0, unwind := 1 }

def orphanClaimAction : Action := ⟨7, 0, 0, 0, 0⟩

set_option maxRecDepth 10000 in
set_option maxHeartbeats 1000000 in
theorem certificate_rejects_orphan_claim :
    (certify orphanClaimState).isSome = false := by decide

set_option maxRecDepth 10000 in
set_option maxHeartbeats 1000000 in
theorem raw_orphan_claim_succeeds :
    (rawRunCall orphanClaimState orphanClaimAction).isOk = true := by decide

def resultCode : Result → Nat
  | .error code => code
  | .ok _ => 0

set_option maxRecDepth 10000 in
set_option maxHeartbeats 1000000 in
theorem checked_orphan_claim_rejected :
    resultCode (runCall orphanClaimState orphanClaimAction) = invariantViolationCode := by decide

theorem certificate_accepts_deposit :
    (certifiedExecute ({} : State) ⟨0, 0, 0, 0, 20 * 10 ^ 18⟩).isSome = true := by decide

end Juicer.PublicCalls
