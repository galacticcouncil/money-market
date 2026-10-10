import JuicerLean.FixedPoint.QueueHistories

namespace Juicer.PublicCalls

open Runtime

def actors := 8
def vaultId := 5
def fundId := 6
def zeroId := 7

structure Request where
  owner : Nat := zeroId
  claim : RedemptionState := ⟨0, 0, 0, 0, 0, 0, 0, false⟩
  synth : Nat := 0
  eligible : Nat := 0
  account : Account := {}

structure State where
  supply : Nat := 0
  assets : Nat := 0
  supplied : Nat := 0
  liquid : Nat := 10^9
  reserve : Nat := 10^9
  debt : Nat := 0
  synth : Nat := 0
  held : Nat := 0
  basis : Nat := 0
  freed : Nat := 0
  reinvest : Nat := 0
  pending : Nat := 0
  queued : Nat := 0
  owed : Nat := 0
  queuedDebt : Nat := 0
  head : Nat := 0
  unwind : Nat := 0
  book : Book := {}
  wallets : Array Nat := Array.replicate actors 0
  accounts : Array Account := Array.replicate actors {}
  collateral : Array Nat := #[10^24, 10^24, 10^24, 10^24, 0, 0, 0, 0]
  approvals : Array Nat := Array.replicate 16 0
  requests : Array Request := #[]
  positions : Array MainPosition := #[{}]
  mainUnits : Nat := 0
  ownedCash : Nat := 0
  outstanding : Nat := 0
  sourceHead : Nat := 1
  unallocated : Nat := 0
  batchAmount : Nat := 0
  batchTotal : Nat := 0
  batchWeight : Nat := 0
  batchCursor : Nat := 0
  batchTail : Nat := 0
  paused : Bool := false
  depositsPaused : Bool := false
  sourcePaused : Bool := false
  time : Nat := 1000
  pullBps : Nat := 10000
  repayLimit : Nat := max256
  expanded : Bool := false
  sourceRate : Nat := wad
  sourceCash : Nat := 0
  feeBps : Nat := 0
  costBps : Nat := 0
  price : Nat := wad
  debtIndex : Nat := ray
  borrowLoss : Nat := 0
  repayLoss : Nat := 0
  activeRemaining : Nat := 0
  unallocatedCost : Nat := 0
  batchCost : Nat := 0
  sourceCost : Nat := 0
  protocolReserve : Nat := 0
  feeReserve : Nat := 0
  sourceFees : Array SourceFee := #[{}]
  feesHollar : Nat := 0
  feesCollateral : Nat := 0
  haircut : Nat := 0
  delever : Nat := 0
  lastHarvest : Nat := 1000
  treasuryCash : Nat := 0
  repayCalls : Nat := 0

def wallet (s : State) (i : Nat) := s.wallets[i]?.getD 0
def account (s : State) (i : Nat) := s.accounts[i]?.getD {}
def position (s : State) (i : Nat) := s.positions[i]?.getD {}
def request (s : State) (i : Nat) := s.requests[i]?.getD {}
def activeSupply (s : State) := s.supply - s.queued
def activeAssets (s : State) := s.assets - s.owed
def toAssets (s : State) (n : Nat) :=
  if activeSupply s == 0 then n else n * activeAssets s / activeSupply s
def special (i : Nat) := i == vaultId || i == fundId || i == zeroId
def units (s : State) (i : Nat) := accountUnits s.book (account s i) (wallet s i) (special i)
def balance (s : State) (i : Nat) :=
  if i == vaultId then wallet s i else
  if i == fundId then if s.book.total == 0 then wallet s i else 0
  else wallet s i + fundedOf (wallet s fundId) s.book.total (units s i)
def setWallet (s : State) (i n : Nat) := { s with wallets := s.wallets.set! i n }
def setAccount (s : State) (i : Nat) (a : Account) := { s with accounts := s.accounts.set! i a }
def setPosition (s : State) (i : Nat) (p : MainPosition) := { s with positions := s.positions.set! i p }
def settleOwner (s : State) (i : Nat) :=
  if special i then s else setAccount s i (settle s.book (account s i) (wallet s i))
