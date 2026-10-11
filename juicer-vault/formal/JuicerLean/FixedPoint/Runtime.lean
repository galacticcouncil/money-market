import Mathlib

/-! executable arithmetic for the current Solidity; natural subtraction saturates only where the
contract guards it. callers supply valid uint256 states and successful external-call results.
`SOLIDITY_PARITY.md` records the bounds, source revision and remaining abstraction boundaries. -/

namespace Juicer.Runtime

def ray : ℕ := 10 ^ 27
def wad : ℕ := 10 ^ 18
def max256 : ℕ := 2 ^ 256 - 1
def ceilDiv (a b : ℕ) : ℕ := a ⌈/⌉ b

def buffered (debt lt : ℕ) : ℕ :=
  let base := ceilDiv (debt * 10000) lt
  base + base / 200

def pegTopUp (debt lt supplied : ℕ) : ℕ :=
  if ceilDiv (debt * 10000 * 10025) (lt * 10000) ≤ supplied then 0
  else buffered debt lt - supplied

theorem buffered_floors (debt lt : ℕ) (hlt : 0 < lt) :
    debt ≤ buffered debt lt * lt / 10000 := by
  apply (Nat.le_div_iff_mul_le (by decide : 0 < 10000)).2
  have h := le_smul_ceilDiv (b := debt * 10000) hlt
  change debt * 10000 ≤ lt * ceilDiv (debt * 10000) lt at h
  dsimp [buffered]
  calc debt * 10000 ≤ ceilDiv (debt * 10000) lt * lt := by simpa [Nat.mul_comm] using h
       _ ≤ _ := Nat.mul_le_mul_right lt (Nat.le_add_right _ _)

structure Book where
  source : ℕ := 0
  protocol : ℕ := 0
  total : ℕ := 0
  index : ℕ := 0
  epoch : ℕ := 0
  scale : ℕ := 0
  deriving Repr, BEq

structure Account where
  units : ℕ := 0
  index : ℕ := 0
  epoch : ℕ := 0
  scale : ℕ := 0
  deriving Repr, BEq

def accountUnits (b : Book) (a : Account) (weight : ℕ) (special := false) : ℕ :=
  if special then a.units else
  let current := a.epoch == b.epoch
  let shift := if current then b.scale - a.scale else 0
  let previous := if current then a.index >>> shift else 0
  let owned := if current then a.units >>> shift else 0
  min b.total (owned + weight * (b.index - previous) / ray)

def settle (b : Book) (a : Account) (weight : ℕ) : Account :=
  ⟨accountUnits b a weight, b.index, b.epoch, b.scale⟩

def fundedOf (funded total owned : ℕ) : ℕ :=
  if total == 0 then 0 else funded * owned / total

def take (funded total owned shares : ℕ) : Option (ℕ × ℕ) :=
  let slice := if owned == 0 then 0 else fundedOf funded total owned
  if slice == 0 || slice < shares then none else
  let taken := min owned (ceilDiv (owned * shares) slice)
  some (taken, owned - taken)

theorem accountUnits_le (b : Book) (a : Account) (w : ℕ) :
    accountUnits b a w ≤ b.total := by
  simp only [accountUnits, Bool.false_eq_true, ↓reduceIte]
  exact min_le_left _ _

theorem fundedOf_le (f t u : ℕ) (hu : u ≤ t) : fundedOf f t u ≤ f := by
  unfold fundedOf
  split
  · exact Nat.zero_le _
  · calc f * u / t ≤ f * t / t := Nat.div_le_div_right (Nat.mul_le_mul_left f hu)
         _ ≤ f := Nat.div_le_of_le_mul (by rw [Nat.mul_comm])

theorem take_conserves (f t u s x left : ℕ) (h : take f t u s = some (x, left)) :
    x + left = u := by
  dsimp [take] at h
  split_ifs at h <;> simp_all
  all_goals
    rcases h with ⟨hx, hl⟩
    rw [← hx, ← hl]
    exact Nat.add_sub_of_le (min_le_left _ _)

