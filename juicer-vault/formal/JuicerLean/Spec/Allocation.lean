import JuicerLean.Spec.YieldShares

-- the shared `variable` block carries `[DecidableEq Acct]` for the ops; a few lemmas don't use it.
set_option linter.unusedSectionVars false

/-!
# Juicer — event-driven allocation with a lazy index (next version, plan §2)

`JuicerYieldAccounting` never visits every holder: an allocation bumps one global index, and a
holder's units are its stored units plus its weight times the index growth since it last settled.
The next version splits `checkpoint` into
* `settle(from, to)` — settle two accounts at the stored index; every transfer uses only this;
* `checkpoint` — settle plus `_allocate`, used only at events (deposit, `requestRedeem`,
  `_startUnwind`, rebalance, compound, `prepareHarvest`, `pokeSettle`, `sync`).

`LazyBook` is that implementation and `view` reads it as the eager `ShareBook` of
`YieldShares.lean`. Proven:
* `view_settle`, `view_allocate`, `view_transfer`, `view_deposit`, `view_requestRedeem`, … — every
  lazy operation is its eager counterpart seen through `view`; `view_run` lifts any trace, so the
  balance identity holds at every lazily reachable state (`run_totalBalance_add`);
* `transfer_frame` / `transfer_noAlloc` — a transfer writes only its two holders and allocates
  nothing: the index and the unit total stay put;
* `allocation_consistent` — at an event every holder gets `m × weight/outside` of its weight at
  the event, however many transfers came before and whenever it last settled;
  `allocate_view_congr` — histories that reach the same balances allocate identically;
* `eventVsTransfer` — against the old per-transfer allocation, the only difference is that the
  yield accrued before a transfer within the interval follows the moved shares;
* `deposit_newcomer` / `deposit_newcomer_value` — a deposit allocates before it mints, so the
  newcomer gets none of the pre-entry yield; `deposit_accIndex` — its accrual starts at the
  post-event index; `mintFirst_captures` — minting first would hand it `m·x/(outside + x)` units.
-/

namespace Juicer

namespace ShareBook

variable {Acct : Type*} [DecidableEq Acct]

/-! ## Deposits allocate first -/

/-- **A newcomer captures no pre-entry yield.** The deposit's checkpoint allocates at the old
weights, where the newcomer weighs nothing; the mint comes after. -/
theorem deposit_newcomer (r : Acct) (x m v : ℝ) (B : ShareBook Acct) (hw : B.wallet r = 0) :
    (B.deposit r x m v).units r = B.units r := by
  show B.units r + m * B.weight r / B.outside = B.units r
  simp [weight, hw]

/-- …so right after the deposit a fresh account is worth exactly the shares it paid for. -/
theorem deposit_newcomer_value (r : Acct) (x m v : ℝ) (B : ShareBook Acct)
    (hw : B.wallet r = 0) (hu : B.units r = 0) :
    (B.deposit r x m v).value r = x * B.price := by
  have hun : (B.deposit r x m v).units r = 0 := by rw [deposit_newcomer r x m v B hw, hu]
  have hwal : (B.deposit r x m v).wallet r = x := by
    show B.wallet r + (if r = r then x else 0) = x
    rw [hw, if_pos rfl, zero_add]
  unfold value
  rw [hun, hwal, zero_div, zero_mul, add_zero]
  rfl

/-- What minting first would do: the newcomer's shares would weigh in the allocation of yield that
accrued before it arrived. -/
theorem mintFirst_newcomer (r : Acct) (x m v : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hr : r ∈ B.holders) (hw : B.wallet r = 0) :
    ((B.mint r x).allocate m v).units r = B.units r + m * x / (B.outside + x) := by
  have hfr : B.fund ≠ r := fun e => h.fund_not_holder (e ▸ hr)
  have hwt : (B.mint r x).weight r = x := by
    show (if r ∈ B.holders then B.wallet r + (if r = r then x else 0) else 0) = x
    rw [if_pos hr, if_pos rfl, hw, zero_add]
  have hO : (B.mint r x).outside = B.outside + x := by
    show B.totalSupply + x - B.queued - (B.wallet B.fund + if B.fund = r then x else 0) = _
    rw [if_neg hfr, add_zero, outside, funded]
    ring
  show (B.mint r x).units r + m * (B.mint r x).weight r / (B.mint r x).outside = _
  rw [hwt, hO]
  rfl

