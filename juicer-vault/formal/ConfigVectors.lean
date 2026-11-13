import JuicerLean.FixedPoint.LoopConfig
import JuicerLean.FixedPoint.Discount

open Juicer

def row (xs : List ℕ) : String := "[" ++ String.intercalate "," (xs.map toString) ++ "]"
def dataset (name : String) (xs : List (List ℕ)) : String :=
  "\"" ++ name ++ "Count\":" ++ toString xs.length ++ ",\"" ++ name ++ "\":[" ++
    String.intercalate "," (xs.map row) ++ "]"

def lcg (x : ℕ) : ℕ := (x * 6364136223846793005 + 1442695040888963407) % 2 ^ 64

def bandValues : List ℕ := [0, 1, 150, 300, 500, 800, 1000, 2500, 2501, 5000, 5001, 65535]
def admissionValues : List ℕ := [0, 1, 50, 250, 10000, 10001, 65535]

def pick (xs : List ℕ) (seed : ℕ) : ℕ := xs.getD (seed % xs.length) 0

def views (r : LoopConfig.Registry) : List ℕ :=
  [0, 1, 2].flatMap fun v =>
    let b := LoopConfig.bandOf r v
    [b.1, b.2.1, b.2.2]

-- vaults 0 and 1 are registered with the loop, 2 is not
def bandRows : List (List ℕ) := Id.run do
  let mut r : LoopConfig.Registry := { vaults := [0, 1] }
  let mut seed := 7
  let mut rows : List (List ℕ) := []
  for _ in List.range 160 do
    seed := lcg seed
    if seed % 5 == 4 then
      let bps := pick admissionValues (seed >>> 8)
      let (next, ok) := match LoopConfig.setAdmission r bps with
        | some r' => (r', 1)
        | none => (r, 0)
      r := next
      rows := rows ++ [[1, 0, 0, 0, bps, ok] ++ views r ++ [r.admission]]
    else
      let v := (seed >>> 8) % 3
      let (target, relever, delever) := if (seed >>> 40) % 6 == 0 then (0, 0, 0)
        else (pick bandValues (seed >>> 16), pick bandValues (seed >>> 24), pick bandValues (seed >>> 32))
      let (next, ok) := match LoopConfig.setBand r v target relever delever with
        | some r' => (r', 1)
        | none => (r, 0)
      r := next
      rows := rows ++ [[0, v, target, relever, delever, ok] ++ views r ++ [r.admission]]
  return rows

def caps : List ℕ := [0, 1, 10 ^ 24, Discount.loopTag - 1]
def pairs : List (ℕ × ℕ) :=
  [(0, 10 ^ 18), (10 ^ 24, 0), (10 ^ 24, 5 * 10 ^ 23), (10 ^ 24, 3 * 10 ^ 24 + 7), (1, 1),
   (3 * 10 ^ 24 + 7, Discount.loopTag ||| 10 ^ 24), (2 ^ 256 - 1, 2 ^ 256 - 1),
   (10 ^ 24, Discount.loopTag - 1)]

-- each row configures the production contract, then compares its rate and the loop's eligibility
def discountRows : List (List ℕ) := do
  let main ← [0, 4000, 10000]
  let loop ← [0, 9000, 10000]
  let cap ← caps
  let c : Discount.Config := { discountBps := main, loopBps := loop, loopCap := cap }
  let eligibility := Discount.loopEligibility c
  let (debt, e) ← pairs ++ [(10 ^ 24, eligibility), (2 * 10 ^ 24, eligibility)]
  pure [main, loop, cap, debt, e, Discount.rate c debt e, eligibility]

def setterRows : List (List ℕ) := Id.run do
  let mut c : Discount.Config := { loopCap := 1 }
  let mut rows : List (List ℕ) := []
  for (kind, value) in [(0, 0), (0, 10000), (0, 10001), (0, 65535), (0, 4000), (1, 10001), (1, 10000),
      (1, 0), (1, 9000), (2, 0), (2, Discount.loopTag), (2, 2 ^ 256 - 1), (2, Discount.loopTag - 1),
      (2, 1), (2, 10 ^ 24)] do
    let next := match kind with
      | 0 => Discount.setDiscountBps c value
      | 1 => Discount.setLoopDiscountBps c value
      | _ => Discount.setLoopCap c value
    let ok := if next.isSome then 1 else 0
    c := next.getD c
    rows := rows ++ [[kind, value, ok, c.discountBps, c.loopBps, c.loopCap]]
  return rows

def main : IO Unit :=
  IO.println ("{" ++ String.intercalate ","
    [dataset "band" bandRows, dataset "discount" discountRows, dataset "setter" setterRows] ++ "}")