def requiredBacking (debt principal cash fee : ℕ) : ℕ :=
  let required := debt - cash
  let interest := debt - principal - cash
  required + if fee < 10000 then ceilDiv (interest * fee) (10000 - fee) else 0

def rescale : ℕ → Book → ℕ → Book
  | 0, b, _ => b
  | n + 1, b, limit =>
    if limit < b.total then
      rescale n { b with total := b.total >>> 64, index := b.index >>> 64, scale := b.scale + 64 } limit
    else b

theorem rescale_four_suffices (b : Book) (limit : ℕ) (h : b.total < 2 ^ 256) :
    (rescale 4 b limit).total ≤ limit := by
  simp only [rescale]
  split_ifs <;> simp_all [Nat.shiftRight_eq_div_pow]
  all_goals omega

theorem take_rounding_example : take 10 3 2 1 = some (1, 1) := by decide

theorem funded_rounding_example : fundedOf 10 3 2 - fundedOf 10 3 1 = 3 := by decide

structure AllocationInput where
  held : ℕ
  equity : ℕ
  required : ℕ
  supply : ℕ
  funded : ℕ
  fundedValue : ℕ
  basis : ℕ
  fee : ℕ
  deriving Repr

def trimLoss (b : Book) (available : ℕ) : Book :=
  if available < b.source + b.protocol then
    let source := b.source * available / (b.source + b.protocol)
    { b with source, protocol := available - source }
  else b

def allocationAvailable (v : AllocationInput) : ℕ :=
  if v.required < v.equity then (v.equity - v.required) * v.held / v.equity else 0

def finishAllocation (b : Book) (v : AllocationInput) (added before : ℕ) : Book :=
  let released := min (added * v.equity / v.held) (v.basis - v.required)
  let untaxed := released * v.held / v.equity
  let feeShares := (added - untaxed) * v.fee / 10000
  let rewardShares := added - feeShares
  let value := v.equity * rewardShares / v.held
  let selfValue := value * v.funded / v.supply
  let outsideSupply := v.supply - v.funded
  let outsideValue := value - selfValue
  let denominator := before + selfValue + 1
  let limit := 2 ^ 160 * denominator / max denominator outsideValue
  let b := rescale 4 b limit
  let minted := outsideValue * (b.total + 1) / denominator
  { b with
    source := b.source + rewardShares
    protocol := b.protocol + feeShares
    total := b.total + minted
    index := b.index + (if outsideSupply != 0 then minted * ray / outsideSupply else 0) }

def allocate (b : Book) (v : AllocationInput) : Book :=
  let available := allocationAvailable v
  let b := trimLoss b available
  let added := available - (b.source + b.protocol)
  let allocating := v.held != 0 && v.supply != 0 && added != 0
  if b.total == 0 && !allocating then b else
  let before := (if v.held == 0 then 0 else v.equity * b.source / v.held) + v.fundedValue
  let b := if b.total != 0 && before == 0 then
    { b with total := 0, index := 0, scale := 0, epoch := b.epoch + 1 } else b
  if !allocating then b else finishAllocation b v added before

structure ExitResult where
  book : Book
  owned : ℕ
  reward : ℕ
  fee : ℕ
  folded : ℕ
  burned : ℕ
  deriving Repr

def startExit (b : Book) (owner request : Account) (wallet shares funded : ℕ) : ExitResult :=
  let current := request.epoch == b.epoch
  let shift := if current then b.scale - request.scale else 0
  let previous := if current then request.index >>> shift else 0
  let committed := if current then request.units >>> shift else 0
  let owned := min b.total (accountUnits b owner wallet + shares * (b.index - previous) / ray)
  let exiting := if owned == 0 || shares == 0 then 0 else owned * shares / (wallet + shares)
  let burned := min b.total (committed + exiting)
  let reward := b.source * burned / b.total
  let fee := if b.source == 0 then 0 else b.protocol * reward / b.source
  let folded := funded * burned / b.total
  ⟨{ b with total := b.total - burned, source := b.source - reward, protocol := b.protocol - fee },
    owned - exiting, reward, fee, folded, burned⟩

