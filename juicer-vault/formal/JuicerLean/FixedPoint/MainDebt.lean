import JuicerLean.FixedPoint.YieldTransitions

namespace Juicer.Runtime

structure MainPosition where
  units : ℕ := 0
  principal : ℕ := 0
  cash : ℕ := 0
  remaining : ℕ := 0
  deriving Repr

structure SourceFee where
  yieldLeft : ℕ := 0
  feeLeft : ℕ := 0
  deriving Repr

def mainDebtOf (debt total : ℕ) (p : MainPosition) : ℕ := fundedOf debt total p.units

def mainBorrow (p : MainPosition) (total previous current : ℕ) : MainPosition × ℕ :=
  let amount := current - previous
  let minted := if total == 0 then amount * wad else ceilDiv (amount * total) previous
  ({ p with units := p.units + minted, principal := p.principal + amount }, total + minted)

theorem mainBorrow_preserves_other_units (p : MainPosition) (t old new : ℕ) (h : p.units ≤ t) :
    (mainBorrow p t old new).2 - (mainBorrow p t old new).1.units = t - p.units := by
  simp only [mainBorrow]
  omega

def mainExit (p : MainPosition) (total debt shares supply claim : ℕ) : MainPosition × MainPosition × ℕ :=
  let units := p.units * shares / supply
  let cash := p.cash * shares / supply
  let principal := p.principal * shares / supply
  let owed := fundedOf debt total units
  ({ p with units := p.units - units, cash := p.cash - cash, principal := p.principal - principal },
   ⟨if owed == 0 then 0 else units, owed, cash, claim⟩,
   if owed == 0 then total - units else total)

theorem mainExit_cash_conserved (p : MainPosition) (t d s supply claim : ℕ) (h : s ≤ supply) :
    (mainExit p t d s supply claim).1.cash + (mainExit p t d s supply claim).2.1.cash = p.cash := by
  simp only [mainExit]
  exact Nat.sub_add_cancel (proportional_le _ _ _ h)

theorem mainExit_units_conserved (p : MainPosition) (t d s supply claim : ℕ)
    (h : s ≤ supply) (hp : p.units ≤ t) :
    (mainExit p t d s supply claim).1.units + (mainExit p t d s supply claim).2.1.units +
      (t - p.units) = (mainExit p t d s supply claim).2.2 := by
  have hx := proportional_le p.units s supply h
  simp only [mainExit]
  split <;> simp_all
  omega

def vestFee (claim principal fee : ℕ) : SourceFee := ⟨claim - principal, min fee (claim - principal)⟩

def settleFee (f : SourceFee) (remaining cost : ℕ) : SourceFee × ℕ :=
  let yieldLeft := f.yieldLeft - min f.yieldLeft cost
  let feeLeft := if f.yieldLeft == 0 then f.feeLeft else f.feeLeft * yieldLeft / f.yieldLeft
  if remaining == 0 then (⟨0, 0⟩, feeLeft) else (⟨yieldLeft, feeLeft⟩, 0)

theorem vested_fee_le_yield (claim principal fee : ℕ) :
    (vestFee claim principal fee).feeLeft ≤ (vestFee claim principal fee).yieldLeft := min_le_right _ _

theorem settleFee_never_increases (f : SourceFee) (r c : ℕ) :
    (settleFee f r c).1.feeLeft + (settleFee f r c).2 ≤ f.feeLeft := by
  have h := proportional_le f.feeLeft (f.yieldLeft - min f.yieldLeft c) f.yieldLeft (Nat.sub_le _ _)
  simp only [settleFee]
  split_ifs <;> simp_all

theorem settleFee_remains_junior (f : SourceFee) (r c : ℕ) (h : f.feeLeft ≤ f.yieldLeft) :
    (settleFee f r c).1.feeLeft ≤ (settleFee f r c).1.yieldLeft := by
  have hp := proportional_le (f.yieldLeft - min f.yieldLeft c) f.feeLeft f.yieldLeft h
  simp only [settleFee]
  split_ifs <;> simp_all [Nat.mul_comm]

theorem unfinished_fee_not_charged (f : SourceFee) (r c : ℕ) (hr : r ≠ 0) :
    (settleFee f r c).2 = 0 := by simp [settleFee, hr]

theorem full_cost_erases_fee (f : SourceFee) (r c : ℕ) (hy : 0 < f.yieldLeft) (hc : f.yieldLeft ≤ c) :
    (settleFee f r c).1.feeLeft = 0 ∧ (settleFee f r c).2 = 0 := by
  simp [settleFee, min_eq_left hc, Nat.ne_of_gt hy]

