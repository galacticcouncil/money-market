import JuicerLean.FixedPoint.PublicCheckpointProofs
import JuicerLean.FixedPoint.PublicClaimProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

structure PaymentNumbers where
  drawn : Nat
  spent : Nat
  unused : Nat
  burned : Nat
  cohortDebt : Nat
  principal : Nat
  reduced : Nat
  calls : Nat
  synthBurn : Nat

def paymentNumbers (s : State) (key limit : Nat) : PaymentNumbers :=
  let p := position s key
  let debt := mainDebtOf s.debt s.mainUnits p
  let quantum := 2 * ceilDiv s.debtIndex ray
  let principal := min p.principal debt
  let interest := debt - principal
  let cap := interest + min principal limit
  let drawn := if key != 0 && p.remaining == 0 && spendable s key < cap then
    min s.protocolReserve (cap - spendable s key + quantum) else 0
  let usable := p.cash + drawn - (fee s key).feeLeft
  let amount := min usable (if key == 0 && limit != 0 then min debt limit else interest + min principal limit)
  let firstPaid := min (min amount s.debt) s.repayLimit
  let firstReduced := if firstPaid == s.debt then firstPaid else firstPaid - s.repayLoss
  let retry := firstPaid == amount && firstReduced < amount && firstPaid < usable
  let extra := if retry then
    min (min (min (usable - firstPaid) (amount - firstReduced + quantum))
      (s.debt - firstReduced)) s.repayLimit else 0
  let paid := firstPaid + extra
  let reduced := firstReduced + (if retry then
    if extra == s.debt - firstReduced then extra else extra - s.repayLoss else 0)
  let spent := if amount != 0 then paid else 0
  let burned := if amount != 0 then
    if debt ≤ reduced then p.units else reduced * s.mainUnits / s.debt else 0
  let principal := if amount != 0 then principal - min principal (reduced - interest) else principal
  let unused := min drawn (p.cash + drawn - spent - (fee s key).feeLeft)
  ⟨drawn,spent,unused,burned,debt,principal,reduced,
    (if amount == 0 then 0 else 1)+(if retry then 1 else 0),
    if s.debt == 0 then 0 else s.synth * reduced / s.debt⟩

def paymentState (s : State) (key : Nat) (p : PaymentNumbers) : State :=
  setPosition { s with
    mainUnits := if p.cohortDebt ≤ p.reduced then s.mainUnits-p.burned-((position s key).units-p.burned)
      else s.mainUnits-p.burned,
    ownedCash := s.ownedCash+p.drawn-p.spent-p.unused,
    protocolReserve := s.protocolReserve-p.drawn+p.unused,
    repayCalls := s.repayCalls+p.calls,
    debt := s.debt-p.reduced, synth := s.synth-p.synthBurn } key
    { position s key with
      cash := (position s key).cash+p.drawn-p.spent-p.unused,
      units := if p.cohortDebt ≤ p.reduced then 0 else (position s key).units-p.burned,
      principal := p.principal }

theorem pay_state_factored (s : State) (key limit : Nat) :
    (pay s key limit).1 = paymentState s key (paymentNumbers s key limit) := by
  simp only [pay,paymentState,paymentNumbers,Nat.add_assoc]

theorem position_sum_replace (s : State) (i : Nat) (p : MainPosition) (f : MainPosition → Nat)
    (hi : i < s.positions.size) :
    (((s.positions.set! i p).toList).map f).sum+f (position s i) =
      (s.positions.toList.map f).sum+f p := by
  have hh := list_sum_map_set s.positions.toList i p {} f (by simpa using hi)
  simpa only [Array.set!_eq_setIfInBounds, Array.toList_setIfInBounds,
    Array.getElem?_toList, position] using hh

theorem position_mem (s : State) (i : Nat) (hi : i < s.positions.size) :
    position s i ∈ s.positions.toList := by
  have hh := List.getElem_mem (show i < s.positions.toList.length by simpa using hi)
  have hg := List.getElem?_eq_getElem (show i < s.positions.toList.length by simpa using hi)
  simp only [Array.getElem?_toList] at hg
  simpa only [position,hg,Option.getD_some] using hh

theorem payment_cash_math (cash fee drawn usable amount debt repayLimit loss quantum : Nat)
    (hu : usable = cash+drawn-fee) (ha : amount ≤ usable) :
    let firstPaid := min (min amount debt) repayLimit
    let firstReduced := if firstPaid == debt then firstPaid else firstPaid-loss
    let retry := firstPaid == amount && firstReduced < amount && firstPaid < usable
    let extra := if retry then
      min (min (min (usable-firstPaid) (amount-firstReduced+quantum))
        (debt-firstReduced)) repayLimit else 0
    let spent := if amount != 0 then firstPaid+extra else 0
    let unused := min drawn (cash+drawn-spent-fee)
    spent+unused ≤ cash+drawn := by
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
  omega

theorem payment_burn_math (units total debt reduced amount : Nat) (hu : units ≤ total) :
    (if amount != 0 then
      if fundedOf debt total units ≤ reduced then units else reduced*total/debt else 0) ≤ units := by
  by_cases ht : total = 0
  · have hz : units = 0 := by omega
    simp [ht,hz]
  · have htpos : 0 < total := by omega
    have hq := (mulDiv_bounds debt units total htpos).1
    split
    · split
      · exact le_rfl
      · rename_i hn
        have hr : reduced < debt*units/total := by
          simpa [fundedOf,ht] using Nat.lt_of_not_ge hn
        apply Nat.div_le_of_le_mul
        nlinarith
    · omega

