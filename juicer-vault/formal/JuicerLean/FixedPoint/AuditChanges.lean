import JuicerLean.FixedPoint.Environment
import JuicerLean.FixedPoint.PublicReachability
import JuicerLean.Spec.SubLoop

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.Runtime

theorem first_allocation_prices_whole_fund (before value outside denominator : ℕ) :
    allocationMinted 0 before value outside denominator = before + value := by
  simp [allocationMinted]

theorem first_allocation_covers_new_value (before value outside denominator : ℕ) :
    value ≤ allocationMinted 0 before value outside denominator := by
  simp [allocationMinted]

theorem arrival_threshold_exact (amount : ℕ) :
    arrivalThreshold amount = ceilDiv (99 * amount) 100 := by
  have h := ceilDiv_bounds (99 * amount) 100 (by decide)
  unfold arrivalThreshold
  omega

theorem arrival_threshold_positive (amount : ℕ) (h : 0 < amount) :
    0 < arrivalThreshold amount := by
  unfold arrivalThreshold
  omega

theorem effective_account_preserves_debt (p : Intent)
    (input output price coll debt lt hf cash reserved : ℕ) (unwinding : Bool) :
    (effectiveAccount p input output price coll debt lt hf unwinding cash reserved).2.1 = debt := by
  by_cases hx : effectiveExtra p input output price unwinding cash reserved = 0 <;>
    simp [effectiveAccount, hx]

theorem effective_account_adds_backing (p : Intent)
    (input output price coll debt lt hf cash reserved : ℕ) (unwinding : Bool) :
    coll ≤ (effectiveAccount p input output price coll debt lt hf unwinding cash reserved).1 := by
  by_cases hx : effectiveExtra p input output price unwinding cash reserved = 0 <;>
    simp [effectiveAccount, hx]

theorem effective_hf_gross_interval {Lane : Type*} [Fintype Lane] (L : IceLoop Lane)
    (p : Intent) (input output price coll debt lt hf cash reserved : ℕ) (unwinding : Bool)
    (he : effectiveExtra p input output price unwinding cash reserved ≠ 0)
    (hd : 0 < debt)
    (hb : L.effColl = (coll + effectiveExtra p input output price unwinding cash reserved : ℕ))
    (hlt : L.lt = (lt : ℝ) / 10000) (hdebt : L.debt = debt) :
    ((effectiveAccount p input output price coll debt lt hf unwinding cash reserved).2.2 : ℝ) ≤
      L.grossHF * 10^18 ∧
    L.grossHF * 10^18 <
      ((effectiveAccount p input output price coll debt lt hf unwinding cash reserved).2.2 : ℝ) + 1 := by
  let n := (coll + effectiveExtra p input output price unwinding cash reserved) * lt * 10^14
  have hr : L.grossHF * 10^18 = (n : ℝ) / debt := by
    rw [IceLoop.grossHF, hb, hlt, hdebt]
    dsimp [n]
    push_cast
    ring
  have hlo : ((n / debt : ℕ) : ℝ) * debt ≤ (n : ℝ) := by
    exact_mod_cast Nat.div_mul_le_self n debt
  have hhi : (n : ℝ) < ((n / debt : ℕ) + 1 : ℝ) * debt := by
    have hm := Nat.mod_lt n hd
    have hq := Nat.mod_add_div n debt
    have hh : n < (n / debt + 1) * debt := by nlinarith
    exact_mod_cast hh
  have hD : (0 : ℝ) < debt := by exact_mod_cast hd
  rw [hr]
  simp only [effectiveAccount, he, beq_iff_eq, if_false, Nat.ne_of_gt hd]
  exact ⟨(le_div_iff₀ hD).mpr hlo, (div_lt_iff₀ hD).mpr hhi⟩

theorem pacing_delay_bounded (interval amount maximum : ℕ)
    (hmax : 0 < maximum) (hamount : amount ≤ maximum) :
    pacingDelay interval amount maximum ≤ interval := by
  have h := (ceilDiv_bounds (interval * amount) maximum hmax).2
  have hb := Nat.mul_le_mul_left interval hamount
  unfold pacingDelay
  nlinarith