def pendingAccounting (s : State) := s.unallocated != 0 || s.unallocatedCost != 0
def fee (s : State) (i : Nat) := s.sourceFees[i]?.getD {}
def spendable (s : State) (i : Nat) := (position s i).cash - (fee s i).feeLeft
def sourceValue (s : State) (n : Nat) := n * s.sourceRate / wad
def sourceEquity (s : State) := sourceValue s s.held / 10^10 * 10^10
def quoteHollar (s : State) (n : Nat) := n * (s.price / 10^10) / 10^8
def quoteCollateral (s : State) (n : Nat) := n * 10^8 / (s.price / 10^10)

def allocationInput (s : State) : AllocationInput :=
  let required := requiredBacking (mainDebtOf s.debt s.mainUnits (position s 0))
    (position s 0).principal (spendable s 0) s.feeBps
  ⟨s.held, sourceEquity s, required + (if required == 0 then 0 else 2*10^10),
    activeSupply s, wallet s fundId, quoteHollar s (toAssets s (wallet s fundId)), s.basis, s.feeBps⟩

def checkpoint (s : State) (a b : Nat) : State := Id.run do
  let mut s := s
  if !pendingAccounting s then
    let v := allocationInput s
    let trimmed := trimLoss s.book (allocationAvailable v)
    let added := allocationAvailable v - trimmed.source - trimmed.protocol
    let released := if v.held != 0 && v.supply != 0 && added != 0 then
      min (added * v.equity / v.held) (v.basis - v.required) else 0
    s := { s with book := allocate s.book v, basis := s.basis - released }
  s := settleOwner s a
  return if a == b then s else settleOwner s b

abbrev Result := Except Nat (State × Nat)

def transfer (s : State) (a b n : Nat) : Except Nat State := do
  let mut s := s
  let mut moved := n
  if a != vaultId && b != vaultId && a != fundId then
    s := settleOwner (settleOwner s a) b
    let excess := n - wallet s a
    if excess != 0 then
      if b == fundId || b == zeroId then throw 10
      let owned := (account s a).units
      if excess > fundedOf (wallet s fundId) s.book.total owned then throw 11
      if a != b then
        match take (wallet s fundId) s.book.total owned excess with
        | none => throw 12
        | some (taken, left) =>
          s := setAccount s a { account s a with units := left }
          s := setAccount s b { account s b with units := (account s b).units + taken }
      moved := wallet s a
  if b == zeroId then throw 13
  if s.paused then throw 14
  if wallet s a < moved then throw 15
  return setWallet (setWallet s a (wallet s a - moved)) b
    ((if a == b then wallet s b - moved else wallet s b) + moved)

def spend (s : State) (owner caller amount : Nat) : Except Nat State := do
  if owner == caller then return s
  let i := owner * 4 + caller
  let allowed := s.approvals[i]?.getD 0
  if allowed == max256 then return s
  if allowed < amount then throw 16
  return { s with approvals := s.approvals.set! i (allowed - amount) }

