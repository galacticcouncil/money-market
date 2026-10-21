import JuicerLean.Spec.Ops
import JuicerLean.Spec.YieldShares

/-!
# Juicer — redemption lifecycle & solvency (Phase 2, cont.)

The async withdrawal path (`requestRedeem → unwind → settle → claim`) and its
invariants:

* `escrowOk` — escrowed shares are non-negative and never exceed outstanding shares.
* `requestRedeem` / `claimShares` preserve `escrowOk` and keep `shares ≥ 0`
  (**escrow** + **shareConservation**).
* `freedBacked` — the loop's value-stable equity (`primeAmt·primePrice − subDebt`)
  covers the Main HOLLAR debt, so no collateral is sold to repay it.
* `collateral_out_ge_in` — under `freedBacked`, settlement returns the **full**
  collateral (out ≥ in): the depositor's principal comes back, repaid from the loop.

Next version (plan §3, exit fold), on the share book of `YieldShares.lean`:
* `ShareBook.startExit` — the request's accrued units join the owner's, the exiting share of the
  owner's units burns with the units committed to the request, their funded slice moves from the
  fund into the escrow and joins the request's shares before the quote, their source slice
  leaves with the unwind;
* `startExit_conserved` / `runExit_totalBalance_add` — conservation (and so the balance identity)
  holds through the fold and through any trace with exits;
* `startExit_wallets` / `startExit_fold` — share conservation including the fold: holders' wallets
  untouched, the fund and the escrow trade exactly the folded shares, supply unchanged;
* `startExit_fullExit` / `requestRedeem_max_then_startExit` — after a full exit the owner has no
  units, no slice of the fund and no balance;
* `startExit_slice_other` / `startExit_unitPrice` — nobody else's slice or unit price moves;
* `State.startExit_requestRedeem` / `State.startExit_escrowOk` — seen by the redemption state the
  fold is an escrow of the folded shares, so `escrowOk` survives it;
* `startExit_quote` — quoting after the fold pays the folded shares at the same per-share value and
  leaves the remaining holders' per-share value unchanged.
-/

namespace Juicer
namespace State

/-- **escrow** invariant: escrowed shares are a non-negative subset of all shares. -/
def escrowOk (s : State) : Prop := 0 ≤ s.escrowShares ∧ s.escrowShares ≤ s.shares

/-- Escrow `x` shares for a pending redemption. -/
def requestRedeem (s : State) (x : ℝ) : State :=
  { s with escrowShares := s.escrowShares + x }

/-- Burn `x` escrowed shares on claim. -/
def claimShares (s : State) (x : ℝ) : State :=
  { s with shares := s.shares - x, escrowShares := s.escrowShares - x }

/-- `requestRedeem` preserves `escrowOk` when there are enough free shares. -/
theorem requestRedeem_escrowOk (s : State) (x : ℝ)
    (hx : 0 ≤ x) (hcap : s.escrowShares + x ≤ s.shares) (h : escrowOk s) :
    escrowOk (s.requestRedeem x) := by
  simp only [escrowOk, requestRedeem] at *
  exact ⟨by linarith [h.1], hcap⟩

/-- `claimShares` preserves `escrowOk`. -/
theorem claimShares_escrowOk (s : State) (x : ℝ)
    (hxe : x ≤ s.escrowShares) (h : escrowOk s) :
    escrowOk (s.claimShares x) := by
  simp only [escrowOk, claimShares] at *
  exact ⟨by linarith [h.1], by linarith [h.2]⟩

/-- **shareConservation:** claiming never drives total shares negative
(`x ≤ escrow ≤ shares`). -/
theorem claimShares_sharesNonneg (s : State) (x : ℝ)
    (hxe : x ≤ s.escrowShares) (h : escrowOk s) :
    0 ≤ (s.claimShares x).shares := by
  simp only [claimShares]
  linarith [h.1, h.2]

/-- Loop equity after repaying loop debt: `primeAmt·primePrice − subDebt`. -/
def loopEquity (s : State) : ℝ := s.primeAmt * s.primePrice - s.subDebt

/-- **freedBacked:** the loop's (value-stable) equity covers the Main HOLLAR debt.
This is exactly the seed-equity identity (debt = equity) preserved as the loop runs. -/
def freedBacked (s : State) : Prop := s.mainDebt ≤ s.loopEquity

