import Lean
import JuicerLean.FixedPoint.SharedIntent

open Lean Juicer.SharedIntent

private def uint (j : Json) : Except String Nat :=
  match j with
  | .str text => match text.toNat? with
    | some n => .ok n
    | none => .error "invalid decimal integer"
  | _ => j.getNat?

private def numbers (j : Json) (key : String) : Except String (Array Nat) := do
  (← (← j.getObjVal? key).getArr?).mapM uint

private def compare (row : Nat) (expected actual : Array Nat) : Except String Unit := do
  if expected.size != actual.size then throw s!"row {row}: snapshot length mismatch"
  for i in [:expected.size] do
    if expected[i]! != actual[i]! then
      throw s!"row {row}, field {i}: Lean {expected[i]!}, Solidity {actual[i]!}"

def main (args : List String) : IO Unit := do
  if args.length != 6 then throw (IO.userError "provide all six shared-intent traces")
  let mut calls := 0
  let mut reverts := 0
  let mut legacyHarvestDetected := 0
  let mut rebases := 0
  let mut fills := 0
  let mut refunds := 0
  let mut spoofs := 0
  for path in args do
    let lines := (← IO.FS.readFile path).splitOn "\n" |>.filter (· != "")
    if lines.length < 3 then throw (IO.userError s!"{path}: incomplete trace")
    let mut state : State := {}
    for row in [:lines.length] do
      let j ← IO.ofExcept (Json.parse lines[row]!)
      let action ← IO.ofExcept (numbers j "action")
      let actual ← IO.ofExcept (numbers j "state")
      let ok ← IO.ofExcept ((← IO.ofExcept (j.getObjVal? "ok")).getBool?)
      let result ← IO.ofExcept (uint (← IO.ofExcept (j.getObjVal? "result")))
      if action.size != 3 then throw (IO.userError "expected three action fields")
      if row == 0 then
        if action != #[999,0,0] || !ok || result != 0 then throw (IO.userError "invalid genesis")
        IO.ofExcept (compare row (snapshot state) actual)
      else if row + 1 == lines.length then
        if action != #[998,0,lines.length - 2] || !ok || result != 0 then
          throw (IO.userError "invalid completion marker")
        IO.ofExcept (compare row (snapshot state) actual)
      else
        calls := calls + 1
        if action[0]! == 10 && harvest state false != harvest state then
          legacyHarvestDetected := legacyHarvestDetected + 1
        let previous := state
        match call state action[0]! action[1]! action[2]! with
        | none =>
          if ok || result != 0 then throw (IO.userError s!"{path} row {row}: unexpected Solidity success")
          IO.ofExcept (compare row (snapshot state) actual)
          reverts := reverts + 1
        | some (next, value) =>
          if !ok then throw (IO.userError s!"{path} row {row}: unexpected Solidity revert, op {action[0]!}")
          if value != result then throw (IO.userError s!"row {row}: return {value} != {result}")
          IO.ofExcept (compare row (snapshot next) actual)
          state := next
          if action[0]! == 0 && previous.pending.kind != 0 &&
              next.pending.inputBase != previous.pending.inputBase then rebases := rebases + 1
          if action[0]! == 2 then fills := fills + 1
          if action[0]! == 3 then refunds := refunds + 1
          if previous.pending.kind != 0 && next.pending.kind == 0 &&
              (next.pallet[previous.pending.nonce]?.getD {}).status == 1 then spoofs := spoofs + 1
    IO.println s!"{path}: {lines.length - 2} public calls matched"
  if calls < 1000 || reverts < 5 || legacyHarvestDetected < 4 || rebases == 0 ||
      fills < 40 || refunds == 0 || spoofs == 0 then
    throw (IO.userError s!"missing coverage: {calls} calls, {reverts} reverts, {legacyHarvestDetected} legacy harvest divergences, {rebases} rebases, {fills} fills, {refunds} refunds, {spoofs} spoof arrivals")
  IO.println s!"shared-intent replay passed: {calls} calls, {reverts} expected reverts; rejected {legacyHarvestDetected} delayed-reconcile mutations; {rebases} rebases, {fills} fills, {refunds} refunds, {spoofs} spoof arrivals"
