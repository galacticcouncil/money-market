import JuicerLean.FixedPoint.Checked
import JuicerLean.FixedPoint.QueueHistories
import JuicerLean.FixedPoint.Lifecycle

namespace Juicer.Runtime

theorem ceilDiv_quotient_remainder (a d : ℕ) (hd : 0 < d) :
    ceilDiv a d = a / d + if a % d = 0 then 0 else 1 := by
  have hb := ceilDiv_bounds a d hd
  have he := Nat.div_add_mod a d
  have hm := Nat.mod_lt a hd
  split_ifs with hz
  · nlinarith
  · have hp : 0 < a % d := by omega
    nlinarith

theorem checkedMulDivUp_nat (a b d result : ℕ) (h : checkedMulDivUp a b d = .ok result) :
    result = ceilDiv (a * b) d := by
  have hr := checkedMulDivUp_refines a b d result h
  rw [hr.2.2, ceilDiv_quotient_remainder _ _ (Nat.pos_of_ne_zero hr.1)]

theorem checkedBorrow_refines (p : MainPosition) (total previous current : ℕ)
    (result : MainPosition × ℕ) (h : checkedBorrow p total previous current = .ok result) :
    result = mainBorrow p total previous current := by
  by_cases ht : total = 0
  · simp [checkedBorrow, ht, checked_bind_eq_ok, checkedSub_ok_iff,
      checkedAdd_ok_iff, checkedMul_ok_iff] at h
    aesop (add simp [mainBorrow, ht])
  · by_cases hp : previous = 0
    · simp [checkedBorrow, ht, hp, checked_bind_eq_ok, checkedSub_ok_iff] at h
    · simp only [checkedBorrow, ht, hp, if_false, checked_bind_eq_ok,
        checkedSub_ok_iff, checkedAdd_ok_iff, checked_pure, Except.ok.injEq] at h
      rcases h with ⟨amount, ha, minted, hm, units, hu, principal, hpr, newTotal, htotal, he⟩
      have hf := checkedMulDivUp_nat amount total previous minted hm
      simp_all [mainBorrow]

theorem checkedRescale_refines (fuel : ℕ) (b result : Book) (limit : ℕ)
    (h : checkedRescale fuel b limit = .ok result) : result = rescale fuel b limit := by
  induction fuel generalizing b result with
  | zero => simpa [checkedRescale, rescale] using h.symm
  | succ fuel ih =>
    by_cases ht : limit < b.total
    · simp only [checkedRescale, ht, if_true, checked_bind_eq_ok, checkedAdd_ok_iff] at h
      rcases h with ⟨scale, hs, hr⟩
      have he := ih _ _ hr
      simpa [rescale, ht, hs.2, checkedShift] using he
    · simpa [checkedRescale, ht, rescale] using h.symm

theorem checked_rescale_finishes (b result : Book) (limit : ℕ) (hb : b.total < 2 ^ 256)
    (h : checkedRescale 4 b limit = .ok result) : result.total ≤ limit := by
  rw [checkedRescale_refines 4 b result limit h]
  exact rescale_four_suffices b limit hb

theorem checked_writeoff_refines (b result : Book) (h : checkedWriteOff b = .ok result) :
    result = { b with total := 0, index := 0, scale := 0, epoch := b.epoch + 1 } ∧
      result.epoch ≤ max256 := by
  simp only [checkedWriteOff, checked_bind_eq_ok, checkedAdd_ok_iff, checked_pure, Except.ok.injEq] at h
  rcases h with ⟨epoch, he, hr⟩
  rcases he with ⟨hb, rfl⟩
  subst result
  exact ⟨rfl, hb⟩

theorem checkedRequiredBacking_refines (d p c fee result : ℕ)
    (h : checkedRequiredBacking d p c fee = .ok result) : result = requiredBacking d p c fee := by
  simp only [checkedRequiredBacking, checked_bind_eq_ok, checkedAdd_ok_iff] at h
  rcases h with ⟨capital, hc, hr⟩
  by_cases hf : fee < 10000
  · simp only [hf, if_true, checked_bind_eq_ok, checkedAdd_ok_iff] at hr
    rcases hr with ⟨gross, hg, hresult⟩
    have he := checkedMulDivUp_nat _ _ _ _ hg
    have hbase : (if c < d then d - c else 0) = d - c := by split_ifs <;> omega
    have hint : (if capital < d then d - p - c else 0) = d - p - c := by
      have := hc.2
      split_ifs <;> omega
    rw [hbase] at hresult
    rw [hint] at he
    simpa only [requiredBacking, hf, if_true, he] using hresult.2
  · simp only [hf, if_false, checked_pure, Except.ok.injEq] at hr
    simp only [requiredBacking, hf, if_false, Nat.add_zero]
    split_ifs at hr <;> omega

