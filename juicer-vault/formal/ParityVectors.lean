import JuicerLean.FixedPoint.Runtime

open Juicer.Runtime

def row (xs : List ℕ) : String := "[" ++ String.intercalate "," (xs.map toString) ++ "]"
def dataset (name : String) (xs : List (List ℕ)) : String :=
  "\"" ++ name ++ "Count\":" ++ toString xs.length ++ ",\"" ++ name ++ "\":[" ++
    String.intercalate "," (xs.map row) ++ "]"
def bookFields (b : Book) : List ℕ := [b.source, b.protocol, b.total, b.index, b.epoch, b.scale]
def accountFields (a : Account) : List ℕ := [a.units, a.index, a.epoch, a.scale]
def intentFields (p : Intent) : List ℕ := [p.kind, p.nonce, p.amount, p.minimum, p.inBase, p.outBase]

def pegRows : List (List ℕ) := do
  let debt ← [0, 1, 2, 195, 196, 199, 200, 10 ^ 18, 10 ^ 28]
  let lt ← [1, 7500, 9800, 10000]
  pure [debt, lt, buffered debt lt]

def takeRow (f t u s : ℕ) : List ℕ :=
  [f, t, u, s] ++ match take f t u s with | none => [0, 0, 0] | some (x, left) => [1, x, left]

def takeRows : List (List ℕ) := (do
  let n ← List.range 80
  let f := 1 + n * (if n % 2 == 0 then 7 else 17)
  let t := 1 + n * 11
  let u := 1 + n * 5
  let slice := fundedOf f t u
  let s := if n % 4 == 0 then slice else if n % 4 == 1 then 1 else if n % 4 == 2 then slice / 2 else slice + 1
  pure (takeRow f t u s)) ++
  [takeRow 2 3 3 1, takeRow 10 3 2 1, takeRow 10 3 2 3,
   takeRow (max256 - 1) max256 max256 1,
   takeRow max256 (2 ^ 128) (2 ^ 128) 1,
   takeRow max256 (2 ^ 128) (2 ^ 128) max256]

def accountRows : List (List ℕ) := do
  let n ← List.range 48
  let b : Book := ⟨0, 0, 1000 + n, 10 * ray, 3, if n % 4 == 0 then 64 else 0⟩
  let a : Account := ⟨if n % 4 == 0 then 99 * 2 ^ 64 else 99,
    if n % 4 == 0 then 2 * ray * 2 ^ 64 else 2 * ray, if n % 3 == 0 then 2 else 3, 0⟩
  let w := n * 7
  pure (bookFields b ++ accountFields a ++ [w, accountUnits b a w])

def allocationRows : List (List ℕ) := do
  let n ← List.range 48
  let b : Book := ⟨if n % 6 == 0 then 2000 else 100, 11,
    if n % 8 == 0 then 2 ^ 220 else if n % 8 == 1 then 0 else 1000 + n,
    if n % 8 == 0 then 2 ^ 230 else 3 * ray, 2, 0⟩
  let v : AllocationInput := ⟨if n % 7 == 0 then 0 else 1000,
    if n % 6 == 0 then 0 else (2 + n) * 10 ^ 10,
    if n % 5 == 0 then 3 * 10 ^ 10 else 0,
    if n % 11 == 0 then 0 else 10000, if n % 6 == 0 || n % 11 == 0 then 0 else 100,
    if n % 6 == 0 then 0 else 10 ^ 10,
    if n % 4 == 0 then 10 ^ 10 else 0, [0, 500, 3333, 10000][n % 4]!⟩
  pure (bookFields b ++ [v.held, v.equity, v.required, v.supply, v.funded, v.fundedValue, v.basis, v.fee] ++
    bookFields (allocate b v))

