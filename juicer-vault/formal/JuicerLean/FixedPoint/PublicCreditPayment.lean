import JuicerLean.FixedPoint.PublicCreditFrame

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem payment_protected_cash (cash fee drawn usable amount debt repayLimit loss quantum : Nat)
    (hu : usable = cash+drawn-fee) (ha : amount ≤ usable) :
    let firstPaid := min (min amount debt) repayLimit
    let firstReduced := if firstPaid == debt then firstPaid else firstPaid-loss
    let retry := firstPaid == amount && firstReduced < amount && firstPaid < usable
    let extra := if retry then
      min (min (min (usable-firstPaid) (amount-firstReduced+quantum))
        (debt-firstReduced)) repayLimit else 0
    let spent := if amount != 0 then firstPaid+extra else 0
    let unused := min drawn (cash+drawn-spent-fee)
    min fee cash ≤ cash+drawn-spent-unused := by
  dsimp only
  have hfirst : min (min amount debt) repayLimit ≤ usable :=
    (min_le_left _ _).trans ((min_le_left _ _).trans ha)
  generalize hf : min (min amount debt) repayLimit = first at hfirst ⊢
  generalize hr : (if first == debt then first else first-loss) = reduced
  generalize ht : (first == amount && reduced < amount && first < usable) = retry
  have hextra : (if retry then
      min (min (min (usable-first) (amount-reduced+quantum)) (debt-reduced)) repayLimit else 0)
      ≤ usable-first := by
    split
    · exact (min_le_left _ _).trans ((min_le_left _ _).trans (min_le_left _ _))
    · omega
  generalize he : (if retry then
    min (min (min (usable-first) (amount-reduced+quantum)) (debt-reduced)) repayLimit else 0)
    = extra at hextra ⊢
  have hspent : (if amount != 0 then first+extra else 0) ≤ usable := by
    split <;> omega
  generalize hs : (if amount != 0 then first+extra else 0) = spent at hspent ⊢
  have hunused := min_le_right drawn (cash+drawn-spent-fee)
  have hf := min_le_left fee cash
  have hc := min_le_right fee cash
  omega

theorem paymentNumbers_protected (s : State) (key limit : Nat) :
    min (fee s key).feeLeft (position s key).cash ≤
      (position s key).cash+(paymentNumbers s key limit).drawn-
        (paymentNumbers s key limit).spent-(paymentNumbers s key limit).unused := by
  apply payment_protected_cash
  · rfl
  · exact min_le_left _ _

theorem feeBacking_payment (f : SourceFee) (cash remaining next : Nat)
    (h : FeeBacking f cash remaining) (hp : min f.feeLeft cash ≤ next) :
    FeeBacking f next remaining := by
  rcases h with h | h
  · exact Or.inl (by omega)
  · by_cases hc : f.feeLeft ≤ cash
    · exact Or.inl (by omega)
    · exact Or.inr (by omega)

theorem paymentState_position (s : State) (key : Nat) (q : PaymentNumbers) (i : Nat) :
    position (paymentState s key q) i =
      if key = i ∧ key < s.positions.size then
        { position s key with
          cash := (position s key).cash+q.drawn-q.spent-q.unused,
          units := if q.cohortDebt ≤ q.reduced then 0 else (position s key).units-q.burned,
          principal := q.principal }
      else position s i := by
  simp only [paymentState, setPosition, position, Array.set!_eq_setIfInBounds,
    Array.getElem?_setIfInBounds]
  split_ifs <;> simp_all <;> omega

theorem pay_feeBacking (s : State) (key limit : Nat) (h : PositionFeeBacking s) :
    PositionFeeBacking (pay s key limit).1 := by
  rw [pay_state_factored]
  intro i hi
  have hs : i < s.positions.size := by
    simpa only [paymentState, setPosition, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using hi
  change FeeBacking (fee s i) (position (paymentState s key (paymentNumbers s key limit)) i).cash
    (if i == 0 then s.activeRemaining else
      (position (paymentState s key (paymentNumbers s key limit)) i).remaining)
  rw [paymentState_position]
  by_cases he : key = i ∧ key < s.positions.size
  · simp only [if_pos he]
    rcases he with ⟨rfl, _⟩
    exact feeBacking_payment _ _ _ _ (h key hs) (paymentNumbers_protected s key limit)
  · simpa only [if_neg he] using h i hs

theorem pay_creditReady (s : State) (key limit : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (pay s key limit).1 := by
  apply creditFrame_ready (hf := pay_feeBacking s key limit h.1.1) (h := h)
  rw [pay_state_factored]
  refine ⟨?_, rfl, rfl, rfl, rfl, rfl, rfl, rfl, le_rfl, le_rfl⟩
  have hr := remaining_setPosition s key
    { position s key with
      cash := (position s key).cash+(paymentNumbers s key limit).drawn-
        (paymentNumbers s key limit).spent-(paymentNumbers s key limit).unused,
      units := if (paymentNumbers s key limit).cohortDebt ≤ (paymentNumbers s key limit).reduced then 0
        else (position s key).units-(paymentNumbers s key limit).burned,
      principal := (paymentNumbers s key limit).principal } rfl
  change ((setPosition s key _).positions.toList.map MainPosition.remaining).take s.positions.size = _
  rw [hr]
  exact List.take_of_length_le (by simp)

end Juicer.PublicCalls
