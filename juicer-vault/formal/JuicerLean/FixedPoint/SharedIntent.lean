import JuicerLean.FixedPoint.PolicyQueue

namespace Juicer.SharedIntent
open Runtime

structure Vault where
  shares : Nat := 0
  principal : Nat := 0
  requested : Nat := 0
  freed : Nat := 0
  allowance : Nat := 0
  cost : Nat := 0
  seenCost : Nat := 0
  weight : Nat := 0
  compounded : Nat := 0
  pulled : Nat := 0
  blocked : Bool := false
  deriving Repr, BEq, Inhabited

structure Pending where
  nonce : Nat := 0
  deadline : Nat := 0
  kind : Nat := 0
  amount : Nat := 0
  minimum : Nat := 0
  fair : Nat := 0
  inputBase : Nat := 0
  outputBase : Nat := 0
  deriving Repr, BEq, Inhabited

structure PalletIntent where
  kind : Nat := 0
  amount : Nat := 0
  minimum : Nat := 0
  deadline : Nat := 0
  status : Nat := 0
  deriving Repr, BEq, Inhabited

structure State where
  cash : Nat := 0
  prime : Nat := 0
  debt : Nat := 0
  flagged : Bool := false
  total : Nat := 0
  principal : Nat := 0
  target : Nat := 0
  reserved : Nat := 0
  order : Nat := 0
  nonce : Nat := 0
  pending : Pending := {}
  vaults : Array Vault := #[{}, {}]
  unwinders : Array Nat := #[]
  pallet : Array PalletIntent := #[{}]
  gift : Nat := 0
  giftOwned : Array Nat := #[0, 0]
  now : Nat := 1800000000
  lastHarvest : Nat := 1800000000
  deriving Repr, BEq, Inhabited

def vault (s : State) (v : Nat) : Vault := s.vaults[v]?.getD {}
def setVault (s : State) (v : Nat) (a : Vault) : State := { s with vaults := s.vaults.set! v a }
def inputBalance (s : State) (kind : Nat) := if kind == 1 then s.cash else s.prime
def outputBalance (s : State) (kind : Nat) := if kind == 1 then s.prime else s.cash
def pendingOutcome (s : State) : Nat × Nat :=
  if s.pending.kind == 0 then (0, 0) else
  outcome ⟨s.pending.kind, s.pending.nonce, s.pending.amount, s.pending.minimum,
    s.pending.inputBase, s.pending.outputBase⟩
    (inputBalance s s.pending.kind) (outputBalance s s.pending.kind)

def coll8 (s : State) := if s.flagged then s.prime * 100 else 0
def debt8 (s : State) := s.debt / 10^10
def lt (s : State) := if coll8 s == 0 then 0 else (coll8 s * 8800 / 10000) * 10000 / coll8 s
def hf (s : State) := if debt8 s == 0 then max256 else coll8 s * 8800 / 10000 * wad / debt8 s
def pendingExit8 (s : State) := if s.pending.kind == 2 then s.pending.amount * 100 else 0
def inFlight8 (s : State) :=
  if (pendingOutcome s).1 != 1 then 0 else
  if s.pending.kind == 1 then s.pending.amount / 10^10 else pendingExit8 s
def equity (s : State) :=
  let c := if coll8 s < s.prime * 100 / 2 then coll8 s + s.prime * 100 else coll8 s
  (c + (s.cash - s.reserved) / 10^10 + inFlight8 s - debt8 s) * 10^10
def live (s : State) := equity s - s.target
def reserve (s : State) := ceilDiv (s.prime * 10^12) 100
def harvestable (s : State) :=
  let protectedColl := if debt8 s == 0 then 0 else if lt s == 0 then coll8 s else
    ceilDiv (debt8 s * (105 * 10^16) * 10000) (wad * lt s)
  min (equity s - (s.principal + s.target + reserve s)) ((coll8 s - protectedColl) * 10^10)
def capacity (s : State) :=
  let available := harvestable s
  if available * wad < s.principal * 10^15 then 0 else available * s.total / live s

def serviceBlocked (s : State) (v : Nat) :=
  (vault s v).blocked || (vault s v).seenCost != (vault s v).cost

