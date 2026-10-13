import JuicerLean.FixedPoint.MainDebt

namespace Juicer.Runtime

structure Policy where
  capacity : ℕ
  refill : ℕ
  credit : ℕ
  updated : ℕ
  expires : ℕ
  minimum : ℕ
  maximum : ℕ
  nextAt : ℕ
  lastBlock : ℕ
  safetyLane : Bool
  activeGroup : Bool
  deriving Repr

def policyCredit (p : Policy) (now : ℕ) : ℕ := min p.capacity (p.credit + (now - p.updated) * p.refill)

def available (p : Policy) (now block : ℕ) (safety : Bool) : ℕ :=
  let amount := if safety && p.safetyLane then p.maximum else
    if (p.expires ≤ now && !p.safetyLane) ||
        (!p.activeGroup && (now < p.nextAt || (p.lastBlock != 0 && p.lastBlock == block))) then 0
    else min p.maximum (policyCredit p now)
  if amount < p.minimum then 0 else amount

def policyCharge (p : Policy) (now amount : ℕ) : ℕ :=
  policyCredit p now - min (policyCredit p now) amount

def priceFloor (fair shortfall : ℕ) : ℕ := ceilDiv (fair * (10000 - shortfall)) 10000

def executionMinimum (fair shortfall quoteOut amount quoteAmount : ℕ) : ℕ :=
  max (priceFloor fair shortfall) (ceilDiv (quoteOut * amount) quoteAmount)

def quoteValid (now block quoted age blocks deadline : ℕ) (hashMatches hashNonzero : Bool) : Bool :=
  quoted < block && block - quoted ≤ blocks && hashMatches && hashNonzero &&
    now ≤ deadline && deadline ≤ now + age

theorem policyCredit_bounded (p : Policy) (now : ℕ) : policyCredit p now ≤ p.capacity := min_le_left _ _

theorem refresh_does_not_refill (p : Policy) (now newCapacity : ℕ) :
    min newCapacity (policyCredit p now) ≤ policyCredit p now := min_le_right _ _

theorem policyCharge_conserved (p : Policy) (now amount : ℕ) :
    policyCharge p now amount + min (policyCredit p now) amount = policyCredit p now := by
  exact Nat.sub_add_cancel (min_le_left _ _)

theorem available_bounded (p : Policy) (now block : ℕ) (safety : Bool) :
    available p now block safety ≤ p.maximum := by
  simp only [available]
  split_ifs <;> simp_all

theorem expired_entry_stops (p : Policy) (now block : ℕ)
    (h : p.expires ≤ now) (hs : p.safetyLane = false) : available p now block false = 0 := by
  simp [available, hs, h]

theorem flagged_safety_keeps_size_bound (p : Policy) (now block : ℕ)
    (h : p.safetyLane = true) (hs : p.minimum ≤ p.maximum) :
    available p now block true = p.maximum := by
  simp [available, h, Nat.not_lt.mpr hs]

theorem execution_quote_only_tightens (f sf qo a qa : ℕ) :
    priceFloor f sf ≤ executionMinimum f sf qo a qa := le_max_left _ _

theorem priceFloor_refines (f sf : ℕ) :
    f * (10000 - sf) ≤ priceFloor f sf * 10000 ∧
      priceFloor f sf * 10000 < f * (10000 - sf) + 10000 :=
  ceilDiv_bounds _ _ (by decide)

structure RedemptionState where
  shares : ℕ
  owed : ℕ
  debt : ℕ
  repaid : ℕ
  settled : ℕ
  burned : ℕ
  claimed : ℕ
  active : Bool
  deriving Repr

def settleRedemption (r : RedemptionState) (principalPaid : ℕ) : RedemptionState :=
  let repaid := r.repaid + min principalPaid (r.debt - r.repaid)
  let entitled := if repaid == r.debt then r.owed else r.owed * repaid / r.debt
  { r with repaid, settled := r.settled + (entitled - r.claimed - r.settled) }

def claimRedemption (r : RedemptionState) : RedemptionState × ℕ × ℕ :=
  let claimed := r.claimed + r.settled
  let complete := r.debt ≤ r.repaid
  let burn := if complete then r.shares - r.burned else r.shares * claimed / r.owed - r.burned
  ({ r with claimed, settled := 0, burned := r.burned + burn, active := if complete then false else r.active },
    r.settled, burn)

def claimReceiver (caller owner requested : ℕ) : ℕ := if caller == owner then requested else owner

def queueReady : ℕ → ℕ → List ℕ → ℕ
  | _, 0, _ => 0
  | _, _ + 1, [] => 0
  | now, fuel + 1, time :: rest => if now < time then 0 else 1 + queueReady now fuel rest

def startQueue (paused : Bool) (delever activeSource now fuel : ℕ) (eligible : List ℕ) : Option ℕ :=
  if paused then none else
  some (if delever != 0 || activeSource != 0 then 0 else queueReady now fuel eligible)

theorem queueReady_bounded (now fuel : ℕ) (eligible : List ℕ) :
    queueReady now fuel eligible ≤ fuel ∧ queueReady now fuel eligible ≤ eligible.length := by
  induction fuel generalizing eligible with
  | zero => simp [queueReady]
  | succ fuel ih =>
    cases eligible with
    | nil => simp [queueReady]
    | cons time rest =>
      simp only [queueReady]
      split
      · simp
      · have h := ih rest; simp only [List.length_cons]; omega

theorem queueReady_fifo (now fuel time : ℕ) (rest : List ℕ) (h : now < time) :
    queueReady now fuel (time :: rest) = 0 := by cases fuel <;> simp [queueReady, h]

theorem resizing_blocks_new_exits (d a now fuel : ℕ) (eligible : List ℕ)
    (h : d ≠ 0 ∨ a ≠ 0) : startQueue false d a now fuel eligible = some 0 := by
  rcases h with h | h <;> simp [startQueue, h]

theorem settled_repayment_capped (r : RedemptionState) (paid : ℕ) (h : r.repaid ≤ r.debt) :
    (settleRedemption r paid).repaid ≤ r.debt := by simp only [settleRedemption]; omega

theorem completed_settlement_owes_full_collateral (r : RedemptionState) (p : ℕ)
    (h : (settleRedemption r p).repaid = r.debt) (hc : r.claimed + r.settled ≤ r.owed) :
    (settleRedemption r p).settled + r.claimed = r.owed := by
  simp only [settleRedemption] at h ⊢
  simp only [h, beq_self_eq_true, ↓reduceIte]
  omega

theorem claim_conserves_collateral (r : RedemptionState) :
    (claimRedemption r).1.claimed = r.claimed + (claimRedemption r).2.1 := rfl

theorem final_claim_burns_all (r : RedemptionState) (h : r.debt ≤ r.repaid) (hb : r.burned ≤ r.shares) :
    (claimRedemption r).1.burned = r.shares ∧ (claimRedemption r).1.active = false := by
  simp [claimRedemption, h, Nat.add_sub_of_le hb]

theorem permissionless_claim_cannot_redirect (caller owner requested : ℕ) (h : caller ≠ owner) :
    claimReceiver caller owner requested = owner := by simp [claimReceiver, h]

end Juicer.Runtime
