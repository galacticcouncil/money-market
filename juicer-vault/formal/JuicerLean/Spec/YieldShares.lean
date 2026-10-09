import Mathlib

-- the shared `variable` block carries `[DecidableEq Acct]` for the ops; the pure sum lemmas don't
-- use it. intentional, as in `SubLoopShares`, so silence the section-var lint.
set_option linter.unusedSectionVars false

/-!
# Juicer — share balances that include funded earnings (next version, plan §3)

The next version shows a holder's funded reward shares inside its share balance, Aave style, with
no claims at all: reward units stay the only claim on the fund, pro rata on both of its parts —
the funded vault shares `F` (held in the fund's wallet) and the reserved source value `S`.

* a holder's displayed balance is `wallet + units/totalUnits × F`;
* the fund displays `wallet − F` (so `0`) once units exist, and its whole wallet before;
* a transfer of `x ≤ wallet` moves wallet shares only; a larger one moves the whole wallet plus
  the units whose `F` slice covers the excess, `δu = min(units, (x − wallet)·totalUnits/F)`
  (the contract rounds the quotient up). The moved units carry their `S` claim too;
* `requestRedeem(x)` beyond the wallet escrows the wallet and commits `δu` units to the request.

`requestUnits` collects the units held by waiting requests (accrued on their escrowed shares, plus
those committed at `requestRedeem`); they belong to no holder until the request starts.

Proven:
* `totalBalance_add` — `Σ balanceOf + requestUnits/totalUnits × F = totalSupply`, so
  `Σ balanceOf ≤ totalSupply`, with equality once no units sit with waiting requests
  (`totalBalance_le`, `totalBalance_eq`); `sum_slice_le` — the holders' slices never exceed `F`;
* conservation is preserved by deposit (allocate, then mint), transfer, allocation, harvest,
  `requestRedeem` and the final escrow burn, and so by any valid trace (`run_conserved`,
  `run_totalBalance_add`);
* `transfer_balanceOf_from` / `_to` / `_other` — a transfer within the sender's balance moves
  exactly `x` of displayed balance and leaves every other account's balance alone;
  `transfer_frame` — it writes only the two holders' wallets and units;
* `transfer_value` — value moves from sender to receiver only; nobody else's value changes;
* `requestRedeem_max_empties` — `requestRedeem(balanceOf)` leaves the owner with nothing;
* `allocate_totalValue` / `transfer_totalValue` — allocation adds exactly the new yield to the
  total value; a transfer keeps it;
* `allocate_unitPrice` / `allocate_value_mono` / `allocate_slice_dip` — with units minted by
  value, allocation never lowers the unit price or a holder's value; its displayed `F` slice can
  dip, by at most its pro-rata share of the new yield;
* `rejected_claim_shifts` — the claim rule this replaced (take `units/totalUnits × F`, burn units
  worth it) strictly lowers every other holder's slice whenever `S > 0`, kept as the reason.
-/

namespace Juicer

open scoped BigOperators

/-- One vault's share ledger together with the reward fund's unit book. -/
@[ext] structure ShareBook (Acct : Type*) where
  /-- every account other than the fund and the escrow that may hold shares or units. -/
  holders      : Finset Acct
  /-- the reward fund (`JuicerYieldAccounting`): its wallet is the funded pool `F`. -/
  fund         : Acct
  /-- the vault itself, holding escrowed redemption shares. -/
  escrow       : Acct
  /-- ERC20 storage balance (`super.balanceOf`). -/
  wallet       : Acct → ℝ
  /-- stored total supply. -/
  totalSupply  : ℝ
  /-- settled reward units per holder. -/
  units        : Acct → ℝ
  /-- stored total reward units. -/
  totalUnits   : ℝ
  /-- units held by waiting redemption requests (accrued and committed), owned by no holder yet. -/
  requestUnits : ℝ
  /-- escrowed shares of waiting requests; they keep earning until their unwind starts. -/
  waiting      : ℝ
  /-- escrowed shares of started requests; they no longer earn. -/
  queued       : ℝ
  /-- value of the source shares reserved for unit holders (`S`, unconverted yield). -/
  srcValue     : ℝ
  /-- value of one share. -/
  price        : ℝ

namespace ShareBook

variable {Acct : Type*} [DecidableEq Acct]

/-! ## Balances -/

/-- the funded pool `F`: every share in the fund's wallet (`_funded()`, nothing is vested). -/
def funded (B : ShareBook Acct) : ℝ := B.wallet B.fund

/-- `a`'s slice of the funded pool: `units/totalUnits × F` (`fundedSharesOf`). -/
noncomputable def slice (B : ShareBook Acct) (a : Acct) : ℝ :=
  B.units a / B.totalUnits * B.funded

/-- what the fund stops showing as its own (`heldForHolders()`): all of `F` once units exist. -/
noncomputable def heldForHolders (B : ShareBook Acct) : ℝ :=
  if B.totalUnits = 0 then 0 else B.funded

/-- the displayed share balance (`CollateralVault.balanceOf`). -/
noncomputable def balanceOf (B : ShareBook Acct) (a : Acct) : ℝ :=
  if a = B.fund then B.wallet B.fund - B.heldForHolders
  else if a = B.escrow then B.wallet B.escrow
  else B.wallet a + B.slice a

/-- `Σ balanceOf` over every account: the fund, the escrow and the holders. -/
noncomputable def totalBalance (B : ShareBook Acct) : ℝ :=
  B.balanceOf B.fund + B.balanceOf B.escrow + ∑ a ∈ B.holders, B.balanceOf a

/-- the fund's value (`_assets()`): reserved source value plus the funded shares' value. -/
def assets (B : ShareBook Acct) : ℝ := B.srcValue + B.funded * B.price

/-- a holder's value: wallet shares at the share price plus its units at the unit price. -/
noncomputable def value (B : ShareBook Acct) (a : Acct) : ℝ :=
  B.wallet a * B.price + B.units a / B.totalUnits * B.assets

/-- **Conservation.** The account sets are disjoint, the wallets sum to the stored supply, the units
of holders and waiting requests sum to the stored total, and the escrow holds exactly the waiting
and started requests' shares. -/
structure Conserved (B : ShareBook Acct) : Prop where
  fund_not_holder   : B.fund ∉ B.holders
  escrow_not_holder : B.escrow ∉ B.holders
  fund_ne_escrow    : B.fund ≠ B.escrow
  supply : B.wallet B.fund + B.wallet B.escrow + ∑ a ∈ B.holders, B.wallet a = B.totalSupply
  units  : ∑ a ∈ B.holders, B.units a + B.requestUnits = B.totalUnits
  escrow : B.wallet B.escrow = B.waiting + B.queued

theorem balanceOf_fund (B : ShareBook Acct) : B.balanceOf B.fund = B.wallet B.fund - B.heldForHolders := by
  simp [balanceOf]

theorem balanceOf_escrow (B : ShareBook Acct) (h : B.Conserved) :
    B.balanceOf B.escrow = B.wallet B.escrow := by
  simp [balanceOf, h.fund_ne_escrow.symm]

theorem balanceOf_holder (B : ShareBook Acct) (h : B.Conserved) {a : Acct} (ha : a ∈ B.holders) :
    B.balanceOf a = B.wallet a + B.slice a := by
  have h1 : a ≠ B.fund := fun e => h.fund_not_holder (e ▸ ha)
  have h2 : a ≠ B.escrow := fun e => h.escrow_not_holder (e ▸ ha)
  simp [balanceOf, h1, h2]

/-- The holders' slices tile their part of the funded pool: `(totalUnits − requestUnits)/totalUnits
× F`. -/
theorem sum_slice (B : ShareBook Acct) (h : B.Conserved) :
    ∑ a ∈ B.holders, B.slice a = (B.totalUnits - B.requestUnits) / B.totalUnits * B.funded := by
  have hu : ∑ a ∈ B.holders, B.units a = B.totalUnits - B.requestUnits := by linarith [h.units]
  simp only [slice]
  rw [← Finset.sum_mul, ← Finset.sum_div, hu]

/-- **The holders' slices never exceed the funded pool** (`= F` once units are fully attributed). -/
theorem sum_slice_le (B : ShareBook Acct) (h : B.Conserved) (hR : 0 ≤ B.requestUnits)
    (hT : 0 ≤ B.totalUnits) (hF : 0 ≤ B.funded) :
    ∑ a ∈ B.holders, B.slice a ≤ B.funded := by
  rw [sum_slice B h, sub_div]
  rcases hT.eq_or_lt with h0 | hpos
  · rw [← h0]; simp [hF]
  · rw [div_self hpos.ne', sub_mul, one_mul]
    have : 0 ≤ B.requestUnits / B.totalUnits * B.funded := by positivity
    linarith

/-- **`Σ balanceOf` up to the waiting requests' slice.** What holders see of the funded pool is
exactly what the fund stops showing, less the slice of units sitting with waiting requests, which
nobody displays until the request starts (and the exit fold pays it out). -/
theorem totalBalance_add (B : ShareBook Acct) (h : B.Conserved) :
    B.totalBalance + B.requestUnits / B.totalUnits * B.funded = B.totalSupply := by
  unfold totalBalance
  rw [balanceOf_fund, balanceOf_escrow B h, Finset.sum_congr rfl (fun a ha => balanceOf_holder B h ha),
    Finset.sum_add_distrib, sum_slice B h, heldForHolders]
  split_ifs with h0
  · simp only [h0, div_zero, zero_mul, sub_zero, add_zero]
    linarith [h.supply]
  · have e : (B.totalUnits - B.requestUnits) / B.totalUnits * B.funded
        = B.funded - B.requestUnits / B.totalUnits * B.funded := by field_simp
    rw [e, funded]
    linarith [h.supply]

theorem totalBalance_le (B : ShareBook Acct) (h : B.Conserved) (hR : 0 ≤ B.requestUnits)
    (hT : 0 ≤ B.totalUnits) (hF : 0 ≤ B.funded) : B.totalBalance ≤ B.totalSupply := by
  have := totalBalance_add B h
  have : 0 ≤ B.requestUnits / B.totalUnits * B.funded := by positivity
  linarith

/-- **`Σ balanceOf = totalSupply`** whenever no units sit with waiting requests. -/
theorem totalBalance_eq (B : ShareBook Acct) (h : B.Conserved) (hR : B.requestUnits = 0) :
    B.totalBalance = B.totalSupply := by
  have := totalBalance_add B h
  rw [hR, zero_div, zero_mul, add_zero] at this
  exact this

/-! ## Operations -/

/-- the weight a holder's units accrue on: its wallet (`_weight`); zero for the fund and the escrow. -/
def weight (B : ShareBook Acct) (a : Acct) : ℝ :=
  if a ∈ B.holders then B.wallet a else 0

/-- the outside supply allocation divides by: active supply less the funded pool
(`supply − funded`, with `supply = totalSupply − totalQueuedShares`). -/
def outside (B : ShareBook Acct) : ℝ := B.totalSupply - B.queued - B.funded

/-- The outside supply is exactly the weight units accrue on: the holders' wallets plus the waiting
requests' escrowed shares. -/
theorem outside_eq (B : ShareBook Acct) (h : B.Conserved) :
    B.outside = ∑ a ∈ B.holders, B.weight a + B.waiting := by
  have hw : ∑ a ∈ B.holders, B.weight a = ∑ a ∈ B.holders, B.wallet a :=
    Finset.sum_congr rfl (fun a ha => by simp [weight, ha])
  rw [hw]
  unfold outside funded
  linarith [h.supply, h.escrow]

/-- `_allocate` at an event: mint `m` units over the outside weight (holders by wallet, waiting
requests by escrowed shares) and reserve `v` more source value for unit holders. -/
noncomputable def allocate (m v : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  { B with units := fun a => B.units a + m * B.weight a / B.outside
           requestUnits := B.requestUnits + m * B.waiting / B.outside
           totalUnits := B.totalUnits + m
           srcValue := B.srcValue + v }

/-- mint `x` shares to `r` (the deposit's `_mint`). -/
def mint (r : Acct) (x : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  { B with wallet := fun b => B.wallet b + if b = r then x else 0
           totalSupply := B.totalSupply + x }

/-- `deposit`: allocate pending yield first (the checkpoint), then mint. -/
noncomputable def deposit (r : Acct) (x m v : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  (B.allocate m v).mint r x

/-- `compound`: mint `h` reward shares to the fund for harvested collateral, converting `c` of the
reserved source value. -/
def harvest (h c : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  { B with wallet := fun b => B.wallet b + if b = B.fund then h else 0
           totalSupply := B.totalSupply + h
           srcValue := B.srcValue - c }

/-- wallet shares a transfer of `x` moves: up to the sender's wallet. -/
noncomputable def walletPart (B : ShareBook Acct) (f : Acct) (x : ℝ) : ℝ := min x (B.wallet f)

/-- units a transfer of `x` moves: none within the wallet; beyond it, the units whose funded slice
covers the excess, capped at the sender's units. -/
noncomputable def unitPart (B : ShareBook Acct) (f : Acct) (x : ℝ) : ℝ :=
  if x ≤ B.wallet f then 0
  else min (B.units f) ((x - B.wallet f) * B.totalUnits / B.funded)

/-- A transfer of `x` from `f` to `t`: wallet shares up to the wallet, units for the excess. No
allocation, no claim; `totalUnits`, `F` and `S` stay put. -/
noncomputable def transfer (f t : Acct) (x : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  { B with wallet := fun b => B.wallet b - (if b = f then B.walletPart f x else 0)
                                + (if b = t then B.walletPart f x else 0)
           units := fun b => B.units b - (if b = f then B.unitPart f x else 0)
                               + (if b = t then B.unitPart f x else 0) }

/-- `requestRedeem` after its checkpoint: escrow up to the wallet and commit units for the excess
to the request. -/
noncomputable def escrowRequest (o : Acct) (x : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  { B with wallet := fun b => B.wallet b - (if b = o then B.walletPart o x else 0)
                                + (if b = B.escrow then B.walletPart o x else 0)
           units := fun b => B.units b - if b = o then B.unitPart o x else 0
           requestUnits := B.requestUnits + B.unitPart o x
           waiting := B.waiting + B.walletPart o x }

/-- `requestRedeem`: checkpoint, then escrow. -/
noncomputable def requestRedeem (o : Acct) (x m v : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  (B.allocate m v).escrowRequest o x

/-- the final collateral claim burns `y` escrowed shares of a started request. -/
def burnEscrow (y : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  { B with wallet := fun b => B.wallet b - if b = B.escrow then y else 0
           totalSupply := B.totalSupply - y
           queued := B.queued - y }

/-! ## Preservation of `Conserved` -/

theorem sum_add_ite (s : Finset Acct) (g : Acct → ℝ) (a : Acct) (d : ℝ) :
    ∑ b ∈ s, (g b + if b = a then d else 0) = ∑ b ∈ s, g b + if a ∈ s then d else 0 := by
  rw [Finset.sum_add_distrib, Finset.sum_ite_eq']

theorem sum_sub_ite (s : Finset Acct) (g : Acct → ℝ) (a : Acct) (d : ℝ) :
    ∑ b ∈ s, (g b - if b = a then d else 0) = ∑ b ∈ s, g b - if a ∈ s then d else 0 := by
  rw [Finset.sum_sub_distrib, Finset.sum_ite_eq']

theorem allocate_conserved (m v : ℝ) (B : ShareBook Acct) (hm : B.outside ≠ 0 ∨ m = 0)
    (h : B.Conserved) : (B.allocate m v).Conserved := by
  refine ⟨h.fund_not_holder, h.escrow_not_holder, h.fund_ne_escrow, h.supply, ?_, h.escrow⟩
  show ∑ a ∈ B.holders, (B.units a + m * B.weight a / B.outside)
      + (B.requestUnits + m * B.waiting / B.outside) = B.totalUnits + m
  rw [Finset.sum_add_distrib]
  rcases hm with hO | hm0
  · have hsplit : ∑ a ∈ B.holders, m * B.weight a / B.outside + m * B.waiting / B.outside = m := by
      rw [← Finset.sum_div, ← add_div, ← Finset.mul_sum, ← mul_add, ← outside_eq B h,
        mul_div_assoc, div_self hO, mul_one]
    linarith [h.units]
  · subst hm0
    simp only [zero_mul, zero_div, Finset.sum_const_zero, add_zero]
    linarith [h.units]

theorem mint_conserved (r : Acct) (x : ℝ) (B : ShareBook Acct) (hr : r ∈ B.holders)
    (h : B.Conserved) : (B.mint r x).Conserved := by
  have hfr : B.fund ≠ r := fun e => h.fund_not_holder (e ▸ hr)
  have her : B.escrow ≠ r := fun e => h.escrow_not_holder (e ▸ hr)
  refine ⟨h.fund_not_holder, h.escrow_not_holder, h.fund_ne_escrow, ?_, h.units, ?_⟩
  · show (B.wallet B.fund + if B.fund = r then x else 0) + (B.wallet B.escrow + if B.escrow = r then x else 0)
        + ∑ b ∈ B.holders, (B.wallet b + if b = r then x else 0) = B.totalSupply + x
    rw [sum_add_ite, if_pos hr, if_neg hfr, if_neg her]
    linarith [h.supply]
  · show (B.wallet B.escrow + if B.escrow = r then x else 0) = B.waiting + B.queued
    rw [if_neg her, add_zero, h.escrow]

theorem deposit_conserved (r : Acct) (x m v : ℝ) (B : ShareBook Acct) (hr : r ∈ B.holders)
    (hm : B.outside ≠ 0 ∨ m = 0) (h : B.Conserved) : (B.deposit r x m v).Conserved :=
  mint_conserved r x _ hr (allocate_conserved m v B hm h)

theorem harvest_conserved (hv c : ℝ) (B : ShareBook Acct) (h : B.Conserved) :
    (B.harvest hv c).Conserved := by
  have hfe : B.escrow ≠ B.fund := h.fund_ne_escrow.symm
  refine ⟨h.fund_not_holder, h.escrow_not_holder, h.fund_ne_escrow, ?_, h.units, ?_⟩
  · show (B.wallet B.fund + if B.fund = B.fund then hv else 0)
        + (B.wallet B.escrow + if B.escrow = B.fund then hv else 0)
        + ∑ b ∈ B.holders, (B.wallet b + if b = B.fund then hv else 0) = B.totalSupply + hv
    rw [sum_add_ite, if_neg h.fund_not_holder, if_pos rfl, if_neg hfe]
    linarith [h.supply]
  · show (B.wallet B.escrow + if B.escrow = B.fund then hv else 0) = B.waiting + B.queued
    rw [if_neg hfe, add_zero, h.escrow]

theorem transfer_conserved (f t : Acct) (x : ℝ) (B : ShareBook Acct) (hf : f ∈ B.holders)
    (ht : t ∈ B.holders) (h : B.Conserved) : (B.transfer f t x).Conserved := by
  have hff : B.fund ≠ f := fun e => h.fund_not_holder (e ▸ hf)
  have hef : B.escrow ≠ f := fun e => h.escrow_not_holder (e ▸ hf)
  have hft : B.fund ≠ t := fun e => h.fund_not_holder (e ▸ ht)
  have het : B.escrow ≠ t := fun e => h.escrow_not_holder (e ▸ ht)
  refine ⟨h.fund_not_holder, h.escrow_not_holder, h.fund_ne_escrow, ?_, ?_, ?_⟩
  · show (B.wallet B.fund - (if B.fund = f then B.walletPart f x else 0)
          + (if B.fund = t then B.walletPart f x else 0))
        + (B.wallet B.escrow - (if B.escrow = f then B.walletPart f x else 0)
          + (if B.escrow = t then B.walletPart f x else 0))
        + ∑ b ∈ B.holders, (B.wallet b - (if b = f then B.walletPart f x else 0)
          + (if b = t then B.walletPart f x else 0)) = B.totalSupply
    rw [sum_add_ite, sum_sub_ite, if_pos hf, if_pos ht, if_neg hff, if_neg hft, if_neg hef,
      if_neg het]
    linarith [h.supply]
  · show ∑ b ∈ B.holders, (B.units b - (if b = f then B.unitPart f x else 0)
          + (if b = t then B.unitPart f x else 0)) + B.requestUnits = B.totalUnits
    rw [sum_add_ite, sum_sub_ite, if_pos hf, if_pos ht]
    linarith [h.units]
  · show B.wallet B.escrow - (if B.escrow = f then B.walletPart f x else 0)
        + (if B.escrow = t then B.walletPart f x else 0) = B.waiting + B.queued
    rw [if_neg hef, if_neg het, sub_zero, add_zero, h.escrow]

theorem escrowRequest_conserved (o : Acct) (x : ℝ) (B : ShareBook Acct) (ho : o ∈ B.holders)
    (h : B.Conserved) : (B.escrowRequest o x).Conserved := by
  have hoe : B.escrow ≠ o := fun e => h.escrow_not_holder (e ▸ ho)
  have hfo : B.fund ≠ o := fun e => h.fund_not_holder (e ▸ ho)
  have hfe : B.fund ≠ B.escrow := h.fund_ne_escrow
  refine ⟨h.fund_not_holder, h.escrow_not_holder, h.fund_ne_escrow, ?_, ?_, ?_⟩
  · show (B.wallet B.fund - (if B.fund = o then B.walletPart o x else 0)
          + (if B.fund = B.escrow then B.walletPart o x else 0))
        + (B.wallet B.escrow - (if B.escrow = o then B.walletPart o x else 0)
          + (if B.escrow = B.escrow then B.walletPart o x else 0))
        + ∑ b ∈ B.holders, (B.wallet b - (if b = o then B.walletPart o x else 0)
          + (if b = B.escrow then B.walletPart o x else 0)) = B.totalSupply
    rw [sum_add_ite, sum_sub_ite, if_pos ho, if_neg h.escrow_not_holder, if_neg hfo, if_neg hfe,
      if_neg hoe, if_pos rfl]
    linarith [h.supply]
  · show ∑ b ∈ B.holders, (B.units b - if b = o then B.unitPart o x else 0)
        + (B.requestUnits + B.unitPart o x) = B.totalUnits
    rw [sum_sub_ite, if_pos ho]
    linarith [h.units]
  · show B.wallet B.escrow - (if B.escrow = o then B.walletPart o x else 0)
        + (if B.escrow = B.escrow then B.walletPart o x else 0)
        = (B.waiting + B.walletPart o x) + B.queued
    rw [if_neg hoe, if_pos rfl, sub_zero, h.escrow]
    ring

theorem requestRedeem_conserved (o : Acct) (x m v : ℝ) (B : ShareBook Acct) (ho : o ∈ B.holders)
    (hm : B.outside ≠ 0 ∨ m = 0) (h : B.Conserved) : (B.requestRedeem o x m v).Conserved :=
  escrowRequest_conserved o x _ ho (allocate_conserved m v B hm h)

theorem burnEscrow_conserved (y : ℝ) (B : ShareBook Acct) (h : B.Conserved) :
    (B.burnEscrow y).Conserved := by
  have hfe : B.fund ≠ B.escrow := h.fund_ne_escrow
  refine ⟨h.fund_not_holder, h.escrow_not_holder, h.fund_ne_escrow, ?_, h.units, ?_⟩
  · show (B.wallet B.fund - if B.fund = B.escrow then y else 0)
        + (B.wallet B.escrow - if B.escrow = B.escrow then y else 0)
        + ∑ b ∈ B.holders, (B.wallet b - if b = B.escrow then y else 0) = B.totalSupply - y
    rw [sum_sub_ite, if_neg h.escrow_not_holder, if_neg hfe, if_pos rfl]
    linarith [h.supply]
  · show (B.wallet B.escrow - if B.escrow = B.escrow then y else 0) = B.waiting + (B.queued - y)
    rw [if_pos rfl, h.escrow]
    ring

/-! ## Transfers: exact, local, value-preserving -/

/-- **A transfer is local.** It writes only the sender's and receiver's wallets and units; the
totals, the funded pool and the source value are untouched. -/
theorem transfer_frame (f t c : Acct) (x : ℝ) (B : ShareBook Acct) (hcf : c ≠ f) (hct : c ≠ t) :
    (B.transfer f t x).wallet c = B.wallet c ∧ (B.transfer f t x).units c = B.units c ∧
    (B.transfer f t x).totalUnits = B.totalUnits ∧ (B.transfer f t x).srcValue = B.srcValue := by
  refine ⟨?_, ?_, rfl, rfl⟩
  · show B.wallet c - (if c = f then B.walletPart f x else 0) + (if c = t then B.walletPart f x else 0)
        = B.wallet c
    rw [if_neg hcf, if_neg hct, sub_zero, add_zero]
  · show B.units c - (if c = f then B.unitPart f x else 0) + (if c = t then B.unitPart f x else 0)
        = B.units c
    rw [if_neg hcf, if_neg hct, sub_zero, add_zero]

/-- The fund's wallet is untouched by a holder-to-holder transfer, so `F` is too. -/
theorem transfer_funded (f t : Acct) (x : ℝ) (B : ShareBook Acct) (hff : B.fund ≠ f)
    (hft : B.fund ≠ t) : (B.transfer f t x).funded = B.funded :=
  (transfer_frame f t B.fund x B hff hft).1

/-- **No third party's displayed balance moves** — holder, fund or escrow. -/
theorem transfer_balanceOf_other (f t c : Acct) (x : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hf : f ∈ B.holders) (ht : t ∈ B.holders) (hcf : c ≠ f) (hct : c ≠ t) :
    (B.transfer f t x).balanceOf c = B.balanceOf c := by
  have hff : B.fund ≠ f := fun e => h.fund_not_holder (e ▸ hf)
  have hft : B.fund ≠ t := fun e => h.fund_not_holder (e ▸ ht)
  have hF := transfer_funded f t x B hff hft
  obtain ⟨hw, hu, hT, -⟩ := transfer_frame f t c x B hcf hct
  have hwf := (transfer_frame f t B.fund x B hff hft).1
  have hfund : (B.transfer f t x).fund = B.fund := rfl
  have hesc : (B.transfer f t x).escrow = B.escrow := rfl
  unfold balanceOf slice heldForHolders
  rw [hfund, hesc, hw, hu, hT, hF, hwf]
  by_cases hc1 : c = B.fund
  · subst hc1; simp
  · by_cases hc2 : c = B.escrow
    · subst hc2
      have hwe := (transfer_frame f t B.escrow x B
        (fun e => h.escrow_not_holder (e ▸ hf)) (fun e => h.escrow_not_holder (e ▸ ht))).1
      simp [hc1, hwe]
    · simp [hc1, hc2]

/-- the units moved for an excess `x − wallet` within the sender's balance carry exactly that much
funded slice. -/
theorem unitPart_slice (f : Acct) (x : ℝ) (B : ShareBook Acct) (hx : B.wallet f < x)
    (hle : x ≤ B.wallet f + B.slice f) (hT : 0 ≤ B.totalUnits) (hF : 0 ≤ B.funded) :
    B.unitPart f x / B.totalUnits * B.funded = x - B.wallet f := by
  have hs : 0 < B.slice f := by linarith
  have hTpos : 0 < B.totalUnits := by
    rcases hT.eq_or_lt with h0 | h0
    · rw [slice, ← h0, div_zero, zero_mul] at hs; exact absurd hs (lt_irrefl 0)
    · exact h0
  have hFpos : 0 < B.funded := by
    rcases hF.eq_or_lt with h0 | h0
    · rw [slice, ← h0, mul_zero] at hs; exact absurd hs (lt_irrefl 0)
    · exact h0
  have hcap : (x - B.wallet f) * B.totalUnits / B.funded ≤ B.units f := by
    rw [div_le_iff₀ hFpos]
    have : x - B.wallet f ≤ B.units f / B.totalUnits * B.funded := by rw [← slice]; linarith
    calc (x - B.wallet f) * B.totalUnits ≤ B.units f / B.totalUnits * B.funded * B.totalUnits :=
          mul_le_mul_of_nonneg_right this hTpos.le
      _ = B.units f * B.funded := by field_simp
  rw [unitPart, if_neg (not_le.mpr hx), min_eq_right hcap]
  field_simp

/-- **The sender's displayed balance falls by exactly `x`** (within its balance). -/
theorem transfer_balanceOf_from (f t : Acct) (x : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hf : f ∈ B.holders) (ht : t ∈ B.holders) (hft : f ≠ t)
    (hle : x ≤ B.balanceOf f) (hT : 0 ≤ B.totalUnits) (hF : 0 ≤ B.funded) :
    (B.transfer f t x).balanceOf f = B.balanceOf f - x := by
  have hff : B.fund ≠ f := fun e => h.fund_not_holder (e ▸ hf)
  have hft' : B.fund ≠ t := fun e => h.fund_not_holder (e ▸ ht)
  rw [balanceOf_holder _ (transfer_conserved f t x B hf ht h) hf, balanceOf_holder B h hf]
  rw [balanceOf_holder B h hf] at hle
  have hF' := transfer_funded f t x B hff hft'
  have hT' : (B.transfer f t x).totalUnits = B.totalUnits := rfl
  have hw : (B.transfer f t x).wallet f = B.wallet f - B.walletPart f x := by
    show B.wallet f - (if f = f then B.walletPart f x else 0) + (if f = t then B.walletPart f x else 0) = _
    rw [if_pos rfl, if_neg hft, add_zero]
  have hun : (B.transfer f t x).units f = B.units f - B.unitPart f x := by
    show B.units f - (if f = f then B.unitPart f x else 0) + (if f = t then B.unitPart f x else 0) = _
    rw [if_pos rfl, if_neg hft, add_zero]
  simp only [slice]
  rw [hw, hun, hT', hF']
  by_cases hxw : x ≤ B.wallet f
  · rw [walletPart, min_eq_left hxw, unitPart, if_pos hxw]
    ring
  · have hx : B.wallet f < x := not_le.mp hxw
    have key := unitPart_slice f x B hx hle hT hF
    rw [walletPart, min_eq_right hx.le, sub_div, sub_mul, key]
    ring

/-- **…and the receiver's rises by exactly `x`.** -/
theorem transfer_balanceOf_to (f t : Acct) (x : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hf : f ∈ B.holders) (ht : t ∈ B.holders) (hft : f ≠ t)
    (hle : x ≤ B.balanceOf f) (hT : 0 ≤ B.totalUnits) (hF : 0 ≤ B.funded) :
    (B.transfer f t x).balanceOf t = B.balanceOf t + x := by
  have hff : B.fund ≠ f := fun e => h.fund_not_holder (e ▸ hf)
  have hft' : B.fund ≠ t := fun e => h.fund_not_holder (e ▸ ht)
  rw [balanceOf_holder _ (transfer_conserved f t x B hf ht h) ht, balanceOf_holder B h ht]
  rw [balanceOf_holder B h hf] at hle
  have hF' := transfer_funded f t x B hff hft'
  have hT' : (B.transfer f t x).totalUnits = B.totalUnits := rfl
  have htf : t ≠ f := Ne.symm hft
  have hw : (B.transfer f t x).wallet t = B.wallet t + B.walletPart f x := by
    show B.wallet t - (if t = f then B.walletPart f x else 0) + (if t = t then B.walletPart f x else 0) = _
    rw [if_neg htf, if_pos rfl, sub_zero]
  have hun : (B.transfer f t x).units t = B.units t + B.unitPart f x := by
    show B.units t - (if t = f then B.unitPart f x else 0) + (if t = t then B.unitPart f x else 0) = _
    rw [if_neg htf, if_pos rfl, sub_zero]
  simp only [slice]
  rw [hw, hun, hT', hF']
  by_cases hxw : x ≤ B.wallet f
  · rw [walletPart, min_eq_left hxw, unitPart, if_pos hxw]
    ring
  · have hx : B.wallet f < x := not_le.mp hxw
    have key := unitPart_slice f x B hx hle hT hF
    rw [walletPart, min_eq_right hx.le, add_div, add_mul, key]
    ring

/-- **Value moves only between the two holders.** The sender's loss is the receiver's gain (wallet
shares at the share price, units at the unit price, `S` claim included); everyone else is untouched. -/
theorem transfer_value (f t : Acct) (x : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hf : f ∈ B.holders) (ht : t ∈ B.holders) (hft : f ≠ t) :
    (B.transfer f t x).value f + (B.transfer f t x).value t = B.value f + B.value t ∧
    ∀ c, c ≠ f → c ≠ t → (B.transfer f t x).value c = B.value c := by
  have hff : B.fund ≠ f := fun e => h.fund_not_holder (e ▸ hf)
  have hft' : B.fund ≠ t := fun e => h.fund_not_holder (e ▸ ht)
  have hA : (B.transfer f t x).assets = B.assets := by
    unfold assets; rw [transfer_funded f t x B hff hft']; rfl
  have hT' : (B.transfer f t x).totalUnits = B.totalUnits := rfl
  have hp : (B.transfer f t x).price = B.price := rfl
  constructor
  · have htf : t ≠ f := Ne.symm hft
    have hwf : (B.transfer f t x).wallet f = B.wallet f - B.walletPart f x := by
      show B.wallet f - (if f = f then B.walletPart f x else 0) + (if f = t then B.walletPart f x else 0) = _
      rw [if_pos rfl, if_neg hft, add_zero]
    have hwt : (B.transfer f t x).wallet t = B.wallet t + B.walletPart f x := by
      show B.wallet t - (if t = f then B.walletPart f x else 0) + (if t = t then B.walletPart f x else 0) = _
      rw [if_neg htf, if_pos rfl, sub_zero]
    have huf : (B.transfer f t x).units f = B.units f - B.unitPart f x := by
      show B.units f - (if f = f then B.unitPart f x else 0) + (if f = t then B.unitPart f x else 0) = _
      rw [if_pos rfl, if_neg hft, add_zero]
    have hut : (B.transfer f t x).units t = B.units t + B.unitPart f x := by
      show B.units t - (if t = f then B.unitPart f x else 0) + (if t = t then B.unitPart f x else 0) = _
      rw [if_neg htf, if_pos rfl, sub_zero]
    unfold value
    rw [hwf, hwt, huf, hut, hA, hT', hp]
    ring
  · intro c hcf hct
    obtain ⟨hw, hu, -, -⟩ := transfer_frame f t c x B hcf hct
    unfold value
    rw [hw, hu, hA, hT', hp]

/-! ## `requestRedeem(max)` -/

/-- **`requestRedeem(balanceOf)` empties the owner**: it escrows the whole wallet and commits every
unit to the request. -/
theorem requestRedeem_max_empties (o : Acct) (m v : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (ho : o ∈ B.holders) (hm : B.outside ≠ 0 ∨ m = 0)
    (hT : 0 < (B.allocate m v).totalUnits) (hF : 0 < (B.allocate m v).funded)
    (hu : 0 ≤ (B.allocate m v).units o) :
    (B.requestRedeem o ((B.allocate m v).balanceOf o) m v).wallet o = 0 ∧
    (B.requestRedeem o ((B.allocate m v).balanceOf o) m v).units o = 0 := by
  set C := B.allocate m v with hC
  set x := C.balanceOf o with hxdef
  have hc : C.Conserved := allocate_conserved m v B hm h
  have hoe : C.escrow ≠ o := fun e => hc.escrow_not_holder (e ▸ ho)
  have hx : x = C.wallet o + C.slice o := balanceOf_holder C hc ho
  have hsl : 0 ≤ C.slice o := by rw [slice]; positivity
  have hwp : C.walletPart o x = C.wallet o := by
    rw [walletPart, min_eq_right]
    rw [hx]
    linarith
  have hup : C.unitPart o x = C.units o := by
    rw [unitPart]
    by_cases hxw : x ≤ C.wallet o
    · rw [if_pos hxw]
      have hs : C.slice o = 0 := le_antisymm (by linarith) hsl
      rw [slice] at hs
      rcases mul_eq_zero.mp hs with h1 | h1
      · rcases div_eq_zero_iff.mp h1 with h2 | h2
        · exact h2.symm
        · exact absurd h2 hT.ne'
      · exact absurd h1 hF.ne'
    · rw [if_neg hxw, min_eq_left]
      rw [hx, slice]
      field_simp
      linarith
  constructor
  · show C.wallet o - (if o = o then C.walletPart o x else 0) + (if o = C.escrow then C.walletPart o x else 0) = 0
    rw [if_pos rfl, if_neg (Ne.symm hoe), hwp]
    ring
  · show C.units o - (if o = o then C.unitPart o x else 0) = 0
    rw [if_pos rfl, hup, sub_self]

/-! ## Allocation: value never drops; the displayed slice can dip, boundedly -/

/-- the yield on the fund's own shares, credited to existing units by a higher unit price
(`selfValue = value × funded/supply`). -/
noncomputable def selfValue (B : ShareBook Acct) (v : ℝ) : ℝ :=
  v * B.funded / (B.totalSupply - B.queued)

/-- **Units are minted by value**: `m` units at the post-`selfValue` unit price buy the rest of the
new yield (`minted = outsideValue × totalUnits / (assets + selfValue)`, cleared). -/
def MintedByValue (B : ShareBook Acct) (m v : ℝ) : Prop :=
  m * (B.assets + B.selfValue v) = (v - B.selfValue v) * B.totalUnits

/-- **The unit price after an allocation is `(assets + selfValue)/totalUnits`** (cross-multiplied):
it never falls below `assets/totalUnits` for non-negative `selfValue`. -/
theorem allocate_unitPrice (m v : ℝ) (B : ShareBook Acct) (hm : B.MintedByValue m v) :
    (B.allocate m v).assets * B.totalUnits
      = (B.assets + B.selfValue v) * (B.allocate m v).totalUnits := by
  have hA : (B.allocate m v).assets = B.assets + v := by
    show B.srcValue + v + B.funded * B.price = _
    unfold assets; ring
  have hT : (B.allocate m v).totalUnits = B.totalUnits + m := rfl
  rw [hA, hT]
  unfold MintedByValue at hm
  linear_combination (-1 : ℝ) * hm

/-- **Allocation never lowers a holder's value**: its existing units gain `selfValue` pro rata and
its weight earns the new units. -/
theorem allocate_value_mono (m v : ℝ) (a : Acct) (B : ShareBook Acct) (hm : B.MintedByValue m v)
    (hT : 0 < B.totalUnits) (hm0 : 0 ≤ m) (hO : 0 < B.outside) (hu : 0 ≤ B.units a)
    (hw : 0 ≤ B.weight a) (hA : 0 ≤ B.assets) (hs : 0 ≤ B.selfValue v) :
    B.value a ≤ (B.allocate m v).value a := by
  have hT' : 0 < (B.allocate m v).totalUnits := by
    show 0 < B.totalUnits + m; linarith
  have hprice := allocate_unitPrice m v B hm
  have hP : (B.allocate m v).assets / (B.allocate m v).totalUnits
      = (B.assets + B.selfValue v) / B.totalUnits := by
    rw [div_eq_div_iff hT'.ne' hT.ne']; linarith
  have hwal : (B.allocate m v).wallet a = B.wallet a := rfl
  have hpr : (B.allocate m v).price = B.price := rfl
  have hun : (B.allocate m v).units a = B.units a + m * B.weight a / B.outside := rfl
  have hval' : (B.allocate m v).value a = B.wallet a * B.price
      + (B.units a + m * B.weight a / B.outside) * ((B.assets + B.selfValue v) / B.totalUnits) := by
    unfold value
    rw [hwal, hpr, hun, div_mul_eq_mul_div, mul_div_assoc, hP]
  rw [hval']
  unfold value
  have h1 : B.units a / B.totalUnits * B.assets
      ≤ B.units a * ((B.assets + B.selfValue v) / B.totalUnits) := by
    rw [div_mul_eq_mul_div, mul_div_assoc']
    exact div_le_div_of_nonneg_right (mul_le_mul_of_nonneg_left (by linarith) hu) hT.le
  have h2 : 0 ≤ m * B.weight a / B.outside * ((B.assets + B.selfValue v) / B.totalUnits) := by
    have : 0 ≤ B.assets + B.selfValue v := by linarith
    positivity
  nlinarith [h1, h2]

/-- **The displayed slice can dip at an allocation, by at most the holder's pro-rata share of the
new yield** (valued at the share price): new units re-split `F` and `S`. With the holder's own new
units the dip is smaller still. -/
theorem allocate_slice_dip (m v : ℝ) (a : Acct) (B : ShareBook Acct) (hm : B.MintedByValue m v)
    (hT : 0 < B.totalUnits) (hm0 : 0 ≤ m) (hO : 0 < B.outside) (hu : 0 ≤ B.units a)
    (hw : 0 ≤ B.weight a) (hF : 0 ≤ B.funded) (hS : 0 ≤ B.srcValue) (hP : 0 ≤ B.price)
    (hs : 0 ≤ B.selfValue v) :
    (B.slice a - (B.allocate m v).slice a) * B.price ≤ B.units a / B.totalUnits * v := by
  have hT' : 0 < B.totalUnits + m := by linarith
  have hFp : B.funded * B.price ≤ B.assets := by unfold assets; linarith
  have hA0 : 0 ≤ B.assets := le_trans (by positivity) hFp
  have hmT : m * (B.assets + v) = (v - B.selfValue v) * (B.totalUnits + m) := by
    unfold MintedByValue at hm; linear_combination hm
  have hslice' : (B.allocate m v).slice a
      = (B.units a + m * B.weight a / B.outside) / (B.totalUnits + m) * B.funded := rfl
  have hlow : B.units a / (B.totalUnits + m) * B.funded ≤ (B.allocate m v).slice a := by
    rw [hslice']
    apply mul_le_mul_of_nonneg_right _ hF
    apply div_le_div_of_nonneg_right _ hT'.le
    have : 0 ≤ m * B.weight a / B.outside := by positivity
    linarith
  have e : B.units a / B.totalUnits * B.funded - B.units a / (B.totalUnits + m) * B.funded
      = B.units a * B.funded * m / (B.totalUnits * (B.totalUnits + m)) := by
    field_simp; ring
  have hd : B.slice a - (B.allocate m v).slice a
      ≤ B.units a * B.funded * m / (B.totalUnits * (B.totalUnits + m)) := by
    rw [← e, slice]; linarith
  have hkey : B.funded * B.price * m ≤ v * (B.totalUnits + m) := by
    have h1 : B.funded * B.price * m ≤ B.assets * m := mul_le_mul_of_nonneg_right hFp hm0
    have hvT : v * B.totalUnits = m * (B.assets + B.selfValue v) + B.selfValue v * B.totalUnits := by
      unfold MintedByValue at hm; linear_combination (-1 : ℝ) * hm
    have hvT0 : 0 ≤ v * B.totalUnits := by rw [hvT]; positivity
    have hv : 0 ≤ v := by
      rcases le_or_gt 0 v with hv | hv
      · exact hv
      · have : v * B.totalUnits < 0 := mul_neg_of_neg_of_pos hv hT
        linarith
    have h2 : B.assets * m ≤ (B.assets + v) * m := by nlinarith
    have h3 : (B.assets + v) * m ≤ v * (B.totalUnits + m) := by
      rw [mul_comm, hmT]
      exact mul_le_mul_of_nonneg_right (by linarith) hT'.le
    linarith
  calc (B.slice a - (B.allocate m v).slice a) * B.price
      ≤ B.units a * B.funded * m / (B.totalUnits * (B.totalUnits + m)) * B.price :=
        mul_le_mul_of_nonneg_right hd hP
    _ = B.units a / B.totalUnits * (B.funded * B.price * m / (B.totalUnits + m)) := by
        field_simp
    _ ≤ B.units a / B.totalUnits * v := by
        apply mul_le_mul_of_nonneg_left _ (by positivity)
        rw [div_le_iff₀ hT']
        exact hkey

/-! ## Total value: allocation adds exactly the new yield, transfers keep it -/

/-- the value held by holders (wallets and units) plus the waiting requests' units. -/
noncomputable def totalValue (B : ShareBook Acct) : ℝ :=
  ∑ a ∈ B.holders, B.value a + B.requestUnits / B.totalUnits * B.assets

/-- With units outstanding, all units together are worth exactly the fund. -/
theorem totalValue_eq (B : ShareBook Acct) (h : B.Conserved) (hT : B.totalUnits ≠ 0) :
    B.totalValue = (∑ a ∈ B.holders, B.wallet a) * B.price + B.assets := by
  have hu : ∑ a ∈ B.holders, B.units a = B.totalUnits - B.requestUnits := by linarith [h.units]
  unfold totalValue value
  rw [Finset.sum_add_distrib, ← Finset.sum_mul, ← Finset.sum_mul, ← Finset.sum_div, hu]
  field_simp
  ring

/-- **Allocation creates exactly the new yield `v` in value** — none lost, none invented. -/
theorem allocate_totalValue (m v : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hm : B.outside ≠ 0 ∨ m = 0) (hT : B.totalUnits ≠ 0) (hT' : B.totalUnits + m ≠ 0) :
    (B.allocate m v).totalValue = B.totalValue + v := by
  rw [totalValue_eq _ (allocate_conserved m v B hm h) hT', totalValue_eq B h hT]
  show (∑ a ∈ B.holders, B.wallet a) * B.price + (B.srcValue + v + B.funded * B.price) = _
  unfold assets
  ring

/-- **A transfer keeps the total value.** -/
theorem transfer_totalValue (f t : Acct) (x : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hf : f ∈ B.holders) (ht : t ∈ B.holders) (hT : B.totalUnits ≠ 0) :
    (B.transfer f t x).totalValue = B.totalValue := by
  have hff : B.fund ≠ f := fun e => h.fund_not_holder (e ▸ hf)
  have hft : B.fund ≠ t := fun e => h.fund_not_holder (e ▸ ht)
  rw [totalValue_eq _ (transfer_conserved f t x B hf ht h) hT, totalValue_eq B h hT]
  have hA : (B.transfer f t x).assets = B.assets := by
    unfold assets; rw [transfer_funded f t x B hff hft]; rfl
  have hw : ∑ a ∈ B.holders, (B.transfer f t x).wallet a = ∑ a ∈ B.holders, B.wallet a := by
    show ∑ b ∈ B.holders, (B.wallet b - (if b = f then B.walletPart f x else 0)
        + (if b = t then B.walletPart f x else 0)) = _
    rw [sum_add_ite, sum_sub_ite, if_pos hf, if_pos ht]
    ring
  have hh : (B.transfer f t x).holders = B.holders := rfl
  have hp : (B.transfer f t x).price = B.price := rfl
  rw [hA, hh, hp, hw]

/-! ## The rejected claim rule (kept as the reason for the design) -/

/-- **The plan's first claim rule shifts everyone else's balance.** A holder with `ua` of `T` units
takes its slice `ua/T·F` and burns units worth it at the unit price `(S + F·p)/T`. Another holder
with `uc` units then shows `uc/(T − burn)·(F − ua/T·F)`, strictly below its old `uc/T·F` whenever
unconverted source value `S` is positive: a passive balance moves on someone else's transfer. -/
theorem rejected_claim_shifts (T F S p ua uc : ℝ) (hT : 0 < T) (hua : 0 < ua) (hlt : ua < T)
    (huc : 0 < uc) (hF : 0 < F) (hS : 0 < S) (hp : 0 < p) :
    uc / (T - ua / T * F * p * T / (S + F * p)) * (F - ua / T * F) < uc / T * F := by
  have hA : 0 < S + F * p := by positivity
  have hburn : ua / T * F * p * T / (S + F * p) = ua * (F * p) / (S + F * p) := by
    field_simp
  have hb : ua * (F * p) / (S + F * p) < ua := by
    rw [div_lt_iff₀ hA]; nlinarith
  rw [hburn]
  have hU' : 0 < T - ua * (F * p) / (S + F * p) := by linarith
  have hTu : 0 < T - ua := by linarith
  have e : uc / T * F = uc * F * (T - ua) / (T * (T - ua)) := by
    field_simp
  have e' : uc / (T - ua * (F * p) / (S + F * p)) * (F - ua / T * F)
      = uc * F * (T - ua) / (T * (T - ua * (F * p) / (S + F * p))) := by
    field_simp
  rw [e, e', div_lt_div_iff₀ (mul_pos hT hU') (mul_pos hT hTu)]
  have hk : 0 < uc * F * (T - ua) * T := by positivity
  nlinarith [mul_lt_mul_of_pos_left hb hk]

/-! ## Any valid trace keeps the balance identity -/

/-- The share-ledger operations. Events (`deposit`, `requestRedeem`, `allocate` for rebalance,
compound, sync, …) allocate; transfers don't. -/
inductive Op (Acct : Type*)
  | deposit (r : Acct) (x m v : ℝ)
  | transfer (f t : Acct) (x : ℝ)
  | allocate (m v : ℝ)
  | harvest (h c : ℝ)
  | requestRedeem (o : Acct) (x m v : ℝ)
  | burnEscrow (y : ℝ)

/-- Apply one operation. -/
noncomputable def apply (B : ShareBook Acct) : Op Acct → ShareBook Acct
  | .deposit r x m v => B.deposit r x m v
  | .transfer f t x => B.transfer f t x
  | .allocate m v => B.allocate m v
  | .harvest h c => B.harvest h c
  | .requestRedeem o x m v => B.requestRedeem o x m v
  | .burnEscrow y => B.burnEscrow y

/-- Each operation's precondition: the accounts it touches are holders, and an allocation mints
nothing when there is no outside supply. -/
def valid (B : ShareBook Acct) : Op Acct → Prop
  | .deposit r _ m _ => r ∈ B.holders ∧ (B.outside ≠ 0 ∨ m = 0)
  | .transfer f t _ => f ∈ B.holders ∧ t ∈ B.holders
  | .allocate m _ => B.outside ≠ 0 ∨ m = 0
  | .harvest _ _ => True
  | .requestRedeem o _ m _ => o ∈ B.holders ∧ (B.outside ≠ 0 ∨ m = 0)
  | .burnEscrow _ => True

theorem apply_conserved (B : ShareBook Acct) (op : Op Acct) (hv : B.valid op) (h : B.Conserved) :
    (B.apply op).Conserved := by
  cases op with
  | deposit r x m v => exact deposit_conserved r x m v B hv.1 hv.2 h
  | transfer f t x => exact transfer_conserved f t x B hv.1 hv.2 h
  | allocate m v => exact allocate_conserved m v B hv h
  | harvest hh c => exact harvest_conserved hh c B h
  | requestRedeem o x m v => exact requestRedeem_conserved o x m v B hv.1 hv.2 h
  | burnEscrow y => exact burnEscrow_conserved y B h

/-- Run a list of operations in order. -/
noncomputable def run (B : ShareBook Acct) : List (Op Acct) → ShareBook Acct
  | [] => B
  | op :: ops => run (B.apply op) ops

/-- A trace is valid when each operation's precondition holds at the state it runs on. -/
def runValid (B : ShareBook Acct) : List (Op Acct) → Prop
  | [] => True
  | op :: ops => B.valid op ∧ runValid (B.apply op) ops

theorem run_conserved (B : ShareBook Acct) (ops : List (Op Acct)) (hv : B.runValid ops)
    (h : B.Conserved) : (B.run ops).Conserved := by
  induction ops generalizing B with
  | nil => exact h
  | cons op ops ih => exact ih (B.apply op) hv.2 (apply_conserved B op hv.1 h)

/-- **The balance identity at every reachable state**: `Σ balanceOf` plus the waiting requests'
slice is the supply. -/
theorem run_totalBalance_add (B : ShareBook Acct) (ops : List (Op Acct)) (hv : B.runValid ops)
    (h : B.Conserved) :
    (B.run ops).totalBalance + (B.run ops).requestUnits / (B.run ops).totalUnits * (B.run ops).funded
      = (B.run ops).totalSupply :=
  totalBalance_add _ (run_conserved B ops hv h)

end ShareBook
end Juicer