def weight (s : State) (v : Nat) :=
  if serviceBlocked s v then 0 else
  (vault s v).shares - ceilDiv ((vault s v).principal * s.total) (live s)

def chargeCost (s : State) (cost : Nat) : State := Id.run do
  let target := s.target
  let mut s := s
  let mut cumulative := 0
  let mut charged := 0
  for v in s.unwinders do
    let a := vault s v
    let remaining := a.requested - a.freed
    let prior := cost * cumulative / target
    cumulative := cumulative + remaining
    let cut := min (min (cost * cumulative / target - prior) a.allowance) remaining
    s := setVault s v { a with
      allowance := a.allowance - cut, requested := a.requested - cut, cost := a.cost + cut }
    charged := charged + cut
  return { s with target := s.target - charged }

def settle (s : State) (output : Nat) : State :=
  let p := s.pending
  let s := { s with pending := {}, flagged := s.flagged || s.prime != 0 }
  if p.kind == 2 && output != 0 && output < p.fair then chargeCost s (p.fair - output) else s

def reconcile (s : State) : State × Nat :=
  let result := pendingOutcome s
  if result.1 == 0 || result.1 == 1 then (s, result.1) else
  (settle s (if result.1 == 2 then max result.2 s.pending.minimum else 0), result.1)

def rebase (s : State) : State :=
  if s.pending.kind == 0 then s else
  { s with pending := { s.pending with
      inputBase := inputBalance s s.pending.kind,
      outputBase := outputBalance s s.pending.kind } }

def submit (s : State) (kind amount fair : Nat) : Option State := do
  let minimum := fair * 990000 / 1000000
  if minimum == 0 || minimum ≥ 2^128 || amount ≥ 2^128 then none else do
    let s ← if kind == 1 then
      if s.cash < amount then none else some { s with cash := s.cash - amount }
      else if s.prime < amount then none else
        let next := { s with prime := s.prime - amount }
        if hf next < wad then none else some next
    let nonce := s.nonce + 1
    let deadline := (s.now + 600) * 1000
    return { s with
      nonce, pending := {
        nonce, deadline, kind, amount, minimum, fair,
        inputBase := inputBalance s kind, outputBase := outputBalance s kind },
      pallet := s.pallet.push { kind, amount, minimum, deadline, status := 1 } }

def deposit (input : State) (v amount : Nat) : Option (State × Nat) := do
  let (s, status) := reconcile input
  if status == 1 || amount == 0 || 10000000 * wad < amount || equity s < s.target ||
      (s.total != 0 && live s == 0) then none else do
    let shares := if s.total == 0 || live s == 0 then amount else amount * s.total / live s
    if shares == 0 then none else do
      let a := vault s v
      let s := setVault s v { a with shares := a.shares + shares, principal := a.principal + amount }
      return (rebase { s with
        cash := s.cash + amount, total := s.total + shares,
        principal := s.principal + amount }, shares)

def borrow (input : State) : Option (State × Nat) := do
  let (s, status) := reconcile input
  if s.target != 0 || status == 1 then some (rebase s, 0) else do
    let s := { s with flagged := s.flagged || s.prime != 0 }
    let earned := equity s / 10^10 - (s.principal + s.target) / 10^10
    let deployColl := coll8 s - min (coll8 s) earned
    let maximum := (deployColl * lt s / 10000) * wad / (105 * 10^16)
    let idle := s.cash - s.reserved
    let amount := min (idle + (maximum - debt8 s) * 10^10) (10000000 * wad)
    let fair := amount / 10^12
    if fair * 990000 < 1000000 then some (rebase s, 0) else do
      let borrowed := amount - idle
      let s := { s with cash := s.cash + borrowed, debt := s.debt + borrowed }
      if borrowed != 0 && hf s < wad then none else do
        let s ← submit s 1 amount fair
        return (rebase s, amount)