/-- abstract shortfall diagnostic, not a runtime sale: current Solidity retains unpaid collateral claims.
`max(mainDebt − loopEquity, 0) / price`. -/
noncomputable def collSold (s : State) : ℝ :=
  max (s.mainDebt - s.loopEquity) 0 / s.price

/-- hypothetical immediately recoverable collateral; the runtime can defer payment without reducing the claim. -/
noncomputable def collateralReturned (s : State) : ℝ := s.coll - s.collSold

/-- Under `freedBacked`, no collateral is sold — the loop repays the debt entirely. -/
theorem freedBacked_no_coll_sold (s : State) (h : freedBacked s) :
    s.collSold = 0 := by
  unfold collSold
  rw [max_eq_right (by unfold freedBacked at h; linarith)]
  simp

/-- **collateral_out_ge_in.** With the loop equity backing the debt, settlement
returns at least the deposited collateral — the principal is made whole from the
value-stable loop, never by selling the collateral. -/
theorem collateral_out_ge_in (s : State) (h : freedBacked s) :
    s.coll ≤ s.collateralReturned := by
  unfold collateralReturned
  rw [freedBacked_no_coll_sold s h]
  linarith

end State

/-! ## Exit fold (next version) -/

-- the section's `[DecidableEq Acct]` is unused by a few pure lemmas below; intentional.
set_option linter.unusedSectionVars false

namespace ShareBook

open scoped BigOperators

variable {Acct : Type*} [DecidableEq Acct]

/-- the owner's units leaving with `x` escrowed shares: its units, with the request's accrued `ra`
credited first, times `x/(wallet + x)` — the exiting share of its weight. -/
noncomputable def exitUnits (B : ShareBook Acct) (o : Acct) (x ra : ℝ) : ℝ :=
  (B.units o + ra) * x / (B.wallet o + x)

/-- every unit burned at the start: the exiting ones plus those committed to the request. -/
noncomputable def burned (B : ShareBook Acct) (o : Acct) (x ra rc : ℝ) : ℝ :=
  B.exitUnits o x ra + rc

/-- the fold: the burned units' slice of the funded pool. -/
noncomputable def fold (B : ShareBook Acct) (o : Acct) (x ra rc : ℝ) : ℝ :=
  B.burned o x ra rc / B.totalUnits * B.funded

/-- `_startUnwind` with `startExit` for a request of `x` escrowed shares owned by `o`, which accrued
`ra` units while waiting and had `rc` units committed at `requestRedeem`. -/
noncomputable def startExit (o : Acct) (x ra rc : ℝ) (B : ShareBook Acct) : ShareBook Acct :=
  { B with wallet := fun b => B.wallet b - (if b = B.fund then B.fold o x ra rc else 0)
                                + (if b = B.escrow then B.fold o x ra rc else 0)
           units := fun b => B.units b + if b = o then ra - B.exitUnits o x ra else 0
           totalUnits := B.totalUnits - B.burned o x ra rc
           requestUnits := B.requestUnits - ra - rc
           srcValue := B.srcValue - B.burned o x ra rc / B.totalUnits * B.srcValue
           waiting := B.waiting - x
           queued := B.queued + x + B.fold o x ra rc }

theorem startExit_conserved (o : Acct) (x ra rc : ℝ) (B : ShareBook Acct) (ho : o ∈ B.holders)
    (h : B.Conserved) : (B.startExit o x ra rc).Conserved := by
  have hfe : B.fund ≠ B.escrow := h.fund_ne_escrow
  refine ⟨h.fund_not_holder, h.escrow_not_holder, h.fund_ne_escrow, ?_, ?_, ?_⟩
  · show (B.wallet B.fund - (if B.fund = B.fund then B.fold o x ra rc else 0)
          + (if B.fund = B.escrow then B.fold o x ra rc else 0))
        + (B.wallet B.escrow - (if B.escrow = B.fund then B.fold o x ra rc else 0)
          + (if B.escrow = B.escrow then B.fold o x ra rc else 0))
        + ∑ b ∈ B.holders, (B.wallet b - (if b = B.fund then B.fold o x ra rc else 0)
          + (if b = B.escrow then B.fold o x ra rc else 0)) = B.totalSupply
    rw [sum_add_ite, sum_sub_ite, if_neg h.fund_not_holder, if_neg h.escrow_not_holder, if_pos rfl,
      if_pos rfl, if_neg hfe, if_neg (Ne.symm hfe)]
    linarith [h.supply]
  · show ∑ b ∈ B.holders, (B.units b + if b = o then ra - B.exitUnits o x ra else 0)
        + (B.requestUnits - ra - rc) = B.totalUnits - B.burned o x ra rc
    rw [sum_add_ite, if_pos ho, burned]
    linarith [h.units]
  · show B.wallet B.escrow - (if B.escrow = B.fund then B.fold o x ra rc else 0)
        + (if B.escrow = B.escrow then B.fold o x ra rc else 0)
        = (B.waiting - x) + (B.queued + x + B.fold o x ra rc)
    rw [if_neg (Ne.symm hfe), if_pos rfl, sub_zero, h.escrow]
    ring

