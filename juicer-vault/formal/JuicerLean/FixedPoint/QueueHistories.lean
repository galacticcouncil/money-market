import JuicerLean.FixedPoint.Orchestration

namespace Juicer.Runtime

def claimEntitlement (owed debt repaid : ℕ) : ℕ :=
  if repaid == debt then owed else owed * repaid / debt

def RedemptionState.valid (r : RedemptionState) : Prop :=
  0 < r.owed ∧ r.repaid ≤ r.debt ∧
  r.claimed + r.settled ≤ claimEntitlement r.owed r.debt r.repaid ∧
  r.burned = r.shares * r.claimed / r.owed ∧
  (0 < r.settled → r.claimed + r.settled = claimEntitlement r.owed r.debt r.repaid)

theorem claim_entitlement_bounded (o d p : ℕ) (h : p ≤ d) : claimEntitlement o d p ≤ o := by
  unfold claimEntitlement
  split
  · exact le_rfl
  · exact proportional_le o p d h

theorem claim_entitlement_monotone (o d p p' : ℕ) (h : p ≤ p') (hd : p' ≤ d) :
    claimEntitlement o d p ≤ claimEntitlement o d p' := by
  by_cases he : p' = d
  · simpa [claimEntitlement, he] using claim_entitlement_bounded o d p (h.trans hd)
  · have hn : p ≠ d := by omega
    simp only [claimEntitlement, beq_iff_eq, hn, he, ↓reduceIte]
    exact Nat.div_le_div_right (Nat.mul_le_mul_left o h)

theorem redemption_claimed_bounded (r : RedemptionState) (h : r.valid) :
    r.claimed + r.settled ≤ r.owed :=
  h.2.2.1.trans (claim_entitlement_bounded _ _ _ h.2.1)

theorem redemption_burned_bounded (r : RedemptionState) (h : r.valid) : r.burned ≤ r.shares := by
  rw [h.2.2.2.1]
  exact proportional_le _ _ _ (by have := redemption_claimed_bounded r h; omega)

theorem redemption_settle_entitlement (r : RedemptionState) (p : ℕ) (h : r.valid) :
    (settleRedemption r p).claimed + (settleRedemption r p).settled =
      claimEntitlement r.owed r.debt (settleRedemption r p).repaid := by
  have hp := settled_repayment_capped r p h.2.1
  have hm := claim_entitlement_monotone r.owed r.debt r.repaid (settleRedemption r p).repaid
    (by simp [settleRedemption]) hp
  have hc := h.2.2.1
  simp only [settleRedemption, claimEntitlement] at hm hc ⊢
  omega

theorem redemption_settle_preserves (r : RedemptionState) (p : ℕ) (h : r.valid) :
    (settleRedemption r p).valid := by
  have he := redemption_settle_entitlement r p h
  exact ⟨h.1, settled_repayment_capped r p h.2.1, he.le, h.2.2.2.1, fun _ => he⟩

theorem redemption_claim_preserves (r : RedemptionState) (h : r.valid) (hs : 0 < r.settled) :
    (claimRedemption r).1.valid := by
  have he := h.2.2.2.2 hs
  have hc := redemption_claimed_bounded r h
  have hb := redemption_burned_bounded r h
  have hm : r.burned ≤ r.shares * (r.claimed + r.settled) / r.owed := by
    rw [h.2.2.2.1]
    exact Nat.div_le_div_right (Nat.mul_le_mul_left _ (by omega))
  unfold RedemptionState.valid
  simp only [claimRedemption]
  refine ⟨h.1, h.2.1, ?_, ?_, ?_⟩
  · simpa using he.le
  · split_ifs with hd
    · have hd' : r.repaid = r.debt := by have := h.2.1; omega
      have hfull : r.claimed + r.settled = r.owed := by simpa [claimEntitlement, hd'] using he
      simp [hfull, Nat.add_sub_of_le hb, h.1]
    · exact Nat.add_sub_of_le hm
  · simp

inductive RedemptionState.Step : RedemptionState → RedemptionState → Prop
  | settle (r : RedemptionState) (paid : ℕ) : Step r (settleRedemption r paid)
  | claim (r : RedemptionState) (ha : r.active = true) (hs : 0 < r.settled) :
      Step r (claimRedemption r).1

theorem redemption_step_preserves (r r' : RedemptionState) (h : r.valid) (step : r.Step r') : r'.valid := by
  cases step with
  | settle paid => exact redemption_settle_preserves _ paid h
  | claim ha hs => exact redemption_claim_preserves _ h hs

theorem redemption_trace_preserves (r r' : RedemptionState) (h : r.valid)
    (steps : Relation.ReflTransGen RedemptionState.Step r r') : r'.valid := by
  induction steps with
  | refl => exact h
  | tail steps step ih => exact redemption_step_preserves _ _ ih step

def freshRedemption (shares owed debt : ℕ) : RedemptionState :=
  ⟨shares, owed, debt, 0, 0, 0, 0, true⟩

theorem fresh_redemption_valid (shares owed debt : ℕ) (ho : 0 < owed) :
    (freshRedemption shares owed debt).valid := by
  simp [RedemptionState.valid, freshRedemption, ho]

theorem redemption_history_no_overpayment (shares owed debt : ℕ) (r : RedemptionState) (ho : 0 < owed)
    (steps : Relation.ReflTransGen RedemptionState.Step (freshRedemption shares owed debt) r) :
    r.claimed + r.settled ≤ r.owed ∧ r.burned ≤ r.shares := by
  have h := redemption_trace_preserves _ _ (fresh_redemption_valid shares owed debt ho) steps
  exact ⟨redemption_claimed_bounded r h, redemption_burned_bounded r h⟩

theorem final_claim_pays_all (r : RedemptionState) (h : r.valid) (hs : 0 < r.settled)
    (hd : r.debt ≤ r.repaid) :
    (claimRedemption r).1.claimed = r.owed ∧ (claimRedemption r).1.burned = r.shares ∧
      (claimRedemption r).1.active = false := by
  have he := h.2.2.2.2 hs
  have hp : r.repaid = r.debt := by have := h.2.1; omega
  have hc : r.claimed + r.settled = r.owed := by simpa [claimEntitlement, hp] using he
  exact ⟨hc, final_claim_burns_all r hd (redemption_burned_bounded r h)⟩

def settleQueue : ℕ → List (RedemptionState × ℕ) → List RedemptionState × ℕ
  | 0, rows => (rows.map Prod.fst, 0)
  | _ + 1, [] => ([], 0)
  | fuel + 1, (r, paid) :: rest =>
    let r' := settleRedemption r paid
    if r'.debt ≤ r'.repaid then
      let next := settleQueue fuel rest
      (r' :: next.1, next.2 + 1)
    else (r' :: rest.map Prod.fst, 0)

theorem settle_queue_work_bound (fuel : ℕ) (rows : List (RedemptionState × ℕ)) :
    (settleQueue fuel rows).2 ≤ fuel ∧ (settleQueue fuel rows).2 ≤ rows.length := by
  induction fuel generalizing rows with
  | zero => simp [settleQueue]
  | succ fuel ih =>
    cases rows with
    | nil => simp [settleQueue]
    | cons row rest =>
      have h := ih rest
      simp only [settleQueue, List.length_cons]
      split <;> omega

theorem settle_queue_stops_at_unpaid (fuel paid : ℕ) (r : RedemptionState)
    (rest : List (RedemptionState × ℕ)) (h : (settleRedemption r paid).repaid < r.debt) :
    settleQueue (fuel + 1) ((r, paid) :: rest) =
      (settleRedemption r paid :: rest.map Prod.fst, 0) := by
  have hn : ¬ (settleRedemption r paid).debt ≤ (settleRedemption r paid).repaid := Nat.not_le.mpr h
  simp only [settleQueue, hn, ↓reduceIte]

theorem settle_queue_preserves (fuel : ℕ) (rows : List (RedemptionState × ℕ))
    (h : ∀ row ∈ rows, row.1.valid) : ∀ r ∈ (settleQueue fuel rows).1, r.valid := by
  induction fuel generalizing rows with
  | zero => simpa [settleQueue] using h
  | succ fuel ih =>
    cases rows with
    | nil => simp [settleQueue]
    | cons row rest =>
      have hhead := redemption_settle_preserves row.1 row.2 (h row (by simp))
      have hrest : ∀ x ∈ rest, x.1.valid := by intro x hx; exact h x (by simp [hx])
      have hi := ih rest hrest
      simp only [settleQueue]
      split <;> simp_all
      exact hrest

end Juicer.Runtime
