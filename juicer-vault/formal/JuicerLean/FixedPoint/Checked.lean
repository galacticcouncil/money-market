import JuicerLean.FixedPoint.Orchestration

namespace Juicer.Runtime

inductive ArithmeticFailure where
  | overflow
  | divisionByZero
  | mulDivOverflow
  | outstandingDebt
  | transferMismatch
  deriving Repr, BEq, DecidableEq

abbrev Checked (α : Type) := Except ArithmeticFailure α

@[simp] theorem checked_bind_ok {α β : Type} (a : α) (f : α → Checked β) :
    ((Except.ok a : Checked α) >>= f) = f a := rfl
@[simp] theorem checked_bind_error {α β : Type} (e : ArithmeticFailure) (f : α → Checked β) :
    ((Except.error e : Checked α) >>= f) = .error e := rfl
@[simp] theorem checked_pure {α : Type} (a : α) : (pure a : Checked α) = .ok a := rfl
@[simp] theorem checked_map_ok {α β : Type} (a : α) (f : α → β) :
    f <$> (Except.ok a : Checked α) = .ok (f a) := rfl
@[simp] theorem checked_map_error {α β : Type} (e : ArithmeticFailure) (f : α → β) :
    f <$> (Except.error e : Checked α) = .error e := rfl

theorem checked_bind_eq_ok {α β : Type} (x : Checked α) (f : α → Checked β) (result : β) :
    (x >>= f) = .ok result ↔ ∃ a, x = .ok a ∧ f a = .ok result := by
  cases x <;> simp

theorem checked_map_eq_ok {α β : Type} (x : Checked α) (f : α → β) (result : β) :
    (f <$> x) = .ok result ↔ ∃ a, x = .ok a ∧ f a = result := by
  cases x <;> simp

def checkWord (n : ℕ) : Checked ℕ :=
  if n ≤ max256 then .ok n else .error .overflow

def checkedAdd (a b : ℕ) : Checked ℕ := checkWord (a + b)
def checkedMul (a b : ℕ) : Checked ℕ := checkWord (a * b)
def checkedSub (a b : ℕ) : Checked ℕ :=
  if b ≤ a then .ok (a - b) else .error .overflow
def checkedDiv (a b : ℕ) : Checked ℕ :=
  if b = 0 then .error .divisionByZero else .ok (a / b)
def checkedCeilDiv (a b : ℕ) : Checked ℕ := do
  if a = 0 then return 0
  let q ← checkedDiv (a - 1) b
  checkedAdd q 1

def checkedMulDiv (a b d : ℕ) : Checked ℕ :=
  if d = 0 then
    if a * b ≤ max256 then .error .divisionByZero else .error .mulDivOverflow
  else if a * b / d ≤ max256 then .ok (a * b / d) else .error .mulDivOverflow

def checkedMulDivUp (a b d : ℕ) : Checked ℕ := do
  let q ← checkedMulDiv a b d
  if a * b % d = 0 then return q else checkedAdd q 1

def checkedShift (a shift : ℕ) : ℕ := a >>> shift

def checkedCeilShift (a shift : ℕ) : ℕ :=
  if a = 0 then 0 else checkedShift (a - 1) shift + 1

theorem checkedCeilShift_refines (a shift : ℕ) : checkedCeilShift a shift = ceilShift a shift := by
  rw [ceilShift_eq_safe]
  rfl

def checkedRescale : ℕ → Book → ℕ → Checked Book
  | 0, b, _ => .ok b
  | n + 1, b, limit => do
    if limit < b.total then
      let scale ← checkedAdd b.scale 64
      checkedRescale n { b with total := checkedShift b.total 64, index := checkedShift b.index 64, scale } limit
    else return b

def checkedWriteOff (b : Book) : Checked Book := do
  let epoch ← checkedAdd b.epoch 1
  return { b with total := 0, index := 0, scale := 0, epoch }

def checkedRequiredBacking (debt principal cash fee : ℕ) : Checked ℕ := do
  let required := if cash < debt then debt - cash else 0
  let capital ← checkedAdd principal cash
  let interest := if capital < debt then debt - principal - cash else 0
  if fee < 10000 then
    let gross ← checkedMulDivUp interest fee (10000 - fee)
    checkedAdd required gross
  else return required

