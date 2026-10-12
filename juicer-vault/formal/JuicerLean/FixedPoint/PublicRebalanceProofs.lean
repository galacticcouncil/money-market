import JuicerLean.FixedPoint.PublicSourceProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1500000

namespace Juicer.PublicCalls
open Runtime

def borrowResult (s : State) (amount : Nat) : Result :=
  if amount == 0 then .ok (s,0)
  else if s.mainUnits != 0 && s.debt == 0 then .error 18
  else
    let supplied := s.synth+buffered amount 9800
    if supplied*9800/10000 < s.debt+(amount-s.borrowLoss) then .error 23
    else .ok (borrowSource s amount supplied,amount*wad/s.sourceRate)

theorem borrowResult_public (s : State) (amount : Nat) (h : PublicInvariant s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (borrowResult s amount) := by
  unfold borrowResult
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · trivial
    · exact onSuccess_if _ _ _ _ trivial (borrowSource_public s amount _ h)

def borrowResultRaw (input : State) (amount : Nat) : Result := do
  let mut s := input
  if amount == 0 then return (s,0)
  if s.mainUnits != 0 && s.debt == 0 then throw 18
  let borrowed := amount-s.borrowLoss
  let (active,total) := mainBorrow (position s 0) s.mainUnits s.debt (s.debt+borrowed)
  s := setPosition s 0 active
  let supplied := s.synth+buffered amount 9800
  if supplied*9800/10000 < s.debt+borrowed then throw 23
  let shares := amount*wad/s.sourceRate
  return ({ s with
    mainUnits := total,debt := s.debt+borrowed,synth := supplied,
    held := s.held+shares,sourceCash := s.sourceCash+amount,basis := s.basis+amount,reinvest := 0 },shares)

theorem borrowResult_factored (s : State) (amount : Nat) :
    borrowResultRaw s amount = borrowResult s amount := by
  unfold borrowResultRaw borrowResult
  simp only [mainBorrow,Nat.add_sub_cancel_left,bind,pure,Except.bind,Except.pure]
  rfl

def rebalanceEnter (s : State) (resize : Bool) (coll8 debt8 target : Nat) : Result :=
  if pendingAccounting s || s.activeRemaining != 0 then .error 18
  else
    let next := { (pay s 0 0).1 with synth := s.synth }
    let wanted := (target-debt8)*10^10
    let amount := if resize then wanted else min wanted
      (coll8*min next.reinvest next.assets/next.assets*7500/10000*10^10)
    borrowResultRaw next amount

theorem rebalanceEnter_public (s : State) (resize : Bool) (coll8 debt8 target : Nat)
    (h : PublicInvariant s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1)
      (rebalanceEnter s resize coll8 debt8 target) := by
  unfold rebalanceEnter
  apply onSuccess_if
  · trivial
  · rw [borrowResult_factored]
    exact borrowResult_public _ _ (synth_public _ _ (pay_public s 0 0 h.2.2.2.2.2.2.2.2.2.1 h))

def rebalanceDelever (s : State) (debt8 target : Nat) : Result :=
  let active := s.held-s.book.source-s.book.protocol
  let equity8 := sourceEquity s/10^10*active/s.held
  let slice := active*min (debt8-target) equity8/equity8
  if slice != 0 then
    if s.activeRemaining != 0 || s.batchAmount != 0 || s.batchCost != 0 || pendingAccounting s then .error 18
    else
      let basis := s.basis*slice/active
      let claim := sourceValue s slice
      let vested := vestFee claim basis ((claim-basis)*s.feeBps/10000)
      .ok (addActiveFee (unwindActiveSource s slice basis) vested,slice)
  else .ok (s,0)

theorem activeDelever_public (s : State) (slice basis : Nat) (h : PublicInvariant s)
    (hzero : s.activeRemaining = 0) (hf : (fee s 0).feeLeft = 0) (hb : slice ≤ s.held) :
    PublicInvariant (addActiveFee (unwindActiveSource s slice basis)
      (vestFee (sourceValue s slice) basis ((sourceValue s slice-basis)*s.feeBps/10000))) :=
  addActiveFee_public _ _ (unwindActiveSource_public s slice basis h hzero hb) hf (vested_fee_le_yield _ _ _)

theorem rebalanceDelever_public (s : State) (debt8 target : Nat)
    (h : PublicInvariant s) (hf : ZeroActiveFee s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rebalanceDelever s debt8 target) := by
  unfold rebalanceDelever
  dsimp only
  split
  · split
    · trivial
    next hguard =>
      have hzero : s.activeRemaining = 0 := by
        clear h hf
        simp only [Bool.or_eq_true,bne_iff_ne] at hguard
        omega
      have hslice : (s.held-s.book.source-s.book.protocol)*
          min (debt8-target) (sourceEquity s/10^10*(s.held-s.book.source-s.book.protocol)/s.held)/
          (sourceEquity s/10^10*(s.held-s.book.source-s.book.protocol)/s.held) ≤ s.held :=
        (proportional_le _ _ _ (min_le_right _ _)).trans ((Nat.sub_le _ _).trans (Nat.sub_le _ _))
      exact activeDelever_public s _ _ h hzero (hf hzero) hslice
  · exact h

def rebalanceTail (s : State) : Result :=
  if s.delever != 0 then .ok (s,0)
  else
    let coll8 := s.supplied*s.price/wad/10^10
    if coll8 == 0 then .ok (s,0)
    else
      let debt8 := s.debt/10^10
      let exiting := s.pending != 0 || s.head != s.unwind || s.freed != 0
      let resize := !exiting && debt8*10000/coll8+500 < 7500
      let target := coll8*7500/10000
      if resize || (s.reinvest != 0 && debt8 < target) then
        rebalanceEnter s resize coll8 debt8 target
      else if !exiting && 7800 < debt8*10000/coll8 then rebalanceDelever s debt8 target
      else .ok (s,0)

theorem rebalanceTail_public (s : State) (h : PublicInvariant s) (hf : ZeroActiveFee s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rebalanceTail s) := by
  unfold rebalanceTail
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · exact h
    · apply onSuccess_if
      · exact rebalanceEnter_public s _ _ _ _ h
      · exact onSuccess_if _ _ _ _ (rebalanceDelever_public s _ _ h hf) h

def rebalanceTailRaw (input : State) : Result := do
  let mut s := input
  if s.delever != 0 then return (s,0)
  let coll8 := s.supplied*s.price/wad/10^10
  if coll8 == 0 then return (s,0)
  let debt8 := s.debt/10^10
  let exiting := s.pending != 0 || s.head != s.unwind || s.freed != 0
  let resize := !exiting && debt8*10000/coll8+500 < 7500
  let target := coll8*7500/10000
  if resize || (s.reinvest != 0 && debt8 < target) then
    if pendingAccounting s || s.activeRemaining != 0 then throw 18
    let oldSynth := s.synth
    s := (pay s 0 0).1
    s := { s with synth := oldSynth }
    let wanted := (target-debt8)*10^10
    let amount := if resize then wanted else min wanted
      (coll8*min s.reinvest s.assets/s.assets*7500/10000*10^10)
    if amount == 0 then return (s,0)
    if s.mainUnits != 0 && s.debt == 0 then throw 18
    let borrowed := amount-s.borrowLoss
    let (active,total) := mainBorrow (position s 0) s.mainUnits s.debt (s.debt+borrowed)
    s := setPosition s 0 active
    let supplied := s.synth+buffered amount 9800
    if supplied*9800/10000 < s.debt+borrowed then throw 23
    let shares := amount*wad/s.sourceRate
    return ({ s with
      mainUnits := total,debt := s.debt+borrowed,synth := supplied,held := s.held+shares,
      sourceCash := s.sourceCash+amount,basis := s.basis+amount,reinvest := 0 },shares)
  if !exiting && 7800 < debt8*10000/coll8 then
    let active := s.held-s.book.source-s.book.protocol
    let equity8 := sourceEquity s/10^10*active/s.held
    let slice := active*min (debt8-target) equity8/equity8
    if slice != 0 then
      if s.activeRemaining != 0 || s.batchAmount != 0 || s.batchCost != 0 || pendingAccounting s then throw 18
      let basis := s.basis*slice/active
      let claim := sourceValue s slice
      let vested := vestFee claim basis ((claim-basis)*s.feeBps/10000)
      return ({ s with
        held := s.held-slice,basis := s.basis-basis,freed := s.freed+claim,outstanding := s.outstanding+claim,
        activeRemaining := claim,delever := claim,sourceFees := s.sourceFees.set! 0 vested,
        feeReserve := s.feeReserve+vested.feeLeft },slice)
  return (s,0)

theorem rebalanceTail_factored (s : State) : rebalanceTailRaw s = rebalanceTail s := by
  unfold rebalanceTailRaw rebalanceTail rebalanceEnter rebalanceDelever borrowResultRaw
    addActiveFee unwindActiveSource
  simp only [bind,pure,Except.bind,Except.pure]

theorem raw_rebalance_factored (s : State) (caller a b n : Nat) :
    rawRunCall s ⟨9,caller,a,b,n⟩ =
      (if s.paused || s.sourcePaused then .error 1 else rebalanceTailRaw (checkpoint s zeroId zeroId)) := by
  rfl

theorem raw_rebalance_public (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) (hm : PublicMetadata s) (hf : ZeroActiveFee s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rawRunCall s ⟨9,caller,a,b,n⟩) := by
  rw [raw_rebalance_factored]
  rw [rebalanceTail_factored]
  exact onSuccess_if _ _ _ _ trivial (rebalanceTail_public _
    (checkpoint_public s zeroId zeroId h hm) (checkpoint_zeroActiveFee s zeroId zeroId hf))

end Juicer.PublicCalls
