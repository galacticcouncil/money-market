import JuicerLean.FixedPoint.AuditChanges

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.Runtime

def fragmentedDelay (interval maximum : ℕ) (amounts : List ℕ) : ℕ :=
  (amounts.map (fun a => pacingDelay interval a maximum)).sum

theorem fragmented_delay_scaled_bounds (interval maximum : ℕ) (amounts : List ℕ)
    (hm : 0 < maximum) :
    interval * amounts.sum ≤ fragmentedDelay interval maximum amounts * maximum ∧
    fragmentedDelay interval maximum amounts * maximum ≤
      interval * amounts.sum + amounts.length * (maximum - 1) := by
  induction amounts with
  | nil => simp [fragmentedDelay]
  | cons a rest ih =>
    have h := ceilDiv_bounds (interval * a) maximum hm
    simp only [fragmentedDelay, List.map_cons, List.sum_cons, List.length_cons] at *
    simp only [pacingDelay] at *
    have hx : ceilDiv (interval * a) maximum * maximum ≤ interval * a + (maximum - 1) := by omega
    constructor <;> nlinarith [ih.1, ih.2]

theorem fragmented_delay_overhead (interval maximum : ℕ) (amounts : List ℕ)
    (hm : 0 < maximum) :
    pacingDelay interval amounts.sum maximum ≤ fragmentedDelay interval maximum amounts ∧
    fragmentedDelay interval maximum amounts ≤ pacingDelay interval amounts.sum maximum + amounts.length := by
  have h := fragmented_delay_scaled_bounds interval maximum amounts hm
  have htotal := ceilDiv_bounds (interval * amounts.sum) maximum hm
  have hpred : maximum - 1 + 1 = maximum := by omega
  unfold pacingDelay
  constructor <;> nlinarith [h.1, h.2, htotal.1, htotal.2]

theorem pacing_deadline_no_wrap (now interval amount maximum : ℕ)
    (h : now + pacingDelay interval amount maximum < 2^64) :
    pacingNextAt now interval amount maximum = now + pacingDelay interval amount maximum :=
  Nat.mod_eq_of_lt h

theorem mature_queue_progress (now fuel : ℕ) (times : List ℕ)
    (ready : ∀ t ∈ times, t ≤ now) : queueReady now fuel times = min fuel times.length := by
  induction fuel generalizing times with
  | zero => simp [queueReady]
  | succ n ih =>
    cases times with
    | nil => simp [queueReady]
    | cons t rest =>
      have ht := ready t (by simp)
      have hr : ∀ t ∈ rest, t ≤ now := by intro t h; exact ready t (by simp [h])
      simp [queueReady, Nat.not_lt.mpr ht, ih rest hr, Nat.succ_min_succ, Nat.add_comm]

theorem funded_queue_progress (fuel : ℕ) (rows : List (RedemptionState × ℕ))
    (funded : ∀ row ∈ rows, row.1.repaid ≤ row.1.debt ∧ row.1.debt - row.1.repaid ≤ row.2) :
    (settleQueue fuel rows).2 = min fuel rows.length := by
  induction fuel generalizing rows with
  | zero => simp [settleQueue]
  | succ n ih =>
    cases rows with
    | nil => simp [settleQueue]
    | cons row rest =>
      have h := funded row (by simp)
      have he : (settleRedemption row.1 row.2).repaid = row.1.debt := by
        simp only [settleRedemption, min_eq_right h.2]
        omega
      have hr : ∀ r ∈ rest, r.1.repaid ≤ r.1.debt ∧ r.1.debt - r.1.repaid ≤ r.2 :=
        fun r mem => funded r (by simp [mem])
      have hd : (settleRedemption row.1 row.2).debt = row.1.debt := rfl
      simp [settleQueue, he, hd, ih rest hr, Nat.succ_min_succ]

theorem empty_queue_progress (fuel count : ℕ) :
    (settleQueue fuel (List.replicate count (freshRedemption 0 0 0, 0))).2 = min fuel count := by
  have h := funded_queue_progress fuel (List.replicate count (freshRedemption 0 0 0, 0)) (by
    intro r hr
    have he : r = (freshRedemption 0 0 0, 0) := (List.mem_replicate.mp hr).2
    simp [he, freshRedemption])
  simpa using h

end Juicer.Runtime

namespace Juicer.PublicCalls
open Runtime