/-- **…and it would capture a positive slice of the pre-entry yield.** -/
theorem mintFirst_captures (r : Acct) (x m v : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hr : r ∈ B.holders) (hw : B.wallet r = 0) (hm : 0 < m) (hx : 0 < x) (hO : 0 < B.outside + x) :
    (B.deposit r x m v).units r < ((B.mint r x).allocate m v).units r := by
  rw [deposit_newcomer r x m v B hw, mintFirst_newcomer r x m v B h hr hw]
  have : 0 < m * x / (B.outside + x) := by positivity
  linarith

/-! ## Event allocation versus the old per-transfer allocation -/

theorem transfer_outside (f t : Acct) (x : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hf : f ∈ B.holders) (ht : t ∈ B.holders) : (B.transfer f t x).outside = B.outside := by
  have hff : B.fund ≠ f := fun e => h.fund_not_holder (e ▸ hf)
  have hft : B.fund ≠ t := fun e => h.fund_not_holder (e ▸ ht)
  unfold outside
  rw [transfer_funded f t x B hff hft]
  rfl

/-- **Within one event interval.** The old design allocated at every transfer (`checkpoint` in
`_beforeTokenTransfer`); the new one allocates the whole interval's yield at the next event. For a
wallet transfer inside the interval, a holder's units differ only by `m₁ × (weight before − weight
after)/outside`, where `m₁` is the yield accrued before the transfer: that slice follows the moved
shares to the receiver. Third parties see no difference, and both mint `m₁ + m₂`. -/
theorem eventVsTransfer (f t a : Acct) (x m₁ v₁ m₂ v₂ : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hf : f ∈ B.holders) (ht : t ∈ B.holders) (hx : x ≤ B.wallet f) :
    (((B.allocate m₁ v₁).transfer f t x).allocate m₂ v₂).units a
      = ((B.transfer f t x).allocate (m₁ + m₂) (v₁ + v₂)).units a
        + m₁ * (B.weight a - (B.transfer f t x).weight a) / B.outside := by
  have hO : (B.transfer f t x).outside = B.outside := transfer_outside f t x B h hf ht
  have hO' : ((B.allocate m₁ v₁).transfer f t x).outside = B.outside := hO
  have hw' : ((B.allocate m₁ v₁).transfer f t x).weight a = (B.transfer f t x).weight a := rfl
  have hu0 : (B.allocate m₁ v₁).unitPart f x = 0 := if_pos hx
  have hu0' : B.unitPart f x = 0 := if_pos hx
  have hua : ((B.allocate m₁ v₁).transfer f t x).units a = B.units a + m₁ * B.weight a / B.outside := by
    show (B.allocate m₁ v₁).units a - (if a = f then (B.allocate m₁ v₁).unitPart f x else 0)
        + (if a = t then (B.allocate m₁ v₁).unitPart f x else 0) = _
    rw [hu0]
    simp only [ite_self, sub_zero, add_zero]
    rfl
  have hub : (B.transfer f t x).units a = B.units a := by
    show B.units a - (if a = f then B.unitPart f x else 0) + (if a = t then B.unitPart f x else 0) = _
    rw [hu0']
    simp only [ite_self, sub_zero, add_zero]
  show ((B.allocate m₁ v₁).transfer f t x).units a
        + m₂ * ((B.allocate m₁ v₁).transfer f t x).weight a / ((B.allocate m₁ v₁).transfer f t x).outside
      = ((B.transfer f t x).units a + (m₁ + m₂) * (B.transfer f t x).weight a / (B.transfer f t x).outside)
        + m₁ * (B.weight a - (B.transfer f t x).weight a) / B.outside
  rw [hua, hub, hw', hO', hO]
  ring

end ShareBook

/-! ## The lazy index -/

/-- The lazily settled reward book: stored units per holder plus the index each last settled at. -/
structure LazyBook (Acct : Type*) where
  /-- wallets, totals, and units as of each holder's last settle. -/
  book     : ShareBook Acct
  /-- the global reward index (`rewardIndex / RAY`). -/
  index    : ℝ
  /-- the index each holder last settled at (`accountIndex`). -/
  accIndex : Acct → ℝ
  /-- the index the waiting requests last settled at (the aggregate of `requestIndex`). -/
  reqIndex : ℝ

namespace LazyBook

variable {Acct : Type*} [DecidableEq Acct]

/-- a holder's current units: stored units plus weight × index growth since its last settle. -/
noncomputable def current (L : LazyBook Acct) (a : Acct) : ℝ :=
  L.book.units a + L.book.weight a * (L.index - L.accIndex a)

/-- the waiting requests' current units. -/
noncomputable def currentReq (L : LazyBook Acct) : ℝ :=
  L.book.requestUnits + L.book.waiting * (L.index - L.reqIndex)

/-- the eager book this lazy one stands for. -/
noncomputable def view (L : LazyBook Acct) : ShareBook Acct :=
  { L.book with units := L.current, requestUnits := L.currentReq }

/-- `_settle(a)`: store `a`'s current units and the index. -/
noncomputable def settle (a : Acct) (L : LazyBook Acct) : LazyBook Acct :=
  { L with book := { L.book with units := fun b => if b = a then L.current a else L.book.units b }
           accIndex := fun b => if b = a then L.index else L.accIndex b }

/-- settle the waiting requests before their escrowed shares change. -/
noncomputable def settleReq (L : LazyBook Acct) : LazyBook Acct :=
  { L with book := { L.book with requestUnits := L.currentReq }
           reqIndex := L.index }

/-- `_allocate`: one index bump; no holder is visited. -/
noncomputable def allocate (m v : ℝ) (L : LazyBook Acct) : LazyBook Acct :=
  { L with book := { L.book with totalUnits := L.book.totalUnits + m
                                 srcValue := L.book.srcValue + v }
           index := L.index + m / L.book.outside }

/-- mint after settling the receiver. -/
noncomputable def mint (r : Acct) (x : ℝ) (L : LazyBook Acct) : LazyBook Acct :=
  { L.settle r with book := (L.settle r).book.mint r x }

/-- `deposit`: checkpoint (allocate), then mint. -/
noncomputable def deposit (r : Acct) (x m v : ℝ) (L : LazyBook Acct) : LazyBook Acct :=
  (L.allocate m v).mint r x

/-- a transfer: `settle(from, to)`, then the wallet and unit moves. No allocation. -/
noncomputable def transfer (f t : Acct) (x : ℝ) (L : LazyBook Acct) : LazyBook Acct :=
  { (L.settle f).settle t with book := ((L.settle f).settle t).book.transfer f t x }

/-- harvest mints to the fund, which accrues nothing as an account. -/
def harvest (h c : ℝ) (L : LazyBook Acct) : LazyBook Acct :=
  { L with book := L.book.harvest h c }

/-- `requestRedeem`: checkpoint, settle the owner and the waiting requests, then escrow. -/
noncomputable def requestRedeem (o : Acct) (x m v : ℝ) (L : LazyBook Acct) : LazyBook Acct :=
  { ((L.allocate m v).settle o).settleReq with
      book := (((L.allocate m v).settle o).settleReq).book.escrowRequest o x }

def burnEscrow (y : ℝ) (L : LazyBook Acct) : LazyBook Acct :=
  { L with book := L.book.burnEscrow y }

/-! ## Every lazy operation is the eager one, seen through `view` -/

theorem view_units (L : LazyBook Acct) (a : Acct) : L.view.units a = L.current a := rfl

/-- settling never changes what anyone holds. -/
theorem view_settle (a : Acct) (L : LazyBook Acct) : (L.settle a).view = L.view := by
  ext1
  all_goals try rfl
  · funext b
    show (if b = a then L.current a else L.book.units b)
        + L.book.weight b * (L.index - if b = a then L.index else L.accIndex b) = L.current b
    by_cases hb : b = a
    · subst hb; simp
    · simp [hb, current]

theorem view_settleReq (L : LazyBook Acct) : L.settleReq.view = L.view := by
  ext1
  all_goals try rfl
  show L.currentReq + L.book.waiting * (L.index - L.index) = L.currentReq
  ring

theorem current_settled (a : Acct) (L : LazyBook Acct) : (L.settle a).book.units a = L.current a := by
  show (if a = a then L.current a else L.book.units a) = L.current a
  rw [if_pos rfl]

/-- **One index bump is the eager allocation**: every holder gets `m × weight/outside`. -/
theorem view_allocate (m v : ℝ) (L : LazyBook Acct) : (L.allocate m v).view = L.view.allocate m v := by
  ext1
  all_goals try rfl
  · funext b
    show L.book.units b + L.book.weight b * (L.index + m / L.book.outside - L.accIndex b)
        = L.current b + m * L.book.weight b / L.book.outside
    unfold current
    ring
  · show L.book.requestUnits + L.book.waiting * (L.index + m / L.book.outside - L.reqIndex)
        = L.currentReq + m * L.book.waiting / L.book.outside
    unfold currentReq
    ring

theorem view_mint (r : Acct) (x : ℝ) (L : LazyBook Acct) : (L.mint r x).view = L.view.mint r x := by
  ext1
  all_goals try rfl
  funext b
  show (if b = r then L.current r else L.book.units b)
      + (if b ∈ L.book.holders then L.book.wallet b + (if b = r then x else 0) else 0)
        * (L.index - if b = r then L.index else L.accIndex b) = L.current b
  by_cases hb : b = r
  · subst hb; simp
  · simp [hb, current, ShareBook.weight]

theorem view_deposit (r : Acct) (x m v : ℝ) (L : LazyBook Acct) :
    (L.deposit r x m v).view = L.view.deposit r x m v := by
  rw [deposit, view_mint, view_allocate]
  rfl

theorem view_transfer (f t : Acct) (x : ℝ) (L : LazyBook Acct) :
    (L.transfer f t x).view = L.view.transfer f t x := by
  -- both endpoints are settled, so the eager parts read current units
  set L2 := (L.settle f).settle t with hL2
  have hv2 : L2.view = L.view := by rw [hL2, view_settle, view_settle]
  have hf2 : L2.book.units f = L.current f := by
    rw [hL2]
    by_cases hft : f = t
    · subst hft; rw [current_settled]
      have := congrArg (fun B => B.units f) (view_settle f L)
      exact this
    · show (if f = t then (L.settle f).current t else (L.settle f).book.units f) = L.current f
      rw [if_neg hft, current_settled]
  have ht2 : L2.book.units t = L.current t := by
    rw [hL2, current_settled]
    exact congrArg (fun B => B.units t) (view_settle f L)
  have hacc : ∀ b, b = f ∨ b = t → L2.accIndex b = L2.index := by
    intro b hb
    show (if b = t then (L.settle f).index else (if b = f then L.index else L.accIndex b)) = L.index
    rcases hb with rfl | rfl
    · by_cases h' : b = t <;> simp [h']; rfl
    · simp; rfl
  have hpart : L2.book.unitPart f x = L.view.unitPart f x := by
    unfold ShareBook.unitPart
    rw [hf2]
    rfl
  have hwpart : L2.book.walletPart f x = L.view.walletPart f x := rfl
  ext1
  all_goals try rfl
  · funext b
    show L2.book.units b - (if b = f then L2.book.unitPart f x else 0)
          + (if b = t then L2.book.unitPart f x else 0)
        + (if b ∈ L2.book.holders then L2.book.wallet b - (if b = f then L2.book.walletPart f x else 0)
            + (if b = t then L2.book.walletPart f x else 0) else 0) * (L2.index - L2.accIndex b)
        = L.current b - (if b = f then L.view.unitPart f x else 0)
          + (if b = t then L.view.unitPart f x else 0)
    rw [hpart]
    by_cases hb : b = f ∨ b = t
    · rw [hacc b hb, sub_self, mul_zero, add_zero]
      rcases hb with rfl | rfl
      · rw [hf2]
      · rw [ht2]
    · push Not at hb
      obtain ⟨hbf, hbt⟩ := hb
      have hcur : L2.current b = L.current b := congrArg (fun B => B.units b) hv2
      simp only [if_neg hbf, if_neg hbt, sub_zero, add_zero]
      exact hcur

theorem view_harvest (hv c : ℝ) (L : LazyBook Acct) (hf : L.book.fund ∉ L.book.holders) :
    (L.harvest hv c).view = L.view.harvest hv c := by
  ext1
  all_goals try rfl
  funext b
  show L.book.units b + (if b ∈ L.book.holders then L.book.wallet b
        + (if b = L.book.fund then hv else 0) else 0) * (L.index - L.accIndex b) = L.current b
  unfold current ShareBook.weight
  by_cases hb : b ∈ L.book.holders
  · have hbf : b ≠ L.book.fund := fun e => hf (e ▸ hb)
    simp [hb, hbf]
  · simp [hb]

theorem view_burnEscrow (y : ℝ) (L : LazyBook Acct) (he : L.book.escrow ∉ L.book.holders) :
    (L.burnEscrow y).view = L.view.burnEscrow y := by
  ext1
  all_goals try rfl
  funext b
  show L.book.units b + (if b ∈ L.book.holders then L.book.wallet b
        - (if b = L.book.escrow then y else 0) else 0) * (L.index - L.accIndex b) = L.current b
  unfold current ShareBook.weight
  by_cases hb : b ∈ L.book.holders
  · have hbe : b ≠ L.book.escrow := fun e => he (e ▸ hb)
    simp [hb, hbe]
  · simp [hb]

/-- `requestRedeem` after its checkpoint, with the owner and the waiting requests settled. -/
theorem view_escrowRequest (o : Acct) (x : ℝ) (L : LazyBook Acct) (he : L.book.escrow ∉ L.book.holders) :
    ({ (L.settle o).settleReq with book := ((L.settle o).settleReq).book.escrowRequest o x }).view
      = L.view.escrowRequest o x := by
  set L2 := (L.settle o).settleReq with hL2
  have hv2 : L2.view = L.view := by rw [hL2, view_settleReq, view_settle]
  have ho2 : L2.book.units o = L.current o := current_settled o L
  have hacc : L2.accIndex o = L2.index := by
    show (if o = o then L.index else L.accIndex o) = L.index
    rw [if_pos rfl]
  have hreq : L2.reqIndex = L2.index := rfl
  have hR2 : L2.book.requestUnits = L.currentReq := by
    show (L.settle o).currentReq = L.currentReq
    exact congrArg (fun B => B.requestUnits) (view_settle o L)
  have hpart : L2.book.unitPart o x = L.view.unitPart o x := by
    unfold ShareBook.unitPart
    rw [ho2]
    rfl
  have hwpart : L2.book.walletPart o x = L.view.walletPart o x := rfl
  ext1
  all_goals try rfl
  · funext b
    show L2.book.units b - (if b = o then L2.book.unitPart o x else 0)
        + (if b ∈ L2.book.holders then L2.book.wallet b - (if b = o then L2.book.walletPart o x else 0)
            + (if b = L2.book.escrow then L2.book.walletPart o x else 0) else 0)
          * (L2.index - L2.accIndex b)
        = L.current b - (if b = o then L.view.unitPart o x else 0)
    rw [hpart]
    by_cases hbo : b = o
    · subst hbo
      rw [hacc, sub_self, mul_zero, add_zero, ho2]
    · have hcur : L2.current b = L.current b := congrArg (fun B => B.units b) hv2
      have hw : (if b ∈ L2.book.holders then L2.book.wallet b
          - (if b = o then L2.book.walletPart o x else 0)
          + (if b = L2.book.escrow then L2.book.walletPart o x else 0) else 0) = L2.book.weight b := by
        unfold ShareBook.weight
        by_cases hbh : b ∈ L2.book.holders
        · have hbe : b ≠ L2.book.escrow := fun e => he (e ▸ hbh)
          rw [if_pos hbh, if_pos hbh, if_neg hbo, if_neg hbe, sub_zero, add_zero]
        · rw [if_neg hbh, if_neg hbh]
      rw [hw]
      simp only [if_neg hbo, sub_zero]
      exact hcur
  · show L2.book.requestUnits + L2.book.unitPart o x
        + (L2.book.waiting + L2.book.walletPart o x) * (L2.index - L2.reqIndex)
        = L.currentReq + L.view.unitPart o x
    rw [hreq, sub_self, mul_zero, add_zero, hR2, hpart]

theorem view_requestRedeem (o : Acct) (x m v : ℝ) (L : LazyBook Acct)
    (he : L.book.escrow ∉ L.book.holders) :
    (L.requestRedeem o x m v).view = L.view.requestRedeem o x m v := by
  show ({ ((L.allocate m v).settle o).settleReq with
      book := (((L.allocate m v).settle o).settleReq).book.escrowRequest o x }).view = _
  rw [view_escrowRequest o x (L.allocate m v) he, view_allocate]
  rfl

/-! ## Traces -/

/-- Apply one share-ledger operation lazily. -/
noncomputable def apply (L : LazyBook Acct) : ShareBook.Op Acct → LazyBook Acct
  | .deposit r x m v => L.deposit r x m v
  | .transfer f t x => L.transfer f t x
  | .allocate m v => L.allocate m v
  | .harvest h c => L.harvest h c
  | .requestRedeem o x m v => L.requestRedeem o x m v
  | .burnEscrow y => L.burnEscrow y

theorem apply_accounts (L : LazyBook Acct) (op : ShareBook.Op Acct) :
    (L.apply op).book.holders = L.book.holders ∧ (L.apply op).book.fund = L.book.fund ∧
    (L.apply op).book.escrow = L.book.escrow := by
  cases op <;> exact ⟨rfl, rfl, rfl⟩

theorem view_apply (L : LazyBook Acct) (op : ShareBook.Op Acct)
    (hf : L.book.fund ∉ L.book.holders) (he : L.book.escrow ∉ L.book.holders) :
    (L.apply op).view = L.view.apply op := by
  cases op with
  | deposit r x m v => exact view_deposit r x m v L
  | transfer f t x => exact view_transfer f t x L
  | allocate m v => exact view_allocate m v L
  | harvest hh c => exact view_harvest hh c L hf
  | requestRedeem o x m v => exact view_requestRedeem o x m v L he
  | burnEscrow y => exact view_burnEscrow y L he

/-- Run a list of operations lazily. -/
noncomputable def run (L : LazyBook Acct) : List (ShareBook.Op Acct) → LazyBook Acct
  | [] => L
  | op :: ops => run (L.apply op) ops

/-- **The lazy implementation refines the eager book along any trace.** -/
theorem view_run (L : LazyBook Acct) (ops : List (ShareBook.Op Acct))
    (hf : L.book.fund ∉ L.book.holders) (he : L.book.escrow ∉ L.book.holders) :
    (L.run ops).view = L.view.run ops := by
  induction ops generalizing L with
  | nil => rfl
  | cons op ops ih =>
      obtain ⟨hh, hfu, hes⟩ := apply_accounts L op
      show ((L.apply op).run ops).view = (L.view.apply op).run ops
      rw [ih (L.apply op) (by rw [hh, hfu]; exact hf) (by rw [hh, hes]; exact he),
        view_apply L op hf he]

/-- **The balance identity at every lazily reachable state.** -/
theorem run_totalBalance_add (L : LazyBook Acct) (ops : List (ShareBook.Op Acct))
    (hv : L.view.runValid ops) (h : L.view.Conserved) :
    (L.run ops).view.totalBalance
      + (L.run ops).view.requestUnits / (L.run ops).view.totalUnits * (L.run ops).view.funded
      = (L.run ops).view.totalSupply := by
  rw [view_run L ops h.fund_not_holder h.escrow_not_holder]
  exact ShareBook.run_totalBalance_add _ ops hv h

/-! ## Transfers settle two holders and allocate nothing -/

/-- **A transfer writes only its two holders**: every other account keeps its wallet, stored units
and settle index. -/
theorem transfer_frame (f t c : Acct) (x : ℝ) (L : LazyBook Acct) (hcf : c ≠ f) (hct : c ≠ t) :
    (L.transfer f t x).book.wallet c = L.book.wallet c ∧
    (L.transfer f t x).book.units c = L.book.units c ∧
    (L.transfer f t x).accIndex c = L.accIndex c := by
  refine ⟨?_, ?_, ?_⟩
  · show L.book.wallet c - (if c = f then _ else 0) + (if c = t then _ else 0) = L.book.wallet c
    rw [if_neg hcf, if_neg hct, sub_zero, add_zero]
  · show (if c = t then _ else (if c = f then _ else L.book.units c))
        - (if c = f then _ else 0) + (if c = t then _ else 0) = L.book.units c
    rw [if_neg hct, if_neg hcf, if_neg hcf, if_neg hct, sub_zero, add_zero]
  · show (if c = t then _ else (if c = f then _ else L.accIndex c)) = L.accIndex c
    rw [if_neg hct, if_neg hcf]

/-- **…and allocates nothing**: the index and the unit total are untouched. -/
theorem transfer_noAlloc (f t : Acct) (x : ℝ) (L : LazyBook Acct) :
    (L.transfer f t x).index = L.index ∧
    (L.transfer f t x).book.totalUnits = L.book.totalUnits := ⟨rfl, rfl⟩

/-! ## Allocation is consistent at events -/

/-- **Allocation at an event is consistent.** Whatever happened since the last event — any number of
transfers, any holder settled at any index — the event credits each holder exactly
`m × weight/outside` of the balances standing at the event, and mints exactly `m`. -/
theorem allocation_consistent (m v : ℝ) (L : LazyBook Acct) (a : Acct) :
    (L.allocate m v).view.units a = L.view.units a + m * L.view.weight a / L.view.outside ∧
    (L.allocate m v).view.totalUnits = L.view.totalUnits + m := by
  rw [view_allocate]
  exact ⟨rfl, rfl⟩

/-- Histories that reach the same balances allocate identically: the lazy bookkeeping (who settled
when) never shows. -/
theorem allocate_view_congr (m v : ℝ) (L₁ L₂ : LazyBook Acct) (h : L₁.view = L₂.view) :
    (L₁.allocate m v).view = (L₂.allocate m v).view := by
  rw [view_allocate, view_allocate, h]

/-- Transfers between events change no holder's current units beyond the units they move, so the
next event sees exactly the eager balances: lazy and eager agree on every transfer trace. -/
theorem transfers_then_allocate (m v : ℝ) (L : LazyBook Acct) (ops : List (ShareBook.Op Acct))
    (hf : L.book.fund ∉ L.book.holders) (he : L.book.escrow ∉ L.book.holders) :
    ((L.run ops).allocate m v).view = (L.view.run ops).allocate m v := by
  rw [view_allocate, view_run L ops hf he]

/-! ## The newcomer's accrual starts after the event -/

/-- The depositor is settled at the post-allocation index, so its future units come only from index
growth after its entry. -/
theorem deposit_accIndex (r : Acct) (x m v : ℝ) (L : LazyBook Acct) :
    (L.deposit r x m v).accIndex r = L.index + m / L.book.outside := by
  show (if r = r then (L.allocate m v).index else _) = _
  rw [if_pos rfl]
  rfl

/-- …and a fresh depositor's stored units are still zero after its deposit. -/
theorem deposit_fresh_units (r : Acct) (x m v : ℝ) (L : LazyBook Acct)
    (hw : L.book.wallet r = 0) (hu : L.book.units r = 0) :
    (L.deposit r x m v).book.units r = 0 := by
  show (if r = r then (L.allocate m v).current r else _) = 0
  rw [if_pos rfl]
  show L.book.units r + L.book.weight r * (L.index + m / L.book.outside - L.accIndex r) = 0
  simp [ShareBook.weight, hw, hu]

end LazyBook
end Juicer
