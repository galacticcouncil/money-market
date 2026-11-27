import JuicerLean.Solidity.Expressions

namespace Juicer.Solidity

structure CallState (σ : Type) where
  status : Nat
  data : σ

inductive GuardFailure where
  | unauthorized
  | reentrant
  | bodyFailure (code : Nat)
  deriving DecidableEq, Repr

abbrev GuardResult (σ α : Type) := Except GuardFailure (CallState σ × α)

inductive GuardPlan where
  | onlyVault
  | nonReentrant (entered cleared : Nat)
  deriving DecidableEq, Repr

inductive GuardContract where
  | accounting
  | mainDebt
  | vault
  | controller
  deriving DecidableEq, Repr

def GuardPlan.run {σ α : Type} (plan : GuardPlan) (caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) : GuardResult σ α :=
  match plan with
  | .onlyVault => if caller = vault then body s else .error .unauthorized
  | .nonReentrant entered cleared =>
    if s.status = entered then .error .reentrant
    else
      match body { s with status := entered } with
      | .error failure => .error failure
      | .ok (next,value) => .ok ({ next with status := cleared },value)

def GuardPlan.execute {σ α : Type} (plan : GuardPlan) (caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) : CallState σ × Except GuardFailure α :=
  match plan.run caller vault s body with
  | .error failure => (s,.error failure)
  | .ok (next,value) => (next,.ok value)

def runGuards {σ α : Type} : List GuardPlan → Nat → Nat → CallState σ →
    (CallState σ → GuardResult σ α) → GuardResult σ α
  | [], _, _, s, body => body s
  | plan :: rest, caller, vault, s, body =>
    plan.run caller vault s (fun current => runGuards rest caller vault current body)

def executeGuards {σ α : Type} (plans : List GuardPlan) (caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) : CallState σ × Except GuardFailure α :=
  match runGuards plans caller vault s body with
  | .error failure => (s,.error failure)
  | .ok (next,value) => (next,.ok value)

structure TransferGuard where
  entered : Nat

def TransferGuard.run {σ α : Type} (guard : TransferGuard) (sender recipient vault fund : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α) : GuardResult σ α :=
  if sender ≠ vault ∧ recipient ≠ vault ∧ sender ≠ fund ∧ s.status = guard.entered
  then .error .reentrant else body s

theorem onlyVault_denied {σ α : Type} (caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) (h : caller ≠ vault) :
    GuardPlan.run .onlyVault caller vault s body = .error .unauthorized := by
  simp only [GuardPlan.run,if_neg h]

theorem onlyVault_authorized {σ α : Type} (caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) (h : caller = vault) :
    GuardPlan.run .onlyVault caller vault s body = body s := by
  simp only [GuardPlan.run,if_pos h]

theorem reentry_denied {σ α : Type} (entered cleared caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) (h : s.status = entered) :
    GuardPlan.run (.nonReentrant entered cleared) caller vault s body = .error .reentrant := by
  simp only [GuardPlan.run,if_pos h]

theorem body_enters_locked {σ α : Type} (entered cleared caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) (h : s.status ≠ entered) :
    GuardPlan.run (.nonReentrant entered cleared) caller vault s body =
      (body { s with status := entered }).map (fun result => ({ result.1 with status := cleared },result.2)) := by
  simp only [GuardPlan.run,if_neg h]
  cases heq : body { s with status := entered } with
  | error failure => rfl
  | ok result => cases result; rfl

theorem successful_call_clears_lock {σ α : Type} (entered cleared caller vault : Nat)
    (s next : CallState σ) (value : α) (body : CallState σ → GuardResult σ α)
    (h : GuardPlan.run (.nonReentrant entered cleared) caller vault s body = .ok (next,value)) :
    next.status = cleared := by
  by_cases hlock : s.status = entered
  · simp only [GuardPlan.run,if_pos hlock] at h
    contradiction
  · simp only [GuardPlan.run,if_neg hlock] at h
    cases heq : body { s with status := entered } with
    | error e => simp only [heq] at h; contradiction
    | ok result =>
      rcases result with ⟨after,valueAfter⟩
      simp only [heq,Except.ok.injEq,Prod.mk.injEq] at h
      exact congrArg CallState.status h.1.symm