def batchReduction (amount cost total cursor : ℕ) : ℕ := (amount + cost) * cursor / total

def batchCash (amount cost total cursor : ℕ) : ℕ :=
  batchReduction amount cost total cursor * amount / (amount + cost)

def batchSegment (amount cost total cursor weight : ℕ) : ℕ × ℕ :=
  let before := batchReduction amount cost total cursor
  let after := batchReduction amount cost total (cursor + weight)
  let cash := batchCash amount cost total (cursor + weight) - batchCash amount cost total cursor
  (cash, after - before - cash)

theorem floor_fraction_lipschitz (a d x y : ℕ) (ha : a ≤ d) (hd : 0 < d) (hxy : x ≤ y) :
    y * a / d - x * a / d ≤ y - x := by
  have bound : y * a ≤ x * a + (y - x) * d := by
    have h1 := Nat.mul_le_mul_left (y - x) ha
    have h2 := Nat.sub_add_cancel hxy
    nlinarith
  have h := Nat.div_le_div_right (c := d) bound
  have he : (x * a + (y - x) * d) / d = x * a / d + (y - x) := by
    exact Nat.add_mul_div_right _ _ hd
  rw [he] at h
  omega

theorem batchSegment_conserved (a c t p w : ℕ) (hr : 0 < a + c) :
    (batchSegment a c t p w).1 + (batchSegment a c t p w).2 =
      batchReduction a c t (p + w) - batchReduction a c t p := by
  have hm : batchReduction a c t p ≤ batchReduction a c t (p + w) :=
    Nat.div_le_div_right (Nat.mul_le_mul_left _ (by omega))
  have h := floor_fraction_lipschitz a (a + c)
    (batchReduction a c t p) (batchReduction a c t (p + w)) (by omega) hr hm
  simp only [batchSegment, batchCash]
  omega

def batchCashTrace (a c t : ℕ) : ℕ → List ℕ → ℕ
  | _, [] => 0
  | p, w :: rest => (batchSegment a c t p w).1 + batchCashTrace a c t (p + w) rest

theorem batchCashTrace_telescopes (a c t p : ℕ) (weights : List ℕ) :
    batchCashTrace a c t p weights + batchCash a c t p = batchCash a c t (p + weights.sum) := by
  induction weights generalizing p with
  | nil => simp [batchCashTrace]
  | cons w rest ih =>
    have hm : batchCash a c t p ≤ batchCash a c t (p + w) := by
      apply Nat.div_le_div_right
      apply Nat.mul_le_mul_right
      exact Nat.div_le_div_right (Nat.mul_le_mul_left _ (by omega))
    simp only [batchCashTrace, batchSegment, List.sum_cons]
    have hi := ih (p + w)
    simp only [Nat.add_assoc] at hi
    omega

theorem full_batch_cash_conserved (a c t : ℕ) (weights : List ℕ)
    (ht : 0 < t) (hr : 0 < a + c) (hw : weights.sum = t) :
    batchCashTrace a c t 0 weights = a := by
  have h := batchCashTrace_telescopes a c t 0 weights
  simpa [hw, batchCash, batchReduction, Nat.ne_of_gt ht, hr, Nat.mul_comm] using h

theorem batchSegment_never_overcredits (a c t p w : ℕ) (hr : 0 < a + c)
    (ht : 0 < t) (hbudget : a + c ≤ t) :
    (batchSegment a c t p w).1 + (batchSegment a c t p w).2 ≤ w := by
  rw [batchSegment_conserved _ _ _ _ _ hr]
  have h := floor_fraction_lipschitz (a + c) t p (p + w) hbudget ht (by omega)
  simpa [batchReduction, Nat.mul_comm] using h

def batchCostTrace (a c t : ℕ) : ℕ → List ℕ → ℕ
  | _, [] => 0
  | p, w :: rest => (batchSegment a c t p w).2 + batchCostTrace a c t (p + w) rest

theorem batchTrace_reduction (a c t p : ℕ) (weights : List ℕ) (hr : 0 < a + c) :
    batchCashTrace a c t p weights + batchCostTrace a c t p weights + batchReduction a c t p =
      batchReduction a c t (p + weights.sum) := by
  induction weights generalizing p with
  | nil => simp [batchCashTrace, batchCostTrace]
  | cons w rest ih =>
    have h := batchSegment_conserved a c t p w hr
    have hm : batchReduction a c t p ≤ batchReduction a c t (p + w) :=
      Nat.div_le_div_right (Nat.mul_le_mul_left _ (by omega))
    have hi := ih (p + w)
    simp only [Nat.add_assoc] at hi
    simp only [batchCashTrace, batchCostTrace, List.sum_cons]
    omega

