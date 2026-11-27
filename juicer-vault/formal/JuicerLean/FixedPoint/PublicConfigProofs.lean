import JuicerLean.FixedPoint.PublicReachability

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem band_bounds (s : State) :
    0 < s.band.relever ∧ 0 < s.band.delever ∧ s.band.gap ≤ 5000 ∧ s.band.relever ≤ 5000 ∧
      s.band.delever ≤ 2500 := by
  obtain ⟨h1, h2, h3, h4, h5⟩ := s.band.valid
  exact ⟨Nat.pos_of_ne_zero h1, Nat.pos_of_ne_zero h2, h3, h4, h5⟩

theorem admission_le (s : State) : s.admission.val ≤ 10000 := Nat.lt_succ_iff.mp s.admission.isLt

theorem setBand_accepts (s : State) (caller a b n : Nat) :
    (∃ t v, rawRunCall s ⟨31, caller, a, b, n⟩ = .ok (t, v)) ↔
      (a = 0 ∧ b = 0 ∧ n = 0) ∨ (b ≠ 0 ∧ n ≠ 0 ∧ a ≤ 5000 ∧ b ≤ 5000 ∧ n ≤ 2500) := by
  rw [rawRunCall_setBand]
  by_cases hz : a = 0 ∧ b = 0 ∧ n = 0
  · obtain ⟨rfl, rfl, rfl⟩ := hz
    simp
  · have hz' : (a == 0 && b == 0 && n == 0) = false := by
      simp only [Bool.and_eq_false_iff, beq_eq_false_iff_ne]
      omega
    simp only [hz', Bool.false_eq_true, ite_false, hz, false_or]
    split
    · next h => exact ⟨fun _ => h, fun _ => ⟨_, _, rfl⟩⟩
    · next h => exact ⟨fun ⟨_, _, e⟩ => (nomatch e), fun h' => absurd h' h⟩

theorem setBand_reads (s t : State) (caller a b n v : Nat)
    (h : rawRunCall s ⟨31, caller, a, b, n⟩ = .ok (t, v)) :
    t = { s with band := t.band } ∧
      (t.band.gap, t.band.relever, t.band.delever) = if b = 0 then (0, 500, 300) else (a, b, n) := by
  rw [rawRunCall_setBand] at h
  split at h
  · next hz =>
    simp only [Bool.and_eq_true, beq_iff_eq] at hz
    obtain ⟨⟨_, rfl⟩, _⟩ := hz
    cases h
    exact ⟨rfl, rfl⟩
  · split at h
    · next hb =>
      cases h
      exact ⟨rfl, by simp [hb.1]⟩
    · cases h

theorem setAdmission_accepts (s : State) (caller a b n : Nat) :
    (∃ t v, rawRunCall s ⟨32, caller, a, b, n⟩ = .ok (t, v)) ↔ n ≤ 10000 := by
  rw [rawRunCall_setAdmission]
  split
  · next h => exact ⟨fun _ => h, fun _ => ⟨_, _, rfl⟩⟩
  · next h => exact ⟨fun ⟨_, _, e⟩ => (nomatch e), fun h' => absurd h' h⟩

theorem setAdmission_reads (s t : State) (caller a b n v : Nat)
    (h : rawRunCall s ⟨32, caller, a, b, n⟩ = .ok (t, v)) :
    t = { s with admission := t.admission } ∧ t.admission.val = n := by
  rw [rawRunCall_setAdmission] at h
  split at h
  · cases h
    exact ⟨rfl, rfl⟩
  · cases h

def coll8 (s : State) : Nat := s.supplied * s.price / wad / 10^10

def rebalanceLtv (s : State) : Nat := s.debt / 10^10 * 10000 / coll8 s

def bandTarget (s : State) : Nat := coll8 s * targetLtv s / 10000

theorem pay_debt_le (s : State) (key limit : Nat) : (pay s key limit).1.debt ≤ s.debt := by
  unfold pay
  exact Nat.sub_le _ _

theorem rebalanceTail_quiet (s : State) (hr : s.reinvest = 0)
    (low : targetLtv s ≤ rebalanceLtv s + s.band.relever)
    (high : rebalanceLtv s ≤ targetLtv s + s.band.delever) :
    rebalanceTail s = .ok (s, 0) := by
  unfold rebalanceLtv coll8 at low high
  unfold rebalanceTail
  split
  · rfl
  · dsimp only
    split
    · rfl
    · split
      · next hc =>
        simp only [hr, bne_self_eq_false, Bool.false_and, Bool.or_false, Bool.and_eq_true,
          Bool.not_eq_true', decide_eq_true_eq] at hc
        omega
      · split
        · next hc =>
          simp only [Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq] at hc
          omega
        · rfl

theorem borrowResult_bounds (s t : State) (amount v : Nat) (h : borrowResult s amount = .ok (t, v)) :
    t.debt ≤ s.debt + amount ∧ (s.debt < t.debt → t.debt ≤ t.synth * 9800 / 10000) := by
  unfold borrowResult at h
  dsimp only at h
  split at h
  · cases h
    omega
  · split at h
    · cases h
    · split at h
      · cases h
      · next hguard =>
        cases h
        simp only [borrowSource]
        constructor
        · omega
        · intro _
          omega

theorem rebalanceEnter_bounds (s t : State) (resize : Bool) (c d target v : Nat)
    (h : rebalanceEnter s resize c d target = .ok (t, v)) :
    t.debt ≤ s.debt + (target - d) * 10^10 ∧ (s.debt < t.debt → t.debt ≤ t.synth * 9800 / 10000) := by
  unfold rebalanceEnter at h
  split at h
  · cases h
  · rw [borrowResult_factored] at h
    have hpay := pay_debt_le s 0 0
    dsimp only at h
    split at h
    · obtain ⟨hdebt, hfloor⟩ := borrowResult_bounds _ _ _ _ h
      exact ⟨by simp only at hdebt; omega, fun hlt => hfloor (lt_of_le_of_lt hpay hlt)⟩
    · obtain ⟨hdebt, hfloor⟩ := borrowResult_bounds _ _ _ _ h
      exact ⟨by simp only at hdebt; omega, fun hlt => hfloor (lt_of_le_of_lt hpay hlt)⟩

theorem borrowResult_held (s t : State) (amount v : Nat) (h : borrowResult s amount = .ok (t, v)) :
    s.held ≤ t.held := by
  unfold borrowResult at h
  dsimp only at h
  split at h
  · cases h; exact le_rfl
  · split at h
    · cases h
    · split at h
      · cases h
      · cases h
        simp only [borrowSource, depositSource, depositSourceState, mintMainPosition, setPosition]
        exact Nat.le_add_right _ _

theorem rebalanceEnter_held (s t : State) (resize : Bool) (c d target v : Nat)
    (h : rebalanceEnter s resize c d target = .ok (t, v)) : s.held ≤ t.held := by
  unfold rebalanceEnter at h
  split at h
  · cases h
  · rw [borrowResult_factored] at h
    have hp : (pay s 0 0).1.held = s.held := by rw [pay_state_factored]; rfl
    dsimp only at h
    split at h
    · have := borrowResult_held _ _ _ _ h
      simp only at this
      omega
    · have := borrowResult_held _ _ _ _ h
      simp only at this
      omega

theorem activeDelever_debt (s : State) (slice basis : Nat) (f : SourceFee) :
    (addActiveFee (unwindActiveSource s slice basis) f).debt = s.debt := rfl

theorem rebalanceDelever_debt (s t : State) (debt8 target v : Nat)
    (h : rebalanceDelever s debt8 target = .ok (t, v)) : t.debt = s.debt := by
  unfold rebalanceDelever at h
  dsimp only at h
  split at h
  · split at h
    · cases h
    · injection h with h
      injection h with ht
      rw [← ht]
      exact activeDelever_debt _ _ _ _
  · cases h
    rfl

theorem rebalanceTail_borrow (s t : State) (v : Nat) (h : rebalanceTail s = .ok (t, v))
    (up : s.debt < t.debt) :
    t.debt ≤ t.synth * 9800 / 10000 ∧ t.debt / 10^10 ≤ bandTarget s ∧
      (s.reinvest = 0 → rebalanceLtv s + s.band.relever < targetLtv s) := by
  unfold rebalanceTail at h
  split at h
  · cases h; omega
  · dsimp only at h
    split at h
    · cases h; omega
    · split at h
      · next henter =>
        obtain ⟨hdebt, hfloor⟩ := rebalanceEnter_bounds s t _ _ _ _ v h
        refine ⟨hfloor up, ?_, ?_⟩
        · unfold bandTarget coll8
          omega
        · intro hr
          unfold rebalanceLtv coll8
          simp only [hr, bne_self_eq_false, Bool.false_and, Bool.or_false, Bool.and_eq_true,
            Bool.not_eq_true', decide_eq_true_eq] at henter
          exact henter.2
      · split at h
        · rw [rebalanceDelever_debt s t _ _ v h] at up
          omega
        · cases h; omega

theorem rebalanceTail_delever (s t : State) (v : Nat) (h : rebalanceTail s = .ok (t, v))
    (sold : t.held < s.held) :
    targetLtv s + s.band.delever < rebalanceLtv s ∧ t.debt = s.debt := by
  unfold rebalanceTail at h
  split at h
  · cases h; omega
  · dsimp only at h
    split at h
    · cases h; omega
    · split at h
      · exact absurd (rebalanceEnter_held s t _ _ _ _ v h) (by omega)
      · split at h
        · next hlev =>
          refine ⟨?_, rebalanceDelever_debt s t _ _ v h⟩
          unfold rebalanceLtv coll8
          simp only [Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq] at hlev
          exact hlev.2
        · cases h; omega

def SameConfig (s t : State) : Prop := t.band = s.band ∧ t.admission = s.admission

theorem settleOwner_config (s : State) (i : Nat) : SameConfig s (settleOwner s i) := by
  unfold settleOwner
  split <;> exact ⟨rfl, rfl⟩

theorem checkpoint_config (s : State) (a b : Nat) : SameConfig s (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have hn : SameConfig s (if !pendingAccounting s then allocateState s else s) := by
    split <;> exact ⟨rfl, rfl⟩
  have ha := settleOwner_config (if !pendingAccounting s then allocateState s else s) a
  split
  · exact ⟨ha.1.trans hn.1, ha.2.trans hn.2⟩
  · have hb := settleOwner_config (settleOwner (if !pendingAccounting s then allocateState s else s) a) b
    exact ⟨hb.1.trans (ha.1.trans hn.1), hb.2.trans (ha.2.trans hn.2)⟩

theorem pay_config (s : State) (key limit : Nat) : SameConfig s (pay s key limit).1 := by
  rw [pay_state_factored]
  exact ⟨rfl, rfl⟩

theorem depositTailRaw_admitted (c t : State) (caller receiver amount v : Nat)
    (h : depositTailRaw c caller receiver amount = .ok (t, v)) :
    admissionDeficitBps c ≤ c.admission.val := by
  unfold depositTailRaw at h
  dsimp only at h
  split_ifs at h
  all_goals first | cases h | omega

theorem deposit_admitted (s t : State) (caller a b n v : Nat)
    (h : rawRunCall s ⟨0, caller, a, b, n⟩ = .ok (t, v)) :
    admissionDeficitBps (checkpoint { (pay s 0 0).1 with synth := s.synth } zeroId b) ≤
      s.admission.val := by
  have hc : (checkpoint { (pay s 0 0).1 with synth := s.synth } zeroId b).admission = s.admission :=
    (checkpoint_config _ zeroId b).2.trans (pay_config s 0 0).2
  rw [raw_deposit_factored] at h
  split_ifs at h
  have := depositTailRaw_admitted _ _ _ _ _ _ h
  rwa [hc] at this

theorem admission_uncovered_bound (s : State) (bound : Nat) (h : admissionDeficitBps s ≤ bound)
    (hd : mainDebtOf s.debt s.mainUnits (position s 0) ≠ 0) :
    max (mainDebtOf s.debt s.mainUnits (position s 0) - admissionBacking s - activeFunds s)
        (requiredBacking (mainDebtOf s.debt s.mainUnits (position s 0)) (position s 0).principal
          (activeFunds s) s.feeBps - admissionBacking s) * 10000 ≤
      bound * mainDebtOf s.debt s.mainUnits (position s 0) := by
  unfold admissionDeficitBps at h
  dsimp only at h
  rw [if_neg (by simpa only [beq_iff_eq] using hd)] at h
  exact (Runtime.ceilDiv_bounds _ _ (Nat.pos_of_ne_zero hd)).1.trans (Nat.mul_le_mul_right _ h)

theorem raw_rebalance_band (s t : State) (caller a b n v : Nat)
    (h : rawRunCall s ⟨9, caller, a, b, n⟩ = .ok (t, v)) :
    let c := checkpoint s zeroId zeroId
    (c.debt < t.debt → t.debt ≤ t.synth * 9800 / 10000 ∧ t.debt / 10^10 ≤ bandTarget c ∧
      (c.reinvest = 0 → rebalanceLtv c + s.band.relever < targetLtv s)) ∧
    (t.held < c.held → targetLtv s + s.band.delever < rebalanceLtv c ∧ t.debt = c.debt) := by
  intro c
  have hband : c.band = s.band := (checkpoint_config s zeroId zeroId).1
  have hltv : targetLtv c = targetLtv s := by unfold targetLtv; rw [hband]
  rw [raw_rebalance_factored, rebalanceTail_factored] at h
  split at h
  · cases h
  · refine ⟨fun up => ?_, fun sold => ?_⟩
    · obtain ⟨h1, h2, h3⟩ := rebalanceTail_borrow c t v h up
      exact ⟨h1, h2, fun hr => by rw [← hltv, ← hband]; exact h3 hr⟩
    · obtain ⟨h1, h2⟩ := rebalanceTail_delever c t v h sold
      exact ⟨by rw [← hltv, ← hband]; exact h1, h2⟩

theorem launch_config_accepted (s : State) :
    (∃ t v, rawRunCall s ⟨31, 0, 0, 1000, 800⟩ = .ok (t, v)) ∧
      (∃ t v, rawRunCall s ⟨32, 0, 0, 0, 250⟩ = .ok (t, v)) :=
  ⟨(setBand_accepts s 0 0 1000 800).2 (.inr (by decide)), (setAdmission_accepts s 0 0 0 250).2 (by decide)⟩

end Juicer.PublicCalls