def request (input : State) (v shares : Nat) : Option (State × Nat) := do
  let (s, status) := reconcile input
  let a := vault s v
  if status == 1 || shares == 0 || a.shares < shares then none else do
    let value := live s * shares / s.total
    if value == 0 then none else do
      let basis := a.principal * shares / a.shares
      let s := setVault s v { a with
        shares := a.shares - shares,
        principal := a.principal - basis, requested := a.requested + value,
        allowance := a.allowance + (value - basis) }
      return (rebase { s with
        total := s.total - shares, principal := s.principal - basis,
        target := s.target + value, order := s.order + 1,
        unwinders := if s.unwinders.contains v then s.unwinders else s.unwinders.push v }, s.order + 1)

def credit (input : State) (freed : Nat) : State := Id.run do
  let target := input.target
  let mut s := input
  let mut distributed := 0
  for v in s.unwinders do
    let a := vault s v
    let remaining := a.requested - a.freed
    let cut := min (freed * remaining / target) remaining
    s := setVault s v { a with freed := a.freed + cut }
    distributed := distributed + cut
  return { s with reserved := s.reserved + distributed, target := s.target - distributed }

def repay (input : State) : Option (State × Nat) := do
  let (s, status) := reconcile input
  if s.target == 0 || status == 1 then some (rebase s, 0) else do
    let minimum := (102 * 10^16) * debt8 s * 10000 / (lt s * wad)
    let need := unwindNeed (coll8 s) (debt8 s) s.cash s.reserved s.target (10^8) 10000
    let amount := if debt8 s == 0 then min s.prime (min (ceilDiv s.target (10^12)) (50 * 10^6))
      else if lt s == 0 then 0 else min s.prime (min need (min (50 * 10^6) ((coll8 s - minimum) * 90 / 100 / 100)))
    let s ← if amount == 0 then some s else submit s 2 amount (amount * 10^12)
    let available := s.cash - s.reserved
    let preColl := coll8 s + pendingExit8 s + available / 10^10
    let paid := min s.debt (min available (available / 10^10 * debt8 s / preColl * 10^10))
    let s := credit { s with cash := s.cash - paid, debt := s.debt - paid } (available - paid)
    return (rebase s, available)

def harvestFor (input : State) (v shares : Nat) : Option (State × Nat) := do
  let s := (reconcile input).1
  let a := vault s v
  if a.shares < shares then none else do
    let value := min (live s * shares / s.total) (harvestable s)
    let amount := value / 10^12
    if amount == 0 then some (rebase s, 0) else do
      let burned := ceilDiv (amount * 10^12 * s.total) (live s)
      if serviceBlocked s v || a.weight < burned || s.prime < amount then none else do
        let s := setVault s v { a with shares := a.shares - burned, weight := a.weight - burned }
        let s := { s with prime := s.prime - amount, total := s.total - burned, gift := s.gift + amount }
        if hf s < wad then none else some (rebase s, amount)

def harvest (input : State) (settleFirst : Bool := true) : Option (State × Nat) := do
  let initial := if settleFirst then (reconcile input).1 else input
  let before := initial.vaults.map (·.shares)
  let weights := (List.range 2).toArray.map (weight initial)
  let totalWeight := weights.foldl (· + ·) 0
  let capacity := min totalWeight (capacity initial)
  let donated := initial.gift
  let parked := initial.giftOwned.foldl (· + ·) 0
  let fresh := donated - parked
  let mut s := initial
  let mut surplus := 0
  if initial.total != 0 && fresh != 0 then
    let mut cumulative := 0
    for v in [:2] do
      let prior := fresh * cumulative / initial.total
      cumulative := cumulative + before[v]!
      let cut := fresh * cumulative / initial.total - prior
      s := { s with giftOwned := s.giftOwned.set! v (s.giftOwned[v]! + cut) }
  for v in [:2] do
    s := setVault s v { vault s v with weight := weights[v]! }
  for v in [:2] do
    let shares := capacity * weights[v]! / totalWeight
    let (next, amount) ← if capacity != 0 && weights[v]! != 0 then harvestFor s v shares else some (s, 0)
    s := next
    let ownedGift := if amount == 0 && !serviceBlocked s v then s.giftOwned[v]! else 0
    let a := vault s v
    s := setVault s v { a with compounded := a.compounded + amount + ownedGift }
    let remainingGift := s.gift - amount - ownedGift
    let remainingOwned := s.giftOwned.set! v (s.giftOwned[v]! - ownedGift)
    s := { s with gift := remainingGift, giftOwned := remainingOwned }
    surplus := surplus + amount + ownedGift
  return ({ s with lastHarvest := if surplus == 0 then s.lastHarvest else s.now }, surplus)