theorem startExit_units_conserved (b : Book) (o r : Account) (w s f : ℕ) :
    (startExit b o r w s f).book.total + (startExit b o r w s f).burned = b.total := by
  simp only [startExit]
  exact Nat.sub_add_cancel (min_le_left _ _)

theorem startExit_fold_le (b : Book) (o r : Account) (w s f : ℕ) :
    (startExit b o r w s f).folded ≤ f := by
  simp only [startExit]
  calc _ ≤ f * b.total / b.total := Nat.div_le_div_right (Nat.mul_le_mul_left f (min_le_left _ _))
       _ ≤ f := Nat.div_le_of_le_mul (by rw [Nat.mul_comm])

def splitHarvest (collateral harvested rewards protocol feeBps : ℕ) : ℕ × ℕ × ℕ :=
  let reward := collateral * rewards / harvested
  let fee := collateral * protocol / harvested
  let service := collateral - reward - fee
  let serviceFee := service * feeBps / 10000
  (reward, service - serviceFee, fee + serviceFee)

structure Intent where
  kind : ℕ := 0
  nonce : ℕ := 0
  amount : ℕ := 0
  minimum : ℕ := 0
  inBase : ℕ := 0
  outBase : ℕ := 0
  deriving Repr

def outcome (p : Intent) (input output : ℕ) : ℕ × ℕ :=
  if p.outBase < output && (p.minimum + 1) / 2 ≤ output - p.outBase then (2, output - p.outBase)
  else if p.inBase < input && (p.amount + 1) / 2 ≤ input - p.inBase then (3, 0)
  else (1, 0)

def inFlight (p : Intent) (input output price : ℕ) : ℕ × ℕ :=
  if p.kind == 0 || (outcome p input output).1 != 1 then (0, 0)
  else if p.kind == 1 then (1, p.amount / 10 ^ 10) else (2, p.amount * price / 10 ^ 6)

def effectiveAccount (p : Intent) (input output price coll debt lt aaveHF : ℕ) : ℕ × ℕ × ℕ :=
  let (kind, value) := inFlight p input output price
  if kind == 0 then (coll, debt, aaveHF) else
  let coll := if kind == 1 then coll else coll + value
  let debt := if kind == 1 then debt - min debt value else debt
  (coll, debt, if debt == 0 then max256 else coll * lt * 10 ^ 14 / debt)

def totalEquity (p : Intent) (input output price coll unflagged debt cash reserved : ℕ) : ℕ :=
  let base := if coll == 0 then unflagged else coll
  base + (cash - reserved) / 10 ^ 10 + (inFlight p input output price).2 - debt

def deLeverTarget (coll debt lt hf target trigger previous : ℕ) : Option ℕ :=
  let ltWad := lt * 10 ^ 14
  if trigger < hf || debt == 0 || target ≤ ltWad || target ≤ hf then none else
  let amount := (target * debt - ltWad * coll) / (target - ltWad) * 10 ^ 10
  if amount == 0 || amount ≤ previous then none else some amount

def callback (p : Intent) (last nonce kind amount : ℕ) (authorized assetMatches : Bool) : ℕ :=
  if !authorized then 0
  else if p.kind == 0 || p.nonce != nonce || p.kind != kind then
    if nonce == 0 || last < nonce then 0 else 1
  else if !assetMatches || amount < p.minimum then 0 else 2

theorem landed_not_inFlight (p : Intent) (i o price : ℕ) (h : (outcome p i o).1 ≠ 1) :
    inFlight p i o price = (0, 0) := by simp [inFlight, h]

theorem stale_callback_ack (p : Intent) (last nonce kind amount : ℕ) (asset : Bool)
    (hm : p.nonce ≠ nonce) (hn : nonce ≠ 0) (hl : nonce ≤ last) :
    callback p last nonce kind amount true asset = 1 := by
  simp [callback, hm, hn, Nat.not_lt.mpr hl]

theorem unauthorized_callback (p : Intent) (last nonce kind amount : ℕ) (asset : Bool) :
    callback p last nonce kind amount false asset = 0 := by simp [callback]

end Juicer.Runtime