theorem empty_unwind_accepted (s : State)
    (hs : (unwindNumbers s).shares = 0) (hp : pendingAccounting s = false) :
    unwindHead s = .ok (unwindCommitted s (unwindNumbers s)) := by
  have ho : (unwindNumbers s).owed = 0 := by
    change ceilDiv (activeAssets s * (unwindNumbers s).shares) (activeSupply s) = 0
    simp [hs, ceilDiv]
  have hd : (unwindNumbers s).debt = 0 :=
    (unwindNumbers_redemption s (by simp [hs])).resolve_left (by omega) |>.2
  have hr : (unwindNumbers s).rounding = 0 := by
    change (unwindNumbers s).owed - _ = 0
    simp [ho]
  simp [unwindHead, hs, hp, hd, hr]

theorem empty_public_start_advances (s : State)
    (hp : s.paused = false) (hsp : s.sourcePaused = false)
    (hd : s.delever = 0) (ha : s.activeRemaining = 0)
    (hi : s.unwind < s.requests.size) (ht : (request s s.unwind).eligible ≤ s.time)
    (hs : (unwindNumbers (checkpoint (withUnwind s s.unwind) zeroId zeroId)).shares = 0)
    (hc : pendingAccounting (checkpoint (withUnwind s s.unwind) zeroId zeroId) = false) :
    ∃ next, rawRunCall s ⟨5,0,0,0,1⟩ = .ok (next,0) ∧ next.unwind = s.unwind + 1 := by
  have h := startOne_cursor s s.unwind
  rw [empty_unwind_accepted _ hs hc] at h
  cases he : startOne s s.unwind with
  | error e => rw [he] at h; cases h
  | ok next =>
    refine ⟨withUnwind next (s.unwind + 1), ?_, rfl⟩
    have hm : startMany 1 s s.unwind = .ok (next, s.unwind + 1) := by
      simp [startMany, Nat.not_le.mpr hi, Nat.not_lt.mpr ht, he]
    rw [raw_startUnwinds_factored]
    simp [hp, hsp, hd, ha, hm]
    rfl

theorem empty_settle_advances (s : State)
    (hp : s.paused = false) (hs : s.sourcePaused = false) (hd : s.delever = 0)
    (hi : s.head < s.unwind) (hz : (request s s.head).claim.debt = 0) :
    (settleOne s).1.head = s.head + 1 ∧ (settleOne s).2 = true := by
  simp only [settleOne, hp, hs, hd, hz, bne_self_eq_false,
    Bool.or_false, decide_eq_false (Nat.not_le.mpr hi), Bool.false_eq_true, ↓reduceIte]
  by_cases hr : (request s s.head).claim.repaid = 0
  · simp [hr, finishSettle, settleRedemption, hz]
  · simp only [beq_iff_eq, Ne.symm hr, ↓reduceIte]
    simp [finishSettle, settleRedemption, hz]

theorem paid_target_clears_despite_rounding (target spent debt : ℕ) (h : target ≤ spent) :
    (if debt == 0 then 0 else target - spent) = 0 := by simp [Nat.sub_eq_zero_of_le h]

theorem funded_active_payment_covers_target (s : State)
    (hp : 0 < s.delever)
    (hc : s.delever ≤ (position s 0).cash - (fee s 0).feeLeft)
    (hd : s.delever ≤ mainDebtOf s.debt s.mainUnits (position s 0))
    (hg : s.delever ≤ s.debt) (hl : s.delever ≤ s.repayLimit) :
    s.delever ≤ (pay s 0 s.delever).2.2 := by
  rw [payment_reports_cash_spent]
  simp [paymentNumbers, Nat.ne_of_gt hp, min_eq_right hd, min_eq_right hc,
    min_eq_left hg, min_eq_left hl]

theorem settleOne_delever (s : State) : (settleOne s).1.delever = s.delever := by
  unfold settleOne
  split
  · rfl
  · dsimp only
    split <;> simp only [finishSettle] <;>
      split <;> rfl

theorem settleMany_delever (s : State) (fuel : ℕ) : (settleMany fuel s).delever = s.delever := by
  induction fuel generalizing s with
  | zero => rfl
  | succ n ih =>
    simp only [settleMany]
    split
    · rw [ih, settleOne_delever]
    · exact settleOne_delever s

theorem funded_active_payment_unblocks_queue (s : State)
    (hp : 0 < s.delever)
    (hc : s.delever ≤ (position s 0).cash - (fee s 0).feeLeft)
    (hd : s.delever ≤ mainDebtOf s.debt s.mainUnits (position s 0))
    (hg : s.delever ≤ s.debt) (hl : s.delever ≤ s.repayLimit) :
    (pokeSettleTail s).delever = 0 := by
  have h := funded_active_payment_covers_target s hp hc hd hg hl
  have frame : (pay s 0 s.delever).1.delever = s.delever := rfl
  simp only [pokeSettleTail, settleMany_delever, frame]
  exact paid_target_clears_despite_rounding _ _ _ h

end Juicer.PublicCalls