/-- **Share conservation including the fold.** Supply is unchanged, every holder's wallet is
untouched, and the fund and the escrow together hold the same shares as before. -/
theorem startExit_wallets (o : Acct) (x ra rc : ℝ) (B : ShareBook Acct) (h : B.Conserved) :
    (B.startExit o x ra rc).totalSupply = B.totalSupply ∧
    (∀ c ∈ B.holders, (B.startExit o x ra rc).wallet c = B.wallet c) ∧
    (B.startExit o x ra rc).wallet B.fund + (B.startExit o x ra rc).wallet B.escrow
      = B.wallet B.fund + B.wallet B.escrow := by
  have hfe : B.fund ≠ B.escrow := h.fund_ne_escrow
  refine ⟨rfl, fun c hc => ?_, ?_⟩
  · have hcf : c ≠ B.fund := fun e => h.fund_not_holder (e ▸ hc)
    have hce : c ≠ B.escrow := fun e => h.escrow_not_holder (e ▸ hc)
    show B.wallet c - (if c = B.fund then B.fold o x ra rc else 0)
        + (if c = B.escrow then B.fold o x ra rc else 0) = B.wallet c
    rw [if_neg hcf, if_neg hce, sub_zero, add_zero]
  · show (B.wallet B.fund - (if B.fund = B.fund then B.fold o x ra rc else 0)
          + (if B.fund = B.escrow then B.fold o x ra rc else 0))
        + (B.wallet B.escrow - (if B.escrow = B.fund then B.fold o x ra rc else 0)
          + (if B.escrow = B.escrow then B.fold o x ra rc else 0)) = _
    rw [if_pos rfl, if_neg hfe, if_neg (Ne.symm hfe), if_pos rfl]
    ring

/-- **The fold.** Exactly the burned units' funded slice leaves the fund for the escrow, where it
joins the request's shares as they move from waiting to started. -/
theorem startExit_fold (o : Acct) (x ra rc : ℝ) (B : ShareBook Acct) (h : B.Conserved) :
    (B.startExit o x ra rc).wallet B.escrow = B.wallet B.escrow + B.fold o x ra rc ∧
    (B.startExit o x ra rc).funded = B.funded - B.fold o x ra rc ∧
    (B.startExit o x ra rc).queued = B.queued + (x + B.fold o x ra rc) ∧
    (B.startExit o x ra rc).waiting = B.waiting - x := by
  have hfe : B.fund ≠ B.escrow := h.fund_ne_escrow
  refine ⟨?_, ?_, by show B.queued + x + B.fold o x ra rc = _; ring, rfl⟩
  · show B.wallet B.escrow - (if B.escrow = B.fund then B.fold o x ra rc else 0)
        + (if B.escrow = B.escrow then B.fold o x ra rc else 0) = _
    rw [if_neg (Ne.symm hfe), if_pos rfl, sub_zero]
  · show B.wallet B.fund - (if B.fund = B.fund then B.fold o x ra rc else 0)
        + (if B.fund = B.escrow then B.fold o x ra rc else 0) = _
    rw [if_pos rfl, if_neg hfe, add_zero]
    rfl

