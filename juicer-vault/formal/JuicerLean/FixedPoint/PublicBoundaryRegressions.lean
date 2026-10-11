import JuicerLean.FixedPoint.PublicReachability

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

end Juicer.PublicCalls