def pay (s : State) (key limit : Nat) : State × Nat × Nat :=
  let p := position s key
  let debt := mainDebtOf s.debt s.mainUnits p
  let quantum := 2 * ceilDiv s.debtIndex ray
  let principal := min p.principal debt
  let interest := debt - principal
  let cap := interest + min principal limit
  let drawn := if key != 0 && p.remaining == 0 && spendable s key < cap then
    min s.protocolReserve (cap - spendable s key + quantum) else 0
  let usable := p.cash + drawn - (fee s key).feeLeft
  let amount := min usable (if key == 0 && limit != 0 then min debt limit else interest + min principal limit)
  let firstPaid := min (min amount s.debt) s.repayLimit
  let firstReduced := if firstPaid == s.debt then firstPaid else firstPaid - s.repayLoss
  let retry := firstPaid == amount && firstReduced < amount && firstPaid < usable
  let extra := if retry then
    min (min (min (usable - firstPaid) (amount - firstReduced + quantum))
      (s.debt - firstReduced)) s.repayLimit else 0
  let paid := firstPaid + extra
  let reduced := firstReduced + (if retry then
    if extra == s.debt - firstReduced then extra else extra - s.repayLoss else 0)
  let spent := if amount != 0 then paid else 0
  let burned := if amount != 0 then
    if debt ≤ reduced then p.units else reduced * s.mainUnits / s.debt else 0
  let units := p.units - burned
  let principal := if amount != 0 then principal - min principal (reduced - interest) else principal
  let unused := min drawn (p.cash + drawn - spent - (fee s key).feeLeft)
  let total := s.mainUnits - burned
  let next := { p with
    cash := p.cash + drawn - spent - unused,
    units := if debt ≤ reduced then 0 else units, principal }
  let synthBurn := if s.debt == 0 then 0 else s.synth * reduced / s.debt
  (setPosition { s with
    mainUnits := if debt ≤ reduced then total - units else total,
    ownedCash := s.ownedCash + drawn - spent - unused,
    protocolReserve := s.protocolReserve - drawn + unused,
    repayCalls := s.repayCalls + (if amount == 0 then 0 else 1) + (if retry then 1 else 0),
    debt := s.debt - reduced, synth := s.synth - synthBurn } key next,
    p.principal - principal, reduced)

def cover (s : State) (n : Nat) : Except Nat State :=
  if s.reserve < n then .error 17
  else .ok { s with reserve := s.reserve - n, assets := s.assets + n }

def startOne (s : State) (id : Nat) : Except Nat State := do
  let mut s := checkpoint s zeroId zeroId
  let r := request s id
  let escrowed := r.claim.shares
  let supply := activeSupply s
  let settled := settle s.book (account s r.owner) (wallet s r.owner)
  let out := startExit s.book (account s r.owner) r.account
    (wallet s r.owner) escrowed (wallet s fundId)
  s := setAccount s r.owner { settled with units := out.owned }
  s := { s with book := out.book }
  s := setWallet (setWallet s fundId (wallet s fundId - out.folded)) vaultId
    (wallet s vaultId + out.folded)
  let shares := escrowed + out.folded
  let numerator := activeAssets s * shares
  let owed := ceilDiv numerator supply
  if owed == 0 then throw 2
  s := { s with reinvest := s.reinvest - s.reinvest * shares / supply }
  let activeSlice := (s.held - s.book.source - s.book.protocol - out.reward - out.fee) * shares / supply
  let slice := activeSlice + out.reward + out.fee
  let basis := s.basis * shares / supply
  if pendingAccounting s then throw 18
  let claim := sourceValue s slice
  let sourceFee := (claim * activeSlice / slice - basis) * s.feeBps / 10000 + claim * out.fee / slice
  let vested := vestFee claim basis sourceFee
  let (active, exit, total) := mainExit (position s 0) s.mainUnits s.debt shares supply claim
  let debt := mainDebtOf s.debt total exit
  if slice == 0 && debt > (position s 0).cash * shares / supply then throw 19
  let synth := if s.debt == 0 then 0 else s.synth * debt / s.debt
  s := setPosition s 0 active
  s := { s with
    positions := s.positions.push exit,
    mainUnits := total,
    held := s.held - slice,
    basis := s.basis - (if slice == 0 then 0 else basis),
    freed := s.freed + claim,
    outstanding := s.outstanding + claim,
    sourceFees := s.sourceFees.push (if s.expanded then vested else {}),
    feeReserve := s.feeReserve + (if s.expanded then vested.feeLeft else 0) }
  s ← cover s (owed - numerator / supply)
  return { s with
    pending := s.pending - escrowed, queued := s.queued + shares,
    owed := s.owed + owed, queuedDebt := s.queuedDebt + debt,
    requests := s.requests.set! id { r with claim := freshRedemption shares owed debt, synth, account := {} } }

