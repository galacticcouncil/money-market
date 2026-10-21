import JuicerLean.FixedPoint.PublicSourceProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem source_cash_after_withdrawal (remaining withdrawn held freed cash : Nat)
    (hs : remaining+withdrawn ≤ held) (hc : held+freed ≤ cash) :
    remaining+freed ≤ cash-withdrawn := by omega

def withdrawSource (s : State) (burned : Nat) : State :=
  { s with held := s.held-burned,sourceCash := s.sourceCash-sourceValue s burned }

theorem withdrawSource_public (s : State) (burned : Nat) (h : PublicInvariant s) (hb : burned ≤ s.held) :
    PublicInvariant (withdrawSource s burned) := by
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · exact h.2.2.2.2.1
  · rcases h.2.2.2.2.2 with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,?_,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    intro hex
    exact source_cash_after_withdrawal _ _ _ _ _ (sourceValue_split s burned hb) (hsourceCash hex)

def harvestFunding (s : State) (burned : Nat) : State :=
  harvestFundState s burned (sourceValue s burned)
    (harvestSlice (harvestable s) s.book.source s.book.protocol burned)

theorem harvestFunding_public (s : State) (burned : Nat) (h : PublicInvariant s) (hb : burned ≤ s.held) :
    PublicInvariant (harvestFunding s burned) :=
  let slice := harvestSlice (harvestable s) s.book.source s.book.protocol burned
  bookFunding_public _ (s.book.source-slice.1) (s.book.protocol-slice.2) s.basis
    (withdrawSource_public s burned h hb)

theorem lastHarvest_public (s : State) (time : Nat) (h : PublicInvariant s) :
    PublicInvariant { s with lastHarvest := time } := h

def harvestProgram (available : State → Nat) (value quote : State → Nat → Nat)
    (splitter : Nat → Nat → Nat → Nat → Nat → Nat × Nat × Nat)
    (operation : State → Nat → Nat → Nat → Nat → Except Nat State)
    (input : State) (minimum : Nat) : Result := do
  let mut s := input
  let burned := min (available s) s.held
  if burned == 0 then return (s,0)
  let amount := value s burned
  let fair := quote s amount
  let out := fair*(10000-s.haircut)/10000
  if out < max minimum (fair*9900/10000) then throw 26
  if out == 0 then throw 28
  let slice := harvestSlice (available s) s.book.source s.book.protocol burned
  let (reward,service,feeAmount) := splitter out burned slice.1 slice.2 s.feeBps
  s := harvestFundState s burned amount slice
  s ← operation s out reward service feeAmount
  return ({ s with lastHarvest := s.time },amount)

theorem harvestProgram_preserves (available : State → Nat) (value quote : State → Nat → Nat)
    (splitter : Nat → Nat → Nat → Nat → Nat → Nat × Nat × Nat)
    (operation : State → Nat → Nat → Nat → Nat → Except Nat State)
    (P : State → Prop) (s : State) (minimum : Nat) (h : P s)
    (hfund : P (harvestFundState s (min (available s) s.held) (value s (min (available s) s.held))
      (harvestSlice (available s) s.book.source s.book.protocol (min (available s) s.held))))
    (hop : ∀ x out reward service fee, P x → OnSuccess P (operation x out reward service fee))
    (htime : ∀ x, P x → P { x with lastHarvest := x.time }) :
    OnSuccess (fun result : State × Nat => P result.1)
      (harvestProgram available value quote splitter operation s minimum) := by
  unfold harvestProgram
  simp only [bind,pure,Except.bind,Except.pure]
  split
  · exact h
  · split
    · trivial
    · split
      · trivial
      · split
        · trivial
        · rename_i next heq
          exact htime next (onSuccess_of_eq (hop _ _ _ _ _ hfund) heq)

theorem harvestProgram_exact (s : State) (minimum : Nat) :
    harvestAll s minimum = harvestProgram harvestable sourceValue quoteCollateral splitHarvest compoundFunds
      (checkpoint s zeroId zeroId) minimum := by rfl


def HarvestBound (s : State) : Prop :=
  harvestBurn (checkpoint s zeroId zeroId) ≤ (checkpoint s zeroId zeroId).held

instance (s : State) : Decidable (HarvestBound s) := by unfold HarvestBound; infer_instance

theorem harvestBound_all (s : State) : HarvestBound s := Nat.min_le_right _ _

theorem harvestAll_public (s : State) (minimum : Nat) (h : PublicInvariant s)
    (hm : PublicMetadata s) (hb : HarvestBound s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (harvestAll s minimum) := by
  rw [harvestProgram_exact]
  exact harvestProgram_preserves harvestable sourceValue quoteCollateral splitHarvest compoundFunds
    PublicInvariant (checkpoint s zeroId zeroId) minimum (checkpoint_public s zeroId zeroId h hm)
    (harvestFunding_public _ _ (checkpoint_public s zeroId zeroId h hm) hb)
    compoundFunds_public (fun next hn => lastHarvest_public next next.time hn)

theorem raw_harvest_public (s : State) (caller a b n : Nat) (h : PublicInvariant s)
    (hm : PublicMetadata s) (hb : HarvestBound s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rawRunCall s ⟨23,caller,a,b,n⟩) := by
  change OnSuccess _ (if s.paused || s.sourcePaused then .error 1 else harvestAll s n)
  exact onSuccess_if _ _ _ _ trivial (harvestAll_public s n h hm hb)

end Juicer.PublicCalls
