import JuicerLean.FixedPoint.PublicCertificates
import JuicerLean.FixedPoint.PublicPreservation
import JuicerLean.FixedPoint.SolidityDispatch

set_option maxRecDepth 4000
set_option maxHeartbeats 2000000

namespace Juicer.PublicCalls

def InvariantAdmissible (s : State) (a : Action) : Prop :=
  OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rawRunCall s a)

instance (s : State) (a : Action) : Decidable (InvariantAdmissible s a) := by
  unfold InvariantAdmissible OnSuccess
  cases rawRunCall s a <;> infer_instance

def ValidSolidityAction (s : State) (a : Action) : Prop :=
  FixtureAction a ∧ InvariantAdmissible s a

instance (s : State) (a : Action) : Decidable (ValidSolidityAction s a) := by
  unfold ValidSolidityAction
  infer_instance

theorem rawRunCall_success_preserves_of_valid {s next : State} {a : Action} {value : Nat}
    (valid : ValidSolidityAction s a) (h : rawRunCall s a = .ok (next, value)) :
    PublicInvariant next := by
  simpa [InvariantAdmissible, OnSuccess, h] using valid.2

theorem rawRunCall_error_admissible {s : State} {a : Action} {code : Nat}
    (h : rawRunCall s a = .error code) : InvariantAdmissible s a := by
  simp [InvariantAdmissible, h, OnSuccess]

theorem checked_eq_raw_of_admissible (s : State) (a : Action)
    (h : InvariantAdmissible s a) : runCall s a = rawRunCall s a := by
  cases hr : rawRunCall s a with
  | error code => simp [runCall, hr]
  | ok result =>
    have hp : PublicInvariant result.1 := by
      simpa [InvariantAdmissible, OnSuccess, hr] using h
    rcases result with ⟨next, value⟩
    simp [runCall, hr, hp]

theorem rawExecute_preserves_of_valid (s : State) (a : Action) (h : PublicInvariant s)
    (valid : ValidSolidityAction s a) : PublicInvariant (rawExecute s a).1 := by
  cases hr : rawRunCall s a with
  | error code => simpa [rawExecute, hr] using h
  | ok result =>
    rcases result with ⟨next, value⟩
    simpa [rawExecute, hr] using rawRunCall_success_preserves_of_valid valid hr

def rawReplay : State → List Action → State
  | s, [] => s
  | s, a :: rest => rawReplay (rawExecute s a).1 rest

def ValidSolidityTrace : State → List Action → Prop
  | _, [] => True
  | s, a :: rest => ValidSolidityAction s a ∧
      ValidSolidityTrace (rawExecute s a).1 rest

theorem validSolidityTrace_invariant (s : State) (actions : List Action)
    (initial : PublicInvariant s) (valid : ValidSolidityTrace s actions) :
    PublicInvariant (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => simpa [rawReplay]
  | cons a rest ih =>
    exact ih (rawExecute s a).1 (rawExecute_preserves_of_valid s a initial valid.1) valid.2

inductive ValidSolidityReachable (initial : State) : State → Prop
  | genesis (certified : PublicInvariant initial) : ValidSolidityReachable initial initial
  | step {s : State} (reachable : ValidSolidityReachable initial s) (a : Action)
      (valid : ValidSolidityAction s a) :
      ValidSolidityReachable initial (rawExecute s a).1

theorem validSolidityReachable_invariant {initial s : State}
    (h : ValidSolidityReachable initial s) : PublicInvariant s := by
  induction h with
  | genesis certified => exact certified
  | step reachable a valid ih => exact rawExecute_preserves_of_valid _ _ ih valid

theorem validSolidityTrace_reachable {initial s : State} {actions : List Action}
    (reachable : ValidSolidityReachable initial s) (valid : ValidSolidityTrace s actions) :
    ValidSolidityReachable initial (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => simpa [rawReplay]
  | cons a rest ih =>
    exact ih (.step reachable a valid.1) valid.2

theorem reachable_rawRunCall_success_preserves {initial s next : State}
    {a : Action} {value : Nat} (reachable : ValidSolidityReachable initial s)
    (valid : ValidSolidityAction s a) (h : rawRunCall s a = .ok (next, value)) :
    PublicInvariant next := by
  have _ := validSolidityReachable_invariant reachable
  exact rawRunCall_success_preserves_of_valid valid h

theorem reachable_dispatch_success_preserves {initial s next : State}
    {a : Action} {value : Nat} (reachable : ValidSolidityReachable initial s)
    (valid : ValidSolidityAction s a) (h : solidityDispatch s a = .ok (next, value)) :
    PublicInvariant next := by
  rw [solidity_dispatch_corresponds] at h
  exact reachable_rawRunCall_success_preserves reachable valid h

set_option maxRecDepth 10000 in
set_option maxHeartbeats 1000000 in
theorem orphan_claim_not_valid :
    ¬ ValidSolidityAction orphanClaimState orphanClaimAction := by decide

end Juicer.PublicCalls