theorem checkedAccountUnits_refines (b : Book) (a : Account) (weight result : ℕ)
    (h : checkedAccountUnits b a weight = .ok result) : result = accountUnits b a weight := by
  by_cases he : a.epoch = b.epoch
  all_goals
    simp only [checkedAccountUnits, he, beq_iff_eq, if_true, if_false, checked_bind_eq_ok,
      checkedSub_ok_iff, checkedAdd_ok_iff, checkedMulDiv_ok_iff,
      checked_pure, Except.ok.injEq] at h
    simp only [accountUnits, Bool.false_eq_true, ↓reduceIte, he, beq_iff_eq]
    rcases h with ⟨shift, hshift, delta, hdelta, pending, hpending, all, hall, hr⟩
    simp_all [checkedShift, checkedCeilShift_refines]

theorem checkedBatchSegment_refines (a c t w shares : ℕ) (result : ℕ × ℕ × ℕ)
    (h : checkedBatchSegment a c t w shares = .ok result) :
    result = (w + shares, (batchSegment a c t w shares).1, (batchSegment a c t w shares).2) := by
  simp only [checkedBatchSegment, checked_bind_eq_ok, checkedSub_ok_iff,
    checkedAdd_ok_iff, checkedMulDiv_ok_iff, checked_pure, Except.ok.injEq] at h
  rcases h with ⟨reduction, hr, before, hb, next, hn, after, ha, ca, hca, cb, hcb,
    credited, hcredit, delta, hd, charged, hc, resultEq⟩
  simp_all [batchSegment, batchCash, batchReduction]

theorem checkedClaim_refines (r : RedemptionState) (result : RedemptionState × ℕ × ℕ)
    (h : checkedClaim r = .ok result) : result = claimRedemption r := by
  by_cases hd : r.debt ≤ r.repaid
  all_goals
    simp [checkedClaim, hd, checked_bind_eq_ok, checkedSub_ok_iff, checkedAdd_ok_iff,
      checkedMul_ok_iff, checkedDiv_ok_iff] at h
    aesop (add simp [claimRedemption, hd]) (add safe (by omega))

theorem checked_claim_burn_available (r : RedemptionState) (h : r.valid) (hs : 0 < r.settled) :
    (claimRedemption r).2.2 ≤ r.shares - r.burned := by
  have hb := redemption_burned_bounded (claimRedemption r).1 (redemption_claim_preserves r h hs)
  change r.burned + (claimRedemption r).2.2 ≤ r.shares at hb
  omega

theorem claim_queue_partition (r : RedemptionState) (rest : List RedemptionState)
    (h : r.valid) (hs : 0 < r.settled) :
    ((claimRedemption r).1.shares - (claimRedemption r).1.burned) +
        (rest.map (fun q => q.shares - q.burned)).sum + (claimRedemption r).2.2 =
      (r.shares - r.burned) + (rest.map (fun q => q.shares - q.burned)).sum := by
  have hb := checked_claim_burn_available r h hs
  change r.shares - (r.burned + (claimRedemption r).2.2) + _ + _ = _
  omega

theorem claim_admits_lifecycle {precision : ℕ} (s : Lifecycle precision)
    (r : RedemptionState) (rest : List RedemptionState) (h : r.valid) (hs : 0 < r.settled)
    (hq : s.queued = (r.shares - r.burned) + (rest.map (fun q => q.shares - q.burned)).sum) :
    s.Step { s with
      supply := s.supply - (claimRedemption r).2.2
      queued := s.queued - (claimRedemption r).2.2 } := by
  apply Lifecycle.Step.claim
  have hb := checked_claim_burn_available r h hs
  omega

end Juicer.Runtime
