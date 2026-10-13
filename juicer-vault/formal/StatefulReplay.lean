import Lean
import JuicerLean.FixedPoint.PublicReadyReachability

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
  let mut claims := 0
  let mut funded := 0
  for i in [:actors] do
    if !special i then
      let a := account s i
      let normalized := Runtime.normalizeAccount s.book a (wallet s i)
      liability := liability + normalized.numerator s.book.index
      claims := claims + units s i
      funded := funded + Runtime.fundedOf (wallet s fundId) s.book.total (units s i)
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
      let normalized := Runtime.normalizeAccount s.book r.account r.claim.shares
      let owned := normalized.claim s.book.total s.book.index
      liability := liability + normalized.numerator s.book.index
      claims := claims + owned
      funded := funded + Runtime.fundedOf (wallet s fundId) s.book.total owned
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
  if liability >= (s.book.total + 1) * Runtime.ray then throw "lazy liability bound failed"
  if claims > s.book.total || funded > wallet s fundId then throw "lazy aggregate claim bound failed"

def checkCertificateParts (s : State) : Except String Unit := do
  unless decide (p := CollateralConserved s) do throw "certificate collateral"
  unless decide (p := (sourceProjection s).valid) do throw "certificate source"
  unless decide (p := (cashProjection s).valid) do throw "certificate cash"
  unless decide (p := (publicProjection s).valid) do throw "certificate lifecycle"
  unless decide (p := publicSlack s < Runtime.ray) do throw "certificate slack"
  unless decide (p := OperationalInvariant s) do throw "certificate operational"
  unless decide (p := PublicMetadata s) do throw "account metadata history"
  unless decide (p := InitializationSafe s) do throw "initialization or locked shares"
  unless decide (p := ActiveFeeSafe s) do throw "zero active remainder retained fees"
  unless decide (p := QueueBacking s) do throw "queue backing or position count"
  unless decide (p := CreditReadyHistory s) do throw "source-credit readiness"
  unless decide (p := PublicCallBounds s) do throw "source/fee rates or request owners"
  unless decide (p := HarvestBound s) do throw "harvest source capacity"
  unless decide (p := UnwindReady s) do throw "unwind readiness"

def checkRow (s : State) (j : Json) (genesis : Bool) (fixture : Nat := 0) : Except String State := do
  let a ← numbers j "action"
  if a.size != 5 then throw "expected five action fields"
  let status ← numbers j "status"
  let actual ← numbers j "state"
  if genesis then
    if a != #[999, 0, 0, 0, fixture] || status != #[0, 0] then throw "missing genesis"
    if (certify s).isNone then throw "genesis invariant certificate rejected"
    unless decide (p := PublicMetadata s) do throw "genesis metadata history rejected"
    unless decide (p := InitializationSafe s) do throw "genesis initialization or locked shares rejected"
    unless decide (p := ActiveFeeSafe s) do throw "genesis active fees rejected"
    unless decide (p := QueueBacking s) do throw "genesis queue backing rejected"
    unless decide (p := CreditReadyHistory s) do throw "genesis source-credit readiness rejected"
    unless decide (p := PublicCallBounds s) do throw "genesis source/fee rates or request owners rejected"
    unless decide (p := HarvestBound s) do throw "genesis harvest capacity rejected"
    unless decide (p := UnwindReady s) do throw "genesis unwind readiness rejected"
    compare (snapshot s) actual
    return s
  if a[0]! == 999 then throw "unexpected state reset"
  if a[0]! == 998 then
    if status != #[0, 0] then throw "invalid completion status"
    compare (snapshot s) actual
    return s
  let action := Juicer.PublicCalls.Action.mk a[0]! a[1]! a[2]! a[3]! a[4]!
  unless decide (p := PublicMetadata s) do throw "input metadata history rejected"
  unless decide (p := InitializationSafe s) do throw "input initialization or locked shares rejected"
  unless decide (p := ActiveFeeSafe s) do throw "input active fees rejected"
  unless decide (p := QueueBacking s) do throw "input queue backing rejected"
  unless decide (p := CreditReadyHistory s) do throw "input source-credit readiness rejected"
  unless decide (p := PublicCallBounds s) do throw "input source/fee rates or request owners rejected"
  unless decide (p := HarvestBound s) do throw "input harvest capacity rejected"
  unless decide (p := UnwindReady s) do throw "input unwind readiness rejected"
  unless decide (p := FixtureAction action) do throw "action outside source-pinned fixture domain"
  unless decide (p := OrdinaryAction s action) do throw "action outside ordinary caller/started-claim domain"
  unless decide (p := ValidSolidityAction s action) do
    checkPartitions (rawExecute s action).1
    checkCertificateParts (rawExecute s action).1
    throw "raw public-call input domain rejected"
  let (next, code, value) := solidityExecute s action
  if (certify next).isNone then throw "reachable raw state lost its certificate"
  unless decide (p := PublicMetadata next) do throw "reachable raw state lost its metadata history"
  unless decide (p := InitializationSafe next) do throw "reachable raw state lost initialization or locked shares"
  unless decide (p := ActiveFeeSafe next) do throw "reachable raw state lost its active fee bound"
  unless decide (p := QueueBacking next) do throw "reachable raw state lost its queue backing"
  unless decide (p := CreditReadyHistory next) do throw "reachable raw state lost its source-credit readiness"
  unless decide (p := PublicCallBounds next) do throw "reachable raw state lost its source/fee rates or request owners"
  unless decide (p := HarvestBound next) do throw "reachable raw state lost its harvest capacity bound"
  unless decide (p := UnwindReady next) do throw "reachable raw state lost its unwind readiness"
  if code == 99 then throw "trace reached an unsupported fixture branch"
  if status != #[code, value] then throw s!"outcome: Lean {[code, value]}, Solidity {status.toList}"
  compare (snapshot next) actual
  checkPartitions next
  return next