theorem pacing_full_interval (interval maximum : ℕ) (h : 0 < maximum) :
    pacingDelay interval maximum maximum = interval := by
  have hb := pacing_delay_bounded interval maximum maximum h le_rfl
  have hlo := (ceilDiv_bounds (interval * maximum) maximum h).1
  unfold pacingDelay at hb ⊢
  nlinarith

theorem delever_cash_covers_target (target cash reserved hp pp slippage minimum : ℕ)
    (h : target ≤ cash - reserved) : deleverNeed target cash reserved hp pp slippage minimum = 0 := by
  simp [deleverNeed, h]

theorem delever_sale_meets_minimum (target cash reserved hp pp slippage minimum : ℕ)
    (h : cash - reserved < target) : minimum ≤ deleverNeed target cash reserved hp pp slippage minimum := by
  simp only [deleverNeed, if_neg (by omega : ¬ target ≤ cash - reserved)]
  exact le_max_right _ _

theorem arrival_rejects_old_half_threshold :
    outcome ⟨1,1,100,100,0,0⟩ 50 50 = (1,0) := by decide

theorem arrival_accepts_near_full_refund :
    outcome ⟨1,1,100,100,0,0⟩ 99 0 = (3,0) := by decide

theorem landed_unwind_cash_backs_debt :
    effectiveAccount {} 0 0 (10^8) (100 * 10^8) (80 * 10^8) 8800 0
      true (20 * wad) 0 = (120 * 10^8, 80 * 10^8, 132 * 10^16) := by decide

theorem foreign_flag_keeps_unflagged_prime :
    totalEquity {} 0 0 (10^8) 1 (100 * 10^8) 0 0 0 = 100 * 10^8 + 1 := by decide

end Juicer.Runtime

namespace Juicer.PublicCalls
open Runtime

theorem payment_reports_cash_spent (s : State) (key limit : ℕ) :
    (pay s key limit).2.2 = (paymentNumbers s key limit).spent := rfl

theorem fund_recipient_transfer_rejected (s : State) (caller amount : ℕ)
    (h : caller < 4) : transfer s caller fundId amount = .error 10 := by
  have hv : caller ≠ 5 := by omega
  have hf : caller ≠ 6 := by omega
  simp [transfer, vaultId, fundId, hv, hf]
  rfl

theorem empty_started_redemption_is_valid : (freshRedemption 0 0 0).valid := fresh_empty_redemption_valid

private def emptyRequestInput : State := {
  supply := 1000, assets := 1000, supplied := 1000
  wallets := #[1000,0,0,0,0,0,0,0]
  book := { total := 1 }
  requests := #[{ owner := 0, claim := freshRedemption 0 0 0, account := { units := 1 } }] }

theorem empty_request_input_valid : PublicInvariant emptyRequestInput := by decide

theorem empty_request_advances_both_cursors :
    let started := rawExecute emptyRequestInput ⟨5,0,0,0,1⟩
    let settled := rawExecute started.1 ⟨6,0,0,0,0⟩
    started.2.1 = 0 ∧ settled.2.1 = 0 ∧ settled.1.unwind = 1 ∧ settled.1.head = 1 ∧
      (request settled.1 0).claim.shares = 0 ∧ (request settled.1 0).claim.debt = 0 ∧
      PublicInvariant settled.1 := by decide

theorem fund_recipient_deposit_rolls_back :
    rawExecute ({} : State) ⟨0,0,0,fundId,2000⟩ = ({},10,0) := by rfl

theorem delever_target_uses_cash_despite_rounding :
    let s : State := {
      debt := 1000, mainUnits := 1000, delever := 100, repayLoss := 1
      positions := #[{ units := 1000, principal := 1000, cash := 100 }] }
    (pay s 0 100).2.2 = 100 ∧ s.debt - (pay s 0 100).1.debt = 99 ∧
      (pokeSettleTail s).delever = 0 := by decide

end Juicer.PublicCalls
