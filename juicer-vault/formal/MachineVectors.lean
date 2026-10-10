import JuicerLean.FixedPoint.Checked
import JuicerLean.FixedPoint.LifecycleRefinement
import JuicerLean.FixedPoint.QueueHistories

open Juicer.Runtime

def row (xs : List ℕ) : String := "[" ++ String.intercalate "," (xs.map toString) ++ "]"
def dataset (name : String) (xs : List (List ℕ)) : String :=
  "\"" ++ name ++ "Count\":" ++ toString xs.length ++ ",\"" ++ name ++ "\":[" ++
    String.intercalate "," (xs.map row) ++ "]"

def failureCode : ArithmeticFailure → ℕ
  | .overflow => 1
  | .divisionByZero => 2
  | .mulDivOverflow => 3
  | .outstandingDebt => 4
  | .transferMismatch => 5

def resultFields (r : Checked ℕ) : List ℕ :=
  match r with
  | .ok value => [0, value]
  | .error e => [failureCode e, 0]

def arithmetic (op a b d : ℕ) : Checked ℕ :=
  match op with
  | 0 => checkedAdd a b
  | 1 => checkedSub a b
  | 2 => checkedMul a b
  | 3 => checkedDiv a b
  | 4 => checkedCeilDiv a b
  | 5 => checkedMulDiv a b d
  | 6 => checkedMulDivUp a b d
  | _ => .ok (checkedShift a b)

def edges : List ℕ := [0, 1, 2, 255, 256, 2 ^ 128 - 1, 2 ^ 128, 2 ^ 255, max256 - 1, max256]

def arithmeticRowsBase : List (List ℕ) := do
  let op ← List.range 8
  let n ← List.range 60
  let a := edges[n % 10]!
  let b := if op == 7 then [0, 1, 64, 255, 256, 257][n / 10]! else edges[(n / 10 + n * 3) % 10]!
  let d := edges[(n / 10 * 3 + n) % 10]!
  pure ([op, a, b, d] ++ resultFields (arithmetic op a b d))

def arithmeticRows : List (List ℕ) := arithmeticRowsBase ++
  [(6, max256 - 1, max256 - 1, max256 - 2), (5, max256 - 1, max256 - 1, max256 - 2),
   (5, max256, max256, max256), (6, max256, max256, max256),
   (5, max256, max256, 0), (5, 0, max256, 0), (4, 0, 0, 0), (4, max256, 1, 0)].map
    (fun (op, a, b, d) => [op, a, b, d] ++ resultFields (arithmetic op a b d))

def backingRows : List (List ℕ) :=
  [(max256, 0, 0, 0), (0, max256, 1, 0), (max256, 0, 0, 1), (max256, 0, 0, 9999),
   (max256, 0, 0, 10000), (0, 0, 0, 9999), (100, 50, 20, 2500), (100, 50, 20, 10000)].map
    (fun (debt, principal, cash, fee) => [debt, principal, cash, fee] ++
      resultFields (checkedRequiredBacking debt principal cash fee))

def accountCases : List (Book × Account × ℕ) :=
  [ (⟨0, 0, max256, ray, 0, 0⟩, ⟨max256, 0, 0, 0⟩, 1),
    (⟨0, 0, 100, 1, 0, 0⟩, ⟨0, 0, 0, 1⟩, 1),
    (⟨0, 0, 100, 0, 0, 0⟩, ⟨0, 1, 0, 0⟩, 1),
    (⟨0, 0, 100, ray, 2, 0⟩, ⟨max256, max256, 1, max256⟩, 5),
    (⟨0, 0, 100, 0, 0, 256⟩, ⟨max256, max256, 0, 0⟩, 1),
    (⟨0, 0, max256, max256, 0, 0⟩, ⟨0, 0, 0, 0⟩, max256),
    (⟨0, 0, 0, 0, 0, 0⟩, ⟨0, 0, 0, 0⟩, max256) ] ++
    (List.range 33).map (fun n =>
      (⟨0, 0, 10000 + n, (n + 1) * ray, n % 3, n % 4 * 64⟩,
       ⟨n * 31, n * ray, n % 2, 0⟩, n + 1))

def accountRows : List (List ℕ) := accountCases.map (fun (b, a, w) =>
  [b.total, b.index, b.epoch, b.scale, a.units, a.index, a.epoch, a.scale, w] ++
    resultFields (checkedAccountUnits b a w))

def batchFields (b : SourceBatch) : List ℕ :=
  [b.weight, b.credited, b.charged, b.cursor, b.pending.length,
   b.amount + b.laterCash - b.credited, b.cost + b.laterCost - b.charged]

def batchRows : List (List ℕ) := do
  let n ← List.range 12
  let count := 65 + n * 7
  let active := n + 11
  let weights := (List.range count).map (fun i => (i * 7 + n * 3) % 23)
  let total := active + weights.sum
  let amount := total / 4
  let cost := total / 7
  let first := ((SourceBatch.begin amount cost (active :: weights)).one).run 64
  let second := (first.receive 17 9).run 64
  let third := second.run 64
  pure ([n, count, active, amount, cost, total] ++ batchFields first ++ batchFields second ++ batchFields third)

def retryRows : List (List ℕ) := do
  let n ← List.range 32
  let cash := 21 + n
  let amount := 10 + n % 9
  let paid := if n % 3 == 0 then amount - 1 else amount
  let reduced := paid - n % 3
  pure [cash, amount, paid, reduced, 2, retryAmount cash amount paid reduced 2]

def claimFields (r : RedemptionState) : List ℕ :=
  [r.shares, r.owed, r.debt, r.repaid, r.settled, r.burned, r.claimed, if r.active then 1 else 0]

def historyRows : List (List ℕ) := do
  let n ← List.range 24
  let initial := freshRedemption (1001 + 7 * n) (10003 + 13 * n) (100 + n)
  let s1 := settleRedemption initial (11 + n % 17)
  let c1 := claimRedemption s1
  let s2 := settleRedemption c1.1 (23 + n % 11)
  let c2 := claimRedemption s2
  let s3 := settleRedemption c2.1 initial.debt
  let c3 := claimRedemption s3
  pure (claimFields initial ++ claimFields s1 ++ claimFields c1.1 ++ claimFields s2 ++
    claimFields c2.1 ++ claimFields s3 ++ claimFields c3.1)

def main : IO Unit := IO.println ("{" ++ String.intercalate ","
  [dataset "arithmetic" arithmeticRows, dataset "backing" backingRows,
    dataset "accounts" accountRows, dataset "batches" batchRows,
    dataset "retries" retryRows, dataset "histories" historyRows] ++ "}")