theorem checkWord_ok_iff (a result : ℕ) :
    checkWord a = .ok result ↔ a ≤ max256 ∧ result = a := by
  simp only [checkWord]
  split <;> simp_all [eq_comm]

theorem checkedAdd_ok_iff (a b result : ℕ) :
    checkedAdd a b = .ok result ↔ a + b ≤ max256 ∧ result = a + b := checkWord_ok_iff _ _

theorem checkedMul_ok_iff (a b result : ℕ) :
    checkedMul a b = .ok result ↔ a * b ≤ max256 ∧ result = a * b := checkWord_ok_iff _ _

theorem checkedSub_ok_iff (a b result : ℕ) :
    checkedSub a b = .ok result ↔ b ≤ a ∧ result = a - b := by
  simp only [checkedSub]
  split <;> simp_all [eq_comm]

theorem checkedDiv_ok_iff (a b result : ℕ) :
    checkedDiv a b = .ok result ↔ b ≠ 0 ∧ result = a / b := by
  simp only [checkedDiv]
  split <;> simp_all [eq_comm]

theorem checkedMulDiv_ok_iff (a b d result : ℕ) :
    checkedMulDiv a b d = .ok result ↔ d ≠ 0 ∧ a * b / d ≤ max256 ∧ result = a * b / d := by
  simp only [checkedMulDiv]
  split_ifs <;> simp_all [eq_comm]

theorem checkedCeilDiv_zero_zero : checkedCeilDiv 0 0 = .ok 0 := rfl

theorem checkedMulDivUp_refines (a b d result : ℕ) (h : checkedMulDivUp a b d = .ok result) :
    d ≠ 0 ∧ result ≤ max256 ∧ result = a * b / d + if a * b % d = 0 then 0 else 1 := by
  unfold checkedMulDivUp at h
  cases he : checkedMulDiv a b d with
  | error e => simp [he] at h
  | ok q =>
    have hq := (checkedMulDiv_ok_iff _ _ _ _).mp he
    simp only [he, checked_bind_ok, checked_pure] at h
    split_ifs at h with hm
    · simp only [Except.ok.injEq] at h
      simp_all
    · have hr := (checkedAdd_ok_iff _ _ _).mp h
      simp_all