def pull (input : State) (v : Nat) : Option (State × Nat) := Id.run do
  let (s, status) := reconcile input
  if status == 1 then return none
  let a := vault s v
  if a.freed == 0 then return some (rebase s, 0)
  let next := { a with
    requested := a.requested - a.freed, freed := 0,
    pulled := a.pulled + a.freed, allowance := if a.requested == a.freed then 0 else a.allowance }
  let mut order := s.unwinders
  if next.requested == 0 then
    if let some i := order.findIdx? (· == v) then
      order := (order.set! i order[order.size - 1]!).pop
  let s := setVault s v next
  return some (rebase { s with cash := s.cash - a.freed, reserved := s.reserved - a.freed, unwinders := order }, a.freed)

def palletFill (s : State) (nonce output : Nat) : Option (State × Nat) := do
  let p := s.pallet[nonce]?.getD {}
  if p.status != 1 || output < p.minimum || p.deadline ≤ s.now * 1000 then none else do
    return ({ s with
      pallet := s.pallet.set! nonce { p with status := 2 },
      cash := s.cash + if p.kind == 2 then output else 0,
      prime := s.prime + if p.kind == 1 then output else 0 }, 0)

def palletRefund (s : State) (nonce : Nat) : Option (State × Nat) := do
  let p := s.pallet[nonce]?.getD {}
  if p.status != 1 || s.now * 1000 < p.deadline then none else do
    return ({ s with
      pallet := s.pallet.set! nonce { p with status := 3 },
      cash := s.cash + if p.kind == 1 then p.amount else 0,
      prime := s.prime + if p.kind == 2 then p.amount else 0 }, 0)

def callback (s : State) (nonce output : Nat) : Option (State × Nat) := do
  let kind := (s.pallet[nonce]?.getD {}).kind
  if s.pending.kind == 0 || s.pending.nonce != nonce || s.pending.kind != kind then
    if nonce == 0 || s.nonce < nonce then none else some (s, 0)
  else if output < s.pending.minimum then none else some (settle s output, 0)

def call (s : State) (op actor amount : Nat) : Option (State × Nat) :=
  match op with
  | 0 => deposit s actor amount
  | 1 => borrow s
  | 2 => palletFill s actor amount
  | 3 => palletRefund s actor
  | 4 => some (reconcile s)
  | 5 => some ({ s with prime := s.prime + amount }, 0)
  | 6 => some ({ s with cash := s.cash + amount }, 0)
  | 7 => request s actor amount
  | 8 => repay s
  | 9 => some ({ s with now := s.now + amount }, 0)
  | 10 => harvest s
  | 11 => some ({ s with gift := s.gift + amount }, 0)
  | 12 => pull s actor
  | 13 => callback s actor amount
  | 14 => some (setVault s actor { vault s actor with seenCost := (vault s actor).cost }, 0)
  | 15 => some (setVault s actor { vault s actor with blocked := amount != 0 }, 0)
  | _ => none

def snapshot (s : State) : Array Nat := Id.run do
  let p := s.pending
  let mut a := #[s.cash, s.prime, s.debt, if s.flagged then 1 else 0, s.total,
    s.principal, s.target, s.reserved, s.order, s.nonce, s.gift, s.now, s.lastHarvest,
    equity s / 10^10, capacity s, hf s, p.nonce, p.deadline, p.kind, p.amount,
    p.minimum, p.fair, p.inputBase, p.outputBase]
  for v in s.vaults do
    a := a ++ #[v.shares, v.principal, v.requested, v.freed, v.allowance, v.cost,
      v.seenCost, v.weight, v.compounded, v.pulled, if v.blocked then 1 else 0]
  a := a ++ s.giftOwned
  for p in s.pallet.toList.drop 1 do
    a := a ++ #[p.kind, p.amount, p.minimum, p.deadline, p.status]
  return a

end Juicer.SharedIntent
