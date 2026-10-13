import JuicerLean.FixedPoint.PolicyQueue


open Juicer.Runtime

def row (xs : List ℕ) : String := "[" ++ String.intercalate "," (xs.map toString) ++ "]"
def dataset (name : String) (xs : List (List ℕ)) : String :=
  "\"" ++ name ++ "Count\":" ++ toString xs.length ++ ",\"" ++ name ++ "\":[" ++
    String.intercalate "," (xs.map row) ++ "]"

def positionFields (p : MainPosition) : List ℕ := [p.units, p.principal, p.cash, p.remaining]
def redemptionFields (r : RedemptionState) : List ℕ :=
  [r.shares, r.owed, r.debt, r.repaid, r.settled, r.burned, r.claimed, if r.active then 1 else 0]

def mainRows : List (List ℕ) := do
  let n ← List.range 48
  let first := (n + 1) * 10 ^ 18 + n
  let more := first / 3 + 1
  let cash := first / 2
  let one := mainBorrow {} 0 0 first
  let two := mainBorrow one.1 one.2 first (first + more)
  let p := { two.1 with cash }
  let shares := n % 11 + 1
  let exited := mainExit p two.2 (first + more) shares 12 0
  let amount := min exited.2.1.cash (mainDebtOf (first + more) exited.2.2 exited.2.1)
  let repaid := mainRepay exited.2.1 exited.2.2 (first + more) amount amount
  pure ([first, more, cash, shares, 12] ++ positionFields exited.1 ++ positionFields exited.2.1 ++
    [exited.2.2, amount] ++ positionFields repaid.1 ++ [repaid.2])

def batchRows : List (List ℕ) := do
  let n ← List.range 48
  let w1 := 1000 + n * 17
  let w2 := 701 + n * 23
  let total := w1 + w2
  let cash := total / 3
  let cost := total / 5
  let one := batchSegment cash cost total 0 w1
  let two := batchSegment cash cost total w1 w2
  pure [w1, w2, cash, cost, one.1, one.2, two.1, two.2]

def feeRows : List (List ℕ) := do
  let n ← List.range 48
  let claim := 1000 + 7 * n
  let principal := if n % 7 == 0 then claim + 1 else claim / 2
  let f := vestFee claim principal (claim / 10)
  let cost := if n % 3 == 0 then f.yieldLeft else f.yieldLeft / 3
  let result := settleFee f 0 cost
  pure [claim, principal, claim / 10, cost, f.yieldLeft, f.feeLeft, result.2]

def policyRows : List (List ℕ) := do
  let n ← List.range 64
  let p : Policy := ⟨1000, n % 5, n * 13 % 1001, 100, if n % 3 == 0 then 101 else 1000,
    10, 500, if n % 4 == 0 then 1000 else 100, if n % 5 == 0 then 99 else 0, n % 2 == 0, false⟩
  let now := 100 + n
  pure [p.capacity, p.refill, p.credit, p.updated, p.expires, p.minimum, p.maximum, p.nextAt,
    p.lastBlock, if p.safetyLane then 1 else 0, now, 99, available p now 99 false,
    available p now 99 true, policyCredit p now, min 800 (policyCredit p now)]

def priceRows : List (List ℕ) := do
  let n ← List.range 32
  let fair := 10000 + n * 17
  let sf := [0, 1, 100, 9999][n % 4]!
  let qo := if n % 2 == 0 then fair * 2 else fair / 2
  pure [fair, sf, qo, 11, 20, executionMinimum fair sf qo 11 20]

def claimRows : List (List ℕ) := do
  let n ← List.range 48
  let shares := 1000 + 7 * n
  let owed := 10001 + 31 * n
  let claimed := owed / 5
  let r : RedemptionState := ⟨shares, owed, 1000, if n % 2 == 0 then 1000 else 700,
    if n % 2 == 0 then owed - claimed else owed / 3, shares * claimed / owed, claimed, true⟩
  let c := claimRedemption r
  pure (redemptionFields r ++ redemptionFields c.1 ++ [c.2.1, c.2.2])

def queueRows : List (List ℕ) := do
  let n ← List.range 32
  let times := [100, 102, 99, 104, 200]
  let now := 100 + n % 7
  let fuel := n % 6
  pure ([now, fuel] ++ times ++ [queueReady now fuel times])

def main : IO Unit :=
  IO.println ("{" ++ String.intercalate "," [dataset "main" mainRows, dataset "batch" batchRows,
    dataset "fees" feeRows, dataset "policy" policyRows, dataset "prices" priceRows,
    dataset "claims" claimRows, dataset "queue" queueRows] ++ "}")