theorem checked_shift_ge_width (a shift : ℕ) (ha : a ≤ max256) (hs : 256 ≤ shift) :
    checkedShift a shift = 0 := by
  have hp : 2 ^ 256 ≤ 2 ^ shift := Nat.pow_le_pow_right (by decide) hs
  have ha' : a < 2 ^ 256 := by unfold max256 at ha; omega
  simpa [checkedShift, Nat.shiftRight_eq_div_pow] using Nat.div_eq_of_lt (ha'.trans_le hp)

theorem checked_shift_bounded (a shift : ℕ) : checkedShift a shift ≤ a := by
  simpa [checkedShift, Nat.shiftRight_eq_div_pow] using Nat.div_le_self a (2 ^ shift)

def checkedAccountUnits (b : Book) (a : Account) (weight : ℕ) : Checked ℕ := do
  let shift ← if a.epoch == b.epoch then checkedSub b.scale a.scale else pure 0
  let previous := if a.epoch == b.epoch then min b.index (checkedCeilShift a.index shift) else 0
  let owned := if a.epoch == b.epoch then checkedShift a.units shift else 0
  let delta ← checkedSub b.index previous
  let pending ← checkedMulDiv weight delta ray
  let all ← checkedAdd owned pending
  return min b.total all

def checkedBorrow (p : MainPosition) (total previous current : ℕ) : Checked (MainPosition × ℕ) := do
  let amount ← checkedSub current previous
  let minted ← if total = 0 then checkedMul amount wad else
    if previous = 0 then .error .outstandingDebt else checkedMulDivUp amount total previous
  let units ← checkedAdd p.units minted
  let principal ← checkedAdd p.principal amount
  let total' ← checkedAdd total minted
  return ({ p with units, principal }, total')

def checkedCostReceipt (unallocated checkpoint cumulative : ℕ) : Checked ℕ := do
  let delta ← checkedSub cumulative checkpoint
  checkedAdd unallocated delta

def checkedRetry (spendable amount paid reduced quantum : ℕ) : Checked ℕ := do
  if paid == amount && reduced < amount && paid < spendable then
    let remaining ← checkedSub spendable paid
    let gap ← checkedSub amount reduced
    let wanted ← checkedAdd gap quantum
    return min remaining wanted
  else return 0

theorem checkedCostReceipt_refines (u before after result : ℕ)
    (h : checkedCostReceipt u before after = .ok result) :
    before ≤ after ∧ result = u + (after - before) ∧ result ≤ max256 := by
  unfold checkedCostReceipt at h
  cases he : checkedSub after before with
  | error e => simp [he] at h
  | ok delta =>
    have hd := (checkedSub_ok_iff _ _ _).mp he
    simp only [he, checked_bind_ok] at h
    have hr := (checkedAdd_ok_iff _ _ _).mp h
    exact ⟨hd.1, by omega, by omega⟩

theorem checkedRetry_refines (s a p d q result : ℕ) (h : checkedRetry s a p d q = .ok result) :
    result = retryAmount s a p d q := by
  unfold checkedRetry at h
  unfold retryAmount
  split_ifs at h ⊢ with hc
  · cases he : checkedSub s p with
    | error e => simp [he] at h
    | ok rem =>
      have hr := (checkedSub_ok_iff _ _ _).mp he
      cases hg : checkedSub a d with
      | error e => simp [he, hg] at h
      | ok gap =>
        have hd := (checkedSub_ok_iff _ _ _).mp hg
        cases hw : checkedAdd gap q with
        | error e => simp [he, hg, hw] at h
        | ok wanted =>
          have hx := (checkedAdd_ok_iff _ _ _).mp hw
          simp only [he, hg, checked_bind_ok, hw, checked_pure, Except.ok.injEq] at h
          simpa [hr.2, hd.2, hx.2] using h.symm
  · simpa using h.symm

def checkedBatchSegment (amount cost total weight shares : ℕ) : Checked (ℕ × ℕ × ℕ) := do
  let reduction ← checkedAdd amount cost
  let before ← checkedMulDiv reduction weight total
  let next ← checkedAdd weight shares
  let after ← checkedMulDiv reduction next total
  let cashAfter ← checkedMulDiv after amount reduction
  let cashBefore ← checkedMulDiv before amount reduction
  let credited ← checkedSub cashAfter cashBefore
  let delta ← checkedSub after before
  let charged ← checkedSub delta credited
  return (next, credited, charged)

def checkedClaim (r : RedemptionState) : Checked (RedemptionState × ℕ × ℕ) := do
  let claimed ← checkedAdd r.claimed r.settled
  let remaining ← checkedSub r.shares r.burned
  let burn ← if r.debt ≤ r.repaid then pure remaining else do
    let numerator ← checkedMul r.shares claimed
    let cumulative ← checkedDiv numerator r.owed
    checkedSub cumulative r.burned
  let burned ← checkedAdd r.burned burn
  return ({ r with claimed, settled := 0, burned, active := if r.debt ≤ r.repaid then false else r.active },
    r.settled, burn)

def transact {σ α : Type} (before : σ) (body : σ → Checked (σ × α)) : σ × Checked α :=
  match body before with
  | .error e => (before, .error e)
  | .ok (after, result) => (after, .ok result)

theorem transaction_failure_rolls_back {σ α : Type} (before : σ) (body : σ → Checked (σ × α))
    (e : ArithmeticFailure) (h : body before = .error e) :
    transact before body = (before, .error e) := by simp [transact, h]

theorem transaction_success_commits {σ α : Type} (before after : σ) (body : σ → Checked (σ × α))
    (result : α) (h : body before = .ok (after, result)) :
    transact before body = (after, .ok result) := by simp [transact, h]

theorem checked_max_add_reverts : checkedAdd max256 1 = .error .overflow := by
  simp [checkedAdd, checkWord]

theorem checked_underflow_reverts (a b : ℕ) (h : a < b) : checkedSub a b = .error .overflow := by
  simp [checkedSub, Nat.not_le.mpr h]

theorem checked_large_product_succeeds : checkedMulDiv max256 max256 max256 = .ok max256 := by
  apply (checkedMulDiv_ok_iff _ _ _ _).mpr
  have hm : 0 < max256 := by norm_num [max256]
  simp [Nat.ne_of_gt hm]

end Juicer.Runtime