theorem guard_failure_rolls_back {σ α : Type} (plan : GuardPlan) (caller vault : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α) (failure : GuardFailure)
    (h : plan.run caller vault s body = .error failure) :
    plan.execute caller vault s body = (s,.error failure) := by
  simp only [GuardPlan.execute,h]

def DataPreserved {σ α : Type} (predicate : σ → Prop) : GuardResult σ α → Prop
  | .error _ => True
  | .ok (next,_) => predicate next.data

theorem guard_preserves_data {σ α : Type} (plan : GuardPlan) (caller vault : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α) (predicate : σ → Prop)
    (h : predicate s.data) (hb : ∀ current, predicate current.data → DataPreserved predicate (body current)) :
    DataPreserved predicate (plan.run caller vault s body) := by
  cases plan with
  | onlyVault =>
    by_cases authorized : caller = vault
    · simpa only [GuardPlan.run,if_pos authorized] using hb s h
    · simp only [GuardPlan.run,if_neg authorized,DataPreserved]
  | nonReentrant entered cleared =>
    by_cases locked : s.status = entered
    · simp only [GuardPlan.run,if_pos locked,DataPreserved]
    · simp only [GuardPlan.run,if_neg locked]
      have hbody := hb { s with status := entered } h
      cases heq : body { s with status := entered } with
      | error e => trivial
      | ok result =>
        rcases result with ⟨next,value⟩
        simpa only [heq,DataPreserved] using hbody

theorem guards_preserve_data {σ α : Type} (plans : List GuardPlan) (caller vault : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α) (predicate : σ → Prop)
    (h : predicate s.data) (hb : ∀ current, predicate current.data → DataPreserved predicate (body current)) :
    DataPreserved predicate (runGuards plans caller vault s body) := by
  induction plans generalizing s with
  | nil => exact hb s h
  | cons plan rest ih => exact guard_preserves_data plan caller vault s _ predicate h ih

theorem guards_preserve_from {σ α : Type} (plans : List GuardPlan) (caller vault : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α) (predicate : σ → Prop)
    (hb : ∀ status, DataPreserved predicate (body ⟨status,s.data⟩)) :
    DataPreserved predicate (runGuards plans caller vault s body) := by
  induction plans generalizing s with
  | nil => exact hb s.status
  | cons plan rest ih =>
    cases plan with
    | onlyVault =>
      by_cases authorized : caller = vault
      · simpa only [runGuards,GuardPlan.run,if_pos authorized] using ih s hb
      · simp only [runGuards,GuardPlan.run,if_neg authorized,DataPreserved]
    | nonReentrant entered cleared =>
      by_cases locked : s.status = entered
      · simp only [runGuards,GuardPlan.run,if_pos locked,DataPreserved]
      · simp only [runGuards,GuardPlan.run,if_neg locked]
        have hrest := ih ⟨entered,s.data⟩ hb
        cases heq : runGuards rest caller vault ⟨entered,s.data⟩ body with
        | error e => trivial
        | ok result =>
          rcases result with ⟨next,value⟩
          simpa only [heq,DataPreserved] using hrest

theorem transfer_reentry_denied {σ α : Type} (guard : TransferGuard) (sender recipient vault fund : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α)
    (hf : sender ≠ vault) (ht : recipient ≠ vault) (ha : sender ≠ fund) (hs : s.status = guard.entered) :
    guard.run sender recipient vault fund s body = .error .reentrant := by
  exact if_pos ⟨hf,ht,ha,hs⟩

theorem transfer_exemption {σ α : Type} (guard : TransferGuard) (sender recipient vault fund : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α)
    (h : sender = vault ∨ recipient = vault ∨ sender = fund) :
    guard.run sender recipient vault fund s body = body s := by
  have hn : ¬ (sender ≠ vault ∧ recipient ≠ vault ∧ sender ≠ fund ∧ s.status = guard.entered) := by
    rintro ⟨hf,ht,ha,_⟩
    rcases h with h | h | h
    · exact hf h
    · exact ht h
    · exact ha h
  simp only [TransferGuard.run,if_neg hn]

theorem guards_failure_rolls_back {σ α : Type} (plans : List GuardPlan) (caller vault : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α) (failure : GuardFailure)
    (h : runGuards plans caller vault s body = .error failure) :
    executeGuards plans caller vault s body = (s,.error failure) := by
  simp only [executeGuards,h]

end Juicer.Solidity