def startMany (fuel : Nat) (s : State) (next : Nat) : Except Nat (State × Nat) := do
  match fuel with
  | 0 => return (s, next)
  | n + 1 =>
    if s.requests.size ≤ next || s.time < (request s next).eligible then return (s, next)
    let s ← startOne s next
    startMany n s (next + 1)

def creditPosition (s : State) (key weight : Nat) : State × Nat := Id.run do
  let (cash, cost) := batchSegment s.batchAmount s.batchCost s.batchTotal s.batchWeight weight
  let remaining := weight - cash - cost
  let (nextFee, charged) := settleFee (fee s key) remaining cost
  let p := position s key
  let s := setPosition s key { p with
    cash := p.cash + cash - charged,
    remaining := if key == 0 then 0 else remaining }
  return ({ s with
    activeRemaining := if key == 0 then remaining else s.activeRemaining,
    sourceFees := s.sourceFees.set! key nextFee,
    feeReserve := s.feeReserve - ((fee s key).feeLeft - nextFee.feeLeft),
    feesHollar := s.feesHollar + charged,
    ownedCash := s.ownedCash - charged,
    unallocated := s.unallocated - cash,
    unallocatedCost := s.unallocatedCost - cost,
    outstanding := s.outstanding - cash - cost,
    batchWeight := s.batchWeight + weight }, cost + charged)

def creditSteps : Nat → State → State
  | 0, s => s
  | fuel + 1, s =>
    if s.batchTail ≤ s.batchCursor then s else
    let key := s.batchCursor
    let next := (creditPosition s key (position s key).remaining).1
    creditSteps fuel { next with
      batchCursor := key + 1,
      sourceHead := if key == next.sourceHead && (position next key).remaining == 0
        then next.sourceHead + 1 else next.sourceHead }

def credit (s : State) (amount cost : Nat) : State := Id.run do
  let mut s := { s with
    unallocated := s.unallocated + amount,
    unallocatedCost := s.unallocatedCost + cost, ownedCash := s.ownedCash + amount }
  if s.batchAmount == 0 && s.batchCost == 0 then
    if s.unallocated == 0 && s.unallocatedCost == 0 then return s
    s := { s with
      batchAmount := s.unallocated, batchCost := s.unallocatedCost,
      batchTotal := s.outstanding, batchWeight := 0,
      batchCursor := s.sourceHead, batchTail := s.positions.size }
    let (next, activeCost) := creditPosition s 0 s.activeRemaining
    s := { next with delever := next.delever - activeCost }
  s := creditSteps 64 s
  if s.batchCursor == s.batchTail then s := { s with batchAmount := 0, batchCost := 0, batchWeight := 0 }
  return s

def settleRecord (s : State) (id : Nat) (r : Request) (next : RedemptionState) : State :=
  let withdrawn := min (next.settled - r.claim.settled) s.supplied
  { s with
    requests := s.requests.set! id { r with claim := next },
    queuedDebt := s.queuedDebt - (next.repaid - r.claim.repaid),
    supplied := s.supplied - withdrawn,
    liquid := s.liquid + withdrawn }

def finishSettle (s : State) (id : Nat) (r : Request) (paid : Nat) : State × Bool :=
  let next := settleRedemption r.claim paid
  let nextState := settleRecord s id r next
  if next.repaid < next.debt then (nextState, false)
  else ({ nextState with head := id + 1 }, true)

def settleOne (s : State) : State × Bool :=
  if s.paused || s.sourcePaused || s.delever != 0 || s.unwind ≤ s.head then (s, false) else
  let id := s.head
  let r := request s id
  let (nextState, paid, _) := if r.claim.debt == r.claim.repaid then (s, 0, 0)
    else pay s (id + 1) (r.claim.debt - r.claim.repaid)
  finishSettle nextState id r paid

def settleMany : Nat → State → State
  | 0, s => s
  | fuel + 1, s =>
    let (next, more) := settleOne s
    if more then settleMany fuel next else next

