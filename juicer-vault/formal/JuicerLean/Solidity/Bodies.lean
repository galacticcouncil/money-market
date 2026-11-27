import JuicerLean.Solidity.GeneratedGuards

namespace Juicer.Solidity

inductive BodySemantic where
  | vaultDeposit
  | accountingBeginHarvest
  | accountingSplitHarvest
  | vaultStartUnwinds
  | vaultPokeSettle
  deriving DecidableEq, Repr

inductive BodyStepKind where
  | block
  | bind
  | branch
  | loop
  | call
  | write
  | emit
  | revert
  | return
  | break
  | continue
  deriving DecidableEq, Repr

structure BodyStep where
  kind : BodyStepKind
  label : String
  depth : Nat
  deriving DecidableEq, Repr

structure BodyBinding where
  semantic : BodySemantic
  contract : GuardContract
  selector : Nat
  source : String
  functionName : String
  astSha256 : String
  parameterCount : Nat
  returnCount : Nat
  statementCount : Nat
  trace : List BodyStep
  deriving DecidableEq, Repr

def BodyBinding.guards (binding : BodyBinding) : List GuardPlan :=
  guardPrefix binding.contract binding.selector

def BodyBinding.hasStep (binding : BodyBinding) (kind : BodyStepKind) (label : String) : Bool :=
  binding.trace.any fun step => step.kind == kind && step.label == label

end Juicer.Solidity
