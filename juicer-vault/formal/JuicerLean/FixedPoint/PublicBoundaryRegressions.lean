import JuicerLean.FixedPoint.PublicMetadataReachability

namespace Juicer.PublicCalls
open Runtime

def escrowBoundaryState : State :=
  (rawExecute (rawExecute ({} : State) ⟨0,0,0,0,20000⟩).1 ⟨4,0,0,0,5000⟩).1

def escrowBoundaryAction : Action := ⟨2,vaultId,0,1,1⟩

def epochBoundaryState : State :=
  { book := { total := 1 }
    accounts := (Array.replicate actors {}).set! 0 { units := 100, epoch := 1 } }

def epochBoundaryAction : Action := ⟨8,0,0,0,0⟩

set_option maxRecDepth 20000 in
set_option maxHeartbeats 2000000 in
theorem vault_impersonation_breaks_escrow :
    PublicInvariant escrowBoundaryState ∧ FixtureAction escrowBoundaryAction ∧
      (rawRunCall escrowBoundaryState escrowBoundaryAction).isOk = true ∧
      ¬ PublicInvariant (rawExecute escrowBoundaryState escrowBoundaryAction).1 := by
  decide

theorem vault_impersonation_not_structural : ¬ StructuralAction escrowBoundaryAction := by decide

set_option maxRecDepth 20000 in
set_option maxHeartbeats 2000000 in
theorem vault_impersonation_not_valid : ¬ ValidSolidityAction escrowBoundaryState escrowBoundaryAction := by
  decide

set_option maxRecDepth 20000 in
set_option maxHeartbeats 2000000 in
theorem future_epoch_breaks_checkpoint :
    PublicInvariant epochBoundaryState ∧ FixtureAction epochBoundaryAction ∧
      (rawRunCall epochBoundaryState epochBoundaryAction).isOk = true ∧
      ¬ PublicInvariant (rawExecute epochBoundaryState epochBoundaryAction).1 := by
  decide

theorem future_epoch_not_metadata : ¬ PublicMetadata epochBoundaryState := by decide

theorem future_epoch_not_raw_reachable (initial : State) (actions : List Action)
    (h : PublicMetadata initial) : rawReplay initial actions ≠ epochBoundaryState := by
  intro heq
  have hm := rawReplay_metadata initial actions h
  rw [heq] at hm
  exact future_epoch_not_metadata hm

set_option maxRecDepth 20000 in
set_option maxHeartbeats 2000000 in
theorem future_epoch_not_valid : ¬ ValidSolidityAction epochBoundaryState epochBoundaryAction := by decide

def initialMintBoundaryState : State := { book := { index := ray } }

def initialMintBoundaryAction : Action := ⟨0,0,0,0,1001⟩

set_option maxRecDepth 20000 in
set_option maxHeartbeats 2000000 in
theorem nonzero_empty_index_breaks_initial_mint :
    PublicInvariant initialMintBoundaryState ∧ PublicMetadata initialMintBoundaryState ∧
      FixtureAction initialMintBoundaryAction ∧
      (rawRunCall initialMintBoundaryState initialMintBoundaryAction).isOk = true ∧
      ¬ PublicInvariant (rawExecute initialMintBoundaryState initialMintBoundaryAction).1 := by
  decide

theorem nonzero_empty_index_not_initialMintSafe : ¬ InitialMintSafe initialMintBoundaryState := by decide

set_option maxRecDepth 20000 in
set_option maxHeartbeats 2000000 in
theorem nonzero_empty_index_not_valid :
    ¬ ValidSolidityAction initialMintBoundaryState initialMintBoundaryAction := by decide

end Juicer.PublicCalls
