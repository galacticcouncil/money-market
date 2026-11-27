import Lean
import JuicerLean.FixedPoint.ScaledDebt

open Lean Juicer.Runtime

def numbers (j : Json) (key : String) : Except String (Array Nat) := do
  let values ← (← j.getObjVal? key).getArr?
  values.mapM fun value =>
    match value with
    | .str text => match text.toNat? with
      | some n => .ok n
      | none => .error "invalid decimal uint256"
    | _ => value.getNat?

def flag (j : Json) (key : String) : Except String Bool := do
  (← j.getObjVal? key).getBool?

def compare (row : Nat) (expected actual : Array Nat) : Except String Unit := do
  if expected.size != actual.size then
    throw s!"row {row}: snapshot length {expected.size} != {actual.size}"
  for i in [:expected.size] do
    if expected[i]! != actual[i]! then
      throw s!"row {row}, field {i}: Lean {expected[i]!}, Solidity {actual[i]!}"

def main (args : List String) : IO Unit := do
  let path ← match args with
    | [path] => pure path
    | _ => throw (IO.userError "provide one scaled-debt trace")
  let lines := (← IO.FS.readFile path).splitOn "\n" |>.filter (· != "")
  if lines.length < 3 then throw (IO.userError "scaled-debt trace is incomplete")
  let mut state : ScaledDebt := {}
  let mut failures := 0
  for row in [:lines.length] do
    let j ← IO.ofExcept (Json.parse lines[row]!)
    let action ← IO.ofExcept (numbers j "action")
    let actual ← IO.ofExcept (numbers j "state")
    let ok ← IO.ofExcept (flag j "ok")
    if action.size != 3 then throw (IO.userError s!"row {row}: expected three action fields")
    if row == 0 then
      if action != #[999, 0, 0] || !ok then throw (IO.userError "invalid scaled-debt genesis")
      IO.ofExcept (compare row (scaledDebtSnapshot state) actual)
    else if row + 1 == lines.length then
      if action != #[998, 0, 516] || !ok then throw (IO.userError "invalid scaled-debt completion marker")
      IO.ofExcept (compare row (scaledDebtSnapshot state) actual)
    else
      match scaledDebtCall state action[0]! action[1]! action[2]! with
      | some next =>
        if !ok then throw (IO.userError s!"row {row}: Lean accepted, Solidity reverted")
        IO.ofExcept (compare row (scaledDebtSnapshot next) actual)
        state := next
      | none =>
        if ok then throw (IO.userError s!"row {row}: Lean rejected, Solidity accepted")
        IO.ofExcept (compare row (scaledDebtSnapshot state) actual)
        failures := failures + 1
  IO.println s!"Aave scaled-debt replay passed: {lines.length - 2} calls, {failures} expected reverts"
