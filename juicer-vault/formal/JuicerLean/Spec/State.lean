import Mathlib

/-!
# Juicer — abstract balance-sheet state

A protocol-managed leveraged-yield vault on Hydration. This file models the
*Main leg* (collateral + synthetic, borrows HOLLAR) and the *Sub leg* (the shared
PRIME isolation loop) as a single real-valued balance sheet, plus the derived
Aave quantities (health factor, borrow capacity).

Implementation: `src/CollateralVault.sol`, `src/lib/CompoundLogic.sol` and
`src/lib/SubLoopLogic.sol`; see `formal/SOLIDITY_PARITY.md` for the abstraction boundary. All values are in a common HOLLAR/USD unit; `*Amt`
are token amounts that prices multiply into value. Reals (ℝ) are the *spec* layer;
a `Uint256`/WAD-RAY refinement is Phase 3.
-/

namespace Juicer

/-- Abstract state of one Juicer collateral vault. -/
structure State where
  -- Main leg (collateral + synthetic in one Aave account)
  /-- collateral token amount supplied to Aave (e.g. ETH). -/
  coll : ℝ
  /-- collateral price in HOLLAR/USD. -/
  price : ℝ
  /-- Aave liquidation threshold of the collateral (e.g. 0.80 for ETH). -/
  ltColl : ℝ
  /-- Aave loan-to-value of the collateral (borrow power; e.g. 0.75 for ETH). -/
  ltvColl : ℝ
  /-- synthetic token amount minted and supplied to Aave. -/
  synth : ℝ
  /-- Aave liquidation threshold of the synthetic reserve (≈ 0.98). -/
  ltSynth : ℝ
  /-- Aave loan-to-value of the synthetic reserve (100 bps in the deployment configuration). -/
  ltvSynth : ℝ
  /-- HOLLAR debt of the Main position. -/
  mainDebt : ℝ
  -- Sub leg (the shared PRIME isolation loop)
  /-- aPRIME amount supplied in the loop. -/
  primeAmt : ℝ
  /-- PRIME price (value-stable, ≈ 1). -/
  primePrice : ℝ
  /-- Aave liquidation threshold of PRIME (≈ 0.88). -/
  ltPrime : ℝ
  /-- HOLLAR debt of the loop. -/
  subDebt : ℝ
  -- ERC4626 bookkeeping
  /-- outstanding vault shares. -/
  shares : ℝ
  /-- shares escrowed by pending redemptions. -/
  escrowShares : ℝ

namespace State

/-- Risk-weighted Main collateral value: `coll·price·LTcoll + synth·LTsynth`.
This is exactly what Aave compares against debt for `HF`. -/
def mainCollateralValue (s : State) : ℝ :=
  s.coll * s.price * s.ltColl + s.synth * s.ltSynth

/-- Main-position Aave health factor. Aave liquidates when `mainHF < 1`. -/
noncomputable def mainHF (s : State) : ℝ :=
  s.mainCollateralValue / s.mainDebt

/-- the vault's borrowing budget excludes synthetic, as `CompoundLogic.rebalance` does. -/
def borrowCapacity (s : State) : ℝ := s.coll * s.price * s.ltvColl

/-- aave itself includes the synthetic's nonzero ltv; this is not the vault's budget. -/
def aaveBorrowCapacity (s : State) : ℝ := s.borrowCapacity + s.synth * s.ltvSynth

/-- Sub-loop (PRIME isolation) health factor. -/
noncomputable def subHF (s : State) : ℝ :=
  (s.primeAmt * s.primePrice * s.ltPrime) / s.subDebt

end State

/-- Structural well-formedness: the sign/range facts every reachable state holds.
These are protocol parameters and accounting facts, not assumptions about price. -/
structure WellFormed (s : State) : Prop where
  coll_nonneg    : 0 ≤ s.coll
  price_nonneg   : 0 ≤ s.price
  ltColl_nonneg  : 0 ≤ s.ltColl
  ltColl_le_one  : s.ltColl ≤ 1
  /-- the synthetic reserve LT is ≈ 0.98 > 0. -/
  ltSynth_pos    : 0 < s.ltSynth
  synth_nonneg   : 0 ≤ s.synth
  mainDebt_pos   : 0 < s.mainDebt
  /-- the synthetic reserve ltv may be positive; the vault excludes it from its budget. -/
  ltvSynth_nonneg  : 0 ≤ s.ltvSynth

end Juicer