def harvestable (s : State) :=
  let equity := sourceEquity s
  let reserved := s.book.source + s.book.protocol
  if pendingAccounting s || equity == 0 || s.held == 0 then 0 else
  reserved + (equity - equity * reserved / s.held - s.basis) * s.held / equity

def compoundFunds (input : State) (out reward service feeAmount : Nat) : Except Nat State := do
  let mut s := input
  let oldSynth := s.synth
  let cashBefore := spendable s 0
  let interest := mainDebtOf s.debt s.mainUnits (position s 0) - (position s 0).principal
  let fresh := reward + service
  let sold := min fresh (ceilDiv (ceilDiv ((interest - cashBefore) * 10000) 9900 * 10^8) (s.price / 10^10))
  if sold != 0 then
    let fair := quoteHollar s sold
    let received := fair * (10000 - s.haircut) / 10000
    if received < fair * 9900 / 10000 then throw 26
    if received == 0 then throw 25
    s := setPosition s 0 { position s 0 with cash := (position s 0).cash + received }
    s := { s with ownedCash := s.ownedCash + received }
  s := (pay s 0 0).1
  s := { s with synth := oldSynth }
  let returned := fresh - sold
  let rewardSpent := sold - service
  let fundedReward := min reward returned
  let serviceRemainder := returned - fundedReward
  if rewardSpent != 0 && cashBefore < spendable s 0 then
    let value := min (spendable s 0 - cashBefore) (quoteHollar s rewardSpent)
    let v := allocationInput s
    let added := min (allocationAvailable v - s.book.source - s.book.protocol) (value * s.held / v.equity)
    s := { s with
      book := { s.book with source := s.book.source + added },
      basis := s.basis - min (added * v.equity / s.held) (s.basis - v.required) }
  let minted := fundedReward * activeSupply s / (activeAssets s + serviceRemainder)
  s := setWallet s fundId (wallet s fundId + minted)
  if out != fresh + feeAmount then throw 99
  return { s with
    supply := s.supply + minted, assets := s.assets + returned,
    supplied := s.supplied + returned, reinvest := s.reinvest + returned,
    feesCollateral := s.feesCollateral + feeAmount }

def harvestAll (s : State) (minimum : Nat) : Except Nat (State × Nat) := do
  let mut s := checkpoint s zeroId zeroId
  let burned := harvestable s
  if burned == 0 then return (s, 0)
  let amount := sourceValue s burned
  let fair := quoteCollateral s amount
  let out := fair * (10000 - s.haircut) / 10000
  if out < max minimum (fair * 9900 / 10000) then throw 26
  if out == 0 then throw 28
  let (reward, service, feeAmount) := splitHarvest out burned s.book.source s.book.protocol s.feeBps
  s := { s with
    held := s.held - burned, sourceCash := s.sourceCash - amount,
    book := { s.book with source := 0, protocol := 0 } }
  s ← compoundFunds s out reward service feeAmount
  return ({ s with lastHarvest := s.time }, amount)

structure Action where
  op : Nat
  caller : Nat := 0
  a : Nat := 0
  b : Nat := 0
  amount : Nat := 0
  deriving Repr

