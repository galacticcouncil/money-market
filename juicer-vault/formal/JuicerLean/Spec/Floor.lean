import JuicerLean.Spec.Invariants

/-!
# Juicer — headline safety theorems (Phase 1)

The "never liquidated" guarantee, machine-checked:

* `floor_main_hf` — `principalFloored` ⟹ `mainHF ≥ 1`.
* `never_liquidated_at_any_price` — the floor holds at *every* collateral price
  `p ≥ 0`, including `p = 0` (collateral crash to zero).
* `peg_floored` — the spec's mint rule (`synth·LTsynth = mainDebt·k`, `k ≥ 1`)
  establishes `principalFloored`; `k = 1.005` is the spec's buffer.
* `synth_adds_no_borrow_power` / `borrow_indep_of_synth` — the vault excludes synthetic
  from its borrowing budget, even though Aave grants it nonzero borrow capacity.
-/

namespace Juicer
namespace State

/-- **Headline theorem.** If the synthetic floors the debt, the Main health factor
is at least 1 — so Aave never liquidates the principal. -/
theorem floor_main_hf (s : State) (wf : WellFormed s) (h : s.principalFloored) :
    1 ≤ s.mainHF := by
  have hD : 0 < s.mainDebt := wf.mainDebt_pos
  have hcoll : 0 ≤ s.coll * s.price * s.ltColl :=
    mul_nonneg (mul_nonneg wf.coll_nonneg wf.price_nonneg) wf.ltColl_nonneg
  have hN : s.mainDebt ≤ s.mainCollateralValue := by
    unfold mainCollateralValue
    have := h          -- principalFloored : mainDebt ≤ synth * ltSynth
    unfold principalFloored at this
    linarith
  unfold mainHF
  rw [le_div_iff₀ hD, one_mul]
  exact hN

/-- The crucial corollary: the floor is *price-independent*. For **any** collateral
price `p ≥ 0` — including `p = 0`, a total collateral wipeout — the Main position
still has `HF ≥ 1`. This is what a bare max-LTV borrow position can never achieve. -/
theorem never_liquidated_at_any_price
    (s : State) (wf : WellFormed s) (h : s.principalFloored) (p : ℝ) (hp : 0 ≤ p) :
    1 ≤ ({s with price := p} : State).mainHF := by
  apply floor_main_hf
  · exact
      { coll_nonneg    := wf.coll_nonneg
        price_nonneg   := hp
        ltColl_nonneg  := wf.ltColl_nonneg
        ltColl_le_one  := wf.ltColl_le_one
        ltSynth_pos    := wf.ltSynth_pos
        synth_nonneg   := wf.synth_nonneg
        mainDebt_pos   := wf.mainDebt_pos
        ltvSynth_nonneg  := wf.ltvSynth_nonneg }
  · -- principalFloored is unaffected by price
    simpa [principalFloored] using h

/-- The spec's mint rule establishes `principalFloored`. The protocol sets
`synth·LTsynth = mainDebt·k` with the buffer `k = 1.005 ≥ 1`. -/
theorem peg_floored (s : State) (k : ℝ) (hk : 1 ≤ k)
    (hpeg : s.synth * s.ltSynth = s.mainDebt * k) (hd : 0 ≤ s.mainDebt) :
    s.principalFloored := by
  unfold principalFloored
  rw [hpeg]
  nlinarith [hd, hk]

/-- the vault's budget excludes synthetic; `invariant_noSynthBorrow` separately checks zero synthetic debt. -/
theorem synth_adds_no_borrow_power (s : State) (_wf : WellFormed s) :
    s.borrowCapacity = s.coll * s.price * s.ltvColl := rfl

theorem borrow_indep_of_synth (s : State) (_wf : WellFormed s) (x : ℝ) :
    ({s with synth := x} : State).borrowCapacity = s.borrowCapacity := rfl

theorem aave_synthetic_borrow_power (s : State) :
    s.aaveBorrowCapacity - s.borrowCapacity = s.synth * s.ltvSynth := by
  unfold aaveBorrowCapacity
  ring

end State
end Juicer
