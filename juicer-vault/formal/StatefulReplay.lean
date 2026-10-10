import Lean
import JuicerLean.FixedPoint.PublicCalls

open Lean Juicer Juicer.PublicCalls

def numbers (j : Json) (key : String) : Except String (Array Nat) := do
  let values ← (← j.getObjVal? key).getArr?
  values.mapM fun value =>
    match value with
    | .str text => match text.toNat? with
      | some n => .ok n
      | none => .error "invalid decimal uint256"
    | _ => value.getNat?

def fieldName (n : Nat) : String :=
  let globals := #["supply", "assets", "aToken", "collateral", "reserve", "debt", "synthetic",
    "source shares", "source principal", "source freed", "reinvestment", "waiting shares",
    "queued shares", "queued collateral", "queued debt", "queue head", "queue unwind", "queue tail",
    "reward source", "protocol source", "reward units", "reward index", "epoch", "scale",
    "Main units", "Main cash", "source outstanding", "source head", "source tail", "unallocated cash",
    "paused", "deposits paused", "source paused", "timestamp"]
  if n < globals.size then globals[n]! else s!"snapshot[{n}]"

def compare (expected actual : Array Nat) : Except String Unit := do
  if expected.size != actual.size then
    throw s!"snapshot length: Lean {expected.size}, Solidity {actual.size}"
  for i in [:expected.size] do
    if expected[i]! != actual[i]! then
      throw s!"{fieldName i}: Lean {expected[i]!}, Solidity {actual[i]!}"

def checkPartitions (s : State) : Except String Unit := do
  let wallets := s.wallets.foldl (· + ·) 0
  let mainUnits := s.positions.foldl (fun n p => n + p.units) 0
  let cash := s.positions.foldl (fun n p => n + p.cash) s.unallocated
  let outstanding := s.positions.foldl (fun n p => n + p.remaining) s.activeRemaining
  let mut queued := 0
  let mut owed := 0
  let mut debt := 0
  let mut waiting := 0
  let mut liability := 0
  for i in [:actors] do
    if !special i then
      let a := account s i
      let owned := if a.epoch == s.book.epoch then a.units else 0
      let index := if a.epoch == s.book.epoch then a.index else 0
      liability := liability + owned * Runtime.ray + wallet s i * (s.book.index - index)
  for i in [:s.requests.size] do
    let r := request s i
    if i < s.unwind then
      queued := queued + r.claim.shares - r.claim.burned
      owed := owed + r.claim.owed - r.claim.claimed
      debt := debt + r.claim.debt - r.claim.repaid
      if r.claim.claimed + r.claim.settled > r.claim.owed then throw "claim entitlement exceeded"
      if r.claim.burned > r.claim.shares || r.claim.repaid > r.claim.debt then throw "claim burn/debt bound exceeded"
    else
      waiting := waiting + r.claim.shares
      let owned := if r.account.epoch == s.book.epoch then r.account.units else 0
      let index := if r.account.epoch == s.book.epoch then r.account.index else 0
      liability := liability + owned * Runtime.ray + r.claim.shares * (s.book.index - index)
  if s.freed + s.unallocated + s.unallocatedCost != s.outstanding then throw "source receipt partition"
  if s.sourceFees.size != s.positions.size then throw "source fee partition size"
  if s.feeReserve != s.sourceFees.foldl (fun n f => n + f.feeLeft) 0 then throw "source fee reserve partition"
  for f in s.sourceFees do
    if f.feeLeft > f.yieldLeft then throw "source fee exceeds junior yield"
  if s.expanded && s.sourceCash < sourceValue s s.held + s.freed then throw "source custody shortfall"
  if s.supply != wallets || s.mainUnits != mainUnits || s.ownedCash != cash || s.outstanding != outstanding then
    throw "holder/Main partition failed"
  if s.queued != queued || s.owed != owed || s.queuedDebt != debt || s.pending != waiting then
    throw "request partition failed"
  if waiting + queued > wallet s vaultId || owed > s.assets then throw "request backing exceeded"
  if s.assets + s.reserve != s.supplied + s.liquid then throw "collateral partition failed"
  if s.book.scale != 0 || liability > s.book.total * Runtime.ray then throw "lazy liability bound failed"

