import JuicerLean.Solidity.GeneratedGuards
import JuicerLean.FixedPoint.PublicReachability

namespace Juicer.Solidity

theorem accounting_prefix_shape (selector : Nat) :
    guardPrefix .accounting selector = [] ∨ guardPrefix .accounting selector = [accountingOnlyVault] := by
  unfold guardPrefix
  split <;> simp_all

theorem accounting_entry_denied {σ α : Type} (selector caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) (hcovered : guardPrefix .accounting selector ≠ [])
    (hcaller : caller ≠ vault) :
    runGuards (guardPrefix .accounting selector) caller vault s body = .error .unauthorized := by
  rcases accounting_prefix_shape selector with h | h
  · exact False.elim (hcovered h)
  · rw [h]
    exact onlyVault_denied caller vault s body hcaller

theorem vault_prefix_shape (selector : Nat) :
    guardPrefix .vault selector = [] ∨ guardPrefix .vault selector = [vaultNonReentrant] := by
  unfold guardPrefix
  split <;> simp_all

theorem vault_entry_reentry_denied {σ α : Type} (selector caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) (hcovered : guardPrefix .vault selector ≠ [])
    (hlock : s.status = 2) :
    runGuards (guardPrefix .vault selector) caller vault s body = .error .reentrant := by
  rcases vault_prefix_shape selector with h | h
  · exact False.elim (hcovered h)
  · rw [h]
    exact reentry_denied 2 1 caller vault s body hlock

theorem vault_entry_clears_lock {σ α : Type} (selector caller vault : Nat) (s next : CallState σ)
    (body : CallState σ → GuardResult σ α) (value : α) (hcovered : guardPrefix .vault selector ≠ [])
    (h : runGuards (guardPrefix .vault selector) caller vault s body = .ok (next,value)) :
    next.status = 1 := by
  rcases vault_prefix_shape selector with hempty | hguard
  · exact False.elim (hcovered hempty)
  · rw [hguard] at h
    exact successful_call_clears_lock 2 1 caller vault s next value body h

theorem main_startExit_guard {σ α : Type} (caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) (hlock : s.status = 2) :
    runGuards (guardPrefix .mainDebt 0x7f2dea43) caller vault s body =
      .error (if caller = vault then .reentrant else .unauthorized) := by
  by_cases hcaller : caller = vault
  · simp only [guardPrefix,runGuards,mainOnlyVault,regularNonReentrant,GuardPlan.run,
      if_pos hcaller,if_pos hlock]
  · simp only [guardPrefix,runGuards,mainOnlyVault,GuardPlan.run,if_neg hcaller]

theorem controller_execute_reentry_denied {σ α : Type} (caller vault : Nat) (s : CallState σ)
    (body : CallState σ → GuardResult σ α) (hlock : s.status = 2) :
    runGuards (guardPrefix .controller 0x8e9b05c6) caller vault s body = .error .reentrant :=
  reentry_denied 2 1 caller vault s body hlock

theorem vault_transfer_reentry_denied {σ α : Type} (sender recipient vault fund : Nat)
    (s : CallState σ) (body : CallState σ → GuardResult σ α)
    (hf : sender ≠ vault) (ht : recipient ≠ vault) (ha : sender ≠ fund) (hs : s.status = 2) :
    vaultTransferGuard.run sender recipient vault fund s body = .error .reentrant :=
  transfer_reentry_denied vaultTransferGuard sender recipient vault fund s body hf ht ha hs

theorem compiled_guards_preserve_publicInvariant {α : Type} (contract : GuardContract)
    (selector caller vault : Nat) (s : CallState PublicCalls.State)
    (body : CallState PublicCalls.State → GuardResult PublicCalls.State α)
    (h : PublicCalls.PublicInvariant s.data)
    (hb : ∀ current, PublicCalls.PublicInvariant current.data → DataPreserved PublicCalls.PublicInvariant (body current)) :
    DataPreserved PublicCalls.PublicInvariant (runGuards (guardPrefix contract selector) caller vault s body) :=
  guards_preserve_data _ caller vault s body PublicCalls.PublicInvariant h hb

def rawPublicBody (action : PublicCalls.Action) (s : CallState PublicCalls.State) :
    GuardResult PublicCalls.State Nat :=
  match PublicCalls.rawRunCall s.data action with
  | .error code => .error (.bodyFailure code)
  | .ok (next,value) => .ok (⟨s.status,next⟩,value)

theorem guarded_raw_body_preserves (contract : GuardContract) (selector caller vault : Nat)
    (s : CallState PublicCalls.State) (action : PublicCalls.Action)
    (h : PublicCalls.PublicInvariant s.data) (ha : PublicCalls.ValidSolidityAction s.data action) :
    DataPreserved PublicCalls.PublicInvariant
      (runGuards (guardPrefix contract selector) caller vault s (rawPublicBody action)) := by
  apply guards_preserve_from
  intro status
  unfold rawPublicBody
  cases heq : PublicCalls.rawRunCall s.data action with
  | error code => trivial
  | ok result =>
    rcases result with ⟨next,value⟩
    exact PublicCalls.rawRunCall_success_preserves_of_valid h ha heq

theorem guarded_raw_execute_preserves (contract : GuardContract) (selector caller vault : Nat)
    (s : CallState PublicCalls.State) (action : PublicCalls.Action)
    (h : PublicCalls.PublicInvariant s.data) (ha : PublicCalls.ValidSolidityAction s.data action) :
    PublicCalls.PublicInvariant
      (executeGuards (guardPrefix contract selector) caller vault s (rawPublicBody action)).1.data := by
  have hp := guarded_raw_body_preserves contract selector caller vault s action h ha
  unfold executeGuards
  cases heq : runGuards (guardPrefix contract selector) caller vault s (rawPublicBody action) with
  | error code => exact h
  | ok result =>
    rcases result with ⟨next,value⟩
    simpa only [heq,DataPreserved] using hp

end Juicer.Solidity