def runCall (input : State) (action : Action) : Result := do
  let ⟨op, caller, a, b, n⟩ := action
  let mut s := input
  if [0, 4, 5, 7, 8, 9, 23, 24].contains op && (s.paused || s.sourcePaused) then throw 1
  if op == 0 then
    if b == zeroId then throw 3
    if s.depositsPaused then throw 4
    if n == 0 then throw 2
    if s.delever != 0 then throw 24
    if pendingAccounting s || s.activeRemaining != 0 then throw 18
    -- beforeDeposit adjusts principal but leaves synthetic custody unchanged.
    let oldSynth := s.synth
    s := (pay s 0 0).1
    s := { s with synth := oldSynth }
    s := checkpoint s zeroId b
    if s.supply == 0 && caller != 0 then throw 5
    if s.assets + n > 1000 * wad then throw 6
    let supply := activeSupply s
    if supply == 0 && n ≤ 1000 then throw 7
    if supply != 0 && activeAssets s == 0 then throw 8
    let shares := if supply == 0 then n - 1000 else ceilDiv (n * supply) (activeAssets s)
    let needed := if supply == 0 then n else ceilDiv (shares * activeAssets s) supply
    if s.supply == 0 then s := setWallet { s with supply := 1000 } 4 1000
    s := setWallet s b (wallet s b + shares)
    s := { s with
      supply := s.supply + shares,
      assets := s.assets + n,
      supplied := s.supplied + n,
      reinvest := s.reinvest + n,
      collateral := s.collateral.set! caller (s.collateral[caller]! - n) }
    s ← cover s (needed - n)
    if s.synth * 9800 / 10000 < s.debt then throw 23
    return (s, shares)
  else if op == 1 then
    return ({ s with approvals := s.approvals.set! (caller * 4 + b) n }, 1)
  else if op == 2 || op == 3 then
    if op == 3 then
      -- ERC20 transferFrom spends even a self-allowance.
      let i := a * 4 + caller
      let allowed := s.approvals[i]?.getD 0
      if allowed != max256 then
        if allowed < n then throw 16
        s := { s with approvals := s.approvals.set! i (allowed - n) }
    s ← transfer s (if op == 2 then caller else a) b n
    return (s, 1)
  else if op == 4 then
    s := checkpoint s a zeroId
    if n == max256 && caller != a then throw 9
    let amount := if n == max256 then balance s a else n
    if amount == 0 || toAssets s amount == 0 then throw 2
    s ← spend s a caller amount
    let escrow := min amount (wallet s a)
    s ← transfer s a vaultId escrow
    let mut owned := (account s a).units
    let mut committed := 0
    if escrow < amount then
      if fundedOf (wallet s fundId) s.book.total owned < amount - escrow then throw 11
      match take (wallet s fundId) s.book.total owned (amount - escrow) with
      | none => throw 12
      | some (taken, left) => committed := taken; owned := left
      s := setAccount s a { account s a with units := owned }
    let r : Request := { owner := a, eligible := s.time + 10, claim := ⟨escrow, 0, 0, 0, 0, 0, 0, true⟩, account := ⟨committed, s.book.index, s.book.epoch, s.book.scale⟩ }
    return ({ s with requests := s.requests.push r, pending := s.pending + escrow }, s.requests.size)
  else if op == 5 then
    if s.delever != 0 || s.activeRemaining != 0 then return (s, 0)
    let (next, cursor) ← startMany n s s.unwind
    return ({ next with unwind := cursor }, 0)
  else if op == 6 then
    let gross := s.freed * s.pullBps / 10000
    let cost := gross * s.costBps / 10000
    let freed := gross - cost
    let pending := pendingAccounting s
    s := credit { s with
      freed := s.freed - gross, sourceCash := s.sourceCash - gross,
      sourceCost := s.sourceCost + cost } freed cost
    let (next, _, reduced) := pay s 0 s.delever
    s := { next with delever := if next.debt == 0 then 0 else next.delever - reduced }
    s := settleMany 32 s
    return (s, freed + (input.debt - s.debt) + (s.head - input.head) + (if pending then 1 else 0))
  else if op == 7 then
    let r := request s n
    if !r.claim.active then throw 20
    let receiver := if caller == r.owner then b else r.owner
    if receiver == zeroId then throw 3
    if r.claim.settled == 0 then throw 21
    let (next, _, burned) := claimRedemption r.claim
    let paid := r.claim.settled
    s := setWallet s vaultId (wallet s vaultId - burned)
    s := { s with
      supply := s.supply - burned,
      assets := s.assets - (if receiver == vaultId then 0 else paid),
      liquid := s.liquid - (if receiver == vaultId then 0 else paid),
      queued := s.queued - burned,
      owed := s.owed - paid,
      requests := s.requests.set! n { r with claim := next },
      collateral := s.collateral.set! receiver (s.collateral[receiver]! + paid) }
    return (s, paid)
  else if op == 8 then
    s := checkpoint s zeroId zeroId
    return (s, harvestable s)
  else if op == 9 then
    s := checkpoint s zeroId zeroId
    if s.delever != 0 then return (s, 0)
    let coll8 := s.supplied * s.price / wad / 10^10
    if coll8 == 0 then return (s, 0)
    let debt8 := s.debt / 10^10
    let exiting := s.pending != 0 || s.head != s.unwind || s.freed != 0
    let resize := !exiting && debt8 * 10000 / coll8 + 500 < 7500
    let target := coll8 * 7500 / 10000
    if resize || (s.reinvest != 0 && debt8 < target) then
      if pendingAccounting s || s.activeRemaining != 0 then throw 18
      let oldSynth := s.synth
      s := (pay s 0 0).1
      s := { s with synth := oldSynth }
      let wanted := (target - debt8) * 10^10
      let amount := if resize then wanted else min wanted
        (coll8 * min s.reinvest s.assets / s.assets * 7500 / 10000 * 10^10)
      if amount == 0 then return (s, 0)
      if s.mainUnits != 0 && s.debt == 0 then throw 18
      let borrowed := amount - s.borrowLoss
      let (active, total) := mainBorrow (position s 0) s.mainUnits s.debt (s.debt + borrowed)
      s := setPosition s 0 active
      let supplied := s.synth + buffered amount 9800
      if supplied * 9800 / 10000 < s.debt + borrowed then throw 23
      let shares := amount * wad / s.sourceRate
      return ({ s with
        mainUnits := total,
        debt := s.debt + borrowed,
        synth := supplied,
        held := s.held + shares,
        sourceCash := s.sourceCash + amount,
        basis := s.basis + amount,
        reinvest := 0 }, shares)
    if !exiting && 7800 < debt8 * 10000 / coll8 then
      let active := s.held - s.book.source - s.book.protocol
      let equity8 := sourceEquity s / 10^10 * active / s.held
      let slice := active * min (debt8 - target) equity8 / equity8
      if slice != 0 then
        if s.activeRemaining != 0 || s.batchAmount != 0 || s.batchCost != 0 || pendingAccounting s then throw 18
        let basis := s.basis * slice / active
        let claim := sourceValue s slice
        let vested := vestFee claim basis ((claim - basis) * s.feeBps / 10000)
        return ({ s with
          held := s.held - slice, basis := s.basis - basis,
          freed := s.freed + claim, outstanding := s.outstanding + claim,
          activeRemaining := claim, delever := claim,
          sourceFees := s.sourceFees.set! 0 vested, feeReserve := s.feeReserve + vested.feeLeft }, slice)
    return (s, 0)
  else if op == 10 then return ({ s with time := s.time + n }, 0)
  else if op == 11 then
    let paid := min (min n s.debt) s.repayLimit
    let reduced := if paid == s.debt then paid else paid - s.repayLoss
    return ({ s with debt := s.debt - reduced, repayCalls := s.repayCalls + 1 }, paid)
  else if op == 12 then return ({ s with pullBps := n }, 0)
  else if op == 13 then return ({ s with repayLimit := n }, 0)
  else if op == 14 then
    if n != 0 && (s.paused || s.sourcePaused) then throw 1
    if n == 0 && !s.paused && !s.sourcePaused then throw 22
    return ({ s with paused := n != 0 }, 0)
  else if op == 15 then return ({ s with depositsPaused := n != 0 }, 0)
  else if op == 16 then return ({ s with sourcePaused := n != 0 }, 0)
  else if op == 17 then
    return ({ s with sourceRate := n, sourceCash := s.sourceCash + s.held * n / wad - sourceValue s s.held }, 0)
  else if op == 18 then return ({ s with feeBps := n }, 0)
  else if op == 19 then return ({ s with costBps := n }, 0)
  else if op == 20 then
    let index := ceilDiv (s.debtIndex * (10000 + n)) 10000
    return ({ s with debt := ceilDiv (s.debt * index) s.debtIndex, debtIndex := index }, 0)
  else if op == 21 then return ({ s with price := n }, 0)
  else if op == 22 then
    if ceilDiv (s.debt * 10000 * 10025) (9800 * 10000) ≤ s.synth then return (s, 0)
    let add := buffered s.debt 9800 - s.synth
    return ({ s with synth := s.synth + add }, add)
  else if op == 23 then harvestAll s n
  else if op == 24 then
    if n == 0 then throw 2
    if s.collateral[caller]! < n then throw 15
    if n < b then throw 28
    s := { s with collateral := s.collateral.set! caller (s.collateral[caller]! - n) }
    s ← compoundFunds s n 0 n 0
    return (s, 0)
  else if op == 25 then return ({ s with borrowLoss := a, repayLoss := n }, 0)
  else if op == 26 then return ({ s with protocolReserve := s.protocolReserve + n }, 0)
  else if op == 27 then
    if a == 0 then return ({ s with
      feesCollateral := 0,
      collateral := s.collateral.set! 3 (s.collateral[3]! + s.feesCollateral) }, 0)
    return ({ s with feesHollar := 0, treasuryCash := s.treasuryCash + s.feesHollar }, 0)
  else if op == 28 then return ({ s with haircut := n }, 0)
  else if op == 30 then
    s := setPosition s 0 { position s 0 with cash := (position s 0).cash + n }
    return ({ s with ownedCash := s.ownedCash + n }, 0)
  else throw 99