/-- **Nothing is left after a full exit.** With the whole wallet escrowed, every unit the owner
holds — its own and the request's accrued ones — exits, so it keeps no units, no slice of the fund
and no balance. -/
theorem startExit_fullExit (o : Acct) (x ra rc : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (ho : o ∈ B.holders) (hw : B.wallet o = 0) (hx : x ≠ 0 ∨ B.units o + ra = 0) :
    (B.startExit o x ra rc).units o = 0 ∧ (B.startExit o x ra rc).slice o = 0 ∧
    (B.startExit o x ra rc).balanceOf o = 0 := by
  have hu : (B.startExit o x ra rc).units o = 0 := by
    show B.units o + (if o = o then ra - B.exitUnits o x ra else 0) = 0
    rw [if_pos rfl, exitUnits, hw, zero_add]
    rcases hx with hx | hz
    · rw [mul_div_assoc, div_self hx, mul_one]
      ring
    · rw [hz, zero_mul, zero_div, sub_zero]
      linarith
  have hs : (B.startExit o x ra rc).slice o = 0 := by
    rw [slice, hu, zero_div, zero_mul]
  refine ⟨hu, hs, ?_⟩
  have hwal : (B.startExit o x ra rc).wallet o = 0 := by
    rw [(startExit_wallets o x ra rc B h).2.1 o ho, hw]
  rw [balanceOf_holder _ (startExit_conserved o x ra rc B ho h) ho, hwal, hs, add_zero]

/-- **End to end: `requestRedeem(max)`, then the start, leaves the owner nothing.** The request
escrows the whole wallet and commits every unit; at the start the units the request accrued while
waiting exit with it. -/
theorem requestRedeem_max_then_startExit (o : Acct) (m v x ra rc : ℝ) (B : ShareBook Acct)
    (h : B.Conserved) (ho : o ∈ B.holders) (hm : B.outside ≠ 0 ∨ m = 0)
    (hT : 0 < (B.allocate m v).totalUnits) (hF : 0 < (B.allocate m v).funded)
    (hu : 0 ≤ (B.allocate m v).units o) (hx : x ≠ 0 ∨ ra = 0) :
    ((B.requestRedeem o ((B.allocate m v).balanceOf o) m v).startExit o x ra rc).units o = 0 ∧
    ((B.requestRedeem o ((B.allocate m v).balanceOf o) m v).startExit o x ra rc).balanceOf o = 0 := by
  obtain ⟨hw, hu0⟩ := requestRedeem_max_empties o m v B h ho hm hT hF hu
  have hc := requestRedeem_conserved o ((B.allocate m v).balanceOf o) m v B ho hm h
  have hx' : x ≠ 0 ∨ (B.requestRedeem o ((B.allocate m v).balanceOf o) m v).units o + ra = 0 := by
    rcases hx with hx | hra
    · exact Or.inl hx
    · exact Or.inr (by rw [hu0, hra, add_zero])
  obtain ⟨h1, -, h3⟩ := startExit_fullExit o x ra rc _ hc ho hw hx'
  exact ⟨h1, h3⟩

/-- **Nobody else's slice moves.** The burned units take their funded and source parts in the same
proportion, so the funded pool per unit is unchanged. -/
theorem startExit_slice_other (o c : Acct) (x ra rc : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hco : c ≠ o) (hT : B.totalUnits ≠ 0) (hT' : B.totalUnits - B.burned o x ra rc ≠ 0) :
    (B.startExit o x ra rc).slice c = B.slice c := by
  have hF := (startExit_fold o x ra rc B h).2.1
  have hu : (B.startExit o x ra rc).units c = B.units c := by
    show B.units c + (if c = o then ra - B.exitUnits o x ra else 0) = B.units c
    rw [if_neg hco, add_zero]
  have hTe : (B.startExit o x ra rc).totalUnits = B.totalUnits - B.burned o x ra rc := rfl
  rw [slice, slice, hu, hTe, hF, fold]
  field_simp

/-- **The unit price is unchanged** (cross-multiplied): both parts of the fund shrink by the burned
units' share. -/
theorem startExit_unitPrice (o : Acct) (x ra rc : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (hT : B.totalUnits ≠ 0) :
    (B.startExit o x ra rc).assets * B.totalUnits = B.assets * (B.startExit o x ra rc).totalUnits := by
  have hF := (startExit_fold o x ra rc B h).2.1
  have hS : (B.startExit o x ra rc).srcValue
      = B.srcValue - B.burned o x ra rc / B.totalUnits * B.srcValue := rfl
  have hTe : (B.startExit o x ra rc).totalUnits = B.totalUnits - B.burned o x ra rc := rfl
  have hp : (B.startExit o x ra rc).price = B.price := rfl
  unfold assets
  rw [hF, hS, hTe, hp, fold]
  field_simp

/-- The burned units never exceed the units outstanding: the owner's units are part of the holders'
total and the request's are part of `requestUnits`. -/
theorem burned_le (o : Acct) (x ra rc : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (ho : o ∈ B.holders) (hu : ∀ b ∈ B.holders, 0 ≤ B.units b) (hra : 0 ≤ ra)
    (hR : ra + rc ≤ B.requestUnits) (hx : 0 ≤ x) (hw : 0 ≤ B.wallet o) :
    B.burned o x ra rc ≤ B.totalUnits := by
  have huo : B.units o ≤ ∑ b ∈ B.holders, B.units b := Finset.single_le_sum hu ho
  have hexit : B.exitUnits o x ra ≤ B.units o + ra := by
    unfold exitUnits
    have hn : 0 ≤ B.units o + ra := by linarith [hu o ho]
    rcases (show 0 ≤ B.wallet o + x by linarith).eq_or_lt with h0 | hpos
    · rw [← h0, div_zero]; exact hn
    · rw [mul_div_assoc]
      have : x / (B.wallet o + x) ≤ 1 := by rw [div_le_one hpos]; linarith
      calc (B.units o + ra) * (x / (B.wallet o + x)) ≤ (B.units o + ra) * 1 :=
            mul_le_mul_of_nonneg_left this hn
        _ = B.units o + ra := mul_one _
  unfold burned
  linarith [h.units]

/-- …so the fold never exceeds the funded pool. -/
theorem fold_le_funded (o : Acct) (x ra rc : ℝ) (B : ShareBook Acct) (h : B.Conserved)
    (ho : o ∈ B.holders) (hu : ∀ b ∈ B.holders, 0 ≤ B.units b) (hra : 0 ≤ ra)
    (hR : ra + rc ≤ B.requestUnits) (hx : 0 ≤ x) (hw : 0 ≤ B.wallet o)
    (hT : 0 < B.totalUnits) (hF : 0 ≤ B.funded) :
    B.fold o x ra rc ≤ B.funded := by
  have hb := burned_le o x ra rc B h ho hu hra hR hx hw
  unfold fold
  calc B.burned o x ra rc / B.totalUnits * B.funded ≤ 1 * B.funded := by
        apply mul_le_mul_of_nonneg_right _ hF
        rw [div_le_one hT]; exact hb
    _ = B.funded := one_mul _

/-- **The quote after the fold.** `_startUnwind` quotes `activeAssets × (x + fold)/activeSupply`:
the folded shares are paid at the same per-share value as the escrowed ones, and the remaining
holders keep their per-share value (cross-multiplied, `A` the active assets). -/
theorem startExit_quote (o : Acct) (x ra rc A : ℝ) (B : ShareBook Acct) :
    let S := B.totalSupply - B.queued
    let owed := A * (x + B.fold o x ra rc) / S
    (B.startExit o x ra rc).totalSupply - (B.startExit o x ra rc).queued = S - (x + B.fold o x ra rc) ∧
    (S ≠ 0 → (A - owed) * S = A * ((B.startExit o x ra rc).totalSupply - (B.startExit o x ra rc).queued)) := by
  intro S owed
  have hS : (B.startExit o x ra rc).totalSupply - (B.startExit o x ra rc).queued
      = S - (x + B.fold o x ra rc) := by
    show B.totalSupply - (B.queued + x + B.fold o x ra rc) = B.totalSupply - B.queued - (x + B.fold o x ra rc)
    ring
  refine ⟨hS, fun hS0 => ?_⟩
  rw [hS]
  show (A - A * (x + B.fold o x ra rc) / S) * S = A * (S - (x + B.fold o x ra rc))
  field_simp

/-! ### Traces with exits -/

/-- the share-ledger operations plus `startExit`. -/
inductive ExitOp (Acct : Type*)
  | base (op : Op Acct)
  | startExit (o : Acct) (x ra rc : ℝ)

noncomputable def applyExit (B : ShareBook Acct) : ExitOp Acct → ShareBook Acct
  | .base op => B.apply op
  | .startExit o x ra rc => B.startExit o x ra rc

def validExit (B : ShareBook Acct) : ExitOp Acct → Prop
  | .base op => B.valid op
  | .startExit o _ _ _ => o ∈ B.holders

theorem applyExit_conserved (B : ShareBook Acct) (op : ExitOp Acct) (hv : B.validExit op)
    (h : B.Conserved) : (B.applyExit op).Conserved := by
  cases op with
  | base op => exact apply_conserved B op hv h
  | startExit o x ra rc => exact startExit_conserved o x ra rc B hv h

noncomputable def runExit (B : ShareBook Acct) : List (ExitOp Acct) → ShareBook Acct
  | [] => B
  | op :: ops => runExit (B.applyExit op) ops

def runValidExit (B : ShareBook Acct) : List (ExitOp Acct) → Prop
  | [] => True
  | op :: ops => B.validExit op ∧ runValidExit (B.applyExit op) ops

theorem runExit_conserved (B : ShareBook Acct) (ops : List (ExitOp Acct)) (hv : B.runValidExit ops)
    (h : B.Conserved) : (B.runExit ops).Conserved := by
  induction ops generalizing B with
  | nil => exact h
  | cons op ops ih => exact ih (B.applyExit op) hv.2 (applyExit_conserved B op hv.1 h)

/-- **The balance identity through exits**: at every state reachable with deposits, transfers,
allocations, harvests, requests, exits and escrow burns. -/
theorem runExit_totalBalance_add (B : ShareBook Acct) (ops : List (ExitOp Acct))
    (hv : B.runValidExit ops) (h : B.Conserved) :
    (B.runExit ops).totalBalance
      + (B.runExit ops).requestUnits / (B.runExit ops).totalUnits * (B.runExit ops).funded
      = (B.runExit ops).totalSupply :=
  totalBalance_add _ (runExit_conserved B ops hv h)

end ShareBook

namespace State

/-- the redemption state's share fields, read off a share book: supply and the escrow's shares. -/
def withShares {Acct : Type*} (s : State) (B : ShareBook Acct) : State :=
  { s with shares := B.totalSupply, escrowShares := B.wallet B.escrow }

/-- **Seen by the redemption state, the fold is an escrow of the folded shares**: total shares stay,
escrow grows by the fold — exactly `requestRedeem fold`. -/
theorem startExit_requestRedeem {Acct : Type*} [DecidableEq Acct] (s : State) (B : ShareBook Acct)
    (h : B.Conserved) (o : Acct) (x ra rc : ℝ) :
    s.withShares (B.startExit o x ra rc) = (s.withShares B).requestRedeem (B.fold o x ra rc) := by
  have he : (B.startExit o x ra rc).wallet (B.startExit o x ra rc).escrow
      = B.wallet B.escrow + B.fold o x ra rc := (ShareBook.startExit_fold o x ra rc B h).1
  unfold withShares requestRedeem
  rw [he]
  rfl

/-- **`escrowOk` survives the fold**: the folded shares come out of the fund, never out of thin air,
so escrow stays within supply. -/
theorem startExit_escrowOk {Acct : Type*} [DecidableEq Acct] (s : State) (B : ShareBook Acct)
    (h : B.Conserved) (o : Acct) (x ra rc : ℝ)
    (hwal : ∀ b ∈ B.holders, 0 ≤ B.wallet b) (he0 : 0 ≤ B.wallet B.escrow)
    (hf0 : 0 ≤ B.fold o x ra rc) (hfold : B.fold o x ra rc ≤ B.wallet B.fund) :
    (s.withShares (B.startExit o x ra rc)).escrowOk := by
  rw [startExit_requestRedeem s B h o x ra rc]
  have hsum : 0 ≤ ∑ b ∈ B.holders, B.wallet b := Finset.sum_nonneg hwal
  apply requestRedeem_escrowOk _ _ hf0
  · show B.wallet B.escrow + B.fold o x ra rc ≤ B.totalSupply
    linarith [h.supply]
  · refine ⟨he0, ?_⟩
    show B.wallet B.escrow ≤ B.totalSupply
    have : 0 ≤ B.wallet B.fund := le_trans hf0 hfold
    linarith [h.supply]

end State
end Juicer
