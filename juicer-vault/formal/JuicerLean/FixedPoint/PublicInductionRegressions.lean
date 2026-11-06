import JuicerLean.FixedPoint.PublicReadyReachability

set_option maxRecDepth 30000
set_option maxHeartbeats 20000000

namespace Juicer.PublicCalls
open Runtime

private def traceDecision : (s : State) → (actions : List Action) → Decidable (ValidSolidityTrace s actions)
  | _, [] => isTrue trivial
  | s, a :: rest =>
    letI := traceDecision (rawExecute s a).1 rest
    inferInstanceAs (Decidable (ValidSolidityAction s a ∧ ValidSolidityTrace (rawExecute s a).1 rest))

local instance (s : State) (actions : List Action) : Decidable (ValidSolidityTrace s actions) :=
  traceDecision s actions

private def ordinaryDecision : (s : State) → (actions : List Action) → Decidable (OrdinaryTrace s actions)
  | _, [] => isTrue trivial
  | s, a :: rest =>
    letI := ordinaryDecision (rawExecute s a).1 rest
    inferInstanceAs (Decidable (OrdinaryAction s a ∧ OrdinaryTrace (rawExecute s a).1 rest))

local instance (s : State) (actions : List Action) : Decidable (OrdinaryTrace s actions) :=
  ordinaryDecision s actions

def harvestCapacityHistory : List Action :=
  [⟨0,0,0,0,wad⟩, ⟨9,0,0,0,0⟩, ⟨30,0,0,0,wad⟩, ⟨8,0,0,0,0⟩,
   ⟨17,0,0,0,333333333333333333⟩, ⟨20,0,0,0,5000⟩, ⟨8,0,0,0,0⟩]

def harvestCapacityState : State := rawReplay {} harvestCapacityHistory

theorem harvest_capacity_history_valid : ValidSolidityTrace {} harvestCapacityHistory := by decide

theorem harvest_capacity_history_ordinary : OrdinaryTrace {} harvestCapacityHistory := by decide

theorem harvest_capacity_history_ready : PublicReady harvestCapacityState :=
  ordinaryTrace_genesis_ready harvestCapacityHistory harvest_capacity_history_ordinary

theorem harvest_capacity_history_invariant : PublicInvariant harvestCapacityState :=
  validSolidityTrace_invariant {} harvestCapacityHistory (by decide) harvest_capacity_history_valid

theorem harvest_quote_exceeds_owned_shares :
    harvestCapacityState.held = 750000000000000000 ∧
    harvestable (checkpoint harvestCapacityState zeroId zeroId) = harvestCapacityState.held+2 ∧
    harvestBurn (checkpoint harvestCapacityState zeroId zeroId) = harvestCapacityState.held := by decide

def deadImpersonationHistory : List Action :=
  [⟨0,0,0,0,wad⟩, ⟨9,0,0,0,0⟩, ⟨17,0,0,0,2*wad⟩, ⟨8,0,0,0,0⟩,
   ⟨2,4,0,0,1000⟩, ⟨4,0,0,0,max256⟩, ⟨10,0,0,0,10⟩, ⟨5,0,0,0,1⟩,
   ⟨6,0,0,0,0⟩, ⟨7,0,0,0,0⟩]

def deadImpersonationState : State := rawReplay {} deadImpersonationHistory

theorem dead_impersonation_history_valid : ValidSolidityTrace {} deadImpersonationHistory := by decide

theorem dead_impersonation_not_ordinary : ¬ OrdinaryTrace {} deadImpersonationHistory := by decide

theorem dead_impersonation_history_invariant : PublicInvariant deadImpersonationState :=
  validSolidityTrace_invariant {} deadImpersonationHistory (by decide) dead_impersonation_history_valid

theorem dead_impersonation_breaks_initialization :
    deadImpersonationState.supply = 0 ∧
    deadImpersonationState.book.index = 749999980000000000000000000 ∧
    ¬ InitialMintSafe deadImpersonationState := by decide

def missingCollateralHistory : List Action :=
  [⟨29,0,0,0,max256⟩, ⟨0,0,0,0,10^24+1⟩]

theorem missing_collateral_history_ordinary : OrdinaryTrace {} missingCollateralHistory := by decide

theorem missing_collateral_deposit_rolls_back :
    rawExecute ({ tvlCap := max256 } : State) ⟨0,0,0,0,10^24+1⟩ =
      ({ tvlCap := max256 }, 15, 0) := by rfl

theorem missing_collateral_rescale_deposit_rolls_back :
    let s : State := {
      expanded := true, feeBps := 1000, tvlCap := max256
      collateral := #[10^30,10^30,10^30,10^30,0,0,0,0] }
    rawExecute s ⟨0,0,0,0,10^30+1⟩ = (s, 15, 0) := by rfl

theorem missing_collateral_history_ready : PublicReady (rawReplay {} missingCollateralHistory) :=
  ordinaryTrace_genesis_ready missingCollateralHistory missing_collateral_history_ordinary

end Juicer.PublicCalls