def execute (s : State) (a : Action) : State × Nat × Nat :=
  match runCall s a with
  | .ok (next, value) => (next, 0, value)
  | .error code => (s, code, 0)

theorem failure_rolls_back (s : State) (a : Action) (code : Nat)
    (h : runCall s a = .error code) : execute s a = (s, code, 0) := by
  simp [execute, h]

def snapshot (s : State) : Array Nat := Id.run do
  let mut out := #[s.supply, s.assets, s.supplied, s.liquid, s.reserve, s.debt, s.synth,
    s.held, s.basis, s.freed, s.reinvest, s.pending, s.queued, s.owed, s.queuedDebt,
    s.head, s.unwind, s.requests.size, s.book.source, s.book.protocol, s.book.total,
    s.book.index, s.book.epoch, s.book.scale, s.mainUnits, s.ownedCash, s.outstanding,
    s.sourceHead, s.positions.size, s.unallocated, (s.paused || s.sourcePaused).toNat, s.depositsPaused.toNat,
    s.sourcePaused.toNat, s.time]
  for i in [:actors] do
    let a := account s i
    out := out ++ #[wallet s i, balance s i, units s i, a.units, a.index, a.epoch, a.scale,
      if i == vaultId then s.liquid else s.collateral[i]!]
  out := out ++ s.approvals
  for r in s.requests do
    let c := r.claim
    out := out ++ #[r.owner, c.shares, c.owed, c.debt, r.synth, c.repaid, c.settled,
      c.burned, c.active.toNat, c.claimed, r.eligible, r.account.units, r.account.index,
      r.account.epoch, r.account.scale]
  for i in [:s.positions.size] do
    let p := position s i
    out := out ++ #[p.units, p.principal, p.cash, p.remaining,
      if i == 0 then zeroId else (request s (i-1)).owner]
  if s.expanded then
    out := out ++ #[s.sourceRate, s.sourceCash, s.feeBps, s.costBps, s.price, s.debtIndex,
      s.borrowLoss, s.repayLoss, s.activeRemaining, s.unallocatedCost, s.sourceCost,
      s.protocolReserve, s.feeReserve, s.feesHollar, s.feesCollateral, s.haircut,
      s.delever, s.lastHarvest, s.treasuryCash, s.batchAmount, s.batchCost, s.batchTotal,
      s.batchWeight, s.batchCursor, s.batchTail, s.repayCalls]
    for f in s.sourceFees do out := out ++ #[f.yieldLeft, f.feeLeft]
  return out

end Juicer.PublicCalls