def main (args : List String) : IO Unit := do
  let regression := args.head? == some "--harvest-capacity"
  let args := if regression then args.drop 1 else args
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
    if !regression && (completion[2]! < 192 || completion[2]! + 20 > completion[4]!) then
      throw (IO.userError s!"{path}: truncated campaign")
    let first ← IO.ofExcept (Json.parse lines.head!)
    let genesis ← IO.ofExcept (numbers first "action")
    if genesis.size != 5 || genesis[4]! > 2 then throw (IO.userError "unknown fixture")
    if regression then
      let expected : List (Array Nat) :=
        [#[18,0,0,0,0], #[0,0,0,0,10^18], #[9,0,0,0,0], #[30,0,0,0,10^18],
         #[8,0,0,0,0], #[17,0,0,0,333333333333333333], #[20,0,0,0,5000],
         #[8,0,0,0,0], #[23,0,0,0,0], #[8,0,0,0,0]]
      if genesis[4]! == 0 || completion != #[998,0,0,genesis[4]!,expected.length] then
        throw (IO.userError "invalid harvest regression metadata")
      for (line, action) in (lines.drop 1).zip expected do
        let j ← IO.ofExcept (Json.parse line)
        if (← IO.ofExcept (numbers j "action")) != action ||
            (← IO.ofExcept (numbers j "status"))[0]! != 0 then
          throw (IO.userError "invalid harvest regression sequence")
    let expanded := genesis[4]! != 0
    let mut state := fixtureGenesis genesis[4]!
    let mut row := 0
    for line in lines do
      let j ← IO.ofExcept (Json.parse line)
      let action ← IO.ofExcept (numbers j "action")
      if action[0]! == 998 && row + 1 != lines.length then throw (IO.userError "early completion marker")
      match checkRow state j (row == 0) genesis[4]! with
      | .error msg =>
        throw (IO.userError s!"{path}, step {row}, action {← IO.ofExcept (numbers j "action")}: {msg}")
      | .ok next =>
        if row == 1 || next.book.scale > state.book.scale then
          let actual ← IO.ofExcept (numbers j "state")
          let baseFields := #[0, 12, 20, 21, 22, 23, 34, 36, 98]
          let extra := 114 + next.requests.size * 15 + next.positions.size * 5
          let fields := if expanded then baseFields ++ #[extra + 1, extra + 5, extra + 10,
            extra + 12, extra + 14, extra + 16, extra + 25, extra + 26] else baseFields
          let fields := if next.requests.isEmpty then fields else fields ++ #[125, 126, 127, 128]
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
    if !regression && row < 193 then throw (IO.userError s!"{path}: truncated campaign")
    steps := steps + row - 2
    IO.println s!"PASS {path}: {row - 2} recorded steps"
  IO.println s!"stateful replay passed: {steps} recorded steps, {failed} expected reverts, {mutationChecks} mutation checks"