theorem paymentNumbers_burned (s : State) (key limit : Nat)
    (hu : (position s key).units ≤ s.mainUnits) :
    (paymentNumbers s key limit).burned ≤ (position s key).units := by
  dsimp only [paymentNumbers]
  exact payment_burn_math _ _ _ _ _ hu

theorem paymentNumbers_cash (s : State) (key limit : Nat) :
    (paymentNumbers s key limit).spent+(paymentNumbers s key limit).unused ≤
      (position s key).cash+(paymentNumbers s key limit).drawn := by
  dsimp only [paymentNumbers]
  exact payment_cash_math _ _ _ _ _ _ _ _ _ rfl (min_le_left _ _)

theorem paymentState_source (s : State) (key : Nat) (p : PaymentNumbers)
    (hi : key < s.positions.size) (h : (sourceProjection s).valid) :
    (sourceProjection (paymentState s key p)).valid := by
  have hh := position_sum_replace s key
    { position s key with
      cash := (position s key).cash+p.drawn-p.spent-p.unused,
      units := if p.cohortDebt ≤ p.reduced then 0 else (position s key).units-p.burned,
      principal := p.principal } MainPosition.remaining hi
  change s.activeRemaining+(s.positions.toList.map MainPosition.remaining).sum = s.outstanding at h
  change (sourceProjection (paymentState s key p)).exits.sum+(position s key).remaining =
    (s.positions.toList.map MainPosition.remaining).sum+(position s key).remaining at hh
  change s.activeRemaining+(sourceProjection (paymentState s key p)).exits.sum = s.outstanding
  omega

theorem paymentState_cash (s : State) (key : Nat) (p : PaymentNumbers)
    (hi : key < s.positions.size) (h : (cashProjection s).valid)
    (hp : p.spent+p.unused ≤ (position s key).cash+p.drawn) :
    (cashProjection (paymentState s key p)).valid := by
  have hh := position_sum_replace s key
    { position s key with
      cash := (position s key).cash+p.drawn-p.spent-p.unused,
      units := if p.cohortDebt ≤ p.reduced then 0 else (position s key).units-p.burned,
      principal := p.principal } MainPosition.cash hi
  have hm := map_value_le_sum MainPosition.cash s.positions.toList (position s key) (position_mem s key hi)
  change (s.positions.toList.map MainPosition.cash).sum+s.unallocated = s.ownedCash at h
  change (cashProjection (paymentState s key p)).cohorts.sum+(position s key).cash =
    (s.positions.toList.map MainPosition.cash).sum+((position s key).cash+p.drawn-p.spent-p.unused) at hh
  change (cashProjection (paymentState s key p)).cohorts.sum+s.unallocated =
    s.ownedCash+p.drawn-p.spent-p.unused
  omega

theorem paymentState_operational (s : State) (key : Nat) (p : PaymentNumbers)
    (hi : key < s.positions.size) (h : OperationalInvariant s)
    (hb : p.burned ≤ (position s key).units) : OperationalInvariant (paymentState s key p) := by
  have hh := position_sum_replace s key
    { position s key with
      cash := (position s key).cash+p.drawn-p.spent-p.unused,
      units := if p.cohortDebt ≤ p.reduced then 0 else (position s key).units-p.burned,
      principal := p.principal } MainPosition.units hi
  have hm := map_value_le_sum MainPosition.units s.positions.toList (position s key) (position_mem s key hi)
  rcases h with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hunits,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  refine ⟨hw,ha,hc,hap,?_,hu,hsupply,?_,hout,?_,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  · simpa only [paymentState,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hpos
  · change (if p.cohortDebt ≤ p.reduced then s.mainUnits-p.burned-((position s key).units-p.burned)
      else s.mainUnits-p.burned) = (_ : List Nat).sum
    change ((paymentState s key p).positions.toList.map MainPosition.units).sum+(position s key).units =
      (s.positions.toList.map MainPosition.units).sum+
        (if p.cohortDebt ≤ p.reduced then 0 else (position s key).units-p.burned) at hh
    split_ifs at hh ⊢ <;> omega
  · simpa only [paymentState,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hfs

theorem pay_public (s : State) (key limit : Nat) (hi : key < s.positions.size)
    (h : PublicInvariant s) : PublicInvariant (pay s key limit).1 := by
  have hu : (position s key).units ≤ s.mainUnits := by
    have hh := map_value_le_sum MainPosition.units s.positions.toList (position s key) (position_mem s key hi)
    have hs : s.mainUnits = (s.positions.toList.map MainPosition.units).sum := h.2.2.2.2.2.2.2.2.2.2.2.2.1
    omega
  rw [pay_state_factored]
  apply public_of_operational
  · exact h.1
  · exact paymentState_source s key _ hi h.2.1
  · exact paymentState_cash s key _ hi h.2.2.1 (paymentNumbers_cash s key limit)
  · exact h.2.2.2.2.1
  · exact paymentState_operational s key _ hi h.2.2.2.2.2 (paymentNumbers_burned s key limit hu)

end Juicer.PublicCalls