theorem full_batch_cost_conserved (a c t : ℕ) (weights : List ℕ)
    (ht : 0 < t) (hr : 0 < a + c) (hw : weights.sum = t) :
    batchCostTrace a c t 0 weights = c := by
  have h := batchTrace_reduction a c t 0 weights hr
  rw [full_batch_cash_conserved a c t weights ht hr hw] at h
  simp [batchReduction, hw, ht] at h
  omega

def spendable (cash fee : ℕ) : ℕ := cash - min cash fee

def repaymentLimit (active : Bool) (debt principal limit : ℕ) : ℕ :=
  if active && limit != 0 then min debt limit else debt - min principal debt + min (min principal debt) limit

def mainRepay (p : MainPosition) (total liveDebt paid reduced : ℕ) : MainPosition × ℕ :=
  let debt := mainDebtOf liveDebt total p
  let principal := min p.principal debt
  let interest := debt - principal
  let burned := if debt ≤ reduced then p.units else reduced * total / liveDebt
  ({ p with units := p.units - burned
            cash := p.cash - paid
            principal := principal - (if interest < reduced then min principal (reduced - interest) else 0) },
   total - burned)

def payValid (amount paid beforeCash afterCash beforeDebt afterDebt quantum : ℕ) : Prop :=
  paid ≤ amount ∧ afterCash + paid = beforeCash ∧ afterDebt ≤ beforeDebt ∧
  max (beforeDebt - afterDebt) paid - min (beforeDebt - afterDebt) paid ≤ quantum

theorem accepted_pay_conserves_cash (a p bc ac bd ad q : ℕ) (h : payValid a p bc ac bd ad q) :
    ac + p = bc := h.2.1

theorem accepted_pay_bounded_error (a p bc ac bd ad q : ℕ) (h : payValid a p bc ac bd ad q) :
    bd - ad ≤ p + q ∧ p ≤ bd - ad + q := by
  rcases h with ⟨_, _, _, h⟩
  omega

theorem mainRepay_cash_conserved (p : MainPosition) (t d paid reduced : ℕ) (h : paid ≤ p.cash) :
    (mainRepay p t d paid reduced).1.cash + paid = p.cash := by
  exact Nat.sub_add_cancel h

theorem mainRepay_clears_tail (p : MainPosition) (t d paid reduced : ℕ)
    (h : mainDebtOf d t p ≤ reduced) : (mainRepay p t d paid reduced).1.units = 0 := by
  simp [mainRepay, h]

theorem mainRepay_units_isolated (p : MainPosition) (t d paid reduced : ℕ)
    (hp : p.units ≤ t) (ht : 0 < t) :
    (mainRepay p t d paid reduced).2 - (mainRepay p t d paid reduced).1.units = t - p.units := by
  have hq := (mulDiv_bounds d p.units t ht).1
  dsimp only [mainRepay]
  split
  · omega
  · rename_i hn
    have hr : reduced < d * p.units / t := by
      simpa [mainDebtOf, fundedOf, Nat.ne_of_gt ht] using Nat.lt_of_not_ge hn
    have hb : reduced * t / d ≤ p.units := by
      apply Nat.div_le_of_le_mul
      nlinarith
    omega

theorem repaymentLimit_bounded (active : Bool) (d p limit : ℕ) :
    repaymentLimit active d p limit ≤ d := by
  simp only [repaymentLimit]
  split
  · exact min_le_left _ _
  · omega

theorem spendable_protects_fee (cash fee : ℕ) : spendable cash fee + min cash fee = cash := by
  exact Nat.sub_add_cancel (min_le_left _ _)

def reserveDraw (active : Bool) (reserve remaining debt principal limit cash fee quantum : ℕ) : ℕ :=
  if active || reserve == 0 || remaining != 0 then 0 else
  let wanted := debt - min principal debt + min (min principal debt) limit
  let available := spendable cash fee
  if wanted ≤ available then 0 else min reserve (wanted - available + quantum)

theorem reserveDraw_bounded (a : Bool) (r rem d p l c f q : ℕ) :
    reserveDraw a r rem d p l c f q ≤ r := by
  simp only [reserveDraw]
  split_ifs <;> simp_all

theorem active_cannot_draw_reserve (r rem d p l c f q : ℕ) :
    reserveDraw true r rem d p l c f q = 0 := by simp [reserveDraw]

theorem unfinished_cannot_draw_reserve (a : Bool) (r rem d p l c f q : ℕ) (h : rem ≠ 0) :
    reserveDraw a r rem d p l c f q = 0 := by simp [reserveDraw, h]

end Juicer.Runtime