def checkRow (s : State) (j : Json) (genesis : Bool) : Except String State := do
  let a ← numbers j "action"
  if a.size != 5 then throw "expected five action fields"
  let status ← numbers j "status"
  let actual ← numbers j "state"
  if genesis then
    if a != #[999, 0, 0, 0, s.expanded.toNat] || status != #[0, 0] then throw "missing genesis"
    compare (snapshot s) actual
    return s
  if a[0]! == 999 then throw "unexpected state reset"
  if a[0]! == 998 then
    if status != #[0, 0] then throw "invalid completion status"
    compare (snapshot s) actual
    return s
  let (next, code, value) := execute s ⟨a[0]!, a[1]!, a[2]!, a[3]!, a[4]!⟩
  if code == 99 then throw "trace reached an unsupported fixture branch"
  if status != #[code, value] then throw s!"outcome: Lean {[code, value]}, Solidity {status.toList}"
  compare (snapshot next) actual
  checkPartitions next
  return next

def main (args : List String) : IO Unit := do
  if args.isEmpty then throw (IO.userError "provide trace JSONL paths")
  let mut steps := 0
  let mut failed := 0
  let mut mutationChecks := 0
  for path in args do
    let contents ← IO.FS.readFile path
    let lines := contents.splitOn "\n" |>.filter (· != "")
    if lines.isEmpty then throw (IO.userError s!"{path}: empty campaign")
    let footer ← IO.ofExcept (Json.parse lines.getLast!)
    let completion ← IO.ofExcept (numbers footer "action")
    if completion.size != 5 || completion[0]! != 998 || completion[4]! + 2 != lines.length then
      throw (IO.userError s!"{path}: missing or invalid completion marker")
    if completion[2]! < 192 || completion[2]! + 20 > completion[4]! then
      throw (IO.userError s!"{path}: truncated campaign")
    let first ← IO.ofExcept (Json.parse lines.head!)
    let genesis ← IO.ofExcept (numbers first "action")
    if genesis.size != 5 || genesis[4]! > 1 then throw (IO.userError "unknown fixture")
    let expanded := genesis[4]! == 1
    let mut state : State := { expanded, feeBps := if expanded then 1000 else 0 }
    let mut row := 0
    for line in lines do
      let j ← IO.ofExcept (Json.parse line)
      let action ← IO.ofExcept (numbers j "action")
      if action[0]! == 998 && row + 1 != lines.length then throw (IO.userError "early completion marker")
      match checkRow state j (row == 0) with
      | .error msg =>
        throw (IO.userError s!"{path}, step {row}, action {← IO.ofExcept (numbers j "action")}: {msg}")
      | .ok next =>
        if row == 1 then
          let actual ← IO.ofExcept (numbers j "state")
          let baseFields := #[0, 12, 20, 34, 98]
          let extra := 114 + next.requests.size * 15 + next.positions.size * 5
          let fields := if expanded then baseFields ++ #[extra + 1, extra + 5, extra + 10,
            extra + 12, extra + 14, extra + 16, extra + 25] else baseFields
          for field in fields do
            let changed := actual.set! field (actual[field]! + 1)
            let corrupt := Json.mkObj [("action", ← IO.ofExcept (j.getObjVal? "action")),
              ("status", ← IO.ofExcept (j.getObjVal? "status")), ("state", toJson changed)]
            if (checkRow state corrupt false).isOk then throw (IO.userError "missed mutated snapshot")
            mutationChecks := mutationChecks + 1
          let corrupt := Json.mkObj [("action", ← IO.ofExcept (j.getObjVal? "action")),
            ("status", toJson (#[999, 0] : Array Nat)), ("state", toJson actual)]
          if (checkRow state corrupt false).isOk then throw (IO.userError "missed mutated outcome")
          mutationChecks := mutationChecks + 1
        state := next
      let status ← IO.ofExcept (numbers j "status")
      if status[0]! != 0 then failed := failed + 1
      row := row + 1
    if row < 193 then throw (IO.userError s!"{path}: truncated campaign")
    steps := steps + row - 2
    IO.println s!"PASS {path}: {row - 2} recorded steps"
  IO.println s!"stateful replay passed: {steps} recorded steps, {failed} expected reverts, {mutationChecks} mutation checks"