def exitRows : List (List ℕ) := do
  let n ← List.range 64
  let b : Book := ⟨1000, 111, if n == 0 then 0 else 1000 + n, 3 * ray, 2, if n % 4 == 0 then 64 else 0⟩
  let o : Account := ⟨120, 2 * ray, if n % 5 == 0 then 1 else 2, 0⟩
  let r : Account := ⟨23, ray, if n % 3 == 0 then 1 else 2, 0⟩
  let w := if n % 7 == 0 then 0 else n * 2
  let s := if n % 8 == 0 then 0 else n * 3
  let f := 1000 + n * 7
  let e := startExit b o r w s f
  pure (bookFields b ++ accountFields o ++ accountFields r ++ [w, s, f] ++
    bookFields e.book ++ [e.owned, e.reward, e.fee, e.folded, e.burned])

def iceRows : List (List ℕ) := do
  let n ← List.range 80
  let kind := n % 3
  let amount := if kind == 1 then (100 + n) * 10 ^ 18 else (100 + n) * 10 ^ 6
  let minimum := if kind == 1 then (90 + n) * 10 ^ 6 else (90 + n) * 10 ^ 18
  let p : Intent := ⟨kind, n + 1, amount, minimum, 7, 11⟩
  let i := p.inBase + if n % 5 == 3 then (amount + 1) / 2 else 0
  let o := p.outBase + if n % 5 == 0 then minimum else if n % 5 == 1 then (minimum + 1) / 2 else if n % 5 == 2 then minimum / 2 - 1 else 0
  let price := 10 ^ 8 + n * 12345
  let coll := if n % 9 == 0 then 0 else (1000 + n) * 10 ^ 8
  let debt := if n % 7 == 0 then 0 else (800 + n) * 10 ^ 8
  let lt := 8800
  let hf := if debt == 0 then max256 else coll * lt * 10 ^ 14 / debt
  let cash := if kind == 1 then i else o
  let unflagged := (if kind == 1 then o else i) * price / 10 ^ 6
  let reserved := if n % 6 == 0 then cash + 1 else cash / 3
  let observed := outcome p i o
  let flight := inFlight p i o price
  let effective := effectiveAccount p i o price coll debt lt hf
  let equity := totalEquity p i o price coll unflagged debt cash reserved
  let target := deLeverTarget effective.1 effective.2.1 lt effective.2.2 (105 * 10 ^ 16) (110 * 10 ^ 16) 0
  pure (intentFields p ++ [i, o, price, coll, debt, lt, hf, reserved,
    observed.1, observed.2, flight.1, flight.2, effective.1, effective.2.1, effective.2.2, equity,
    if target.isSome then 1 else 0, target.getD 0])

def callbackRows : List (List ℕ) := do
  let n ← List.range 64
  let p : Intent := ⟨if n % 8 == 0 then 0 else 1, 5, 100, 80, 0, 0⟩
  let nonce := n % 8
  let kind := if n % 6 == 0 then 2 else 1
  let amount := if n % 7 == 0 then 79 else 80
  let auth := n % 9 != 0
  let asset := n % 10 != 0
  pure (intentFields p ++ [5, nonce, kind, amount, if auth then 1 else 0, if asset then 1 else 0,
    callback p 5 nonce kind amount auth asset])

def fundingRows : List (List ℕ) := do
  let n ← List.range 48
  let debt := (n + 1) * 10 ^ 18 + n
  let principal := if n % 4 == 0 then debt + 1 else debt * 3 / 4
  let cash := if n % 5 == 0 then debt + 1 else debt / 7
  let fee := [0, 1, 500, 3333, 9999, 10000][n % 6]!
  pure [debt, principal, cash, fee, requiredBacking debt principal cash fee]

def harvestRows : List (List ℕ) := do
  let n ← List.range 32
  let amount := (n + 1) * 12345
  let total := 17 + n
  let rewards := total / 3
  let protocol := total / 7
  let fee := [0, 500, 3333, 10000][n % 4]!
  let result := splitHarvest amount total rewards protocol fee
  pure [amount, total, rewards, protocol, fee, result.1, result.2.1, result.2.2]

def main : IO Unit :=
  IO.println ("{" ++ String.intercalate "," [dataset "peg" pegRows, dataset "take" takeRows,
    dataset "accounts" accountRows, dataset "allocations" allocationRows, dataset "exits" exitRows,
    dataset "ice" iceRows, dataset "callbacks" callbackRows,
    dataset "funding" fundingRows, dataset "harvest" harvestRows] ++ "}")
