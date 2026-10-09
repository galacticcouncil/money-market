import JuicerLean.Spec.Redemption
import JuicerLean.Spec.Preservation

/-!
# Juicer — SubLoop de-lever / unwind step (ℝ-spec)

Models the loop's **de-lever** step: sell `a` aPRIME (at `primePrice`) and repay the proceeds
(`a·primePrice` HOLLAR) against the loop's own debt. PRIME is value-stable, so the step removes the
*same value* from collateral and debt — the deleveraging spiral that `pokeRepay` / `deLever` drive on
chain. Proven here:

* `deLever_loopEquity` — equity-neutral: `primeAmt·primePrice − subDebt` is invariant.
* `deLever_mainHF` / `deLever_principalFloored` — the Main leg is untouched, so `mainHF` and the
  principal floor are preserved (de-levering the loop can't endanger the principal).
* `deLever_raises_subHF` — when the loop is **solvent** (collateral value ≥ debt), unwinding a
  positive value-stable slice **raises** the sub-loop health factor — so de-lever always moves HF up
  toward target, the on-chain `deLever`/unwind-spiral safety property.

Next version (plan §4): ICE intents in flight — `IceLoop`, at the end of the file.
-/

namespace Juicer
namespace State

/-- De-lever by selling `a` aPRIME and repaying the (value-stable) proceeds against the loop debt. -/
noncomputable def deLever (s : State) (a : ℝ) : State :=
  { s with primeAmt := s.primeAmt - a, subDebt := s.subDebt - a * s.primePrice }

/-- **Equity-neutral.** The slice removes equal value from collateral and debt. -/
theorem deLever_loopEquity (s : State) (a : ℝ) :
    (s.deLever a).loopEquity = s.loopEquity := by
  simp only [loopEquity, deLever]; ring

/-- The Main position (collateral, synthetic, HOLLAR debt) is untouched, so its health factor is
unchanged — de-levering the loop never moves the principal's HF. -/
theorem deLever_mainHF (s : State) (a : ℝ) :
    (s.deLever a).mainHF = s.mainHF := by
  simp only [mainHF, mainCollateralValue, deLever]

/-- …and the principal floor is preserved. -/
theorem deLever_principalFloored (s : State) (a : ℝ) (h : s.principalFloored) :
    (s.deLever a).principalFloored := by
  simpa [principalFloored, deLever] using h

/-- **De-lever safety.** When the loop is solvent (`subDebt ≤ primeAmt·primePrice`, i.e.
`loopEquity ≥ 0`), unwinding a positive value-stable slice (`0 < a·primePrice < subDebt`) raises the
sub-loop health factor: `subHF s ≤ subHF (deLever s a)`. So de-lever monotonically moves HF up. -/
theorem deLever_raises_subHF (s : State) (a : ℝ)
    (hlt : 0 ≤ s.ltPrime)
    (hD : 0 < s.subDebt)
    (hδpos : 0 < a * s.primePrice)
    (hδlt : a * s.primePrice < s.subDebt)
    (hsolvent : s.subDebt ≤ s.primeAmt * s.primePrice) :
    s.subHF ≤ (s.deLever a).subHF := by
  have hDδ : 0 < s.subDebt - a * s.primePrice := by linarith
  simp only [subHF, deLever]
  rw [le_div_iff₀ hDδ, div_mul_eq_mul_div, div_le_iff₀ hD]
  nlinarith [mul_nonneg (mul_nonneg hlt hδpos.le) (sub_nonneg.mpr hsolvent)]

/-! ### De-lever and the redemption solvency guarantee

The headline user-facing theorem is `Redemption.collateral_out_ge_in`: under `freedBacked` (the loop's
value-stable equity covers the Main HOLLAR debt), a full unwind returns at least the deposited
collateral. Juicer unwinds *gradually* — a DCA sequence of `deLever` steps — so the guarantee is
only meaningful if it survives each step. It does: `deLever` leaves Main debt, collateral, and price
untouched and holds `loopEquity` invariant, so `freedBacked` and `collateralReturned` are preserved
unchanged by every step. The depositor stays made-whole throughout the unwind, not just at the end. -/

/-- **`freedBacked` is preserved by de-lever.** Main debt is untouched and `loopEquity` is invariant
(`deLever_loopEquity`), so the loop keeps backing the Main HOLLAR debt through each unwind step. -/
theorem deLever_freedBacked (s : State) (a : ℝ) (h : s.freedBacked) :
    (s.deLever a).freedBacked := by
  unfold freedBacked at *
  rw [deLever_loopEquity]
  exact h

/-- **Collateral returned is invariant under de-lever.** `collateralReturned = coll − collSold`, and
`collSold = max(mainDebt − loopEquity, 0)/price` depends only on quantities de-lever leaves fixed
(`coll`, `mainDebt`, `price`) plus the invariant `loopEquity`. -/
theorem deLever_collateralReturned (s : State) (a : ℝ) :
    (s.deLever a).collateralReturned = s.collateralReturned := by
  have he := deLever_loopEquity s a
  simp only [collateralReturned, collSold]
  rw [he]
  simp only [deLever]

/-- **De-lever preserves `collateral_out_ge_in`.** After any de-lever step on a `freedBacked` loop,
settlement still returns at least the deposited collateral — the gradual DCA unwind never erodes the
principal-back guarantee. -/
theorem deLever_collateral_out_ge_in (s : State) (a : ℝ) (h : s.freedBacked) :
    s.coll ≤ (s.deLever a).collateralReturned := by
  rw [deLever_collateralReturned]
  exact collateral_out_ge_in s h

/-! ### `subLoopHealthy` preservation

`subLoopHealthy s t := t ≤ s.subHF` (the loop stays at/above the de-lever trigger). The Main-position
maintenance ops (`accrueInterest`/`maintainPeg`/`tick`/`repay`) only touch `mainDebt`/`synth`, never
the loop fields `primeAmt·primePrice·ltPrime/subDebt`, so `subHF` is **invariant** under them and the
trigger is trivially held. The loop's own `deLever` step *raises* `subHF` on a solvent loop
(`deLever_raises_subHF`), so it preserves the trigger too. Hence every transition in the ℝ-spec keeps
the loop healthy. -/

theorem accrueInterest_subHF (s : State) (δ : ℝ) : (s.accrueInterest δ).subHF = s.subHF := by
  simp only [subHF, accrueInterest]

theorem maintainPeg_subHF (s : State) : s.maintainPeg.subHF = s.subHF := by
  simp only [subHF, maintainPeg, mintSynthToPeg]

theorem tick_subHF (s : State) (δ : ℝ) : (s.tick δ).subHF = s.subHF := by
  unfold tick
  rw [maintainPeg_subHF, accrueInterest_subHF]

theorem repay_subHF (s : State) (r : ℝ) : (s.repay r).subHF = s.subHF := by
  unfold repay
  rw [maintainPeg_subHF]
  simp only [subHF]

/-- The maintenance tick (accrue interest + re-peg) leaves the loop health untouched. -/
theorem tick_subLoopHealthy (s : State) (δ t : ℝ) (h : s.subLoopHealthy t) :
    (s.tick δ).subLoopHealthy t := by
  unfold subLoopHealthy at *; rwa [tick_subHF]

/-- Repaying Main debt + re-peg leaves the loop health untouched. -/
theorem repay_subLoopHealthy (s : State) (r t : ℝ) (h : s.subLoopHealthy t) :
    (s.repay r).subLoopHealthy t := by
  unfold subLoopHealthy at *; rwa [repay_subHF]

/-- **De-lever keeps the loop healthy.** On a solvent loop a de-lever step only raises `subHF`
(`deLever_raises_subHF`), so a state at/above the trigger stays at/above it. -/
theorem deLever_subLoopHealthy (s : State) (a t : ℝ)
    (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (hδpos : 0 < a * s.primePrice) (hδlt : a * s.primePrice < s.subDebt)
    (hsolvent : s.subDebt ≤ s.primeAmt * s.primePrice)
    (h : s.subLoopHealthy t) :
    (s.deLever a).subLoopHealthy t := by
  unfold subLoopHealthy at *
  exact le_trans h (deLever_raises_subHF s a hlt hD hδpos hδlt hsolvent)

/-! ### Iterated (gradual) unwind

Juicer unwinds across many transactions — a *sequence* of `deLever` slices, not one big step.
`deLeverSeq s as` applies the per-step transition once per slice size in `as`. The per-step lemmas
lift to the whole sequence by induction: loop equity stays invariant, `freedBacked` is preserved, and
`collateralReturned` is unchanged — so **`collateral_out_ge_in` holds after an arbitrary finite
unwind**, making the "gradual DCA" guarantee explicit rather than only per-step. -/

/-- Apply `deLever` once per slice in `as`, in order. -/
noncomputable def deLeverSeq : State → List ℝ → State
  | s, [] => s
  | s, a :: as => deLeverSeq (s.deLever a) as

@[simp] theorem deLeverSeq_nil (s : State) : deLeverSeq s [] = s := rfl

theorem deLeverSeq_cons (s : State) (a : ℝ) (as : List ℝ) :
    deLeverSeq s (a :: as) = deLeverSeq (s.deLever a) as := rfl

/-- Loop equity is invariant under the whole unwind. -/
theorem deLeverSeq_loopEquity (s : State) (as : List ℝ) :
    (deLeverSeq s as).loopEquity = s.loopEquity := by
  induction as generalizing s with
  | nil => rfl
  | cons a as ih => rw [deLeverSeq_cons, ih (s.deLever a), deLever_loopEquity]

/-- `freedBacked` is preserved by the whole unwind. -/
theorem deLeverSeq_freedBacked (s : State) (as : List ℝ) (h : s.freedBacked) :
    (deLeverSeq s as).freedBacked := by
  induction as generalizing s with
  | nil => exact h
  | cons a as ih => exact ih (s.deLever a) (deLever_freedBacked s a h)

/-- Collateral returned is invariant under the whole unwind. -/
theorem deLeverSeq_collateralReturned (s : State) (as : List ℝ) :
    (deLeverSeq s as).collateralReturned = s.collateralReturned := by
  induction as generalizing s with
  | nil => rfl
  | cons a as ih => rw [deLeverSeq_cons, ih (s.deLever a), deLever_collateralReturned]

/-- **Iterated principal-back guarantee.** After *any* finite sequence of de-lever steps on a
`freedBacked` loop, settlement returns at least the originally deposited collateral — the gradual
DCA unwind keeps the depositor made whole at every point along the way. -/
theorem deLeverSeq_collateral_out_ge_in (s : State) (as : List ℝ) (h : s.freedBacked) :
    s.coll ≤ (deLeverSeq s as).collateralReturned := by
  rw [deLeverSeq_collateralReturned]
  exact collateral_out_ge_in s h

/-- `principalFloored` is preserved by the whole unwind: `deLever` touches no Main-position field, so
the floor is literally invariant under it (no solvency hypothesis needed). -/
theorem deLeverSeq_principalFloored (s : State) (as : List ℝ) (h : s.principalFloored) :
    (deLeverSeq s as).principalFloored := by
  induction as generalizing s with
  | nil => exact h
  | cons a as ih => exact ih (s.deLever a) (deLever_principalFloored s a h)

/-! ### WellFormed preservation

The three transitions keep the state `WellFormed`. `deLever` touches only loop fields, so it's
immediate; `tick`/`repay` end in a re-peg, so they reduce to `maintainPeg_wellFormed` once the
interim `mainDebt` is shown positive (`tick` raises it by `δ ≥ 0`; `repay` needs the **partial**
condition `r < mainDebt`, since a fully-repaid debt would violate `mainDebt_pos`). -/

/-- `deLever` preserves `WellFormed` — it changes only `primeAmt`/`subDebt`, no Main-position field. -/
theorem deLever_wellFormed (s : State) (a : ℝ) (wf : WellFormed s) : WellFormed (s.deLever a) :=
  { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
    ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
    ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
    mainDebt_pos  := wf.mainDebt_pos,  ltvSynth_zero := wf.ltvSynth_zero }

/-- A full maintenance tick (accrue `δ ≥ 0`, then re-peg) preserves `WellFormed`. -/
theorem tick_wellFormed (s : State) (δ : ℝ) (wf : WellFormed s) (hδ : 0 ≤ δ) :
    WellFormed (s.tick δ) := by
  unfold tick
  apply maintainPeg_wellFormed
  exact
    { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
      ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
      ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
      mainDebt_pos  := by simp only [accrueInterest]; linarith [wf.mainDebt_pos]
      ltvSynth_zero := wf.ltvSynth_zero }

/-- A **partial** repay (`r < mainDebt`) then re-peg preserves `WellFormed`. -/
theorem repay_wellFormed (s : State) (r : ℝ) (wf : WellFormed s) (hr : r < s.mainDebt) :
    WellFormed (s.repay r) := by
  unfold repay
  apply maintainPeg_wellFormed
  exact
    { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
      ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
      ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
      mainDebt_pos  := by simp only; linarith
      ltvSynth_zero := wf.ltvSynth_zero }

/-! ### pegBand preservation

`pegBand s ε := mainDebt ≤ synth·ltSynth ≤ mainDebt·(1+ε)` — the synthetic tracks the Main debt
within the spec buffer. Its **lower** bound is exactly `principalFloored`; the **upper** bound caps
over-minting. The maintenance re-peg sets `synth·ltSynth = mainDebt·1.005`, so `tick`/`repay`
re-establish `pegBand … 0.005`; `deLever` touches neither `synth` nor `mainDebt`, so it preserves any
band. -/

/-- The maintenance re-peg lands the synthetic in the spec peg band (`ε = 0.005`). -/
theorem maintainPeg_pegBand (s : State) (hd : 0 ≤ s.mainDebt) (hlt : 0 < s.ltSynth) :
    s.maintainPeg.pegBand 0.005 := by
  simp only [pegBand, maintainPeg, mintSynthToPeg]
  have hcancel : s.mainDebt * 1.005 / s.ltSynth * s.ltSynth = s.mainDebt * 1.005 :=
    div_mul_cancel₀ (s.mainDebt * 1.005) (ne_of_gt hlt)
  rw [hcancel]
  have h15 : (1 : ℝ) + 0.005 = 1.005 := by norm_num
  rw [h15]
  exact ⟨by nlinarith [hd], le_refl _⟩

/-- A full maintenance tick re-establishes the peg band. -/
theorem tick_pegBand (s : State) (δ : ℝ)
    (hδ : 0 ≤ δ) (hd : 0 < s.mainDebt) (hlt : 0 < s.ltSynth) :
    (s.tick δ).pegBand 0.005 := by
  unfold tick
  apply maintainPeg_pegBand
  · simp only [accrueInterest]; linarith
  · simpa [accrueInterest] using hlt

/-- A repay-then-repeg re-establishes the peg band (`r ≤ mainDebt` suffices for the band). -/
theorem repay_pegBand (s : State) (r : ℝ)
    (hr : r ≤ s.mainDebt) (hlt : 0 < s.ltSynth) :
    (s.repay r).pegBand 0.005 := by
  unfold repay
  apply maintainPeg_pegBand
  · simp only; linarith
  · simpa using hlt

/-- `deLever` preserves any peg band — it touches neither `synth`, `mainDebt`, nor `ltSynth`. -/
theorem deLever_pegBand (s : State) (a ε : ℝ) (h : s.pegBand ε) :
    (s.deLever a).pegBand ε := by
  simpa [pegBand, deLever] using h

/-! ### Capstone — the per-step safety bundle

`LoopSafe s t` bundles the invariants the loop maintains at every step: the state is `WellFormed`, the
synthetic sits in the spec peg band (`pegBand … 0.005`, whose lower bound *is* `principalFloored`),
and the sub-loop sits at/above the de-lever trigger. Each transition (`tick`/`repay`/`deLever`)
preserves it, composing the proofs above — and because `WellFormed` is in the bundle, `LoopSafe`
directly implies the never-liquidated guarantee `mainHF ≥ 1` (`LoopSafe_mainHF`). (Note: `freedBacked`
is deliberately *not* in `LoopSafe` — interest accrual raises `mainDebt` while loop equity is fixed, so
it erodes between harvests; it is the redemption-time precondition for `collateral_out_ge_in`, proven
separately.) -/

/-- The per-step safety bundle: `WellFormed`, synthetic in the peg band, loop at/above the trigger. -/
def LoopSafe (s : State) (t : ℝ) : Prop :=
  WellFormed s ∧ s.pegBand 0.005 ∧ s.subLoopHealthy t

/-- `principalFloored` is the lower edge of the bundled peg band. -/
theorem LoopSafe_principalFloored (s : State) (t : ℝ) (h : s.LoopSafe t) : s.principalFloored :=
  h.2.1.1

/-- **synthConserved** (over-mint cap) is the upper edge of the bundled peg band: the synthetic's
risk-weighted value never exceeds the Main debt by more than the spec buffer (`synth·ltSynth ≤
mainDebt·1.005`). So the bundle covers both directions of §8 `synthConserved`. -/
theorem LoopSafe_synthConserved (s : State) (t : ℝ) (h : s.LoopSafe t) :
    s.synth * s.ltSynth ≤ s.mainDebt * (1 + 0.005) :=
  h.2.1.2

/-- **noSynthBorrow** follows from the bundle: the `WellFormed` conjunct carries `ltvSynth = 0`, so
borrow capacity is exactly the real collateral's — the synthetic unlocks no borrowing. -/
theorem LoopSafe_noSynthBorrow (s : State) (t : ℝ) (h : s.LoopSafe t) :
    s.borrowCapacity = s.coll * s.price * s.ltvColl :=
  synth_adds_no_borrow_power s h.1

/-- The bundle implies the headline never-liquidated guarantee. -/
theorem LoopSafe_mainHF (s : State) (t : ℝ) (h : s.LoopSafe t) : 1 ≤ s.mainHF :=
  floor_main_hf s h.1 h.2.1.1

/-- A full maintenance tick preserves the safety bundle (positivity of `mainDebt`/`ltSynth` comes
from the `WellFormed` conjunct, so no extra hypotheses beyond `δ ≥ 0`). -/
theorem tick_LoopSafe (s : State) (δ t : ℝ) (hδ : 0 ≤ δ) (h : s.LoopSafe t) :
    (s.tick δ).LoopSafe t :=
  ⟨tick_wellFormed s δ h.1 hδ,
   tick_pegBand s δ hδ h.1.mainDebt_pos h.1.ltSynth_pos,
   tick_subLoopHealthy s δ t h.2.2⟩

/-- A partial repay-then-repeg (`r < mainDebt`) preserves the safety bundle. -/
theorem repay_LoopSafe (s : State) (r t : ℝ)
    (hr : r < s.mainDebt) (h : s.LoopSafe t) :
    (s.repay r).LoopSafe t :=
  ⟨repay_wellFormed s r h.1 hr,
   repay_pegBand s r (le_of_lt hr) h.1.ltSynth_pos,
   repay_subLoopHealthy s r t h.2.2⟩

/-- A de-lever step on a solvent loop preserves the safety bundle (WellFormed + peg band invariant,
trigger raised). -/
theorem deLever_LoopSafe (s : State) (a t : ℝ)
    (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (hδpos : 0 < a * s.primePrice) (hδlt : a * s.primePrice < s.subDebt)
    (hsolvent : s.subDebt ≤ s.primeAmt * s.primePrice) (h : s.LoopSafe t) :
    (s.deLever a).LoopSafe t :=
  ⟨deLever_wellFormed s a h.1,
   deLever_pegBand s a 0.005 h.2.1,
   deLever_subLoopHealthy s a t hlt hD hδpos hδlt hsolvent h.2.2⟩

/-! ### Cross-preservation: redemption ↔ loop

The redemption ops (`requestRedeem`/`claimShares`) touch only `shares`/`escrowShares`, so they leave
every `LoopSafe` field fixed; the maintenance/unwind ops touch only Main/loop fields, so they leave
`escrowOk` fixed. These trivial-invariance lemmas let the two safety properties travel together. -/

theorem deLever_escrowOk (s : State) (a : ℝ) (h : s.escrowOk) : (s.deLever a).escrowOk := by
  simpa [escrowOk, deLever] using h

theorem tick_escrowOk (s : State) (δ : ℝ) (h : s.escrowOk) : (s.tick δ).escrowOk := by
  simpa [escrowOk, tick, maintainPeg, mintSynthToPeg, accrueInterest] using h

theorem repay_escrowOk (s : State) (r : ℝ) (h : s.escrowOk) : (s.repay r).escrowOk := by
  simpa [escrowOk, repay, maintainPeg, mintSynthToPeg] using h

theorem requestRedeem_wellFormed (s : State) (x : ℝ) (wf : WellFormed s) :
    WellFormed (s.requestRedeem x) :=
  { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
    ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
    ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
    mainDebt_pos  := wf.mainDebt_pos,  ltvSynth_zero := wf.ltvSynth_zero }

theorem claimShares_wellFormed (s : State) (x : ℝ) (wf : WellFormed s) :
    WellFormed (s.claimShares x) :=
  { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
    ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
    ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
    mainDebt_pos  := wf.mainDebt_pos,  ltvSynth_zero := wf.ltvSynth_zero }

/-- Requesting a redemption (escrowing shares) preserves the loop safety bundle. -/
theorem requestRedeem_LoopSafe (s : State) (t x : ℝ) (h : s.LoopSafe t) :
    (s.requestRedeem x).LoopSafe t := by
  obtain ⟨wf, pb, sh⟩ := h
  refine ⟨requestRedeem_wellFormed s x wf, ?_, ?_⟩
  · simpa [pegBand, requestRedeem] using pb
  · simpa [subLoopHealthy, subHF, requestRedeem] using sh

/-- Claiming (burning escrowed shares) preserves the loop safety bundle. -/
theorem claimShares_LoopSafe (s : State) (t x : ℝ) (h : s.LoopSafe t) :
    (s.claimShares x).LoopSafe t := by
  obtain ⟨wf, pb, sh⟩ := h
  refine ⟨claimShares_wellFormed s x wf, ?_, ?_⟩
  · simpa [pegBand, claimShares] using pb
  · simpa [subLoopHealthy, subHF, claimShares] using sh

/-- **Full safety bundle:** loop safety *and* escrow well-formedness — all six §8 invariants in one
predicate (`WellFormed`, `pegBand` [floor + over-mint cap], `subLoopHealthy` via `LoopSafe`; plus
`escrowOk` [escrow] and `0 ≤ shares` [shareConservation]). -/
def Safe (s : State) (t : ℝ) : Prop := s.LoopSafe t ∧ s.escrowOk

/-- **Genesis is `Safe`.** Every deposit ends by pegging the synthetic (`maintainPeg`). From a
well-formed base position with a healthy sub-loop and clean escrow, that peg step lands in a `Safe`
state: the re-peg establishes `pegBand` and keeps `WellFormed`, while the loop fields and escrow are
untouched. This is the seed `run_Safe` carries forward through every subsequent operation. -/
theorem maintainPeg_Safe (s : State) (t : ℝ)
    (wf : WellFormed s) (hhealthy : s.subLoopHealthy t) (hesc : s.escrowOk) :
    s.maintainPeg.Safe t := by
  refine ⟨⟨maintainPeg_wellFormed s wf,
           maintainPeg_pegBand s wf.mainDebt_pos.le wf.ltSynth_pos, ?_⟩, ?_⟩
  · unfold subLoopHealthy at *; rwa [maintainPeg_subHF]
  · simpa [escrowOk, maintainPeg, mintSynthToPeg] using hesc

/-! ### `freedBacked` preservation

`freedBacked s := mainDebt ≤ loopEquity` — the loop's value-stable equity covers the Main HOLLAR debt
(the redemption-time precondition for `collateral_out_ge_in`). Unlike the other invariants it is *not*
unconditionally preserved: `tick` accrues interest (raises `mainDebt`) while loop equity is fixed, so it
holds only while the accrued debt stays covered (`mainDebt + δ ≤ loopEquity` — the keeper's backing
obligation). `repay` with `0 ≤ r` only lowers the debt, so it helps; `deLever` keeps equity invariant
(`deLever_freedBacked`); the redemption ops touch neither side. -/

theorem tick_freedBacked (s : State) (δ : ℝ) (hbk : s.mainDebt + δ ≤ s.loopEquity) :
    (s.tick δ).freedBacked := by
  unfold freedBacked
  have hd : (s.tick δ).mainDebt = s.mainDebt + δ := by
    simp [tick, maintainPeg, mintSynthToPeg, accrueInterest]
  have he : (s.tick δ).loopEquity = s.loopEquity := by
    simp [loopEquity, tick, maintainPeg, mintSynthToPeg, accrueInterest]
  rw [hd, he]; exact hbk

theorem repay_freedBacked (s : State) (r : ℝ) (hr0 : 0 ≤ r) (h : s.freedBacked) :
    (s.repay r).freedBacked := by
  unfold freedBacked at *
  have hd : (s.repay r).mainDebt = s.mainDebt - r := by
    simp [repay, maintainPeg, mintSynthToPeg]
  have he : (s.repay r).loopEquity = s.loopEquity := by
    simp [loopEquity, repay, maintainPeg, mintSynthToPeg]
  rw [hd, he]; linarith

theorem requestRedeem_freedBacked (s : State) (x : ℝ) (h : s.freedBacked) :
    (s.requestRedeem x).freedBacked := by
  simpa [freedBacked, loopEquity, requestRedeem] using h

theorem claimShares_freedBacked (s : State) (x : ℝ) (h : s.freedBacked) :
    (s.claimShares x).freedBacked := by
  simpa [freedBacked, loopEquity, claimShares] using h

theorem maintainPeg_freedBacked (s : State) (h : s.freedBacked) : s.maintainPeg.freedBacked := by
  unfold freedBacked at *
  have hd : s.maintainPeg.mainDebt = s.mainDebt := by simp [maintainPeg, mintSynthToPeg]
  have he : s.maintainPeg.loopEquity = s.loopEquity := by
    simp [loopEquity, maintainPeg, mintSynthToPeg]
  rw [hd, he]; exact h

/-- The full safety bundle **plus** the redemption-backing invariant `freedBacked`. -/
def SafeBacked (s : State) (t : ℝ) : Prop := s.Safe t ∧ s.freedBacked

/-- Genesis with backing: a freshly-pegged position that is additionally `freedBacked` is
`SafeBacked` (the peg step preserves the backing). -/
theorem maintainPeg_SafeBacked (s : State) (t : ℝ)
    (wf : WellFormed s) (hhealthy : s.subLoopHealthy t) (hesc : s.escrowOk) (hbk : s.freedBacked) :
    s.maintainPeg.SafeBacked t :=
  ⟨maintainPeg_Safe s t wf hhealthy hesc, maintainPeg_freedBacked s hbk⟩

/-! ### Loop yield — `freedBacked` is restored by carry

The loop runs a positive carry (aPRIME yield − HOLLAR borrow rate), crediting earned aPRIME to the
position. `accrueLoop g` adds `g ≥ 0` aPRIME — the economic dual of `deLever`. It touches no Main field
and no escrow, so it preserves `WellFormed`/`pegBand`/`escrowOk`; it *raises* `subHF` (more collateral,
same debt); and it raises `loopEquity` by `g·primePrice`, so it preserves `freedBacked` and — given
enough cumulative yield — **restores** it after interest accrual has eroded it. This is what makes the
`validBacked` backing precondition sustainable: the keeper harvests carry to keep the loop covering the
debt. -/

/-- Credit `g` earned aPRIME to the loop (positive-carry yield). -/
noncomputable def accrueLoop (s : State) (g : ℝ) : State :=
  { s with primeAmt := s.primeAmt + g }

/-- Yield raises loop equity by exactly `g·primePrice`. -/
theorem accrueLoop_loopEquity (s : State) (g : ℝ) :
    (s.accrueLoop g).loopEquity = s.loopEquity + g * s.primePrice := by
  simp only [loopEquity, accrueLoop]; ring

theorem accrueLoop_wellFormed (s : State) (g : ℝ) (wf : WellFormed s) :
    WellFormed (s.accrueLoop g) :=
  { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
    ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
    ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
    mainDebt_pos  := wf.mainDebt_pos,  ltvSynth_zero := wf.ltvSynth_zero }

theorem accrueLoop_pegBand (s : State) (g ε : ℝ) (h : s.pegBand ε) : (s.accrueLoop g).pegBand ε := by
  simpa [pegBand, accrueLoop] using h

theorem accrueLoop_escrowOk (s : State) (g : ℝ) (h : s.escrowOk) : (s.accrueLoop g).escrowOk := by
  simpa [escrowOk, accrueLoop] using h

/-- Yield raises the sub-loop health factor (more collateral against the same debt). -/
theorem accrueLoop_raises_subHF (s : State) (g : ℝ)
    (hg : 0 ≤ g) (hp : 0 ≤ s.primePrice) (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt) :
    s.subHF ≤ (s.accrueLoop g).subHF := by
  simp only [subHF, accrueLoop]
  gcongr
  nlinarith [mul_nonneg (mul_nonneg hg hp) hlt]

/-- Yield keeps the loop at/above the trigger (it only raises `subHF`). -/
theorem accrueLoop_subLoopHealthy (s : State) (g t : ℝ)
    (hg : 0 ≤ g) (hp : 0 ≤ s.primePrice) (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (h : s.subLoopHealthy t) : (s.accrueLoop g).subLoopHealthy t := by
  unfold subLoopHealthy at *
  exact le_trans h (accrueLoop_raises_subHF s g hg hp hlt hD)

/-- Yield preserves the loop safety bundle. -/
theorem accrueLoop_LoopSafe (s : State) (g t : ℝ)
    (hg : 0 ≤ g) (hp : 0 ≤ s.primePrice) (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (h : s.LoopSafe t) : (s.accrueLoop g).LoopSafe t :=
  ⟨accrueLoop_wellFormed s g h.1,
   accrueLoop_pegBand s g 0.005 h.2.1,
   accrueLoop_subLoopHealthy s g t hg hp hlt hD h.2.2⟩

/-- Yield preserves `freedBacked` (it only grows the loop equity backing the debt). -/
theorem accrueLoop_freedBacked (s : State) (g : ℝ)
    (hg : 0 ≤ g) (hp : 0 ≤ s.primePrice) (h : s.freedBacked) : (s.accrueLoop g).freedBacked := by
  unfold freedBacked at *
  rw [accrueLoop_loopEquity]
  simp only [accrueLoop]
  nlinarith [h, mul_nonneg hg hp]

/-- **`freedBacked` restored by yield.** Even from a state whose backing was eroded (by interest
accrual), once cumulative yield brings the loop equity back up to the Main debt
(`mainDebt ≤ loopEquity + g·primePrice`), the position is `freedBacked` again. -/
theorem accrueLoop_restores_freedBacked (s : State) (g : ℝ)
    (hcover : s.mainDebt ≤ s.loopEquity + g * s.primePrice) :
    (s.accrueLoop g).freedBacked := by
  unfold freedBacked
  rw [accrueLoop_loopEquity]
  simpa only [accrueLoop] using hcover

end State

/-! ### Reachability — `LoopSafe` is closed under any valid operation sequence

Single-step preservation is not the whole story: we want *every reachable state* safe. Model the
protocol's state-changing actions as an `Op`, with a per-op `valid` precondition (the side-conditions
each transition needs *at the current state*), and `run` them in sequence. `run_LoopSafe` then proves:
from any `LoopSafe` start, executing **any** valid trace lands in a `LoopSafe` state — so with
`LoopSafe_mainHF`, every reachable state is never-liquidated. -/

/-- The state-changing protocol actions in the ℝ-spec — the maintenance/unwind ops plus the two
redemption ops, i.e. the full §6 entrypoint surface. -/
inductive Op
  | tick (δ : ℝ)
  | repay (r : ℝ)
  | deLever (a : ℝ)
  | requestRedeem (x : ℝ)
  | claim (x : ℝ)
  | accrueLoop (g : ℝ)

/-- Apply one operation. -/
noncomputable def Op.apply (s : State) : Op → State
  | .tick δ         => s.tick δ
  | .repay r        => s.repay r
  | .deLever a      => s.deLever a
  | .requestRedeem x => s.requestRedeem x
  | .claim x        => s.claimShares x
  | .accrueLoop g   => s.accrueLoop g

/-- The precondition for an operation to be a legitimate transition *at `s`* (mirrors the on-chain
guards): non-negative interest accrual; strictly-partial repay; a positive value-stable de-lever
slice on a solvent loop; a redemption request within free shares; a claim within escrowed shares. -/
def Op.valid (s : State) : Op → Prop
  | .tick δ   => 0 ≤ δ
  | .repay r  => r < s.mainDebt
  | .deLever a =>
      0 ≤ s.ltPrime ∧ 0 < s.subDebt ∧ 0 < a * s.primePrice ∧
        a * s.primePrice < s.subDebt ∧ s.subDebt ≤ s.primeAmt * s.primePrice
  | .requestRedeem x => 0 ≤ x ∧ s.escrowShares + x ≤ s.shares
  | .claim x => x ≤ s.escrowShares
  | .accrueLoop g => 0 ≤ g ∧ 0 ≤ s.primePrice ∧ 0 ≤ s.ltPrime ∧ 0 < s.subDebt

/-- One valid operation preserves the loop safety bundle (redemption ops preserve it unconditionally,
since they touch no `LoopSafe` field). -/
theorem Op.apply_LoopSafe (s : State) (t : ℝ) (op : Op)
    (hv : op.valid s) (h : s.LoopSafe t) : (op.apply s).LoopSafe t := by
  cases op with
  | tick δ => exact State.tick_LoopSafe s δ t hv h
  | repay r => exact State.repay_LoopSafe s r t hv h
  | deLever a =>
      obtain ⟨h1, h2, h3, h4, h5⟩ := hv
      exact State.deLever_LoopSafe s a t h1 h2 h3 h4 h5 h
  | requestRedeem x => exact State.requestRedeem_LoopSafe s t x h
  | claim x => exact State.claimShares_LoopSafe s t x h
  | accrueLoop g =>
      obtain ⟨hg, hp, hlt, hD⟩ := hv
      exact State.accrueLoop_LoopSafe s g t hg hp hlt hD h

/-- One valid operation preserves `escrowOk` (maintenance/unwind ops touch no escrow field; the
redemption ops carry their own escrow-preservation guards). -/
theorem Op.apply_escrowOk (s : State) (op : Op)
    (hv : op.valid s) (h : s.escrowOk) : (op.apply s).escrowOk := by
  cases op with
  | tick δ => exact State.tick_escrowOk s δ h
  | repay r => exact State.repay_escrowOk s r h
  | deLever a => exact State.deLever_escrowOk s a h
  | requestRedeem x =>
      obtain ⟨hx, hcap⟩ := hv
      exact State.requestRedeem_escrowOk s x hx hcap h
  | claim x => exact State.claimShares_escrowOk s x hv h
  | accrueLoop g => exact State.accrueLoop_escrowOk s g h

/-- One valid operation preserves the **full** safety bundle. -/
theorem Op.apply_Safe (s : State) (t : ℝ) (op : Op)
    (hv : op.valid s) (h : s.Safe t) : (op.apply s).Safe t :=
  ⟨Op.apply_LoopSafe s t op hv h.1, Op.apply_escrowOk s op hv h.2⟩

/-- Run a sequence of operations in order. -/
noncomputable def run (s : State) : List Op → State
  | [] => s
  | op :: ops => run (op.apply s) ops

/-- A trace is valid when each op satisfies its precondition *at the state it executes on*. -/
def runValid (s : State) : List Op → Prop
  | [] => True
  | op :: ops => op.valid s ∧ runValid (op.apply s) ops

/-- **Reachability / transition-system safety.** From any `LoopSafe` state, executing any valid
operation trace lands in a `LoopSafe` state. -/
theorem run_LoopSafe (s : State) (t : ℝ) (ops : List Op)
    (hv : runValid s ops) (h : s.LoopSafe t) : (run s ops).LoopSafe t := by
  induction ops generalizing s with
  | nil => exact h
  | cons op ops ih => exact ih (op.apply s) hv.2 (Op.apply_LoopSafe s t op hv.1 h)

/-- **Whole-protocol safety.** From any `Safe` state, executing any valid trace over the full action
set (maintenance, unwind, **and** redemption) lands in a `Safe` state — all six §8 invariants hold at
every reachable state. -/
theorem run_Safe (s : State) (t : ℝ) (ops : List Op)
    (hv : runValid s ops) (h : s.Safe t) : (run s ops).Safe t := by
  induction ops generalizing s with
  | nil => exact h
  | cons op ops ih => exact ih (op.apply s) hv.2 (Op.apply_Safe s t op hv.1 h)

/-- Every reachable state is never liquidated: `mainHF ≥ 1` after any valid trace. -/
theorem run_mainHF (s : State) (t : ℝ) (ops : List Op)
    (hv : runValid s ops) (h : s.Safe t) : 1 ≤ (run s ops).mainHF :=
  State.LoopSafe_mainHF _ t (run_Safe s t ops hv h).1

/-- **End-to-end safety from genesis.** Starting from a freshly-deposited (pegged) position — a
well-formed base with a healthy loop and clean escrow — *any* valid sequence of protocol operations
leaves the position never liquidated (`mainHF ≥ 1`). Genesis `Safe` (`maintainPeg_Safe`) seeds the
reachability closure (`run_Safe`); no extra hypotheses about reachable states are needed. -/
theorem genesis_run_mainHF (s : State) (t : ℝ) (ops : List Op)
    (wf : WellFormed s) (hhealthy : s.subLoopHealthy t) (hesc : s.escrowOk)
    (hv : runValid s.maintainPeg ops) :
    1 ≤ (run s.maintainPeg ops).mainHF :=
  run_mainHF s.maintainPeg t ops hv (State.maintainPeg_Safe s t wf hhealthy hesc)

/-! ### Threading `freedBacked` through the transition system

`freedBacked` needs a stronger per-op precondition than `Safe` (only `tick` can break it). `validBacked`
strengthens `valid`: `tick` must keep the accrued debt backed (`mainDebt + δ ≤ loopEquity`), and `repay`
must be non-negative; all other ops are unchanged. Every `validBacked` trace is a `valid` trace, so
`SafeBacked := Safe ∧ freedBacked` is closed under `validBacked` traces — and at every such reachable
state the redemption solvency `collateral_out_ge_in` holds. -/

/-- The backing-aware precondition: as `valid`, but `tick` must keep the debt covered and `repay` is
non-negative. -/
def Op.validBacked (s : State) : Op → Prop
  | .tick δ   => 0 ≤ δ ∧ s.mainDebt + δ ≤ s.loopEquity
  | .repay r  => 0 ≤ r ∧ r < s.mainDebt
  | .deLever a =>
      0 ≤ s.ltPrime ∧ 0 < s.subDebt ∧ 0 < a * s.primePrice ∧
        a * s.primePrice < s.subDebt ∧ s.subDebt ≤ s.primeAmt * s.primePrice
  | .requestRedeem x => 0 ≤ x ∧ s.escrowShares + x ≤ s.shares
  | .claim x => x ≤ s.escrowShares
  | .accrueLoop g => 0 ≤ g ∧ 0 ≤ s.primePrice ∧ 0 ≤ s.ltPrime ∧ 0 < s.subDebt

/-- A backing-valid op is in particular `valid`. -/
theorem Op.validBacked_valid (s : State) (op : Op) (h : op.validBacked s) : op.valid s := by
  cases op with
  | tick δ => exact h.1
  | repay r => exact h.2
  | deLever a => exact h
  | requestRedeem x => exact h
  | claim x => exact h
  | accrueLoop g => exact h

/-- One backing-valid op preserves `freedBacked`. -/
theorem Op.apply_freedBacked (s : State) (op : Op)
    (hv : op.validBacked s) (h : s.freedBacked) : (op.apply s).freedBacked := by
  cases op with
  | tick δ => exact State.tick_freedBacked s δ hv.2
  | repay r => exact State.repay_freedBacked s r hv.1 h
  | deLever a => exact State.deLever_freedBacked s a h
  | requestRedeem x => exact State.requestRedeem_freedBacked s x h
  | claim x => exact State.claimShares_freedBacked s x h
  | accrueLoop g =>
      obtain ⟨hg, hp, _, _⟩ := hv
      exact State.accrueLoop_freedBacked s g hg hp h

/-- One backing-valid op preserves the full `SafeBacked` bundle. -/
theorem Op.apply_SafeBacked (s : State) (t : ℝ) (op : Op)
    (hv : op.validBacked s) (h : s.SafeBacked t) : (op.apply s).SafeBacked t :=
  ⟨Op.apply_Safe s t op (Op.validBacked_valid s op hv) h.1,
   Op.apply_freedBacked s op hv h.2⟩

/-- A trace is backing-valid when each op meets its backing-aware precondition at its state. -/
def runValidBacked (s : State) : List Op → Prop
  | [] => True
  | op :: ops => op.validBacked s ∧ runValidBacked (op.apply s) ops

/-- **Whole-protocol safety with backing.** From any `SafeBacked` state, any backing-valid trace lands
in a `SafeBacked` state — all six §8 invariants *and* `freedBacked` hold at every reachable state. -/
theorem run_SafeBacked (s : State) (t : ℝ) (ops : List Op)
    (hv : runValidBacked s ops) (h : s.SafeBacked t) : (run s ops).SafeBacked t := by
  induction ops generalizing s with
  | nil => exact h
  | cons op ops ih => exact ih (op.apply s) hv.2 (Op.apply_SafeBacked s t op hv.1 h)

/-- **Redemption solvency everywhere.** At every state reachable by a backing-valid trace, a full
unwind returns at least the deposited collateral (`collateral_out_ge_in`) — the principal-back
guarantee holds throughout the protocol's life, not just at the seed. -/
theorem run_collateral_out_ge_in (s : State) (t : ℝ) (ops : List Op)
    (hv : runValidBacked s ops) (h : s.SafeBacked t) :
    (run s ops).coll ≤ (run s ops).collateralReturned :=
  State.collateral_out_ge_in _ (run_SafeBacked s t ops hv h).2

/-! ## ICE intents in flight (next version, plan §4)

Entries (deploy, `pokeBorrow`: HOLLAR → aPRIME) and normal unwinds (`_sellForUnwind`: aPRIME → HOLLAR)
go through ICE intents: the input leaves for the pallet at submit, a solver pays the output a block
later and the executor calls back, or the intent expires and the pallet returns the input with no
callback. `pending[lane]` holds at most one intent per lane, keyed by nonce; a permissionless
`reconcile` settles a lane whose outcome has landed (output arrived, or input back). The safety
de-lever keeps the synchronous router (`State.deLever` above).

`IceLoop` is the loop's own book. Each intent counts exactly once: as its input at oracle value while
in flight, then as whatever landed. Idle and in-flight HOLLAR are debt-backed cash; HF math counts
them beside the aPRIME collateral (`effColl`). Proven:
* `submit_equity` / `expire_equity` / `callback_equity` / `reconcile_equity` — submitting, expiring
  and recording an outcome leave equity unchanged; `fill_equity` — a fill moves it by exactly the
  execution difference, `fill_equity_ge` bounded by the slippage allowance, `fill_equity_fair` zero
  at the oracle; `run_equity_noFill` — only fills ever move equity;
* `submit_effHF` / `expire_effHF` / `fill_fair_effHF` / …, `ramp_fill_effHF` — HF math sees an
  entry's HOLLAR in flight as what it buys at the oracle, while Aave's own HF dips
  (`ramp_aaveHF_lt`);
* `submit_deLeverOk_iff` / … — the de-lever precondition (solvent counting debt-backed cash) does
  not change while an intent is in flight; `deLever_raises_effHF` / `deLever_equity`;
* `submit_busy` / `ramp_busy` — a busy lane takes no second intent, so a pending record is never
  overwritten; at most one per lane by construction;
* `callback_stale` / `late_callback` — once a lane's intent is reconciled, a late callback with its
  nonce changes nothing, after any number of further operations; `reconcile_eq_callback` —
  callback and reconcile record the same thing, so whichever lands second is a no-op;
* `naiveEquity_sub_equity` — counting a pending record after its outcome has landed would
  overstate equity by exactly that intent's input until it is recorded;
* `onto_loopEquity` / `onto_subHF` / `deLeverOk_iff_valid` — a quiescent loop is the `State` loop.
-/

/-- An ICE intent as the SubLoop records it in `pending[lane]`. -/
structure Intent where
  /-- the lane nonce carried in the callback data. -/
  nonce    : ℕ
  /-- `true`: HOLLAR → aPRIME (deploy, `pokeBorrow`); `false`: aPRIME → HOLLAR (unwind). -/
  entry    : Bool
  /-- the input the pallet holds. -/
  amountIn : ℝ
  /-- the output floor (`minOut`). -/
  minOut   : ℝ

/-- The pallet's side of a lane's intent. -/
inductive Outcome
  | inFlight
  | filled
  | expired
  deriving DecidableEq

/-- The SubLoop's book with ICE intents in flight. -/
structure IceLoop (Lane : Type*) where
  /-- aPRIME supplied (the loop's collateral). -/
  coll    : ℝ
  /-- idle HOLLAR held by the loop. -/
  cash    : ℝ
  /-- the loop's HOLLAR debt. -/
  debt    : ℝ
  /-- PRIME oracle price in HOLLAR (HOLLAR at par). -/
  price   : ℝ
  /-- PRIME liquidation threshold. -/
  lt      : ℝ
  /-- `pending[lane]`: at most one intent per lane. -/
  pending : Lane → Option Intent
  /-- what the pallet did with each lane's intent. -/
  outcome : Lane → Outcome
  /-- the next nonce. -/
  nonce   : ℕ

-- the section's `[DecidableEq Lane] [Fintype Lane]` are unused by some lemmas; intentional.
set_option linter.unusedSectionVars false

namespace IceLoop

variable {Lane : Type*} [DecidableEq Lane] [Fintype Lane]

/-- an intent's input at oracle value: HOLLAR at par, aPRIME at the PRIME price. -/
def valueIn (L : IceLoop Lane) (i : Intent) : ℝ := if i.entry then i.amountIn else i.amountIn * L.price

/-- an output's oracle value. -/
def valueOut (L : IceLoop Lane) (i : Intent) (out : ℝ) : ℝ := if i.entry then out * L.price else out

/-- what the loop holds: aPRIME at the oracle plus idle HOLLAR. -/
def holdings (L : IceLoop Lane) : ℝ := L.coll * L.price + L.cash

/-- a lane's input while its intent is in flight. -/
def laneValue (L : IceLoop Lane) (l : Lane) : ℝ :=
  match L.pending l with
  | some i => if L.outcome l = .inFlight then L.valueIn i else 0
  | none => 0

/-- every input in flight, at oracle value. -/
def inFlight (L : IceLoop Lane) : ℝ := ∑ l, L.laneValue l

/-- collateral plus debt-backed cash: what HF math and equity count. -/
def effColl (L : IceLoop Lane) : ℝ := L.holdings + L.inFlight

/-- the loop's equity (`totalEquity`): in-flight input included at oracle value. -/
def equity (L : IceLoop Lane) : ℝ := L.effColl - L.debt

/-- the health factor the loop's own math uses. -/
noncomputable def effHF (L : IceLoop Lane) : ℝ := L.effColl * L.lt / L.debt

/-- Aave's health factor: aPRIME collateral only. -/
noncomputable def aaveHF (L : IceLoop Lane) : ℝ := L.coll * L.price * L.lt / L.debt

/-! ### Operations -/

/-- the intent `submit` would record on lane-idle state `L`. -/
def nextIntent (L : IceLoop Lane) (entry : Bool) (amountIn minOut : ℝ) : Intent :=
  ⟨L.nonce, entry, amountIn, minOut⟩

/-- submit an intent on lane `l` (`DcaDispatch.submitIntent`): only on an idle lane; the input
leaves for the pallet. -/
def submit (l : Lane) (entry : Bool) (amountIn minOut : ℝ) (L : IceLoop Lane) : IceLoop Lane :=
  match L.pending l with
  | some _ => L
  | none =>
    { L with coll := L.coll - (if entry then 0 else amountIn)
             cash := L.cash - (if entry then amountIn else 0)
             pending := Function.update L.pending l (some (L.nextIntent entry amountIn minOut))
             outcome := Function.update L.outcome l .inFlight
             nonce := L.nonce + 1 }

/-- borrow `a` HOLLAR: debt and cash rise together. -/
def borrow (a : ℝ) (L : IceLoop Lane) : IceLoop Lane :=
  { L with debt := L.debt + a, cash := L.cash + a }

/-- `pokeBorrow`: wait while the entry lane is busy; otherwise borrow and submit the HOLLAR. -/
def ramp (l : Lane) (a minOut : ℝ) (L : IceLoop Lane) : IceLoop Lane :=
  match L.pending l with
  | some _ => L
  | none => (L.borrow a).submit l true a minOut

/-- a solver fills lane `l`'s intent at or above its floor; the output lands. -/
noncomputable def fill (l : Lane) (out : ℝ) (L : IceLoop Lane) : IceLoop Lane :=
  match L.pending l with
  | some i =>
    if L.outcome l = .inFlight ∧ i.minOut ≤ out then
      { L with coll := L.coll + (if i.entry then out else 0)
               cash := L.cash + (if i.entry then 0 else out)
               outcome := Function.update L.outcome l .filled }
    else L
  | none => L

/-- lane `l`'s intent expires; the pallet returns the input (`cleanup_intent`, no callback). -/
def expire (l : Lane) (L : IceLoop Lane) : IceLoop Lane :=
  match L.pending l with
  | some i =>
    if L.outcome l = .inFlight then
      { L with coll := L.coll + (if i.entry then 0 else i.amountIn)
               cash := L.cash + (if i.entry then i.amountIn else 0)
               outcome := Function.update L.outcome l .expired }
    else L
  | none => L

/-- clear lane `l`'s record. -/
def clear (l : Lane) (L : IceLoop Lane) : IceLoop Lane :=
  { L with pending := Function.update L.pending l none }

/-- `execute` callback: right nonce, a filled intent, output at or above the floor. -/
noncomputable def callback (l : Lane) (n : ℕ) (out : ℝ) (L : IceLoop Lane) : IceLoop Lane :=
  match L.pending l with
  | some i => if i.nonce = n ∧ L.outcome l = .filled ∧ i.minOut ≤ out then L.clear l else L
  | none => L

/-- permissionless `reconcile`: record whatever landed; wait while in flight. -/
def reconcile (l : Lane) (L : IceLoop Lane) : IceLoop Lane :=
  match L.pending l with
  | some _ => if L.outcome l = .inFlight then L else L.clear l
  | none => L

/-- the synchronous safety de-lever: sell `a` aPRIME at the oracle and repay. -/
def deLever (a : ℝ) (L : IceLoop Lane) : IceLoop Lane :=
  { L with coll := L.coll - a, debt := L.debt - a * L.price }

/-- the de-lever precondition, counting debt-backed cash: a positive slice smaller than the debt on a
loop solvent once in-flight and idle HOLLAR are counted. -/
def deLeverOk (L : IceLoop Lane) (a : ℝ) : Prop :=
  0 ≤ L.lt ∧ 0 < L.debt ∧ 0 < a * L.price ∧ a * L.price < L.debt ∧ L.debt ≤ L.effColl

/-! ### Bookkeeping lemmas -/

theorem sum_agree (g g' : Lane → ℝ) (l₀ : Lane) (h : ∀ l, l ≠ l₀ → g' l = g l) :
    ∑ l, g' l = ∑ l, g l - g l₀ + g' l₀ := by
  rw [← Finset.add_sum_erase _ g' (Finset.mem_univ l₀), ← Finset.add_sum_erase _ g (Finset.mem_univ l₀),
    Finset.sum_congr rfl (fun l hl => h l (Finset.ne_of_mem_erase hl))]
  ring

/-- the in-flight total after a change confined to lane `l₀`. -/
theorem inFlight_agree (L L' : IceLoop Lane) (l₀ : Lane) (hpr : L'.price = L.price)
    (hp : ∀ l, l ≠ l₀ → L'.pending l = L.pending l) (ho : ∀ l, l ≠ l₀ → L'.outcome l = L.outcome l) :
    L'.inFlight = L.inFlight - L.laneValue l₀ + L'.laneValue l₀ := by
  unfold inFlight
  apply sum_agree
  intro l hl
  unfold laneValue valueIn
  rw [hp l hl, ho l hl, hpr]

theorem laneValue_none (L : IceLoop Lane) (l : Lane) (h : L.pending l = none) : L.laneValue l = 0 := by
  unfold laneValue; rw [h]

theorem laneValue_some (L : IceLoop Lane) (l : Lane) {i : Intent} (h : L.pending l = some i) :
    L.laneValue l = if L.outcome l = .inFlight then L.valueIn i else 0 := by
  unfold laneValue; rw [h]

/-! ### Equity: submitting, expiring and recording keep it; a fill moves it by the execution -/

/-- `submit` on an idle lane, written out. -/
theorem submit_idle (l : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none) :
    L.submit l e a mo =
      { L with coll := L.coll - (if e then 0 else a)
               cash := L.cash - (if e then a else 0)
               pending := Function.update L.pending l (some (L.nextIntent e a mo))
               outcome := Function.update L.outcome l .inFlight
               nonce := L.nonce + 1 } := by
  simp only [submit, hl]

/-- **In-flight input counts at oracle value**: submitting moves the input from the holdings into
flight without changing collateral-plus-cash. -/
theorem submit_effColl (l : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none) :
    (L.submit l e a mo).effColl = L.effColl := by
  rw [submit_idle l e a mo L hl]
  set L' : IceLoop Lane :=
    { L with coll := L.coll - (if e then 0 else a)
             cash := L.cash - (if e then a else 0)
             pending := Function.update L.pending l (some (L.nextIntent e a mo))
             outcome := Function.update L.outcome l .inFlight
             nonce := L.nonce + 1 } with hL'
  have hfl := inFlight_agree L L' l rfl
    (fun l' hl' => Function.update_of_ne hl' _ _) (fun l' hl' => Function.update_of_ne hl' _ _)
  have h1 : L'.laneValue l = L.valueIn (L.nextIntent e a mo) := by
    rw [laneValue_some L' l (Function.update_self l _ _)]
    rw [if_pos (Function.update_self l _ _)]
    rfl
  unfold effColl
  rw [hfl, laneValue_none L l hl, h1, hL']
  unfold holdings valueIn nextIntent
  cases e <;> simp <;> ring

theorem submit_frame (l : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) :
    (L.submit l e a mo).debt = L.debt ∧ (L.submit l e a mo).lt = L.lt ∧
    (L.submit l e a mo).price = L.price := by
  unfold submit
  split <;> exact ⟨rfl, rfl, rfl⟩

theorem submit_equity (l : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none) :
    (L.submit l e a mo).equity = L.equity := by
  unfold equity
  rw [submit_effColl l e a mo L hl, (submit_frame l e a mo L).1]

/-- the in-flight total grows by exactly the new intent's input. -/
theorem submit_inFlight (l : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none) :
    (L.submit l e a mo).inFlight = L.inFlight + L.valueIn (L.nextIntent e a mo) := by
  have he := submit_effColl l e a mo L hl
  have hh : (L.submit l e a mo).holdings = L.holdings - L.valueIn (L.nextIntent e a mo) := by
    rw [submit_idle l e a mo L hl]
    unfold holdings valueIn nextIntent
    cases e <;> simp <;> ring
  unfold effColl at he
  linarith

/-- **At most one intent per lane**: a busy lane takes no second intent, so a pending record (and
the input it tracks) is never overwritten. -/
theorem submit_busy (l : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) {i : Intent}
    (hl : L.pending l = some i) : L.submit l e a mo = L := by
  simp only [submit, hl]

/-- …and the next ramp step waits for the lane to resolve. -/
theorem ramp_busy (l : Lane) (a mo : ℝ) (L : IceLoop Lane) {i : Intent}
    (hl : L.pending l = some i) : L.ramp l a mo = L := by
  simp only [ramp, hl]

/-- an expiry on an in-flight lane, written out. -/
theorem expire_open (l : Lane) (L : IceLoop Lane) {i : Intent} (hl : L.pending l = some i)
    (ho : L.outcome l = .inFlight) :
    L.expire l = { L with coll := L.coll + (if i.entry then 0 else i.amountIn)
                          cash := L.cash + (if i.entry then i.amountIn else 0)
                          outcome := Function.update L.outcome l .expired } := by
  simp only [expire, hl, if_pos ho]

/-- **Expiry keeps equity**: the pallet returns the input, worth what it was counted at in flight. -/
theorem expire_effColl (l : Lane) (L : IceLoop Lane) : (L.expire l).effColl = L.effColl := by
  rcases hl : L.pending l with _ | i
  · simp only [expire, hl]
  · by_cases ho : L.outcome l = .inFlight
    · rw [expire_open l L hl ho]
      set L' : IceLoop Lane :=
        { L with coll := L.coll + (if i.entry then 0 else i.amountIn)
                 cash := L.cash + (if i.entry then i.amountIn else 0)
                 outcome := Function.update L.outcome l .expired } with hL'
      have hfl := inFlight_agree L L' l rfl (fun _ _ => rfl)
        (fun l' hl' => Function.update_of_ne hl' _ _)
      have h1 : L'.laneValue l = 0 := by
        rw [laneValue_some L' l (show L'.pending l = some i from hl)]
        rw [if_neg (by rw [show L'.outcome l = .expired from Function.update_self l _ _]; decide)]
      unfold effColl
      rw [hfl, laneValue_some L l hl, if_pos ho, h1, hL']
      unfold holdings valueIn
      cases i.entry <;> simp <;> ring
    · simp only [expire, hl, if_neg ho]

theorem expire_frame (l : Lane) (L : IceLoop Lane) :
    (L.expire l).debt = L.debt ∧ (L.expire l).lt = L.lt ∧ (L.expire l).price = L.price := by
  unfold expire
  split
  · split_ifs <;> exact ⟨rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl⟩

theorem expire_equity (l : Lane) (L : IceLoop Lane) : (L.expire l).equity = L.equity := by
  unfold equity; rw [expire_effColl, (expire_frame l L).1]

/-- a fill on an in-flight lane, written out. -/
theorem fill_open (l : Lane) (out : ℝ) (L : IceLoop Lane) {i : Intent} (hl : L.pending l = some i)
    (ho : L.outcome l = .inFlight) (hmin : i.minOut ≤ out) :
    L.fill l out = { L with coll := L.coll + (if i.entry then out else 0)
                            cash := L.cash + (if i.entry then 0 else out)
                            outcome := Function.update L.outcome l .filled } := by
  simp only [fill, hl, if_pos (And.intro ho hmin)]

/-- **A fill moves collateral-plus-cash by exactly the execution difference**: the in-flight input
leaves, the output lands. -/
theorem fill_effColl (l : Lane) (out : ℝ) (L : IceLoop Lane) {i : Intent} (hl : L.pending l = some i)
    (ho : L.outcome l = .inFlight) (hmin : i.minOut ≤ out) :
    (L.fill l out).effColl = L.effColl - L.valueIn i + L.valueOut i out := by
  rw [fill_open l out L hl ho hmin]
  set L' : IceLoop Lane :=
    { L with coll := L.coll + (if i.entry then out else 0)
             cash := L.cash + (if i.entry then 0 else out)
             outcome := Function.update L.outcome l .filled } with hL'
  have hfl := inFlight_agree L L' l rfl (fun _ _ => rfl) (fun l' hl' => Function.update_of_ne hl' _ _)
  have h1 : L'.laneValue l = 0 := by
    rw [laneValue_some L' l (show L'.pending l = some i from hl)]
    rw [if_neg (by rw [show L'.outcome l = .filled from Function.update_self l _ _]; decide)]
  unfold effColl
  rw [hfl, laneValue_some L l hl, if_pos ho, h1, hL']
  unfold holdings valueIn valueOut
  cases i.entry <;> simp <;> ring

theorem fill_frame (l : Lane) (out : ℝ) (L : IceLoop Lane) :
    (L.fill l out).debt = L.debt ∧ (L.fill l out).lt = L.lt ∧ (L.fill l out).price = L.price := by
  unfold fill
  split
  · split_ifs <;> exact ⟨rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl⟩

theorem fill_equity (l : Lane) (out : ℝ) (L : IceLoop Lane) {i : Intent} (hl : L.pending l = some i)
    (ho : L.outcome l = .inFlight) (hmin : i.minOut ≤ out) :
    (L.fill l out).equity = L.equity - L.valueIn i + L.valueOut i out := by
  unfold equity
  rw [fill_effColl l out L hl ho hmin, (fill_frame l out L).1]
  ring

/-- …zero at an oracle-fair fill… -/
theorem fill_equity_fair (l : Lane) (out : ℝ) (L : IceLoop Lane) {i : Intent}
    (hl : L.pending l = some i) (ho : L.outcome l = .inFlight) (hmin : i.minOut ≤ out)
    (hfair : L.valueOut i out = L.valueIn i) : (L.fill l out).equity = L.equity := by
  rw [fill_equity l out L hl ho hmin, hfair]
  ring

/-- …and never worse than the slippage allowance `sl` the floor was set with
(`minOut ≥ oracle × (1 − sl)`). -/
theorem fill_equity_ge (l : Lane) (out sl : ℝ) (L : IceLoop Lane) {i : Intent}
    (hl : L.pending l = some i) (ho : L.outcome l = .inFlight) (hmin : i.minOut ≤ out)
    (hp : 0 ≤ L.price) (hfloor : (1 - sl) * L.valueIn i ≤ L.valueOut i i.minOut) :
    L.equity - sl * L.valueIn i ≤ (L.fill l out).equity := by
  rw [fill_equity l out L hl ho hmin]
  have hmono : L.valueOut i i.minOut ≤ L.valueOut i out := by
    unfold valueOut
    split
    · exact mul_le_mul_of_nonneg_right hmin hp
    · exact hmin
  linarith

/-- recording a landed lane is pure bookkeeping. -/
theorem clear_effColl (l : Lane) (L : IceLoop Lane) (hland : L.outcome l ≠ .inFlight) :
    (L.clear l).effColl = L.effColl := by
  have hfl := inFlight_agree L (L.clear l) l rfl (fun l' hl' => Function.update_of_ne hl' _ _)
    (fun _ _ => rfl)
  have h0 : L.laneValue l = 0 := by
    unfold laneValue
    split
    · rw [if_neg hland]
    · rfl
  have h1 : (L.clear l).laneValue l = 0 :=
    laneValue_none (L.clear l) l (by
      show Function.update L.pending l none l = none
      exact Function.update_self l none L.pending)
  unfold effColl
  rw [hfl, h0, h1, show (L.clear l).holdings = L.holdings from rfl]
  ring

theorem callback_effColl (l : Lane) (n : ℕ) (out : ℝ) (L : IceLoop Lane) :
    (L.callback l n out).effColl = L.effColl := by
  unfold callback
  split
  · split_ifs with h
    · exact clear_effColl l L (by rw [h.2.1]; decide)
    · rfl
  · rfl

theorem reconcile_effColl (l : Lane) (L : IceLoop Lane) : (L.reconcile l).effColl = L.effColl := by
  unfold reconcile
  split
  · split_ifs with h
    · rfl
    · exact clear_effColl l L h
  · rfl

theorem callback_frame (l : Lane) (n : ℕ) (out : ℝ) (L : IceLoop Lane) :
    (L.callback l n out).debt = L.debt ∧ (L.callback l n out).lt = L.lt ∧
    (L.callback l n out).price = L.price := by
  unfold callback
  split
  · split_ifs <;> exact ⟨rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl⟩

theorem reconcile_frame (l : Lane) (L : IceLoop Lane) :
    (L.reconcile l).debt = L.debt ∧ (L.reconcile l).lt = L.lt ∧ (L.reconcile l).price = L.price := by
  unfold reconcile
  split
  · split_ifs <;> exact ⟨rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl⟩

theorem callback_equity (l : Lane) (n : ℕ) (out : ℝ) (L : IceLoop Lane) :
    (L.callback l n out).equity = L.equity := by
  unfold equity; rw [callback_effColl, (callback_frame l n out L).1]

theorem reconcile_equity (l : Lane) (L : IceLoop Lane) : (L.reconcile l).equity = L.equity := by
  unfold equity; rw [reconcile_effColl, (reconcile_frame l L).1]

theorem borrow_effColl (a : ℝ) (L : IceLoop Lane) : (L.borrow a).effColl = L.effColl + a := by
  have hfl : (L.borrow a).inFlight = L.inFlight := rfl
  unfold effColl
  rw [hfl]
  show L.coll * L.price + (L.cash + a) + L.inFlight = L.coll * L.price + L.cash + L.inFlight + a
  ring

theorem borrow_equity (a : ℝ) (L : IceLoop Lane) : (L.borrow a).equity = L.equity := by
  unfold equity
  rw [borrow_effColl]
  show L.effColl + a - (L.debt + a) = _
  ring

theorem deLever_effColl (a : ℝ) (L : IceLoop Lane) :
    (L.deLever a).effColl = L.effColl - a * L.price := by
  have hfl : (L.deLever a).inFlight = L.inFlight := rfl
  unfold effColl
  rw [hfl]
  show (L.coll - a) * L.price + L.cash + L.inFlight = L.coll * L.price + L.cash + L.inFlight - a * L.price
  ring

theorem deLever_equity (a : ℝ) (L : IceLoop Lane) : (L.deLever a).equity = L.equity := by
  unfold equity
  rw [deLever_effColl]
  show L.effColl - a * L.price - (L.debt - a * L.price) = _
  ring

/-! ### HF math: the in-flight HOLLAR is debt-backed cash -/

theorem submit_effHF (l : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none) :
    (L.submit l e a mo).effHF = L.effHF := by
  obtain ⟨hd, hlt, -⟩ := submit_frame l e a mo L
  unfold effHF; rw [submit_effColl l e a mo L hl, hd, hlt]

theorem expire_effHF (l : Lane) (L : IceLoop Lane) : (L.expire l).effHF = L.effHF := by
  obtain ⟨hd, hlt, -⟩ := expire_frame l L
  unfold effHF; rw [expire_effColl, hd, hlt]

theorem callback_effHF (l : Lane) (n : ℕ) (out : ℝ) (L : IceLoop Lane) :
    (L.callback l n out).effHF = L.effHF := by
  obtain ⟨hd, hlt, -⟩ := callback_frame l n out L
  unfold effHF; rw [callback_effColl, hd, hlt]

theorem reconcile_effHF (l : Lane) (L : IceLoop Lane) : (L.reconcile l).effHF = L.effHF := by
  obtain ⟨hd, hlt, -⟩ := reconcile_frame l L
  unfold effHF; rw [reconcile_effColl, hd, hlt]

theorem fill_fair_effHF (l : Lane) (out : ℝ) (L : IceLoop Lane) {i : Intent}
    (hl : L.pending l = some i) (ho : L.outcome l = .inFlight) (hmin : i.minOut ≤ out)
    (hfair : L.valueOut i out = L.valueIn i) : (L.fill l out).effHF = L.effHF := by
  obtain ⟨hd, hlt, -⟩ := fill_frame l out L
  unfold effHF
  rw [fill_effColl l out L hl ho hmin, hfair, hd, hlt, sub_add_cancel]

/-- the HF the loop's math uses is never below Aave's: in-flight and idle HOLLAR only add. -/
theorem aaveHF_le_effHF (L : IceLoop Lane) (hc : 0 ≤ L.cash) (hI : 0 ≤ L.inFlight)
    (hlt : 0 ≤ L.lt) (hD : 0 < L.debt) : L.aaveHF ≤ L.effHF := by
  unfold aaveHF effHF effColl holdings
  apply div_le_div_of_nonneg_right _ hD.le
  apply mul_le_mul_of_nonneg_right _ hlt
  linarith

/-- `pokeBorrow` on an idle lane, written out. -/
theorem ramp_idle (l : Lane) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none) :
    L.ramp l a mo = (L.borrow a).submit l true a mo := by
  simp only [ramp, hl]

/-- a ramp step borrows `a` and sends it in flight: debt and debt-backed cash rise alike, the
aPRIME collateral not yet. -/
theorem ramp_book (l : Lane) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none) :
    (L.ramp l a mo).effColl = L.effColl + a ∧ (L.ramp l a mo).debt = L.debt + a ∧
    (L.ramp l a mo).coll = L.coll ∧ (L.ramp l a mo).price = L.price ∧ (L.ramp l a mo).lt = L.lt := by
  have hl' : (L.borrow a).pending l = none := hl
  rw [ramp_idle l a mo L hl]
  obtain ⟨hd, hlt, hpr⟩ := submit_frame l true a mo (L.borrow a)
  refine ⟨?_, ?_, ?_, hpr, hlt⟩
  · rw [submit_effColl l true a mo _ hl', borrow_effColl]
  · rw [hd]; rfl
  · rw [submit_idle l true a mo _ hl']
    show L.coll - 0 = L.coll
    ring

theorem ramp_equity (l : Lane) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none) :
    (L.ramp l a mo).equity = L.equity := by
  obtain ⟨h1, h2, -⟩ := ramp_book l a mo L hl
  unfold equity; rw [h1, h2]; ring

/-- **The loop's HF in flight is the HF it gets on an oracle-fair fill**, so a de-lever decided while
the entry is in flight matches the resolved position. -/
theorem ramp_fill_effHF (l : Lane) (a mo out : ℝ) (L : IceLoop Lane) (hl : L.pending l = none)
    (hmin : mo ≤ out) (hfair : out * L.price = a) :
    ((L.ramp l a mo).fill l out).effHF = (L.ramp l a mo).effHF := by
  have hl' : (L.borrow a).pending l = none := hl
  set i := (L.borrow a).nextIntent true a mo with hi
  have hR : L.ramp l a mo = (L.borrow a).submit l true a mo := ramp_idle l a mo L hl
  have hp : (L.ramp l a mo).pending l = some i := by
    rw [hR, submit_idle l true a mo _ hl']; exact Function.update_self l _ _
  have ho : (L.ramp l a mo).outcome l = .inFlight := by
    rw [hR, submit_idle l true a mo _ hl']; exact Function.update_self l _ _
  have hpr : (L.ramp l a mo).price = L.price := (ramp_book l a mo L hl).2.2.2.1
  apply fill_fair_effHF l out _ hp ho hmin
  show (if true then out * (L.ramp l a mo).price else out) = (if true then a else a * (L.ramp l a mo).price)
  rw [if_pos rfl, if_pos rfl, hpr, hfair]

/-- **…while Aave's own HF dips in flight**: the debt is there, the aPRIME is not yet. Counting the
in-flight HOLLAR is what keeps the de-lever from firing on a ramp step. -/
theorem ramp_aaveHF_lt (l : Lane) (a mo : ℝ) (L : IceLoop Lane) (hl : L.pending l = none)
    (ha : 0 < a) (hD : 0 < L.debt) (hC : 0 < L.coll * L.price * L.lt) :
    (L.ramp l a mo).aaveHF < L.aaveHF := by
  obtain ⟨-, hd, hc, hpr, hlt⟩ := ramp_book l a mo L hl
  unfold aaveHF
  rw [hd, hc, hpr, hlt]
  exact div_lt_div_of_pos_left hC hD (by linarith)

/-! ### The de-lever precondition accounts for in-flight cash -/

/-- **De-lever raises the loop's HF** when it is solvent counting debt-backed cash. -/
theorem deLever_raises_effHF (a : ℝ) (L : IceLoop Lane) (h : L.deLeverOk a) :
    L.effHF ≤ (L.deLever a).effHF := by
  obtain ⟨hlt, hD, hδpos, hδlt, hsolvent⟩ := h
  have hDδ : 0 < L.debt - a * L.price := by linarith
  unfold effHF
  rw [deLever_effColl, show (L.deLever a).lt = L.lt from rfl,
    show (L.deLever a).debt = L.debt - a * L.price from rfl]
  rw [le_div_iff₀ hDδ, div_mul_eq_mul_div, div_le_iff₀ hD]
  nlinarith [mul_nonneg (mul_nonneg hlt hδpos.le) (sub_nonneg.mpr hsolvent)]

theorem submit_deLeverOk_iff (l : Lane) (e : Bool) (a mo d : ℝ) (L : IceLoop Lane)
    (hl : L.pending l = none) : (L.submit l e a mo).deLeverOk d ↔ L.deLeverOk d := by
  obtain ⟨hd, hlt, hpr⟩ := submit_frame l e a mo L
  unfold deLeverOk; rw [submit_effColl l e a mo L hl, hd, hlt, hpr]

theorem expire_deLeverOk_iff (l : Lane) (d : ℝ) (L : IceLoop Lane) :
    (L.expire l).deLeverOk d ↔ L.deLeverOk d := by
  obtain ⟨hd, hlt, hpr⟩ := expire_frame l L
  unfold deLeverOk; rw [expire_effColl, hd, hlt, hpr]

theorem callback_deLeverOk_iff (l : Lane) (n : ℕ) (out d : ℝ) (L : IceLoop Lane) :
    (L.callback l n out).deLeverOk d ↔ L.deLeverOk d := by
  obtain ⟨hd, hlt, hpr⟩ := callback_frame l n out L
  unfold deLeverOk; rw [callback_effColl, hd, hlt, hpr]

theorem reconcile_deLeverOk_iff (l : Lane) (d : ℝ) (L : IceLoop Lane) :
    (L.reconcile l).deLeverOk d ↔ L.deLeverOk d := by
  obtain ⟨hd, hlt, hpr⟩ := reconcile_frame l L
  unfold deLeverOk; rw [reconcile_effColl, hd, hlt, hpr]

theorem fill_fair_deLeverOk_iff (l : Lane) (out d : ℝ) (L : IceLoop Lane) {i : Intent}
    (hl : L.pending l = some i) (ho : L.outcome l = .inFlight) (hmin : i.minOut ≤ out)
    (hfair : L.valueOut i out = L.valueIn i) : (L.fill l out).deLeverOk d ↔ L.deLeverOk d := by
  obtain ⟨hd, hlt, hpr⟩ := fill_frame l out L
  unfold deLeverOk
  rw [fill_effColl l out L hl ho hmin, hfair, hd, hlt, hpr, sub_add_cancel]

/-! ### Late callbacks -/

/-- a callback carrying a nonce the lane no longer holds does nothing. -/
theorem callback_stale (l : Lane) (n : ℕ) (out : ℝ) (L : IceLoop Lane)
    (h : ∀ j, L.pending l = some j → j.nonce ≠ n) : L.callback l n out = L := by
  unfold callback
  split
  · rename_i j hj
    rw [if_neg (fun hc => h j hj hc.1)]
  · rfl

/-- reconcile clears a lane whose outcome has landed. -/
theorem reconcile_clears (l : Lane) (L : IceLoop Lane) {i : Intent} (hl : L.pending l = some i)
    (hland : L.outcome l ≠ .inFlight) : (L.reconcile l).pending l = none := by
  simp only [reconcile, hl, if_neg hland]
  exact Function.update_self l none L.pending

/-- **Callback and reconcile record the same thing**: on a filled intent at or above its floor both
just clear the lane, so whichever comes second finds nothing to do. -/
theorem reconcile_eq_callback (l : Lane) (out : ℝ) (L : IceLoop Lane) {i : Intent}
    (hl : L.pending l = some i) (hf : L.outcome l = .filled) (hmin : i.minOut ≤ out) :
    L.reconcile l = L.callback l i.nonce out := by
  have hland : L.outcome l ≠ .inFlight := by rw [hf]; decide
  have h1 : L.reconcile l = L.clear l := by simp only [reconcile, hl, if_neg hland]
  have h2 : L.callback l i.nonce out = L.clear l := by
    unfold callback
    rw [hl]
    show (if i.nonce = i.nonce ∧ L.outcome l = .filled ∧ i.minOut ≤ out then L.clear l else L) = L.clear l
    rw [if_pos ⟨rfl, hf, hmin⟩]
  rw [h1, h2]

/-- nonces are fresh: every pending intent's nonce is below the next one. -/
def NonceFresh (L : IceLoop Lane) : Prop := ∀ l i, L.pending l = some i → i.nonce < L.nonce

/-- nonce `n` is dead on lane `l`: already issued, and not the lane's current intent. -/
def Stale (l : Lane) (n : ℕ) (L : IceLoop Lane) : Prop :=
  n < L.nonce ∧ ∀ j, L.pending l = some j → j.nonce ≠ n

/-- the ICE operations on the loop's book. -/
inductive IceOp (Lane : Type*)
  | submit (l : Lane) (entry : Bool) (amountIn minOut : ℝ)
  | ramp (l : Lane) (a minOut : ℝ)
  | fill (l : Lane) (out : ℝ)
  | expire (l : Lane)
  | callback (l : Lane) (n : ℕ) (out : ℝ)
  | reconcile (l : Lane)
  | borrow (a : ℝ)
  | deLever (a : ℝ)

noncomputable def apply (L : IceLoop Lane) : IceOp Lane → IceLoop Lane
  | .submit l e a mo => L.submit l e a mo
  | .ramp l a mo => L.ramp l a mo
  | .fill l out => L.fill l out
  | .expire l => L.expire l
  | .callback l n out => L.callback l n out
  | .reconcile l => L.reconcile l
  | .borrow a => L.borrow a
  | .deLever a => L.deLever a

noncomputable def run (L : IceLoop Lane) : List (IceOp Lane) → IceLoop Lane
  | [] => L
  | op :: ops => run (L.apply op) ops

/-- what `submit` does to one lane's record: nothing, or (on the idle lane) the fresh intent with the
nonce bumped. -/
theorem submit_pending (l l' : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) :
    (L.submit l e a mo).pending l' = L.pending l' ∨
    ((L.submit l e a mo).pending l' = some (L.nextIntent e a mo) ∧
      (L.submit l e a mo).nonce = L.nonce + 1) := by
  rcases hl : L.pending l with _ | i
  · rw [submit_idle l e a mo L hl]
    by_cases h : l' = l
    · subst h; exact Or.inr ⟨Function.update_self _ _ _, rfl⟩
    · exact Or.inl (Function.update_of_ne h _ _)
  · rw [submit_busy l e a mo L hl]; exact Or.inl rfl

theorem submit_nonce (l : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) :
    L.nonce ≤ (L.submit l e a mo).nonce := by
  rcases hl : L.pending l with _ | i
  · rw [submit_idle l e a mo L hl]; exact Nat.le_succ _
  · rw [submit_busy l e a mo L hl]

theorem clear_pending (l l' : Lane) (L : IceLoop Lane) :
    (L.clear l).pending l' = L.pending l' ∨ (L.clear l).pending l' = none := by
  by_cases h : l' = l
  · subst h; exact Or.inr (Function.update_self _ _ _)
  · exact Or.inl (Function.update_of_ne h _ _)

/-- the shape of every operation's effect on one lane's record. -/
def Shaped (L L' : IceLoop Lane) (l' : Lane) : Prop :=
  L.nonce ≤ L'.nonce ∧
  (L'.pending l' = L.pending l' ∨ L'.pending l' = none ∨
    ∃ j, L'.pending l' = some j ∧ L.nonce ≤ j.nonce ∧ j.nonce < L'.nonce)

theorem shaped_refl (L : IceLoop Lane) (l' : Lane) : Shaped L L l' := ⟨le_refl _, Or.inl rfl⟩

theorem submit_shaped (l l' : Lane) (e : Bool) (a mo : ℝ) (L : IceLoop Lane) :
    Shaped L (L.submit l e a mo) l' := by
  refine ⟨submit_nonce l e a mo L, ?_⟩
  rcases submit_pending l l' e a mo L with h | ⟨h, hn⟩
  · exact Or.inl h
  · exact Or.inr (Or.inr ⟨_, h, le_refl _, by rw [hn]; exact Nat.lt_succ_self _⟩)

theorem clear_shaped (l l' : Lane) (L : IceLoop Lane) : Shaped L (L.clear l) l' := by
  rcases clear_pending l l' L with h | h
  · exact ⟨le_refl _, Or.inl h⟩
  · exact ⟨le_refl _, Or.inr (Or.inl h)⟩

/-- **Every operation keeps a lane's record, clears it, or installs a fresh intent** whose nonce was
issued at that step; nonces never go back. -/
theorem apply_shaped (L : IceLoop Lane) (op : IceOp Lane) (l' : Lane) : Shaped L (L.apply op) l' := by
  cases op with
  | submit l e a mo => exact submit_shaped l l' e a mo L
  | ramp l a mo =>
      show Shaped L (L.ramp l a mo) l'
      rcases hl : L.pending l with _ | i
      · rw [ramp_idle l a mo L hl]; exact submit_shaped l l' true a mo (L.borrow a)
      · rw [ramp_busy l a mo L hl]; exact shaped_refl L l'
  | fill l out =>
      show Shaped L (L.fill l out) l'
      unfold fill
      split
      · split_ifs <;> exact ⟨le_refl _, Or.inl rfl⟩
      · exact shaped_refl L l'
  | expire l =>
      show Shaped L (L.expire l) l'
      unfold expire
      split
      · split_ifs <;> exact ⟨le_refl _, Or.inl rfl⟩
      · exact shaped_refl L l'
  | callback l n out =>
      show Shaped L (L.callback l n out) l'
      unfold callback
      split
      · split_ifs
        · exact clear_shaped l l' L
        · exact shaped_refl L l'
      · exact shaped_refl L l'
  | reconcile l =>
      show Shaped L (L.reconcile l) l'
      unfold reconcile
      split
      · split_ifs
        · exact shaped_refl L l'
        · exact clear_shaped l l' L
      · exact shaped_refl L l'
  | borrow a => exact ⟨le_refl _, Or.inl rfl⟩
  | deLever a => exact ⟨le_refl _, Or.inl rfl⟩

theorem apply_nonceFresh (L : IceLoop Lane) (op : IceOp Lane) (h : NonceFresh L) :
    NonceFresh (L.apply op) := by
  intro l' j hj
  obtain ⟨hmono, hcase⟩ := apply_shaped L op l'
  rcases hcase with h1 | h1 | ⟨k, hk, -, hkn⟩
  · exact lt_of_lt_of_le (h l' j (h1 ▸ hj)) hmono
  · rw [h1] at hj; exact absurd hj (by simp)
  · rw [hk] at hj; cases hj; exact hkn

theorem run_nonceFresh (L : IceLoop Lane) (ops : List (IceOp Lane)) (h : NonceFresh L) :
    NonceFresh (L.run ops) := by
  induction ops generalizing L with
  | nil => exact h
  | cons op ops ih => exact ih (L.apply op) (apply_nonceFresh L op h)

theorem apply_stale (L : IceLoop Lane) (op : IceOp Lane) (l : Lane) (n : ℕ) (h : Stale l n L) :
    Stale l n (L.apply op) := by
  obtain ⟨hn, hp⟩ := h
  obtain ⟨hmono, hcase⟩ := apply_shaped L op l
  refine ⟨lt_of_lt_of_le hn hmono, fun j hj => ?_⟩
  rcases hcase with h1 | h1 | ⟨k, hk, hkn, -⟩
  · exact hp j (h1 ▸ hj)
  · rw [h1] at hj; exact absurd hj (by simp)
  · rw [hk] at hj
    cases hj
    exact ne_of_gt (lt_of_lt_of_le hn hkn)

theorem run_stale (L : IceLoop Lane) (ops : List (IceOp Lane)) (l : Lane) (n : ℕ)
    (h : Stale l n L) : Stale l n (L.run ops) := by
  induction ops generalizing L with
  | nil => exact h
  | cons op ops ih => exact ih (L.apply op) (apply_stale L op l n h)

/-- **A late callback after reconcile changes nothing** — immediately, or after any number of further
operations (new intents on the same lane carry later nonces). -/
theorem late_callback (l : Lane) (out : ℝ) (L : IceLoop Lane) {i : Intent} (hfresh : NonceFresh L)
    (hl : L.pending l = some i) (hland : L.outcome l ≠ .inFlight) (ops : List (IceOp Lane)) :
    ((L.reconcile l).run ops).callback l i.nonce out = (L.reconcile l).run ops := by
  apply callback_stale
  have hn : (L.reconcile l).nonce = L.nonce := by
    simp only [reconcile, hl, if_neg hland]; rfl
  have h0 : Stale l i.nonce (L.reconcile l) := by
    refine ⟨by rw [hn]; exact hfresh l i hl, fun j hj => ?_⟩
    rw [reconcile_clears l L hl hland] at hj
    exact absurd hj (by simp)
  exact (run_stale _ ops l i.nonce h0).2

/-! ### Only fills move equity -/

/-- an operation other than a solver fill. -/
def IceOp.noFill : IceOp Lane → Prop
  | .fill _ _ => False
  | _ => True

/-- **Equity moves only at fills**: every other operation — submit, ramp, expiry, callback,
reconcile, borrow, the synchronous de-lever — leaves it unchanged. -/
theorem apply_equity (L : IceLoop Lane) (op : IceOp Lane) (hop : op.noFill) :
    (L.apply op).equity = L.equity := by
  cases op with
  | submit l e a mo =>
      show (L.submit l e a mo).equity = _
      rcases hl : L.pending l with _ | i
      · exact submit_equity l e a mo L hl
      · rw [submit_busy l e a mo L hl]
  | ramp l a mo =>
      show (L.ramp l a mo).equity = _
      rcases hl : L.pending l with _ | i
      · exact ramp_equity l a mo L hl
      · rw [ramp_busy l a mo L hl]
  | fill l out => exact absurd hop id
  | expire l => exact expire_equity l L
  | callback l n out => exact callback_equity l n out L
  | reconcile l => exact reconcile_equity l L
  | borrow a => exact borrow_equity a L
  | deLever a => exact deLever_equity a L

theorem run_equity_noFill (L : IceLoop Lane) (ops : List (IceOp Lane)) (h : ∀ op ∈ ops, op.noFill) :
    (L.run ops).equity = L.equity := by
  induction ops generalizing L with
  | nil => rfl
  | cons op ops ih =>
      show ((L.apply op).run ops).equity = _
      rw [ih (L.apply op) (fun o ho => h o (List.mem_cons_of_mem _ ho)),
        apply_equity L op (h op List.mem_cons_self)]

/-! ### A naive equity view double-counts landed outcomes -/

/-- a lane's input if its record is still pending, landed or not. -/
def pendingValue (L : IceLoop Lane) (l : Lane) : ℝ :=
  match L.pending l with
  | some i => L.valueIn i
  | none => 0

/-- the input of a pending intent whose outcome has already landed in the holdings. -/
def landedValue (L : IceLoop Lane) (l : Lane) : ℝ :=
  match L.pending l with
  | some i => if L.outcome l = .inFlight then 0 else L.valueIn i
  | none => 0

/-- equity counting every pending record as in flight, landed or not. -/
def naiveEquity (L : IceLoop Lane) : ℝ := L.holdings + ∑ l, L.pendingValue l - L.debt

/-- **The naive view overstates equity by every landed-but-unrecorded input**: between a fill (or an
expiry) and its callback (or reconcile) the same value would sit in the holdings and in the record. -/
theorem naiveEquity_sub_equity (L : IceLoop Lane) :
    L.naiveEquity - L.equity = ∑ l, L.landedValue l := by
  have h : ∀ l, L.pendingValue l = L.laneValue l + L.landedValue l := by
    intro l
    unfold pendingValue laneValue landedValue
    split
    · split_ifs <;> ring
    · ring
  unfold naiveEquity equity effColl inFlight
  rw [Finset.sum_congr rfl (fun l _ => h l), Finset.sum_add_distrib]
  ring

/-- right after a fill, the filled lane's input is exactly what the naive view double-counts. -/
theorem fill_landedValue (l : Lane) (out : ℝ) (L : IceLoop Lane) {i : Intent}
    (hl : L.pending l = some i) (ho : L.outcome l = .inFlight) (hmin : i.minOut ≤ out) :
    (L.fill l out).landedValue l = L.valueIn i := by
  rw [fill_open l out L hl ho hmin]
  unfold landedValue
  rw [show ({ L with coll := L.coll + (if i.entry then out else 0)
                     cash := L.cash + (if i.entry then 0 else out)
                     outcome := Function.update L.outcome l .filled } : IceLoop Lane).pending l
      = some i from hl]
  simp only [Function.update_self]
  rw [if_neg (by decide)]
  rfl

/-! ### A quiescent loop is the `State` loop -/

/-- read the loop's fields into a protocol `State`. -/
def onto (s : State) (L : IceLoop Lane) : State :=
  { s with primeAmt := L.coll, primePrice := L.price, ltPrime := L.lt, subDebt := L.debt }

theorem onto_loopEquity (s : State) (L : IceLoop Lane) (hc : L.cash = 0) (hI : L.inFlight = 0) :
    (L.onto s).loopEquity = L.equity := by
  unfold equity effColl holdings State.loopEquity onto
  rw [hc, hI]
  ring

theorem onto_subHF (s : State) (L : IceLoop Lane) (hc : L.cash = 0) (hI : L.inFlight = 0) :
    (L.onto s).subHF = L.effHF := by
  unfold effHF effColl holdings State.subHF onto
  rw [hc, hI, add_zero, add_zero]

theorem onto_deLever (s : State) (a : ℝ) (L : IceLoop Lane) :
    (L.deLever a).onto s = (L.onto s).deLever a := rfl

/-- with nothing in flight and no idle cash the ICE-aware precondition is the original one. -/
theorem deLeverOk_iff_valid (s : State) (a : ℝ) (L : IceLoop Lane) (hc : L.cash = 0)
    (hI : L.inFlight = 0) : L.deLeverOk a ↔ (Op.deLever a).valid (L.onto s) := by
  unfold deLeverOk effColl holdings
  rw [hc, hI, add_zero, add_zero]
  rfl

end IceLoop
end Juicer
