import JuicerLean.FixedPoint.PublicActiveFeeTransitions
import JuicerLean.FixedPoint.PublicReachability

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem initialMint_activeFeeSafe (s : State) (h : ActiveFeeSafe s) : ActiveFeeSafe (initialMint s) := by
  unfold initialMint
  split <;> exact h

theorem mintWallet_activeFeeSafe (s : State) (receiver shares : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (mintWallet s receiver shares) := h

theorem depositAssets_activeFeeSafe (s : State) (caller amount : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (depositAssets s caller amount) := h

theorem depositResult_activeFeeSafe (s : State) (caller receiver amount shares needed : Nat)
    (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1)
      (depositResult s caller receiver amount shares needed) := by
  unfold depositResult
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · rw [onSuccess_bind]
      intro next heq
      have hm := mintWallet_activeFeeSafe (initialMint s) receiver shares (initialMint_activeFeeSafe s h)
      have ha := depositAssets_activeFeeSafe (mintWallet (initialMint s) receiver shares) caller amount hm
      have hn := onSuccess_of_eq (cover_activeFeeSafe _ _ ha) heq
      exact hn

theorem raw_deposit_activeFeeSafe (s : State) (caller a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s ⟨0, caller, a, b, n⟩) := by
  rw [raw_deposit_factored]
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · apply onSuccess_if
        · trivial
        · apply onSuccess_if
          · trivial
          · apply onSuccess_if
            · trivial
            · apply onSuccess_if
              · trivial
              · rw [depositTail_factored]
                unfold depositTail
                apply onSuccess_if
                · trivial
                · apply onSuccess_if
                  · trivial
                  · apply onSuccess_if
                    · trivial
                    · apply onSuccess_if
                      · trivial
                      · apply onSuccess_if
                        · trivial
                        · exact depositResult_activeFeeSafe _ caller b n _ _
                            (checkpoint_activeFeeSafe _ zeroId b
                              (activeFeeSafe_synth (pay s 0 0).1 s.synth (pay_activeFeeSafe s 0 0 h)))

theorem transfer_result_activeFeeSafe (s : State) (a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1)
      (do let next ← transfer s a b n; pure (next, 1)) := by
  rw [onSuccess_bind]
  intro next heq
  change ActiveFeeSafe next
  exact onSuccess_of_eq (transfer_activeFeeSafe s a b n h) heq

theorem raw_transferFrom_activeFeeSafe (s : State) (caller a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s ⟨3, caller, a, b, n⟩) := by
  rw [rawRunCall_transferFrom]
  dsimp only
  split
  · split
    · trivial
    · exact transfer_result_activeFeeSafe _ a b n h
  · exact transfer_result_activeFeeSafe s a b n h

theorem requestTail_activeFeeSafe (s : State) (owner escrow amount : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (requestTail s owner escrow amount) := by
  rw [requestTail_factored, onSuccess_bind]
  intro next heq
  change ActiveFeeSafe next
  exact onSuccess_of_eq (commitRequest_activeFeeSafe s owner escrow amount h) heq

theorem raw_request_activeFeeSafe (s : State) (caller a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s ⟨4, caller, a, b, n⟩) := by
  rw [raw_request_factored]
  dsimp only
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · rw [onSuccess_bind]
        intro paid hpaid
        have hp := onSuccess_of_eq (spend_activeFeeSafe _ a caller _ (checkpoint_activeFeeSafe s a zeroId h)) hpaid
        rw [onSuccess_bind]
        intro moved hmoved
        exact requestTail_activeFeeSafe moved a _ _ (onSuccess_of_eq (transfer_activeFeeSafe paid a vaultId _ hp) hmoved)

theorem raw_startUnwinds_activeFeeSafe (s : State) (caller a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s ⟨5, caller, a, b, n⟩) := by
  rw [raw_startUnwinds_factored]
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · exact h
    · rw [onSuccess_map]
      exact startMany_activeFeeSafe n s s.unwind h

theorem pokeSettleTail_activeFeeSafe (s : State) (h : ActiveFeeSafe s) : ActiveFeeSafe (pokeSettleTail s) := by
  unfold pokeSettleTail
  apply settleMany_activeFeeSafe 32
  exact activeFeeSafe_delever (pay s 0 s.delever).1 _ (pay_activeFeeSafe s 0 s.delever h)

theorem raw_pokeSettle_activeFeeSafe (s : State) (caller a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s ⟨6, caller, a, b, n⟩) :=
  let gross := s.freed*s.pullBps/10000
  let cost := gross*s.costBps/10000
  let next := { s with freed := s.freed-gross, sourceCash := s.sourceCash-gross, sourceCost := s.sourceCost+cost }
  let hn : ActiveFeeSafe next := h
  let hc := credit_activeFeeSafe next (gross-cost) cost hn
  (congrArg (OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1))
    (raw_pokeSettle_factored s caller a b n)).mpr (pokeSettleTail_activeFeeSafe _ hc)

theorem claimState_activeFeeSafe (s : State) (i receiver : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (claimState s i receiver) := h

theorem raw_claim_activeFeeSafe (s : State) (caller a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s ⟨7, caller, a, b, n⟩) := by
  rw [rawRunCall_claim]
  split_ifs <;> trivial

theorem mintMainPosition_activeFeeSafe (s : State) (units principal : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (mintMainPosition s units principal) := h

theorem depositSourceState_activeFeeSafe (s : State) (shares amount : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (depositSourceState s shares amount) := h

theorem depositSource_activeFeeSafe (s : State) (amount : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (depositSource s amount) := depositSourceState_activeFeeSafe s _ amount h

theorem activeFeeSafe_debtSynth (s : State) (debt synth : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe { s with debt := debt, synth := synth } := h

theorem borrowSource_activeFeeSafe (s : State) (amount supplied : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (borrowSource s amount supplied) :=
  activeFeeSafe_debtSynth _ _ supplied (depositSource_activeFeeSafe _ amount (mintMainPosition_activeFeeSafe s _ _ h))

theorem borrowResult_activeFeeSafe (s : State) (amount : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (borrowResult s amount) := by
  unfold borrowResult
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · trivial
    · exact onSuccess_if _ _ _ _ trivial (borrowSource_activeFeeSafe s amount _ h)

theorem rebalanceEnter_activeFeeSafe (s : State) (resize : Bool) (coll8 debt8 target : Nat)
    (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rebalanceEnter s resize coll8 debt8 target) := by
  unfold rebalanceEnter
  apply onSuccess_if
  · trivial
  · rw [borrowResult_factored]
    exact borrowResult_activeFeeSafe _ _ (activeFeeSafe_synth (pay s 0 0).1 s.synth (pay_activeFeeSafe s 0 0 h))

theorem activeDelever_activeFeeSafe (s : State) (slice basis : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (addActiveFee (unwindActiveSource s slice basis)
      (vestFee (sourceValue s slice) basis ((sourceValue s slice-basis)*s.feeBps/10000))) := by
  refine ⟨?_, ?_⟩
  · simpa only [addActiveFee, unwindActiveSource, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using h.1
  · intro hz
    change sourceValue s slice = 0 at hz
    simp only [fee, addActiveFee, unwindActiveSource, Array.set!_eq_setIfInBounds,
      Array.getElem?_setIfInBounds, ite_true, h.1, Option.getD_some, vestFee, hz,
      Nat.zero_sub, Nat.zero_mul, Nat.zero_div, Nat.min_self]

theorem rebalanceDelever_activeFeeSafe (s : State) (debt8 target : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rebalanceDelever s debt8 target) := by
  unfold rebalanceDelever
  dsimp only
  apply onSuccess_if
  · exact onSuccess_if _ _ _ _ trivial (activeDelever_activeFeeSafe s _ _ h)
  · exact h

theorem rebalanceTail_activeFeeSafe (s : State) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rebalanceTail s) := by
  unfold rebalanceTail
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · exact h
    · apply onSuccess_if
      · exact rebalanceEnter_activeFeeSafe s _ _ _ _ h
      · exact onSuccess_if _ _ _ _ (rebalanceDelever_activeFeeSafe s _ _ h) h

theorem raw_rebalance_activeFeeSafe (s : State) (caller a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s ⟨9, caller, a, b, n⟩) := by
  rw [raw_rebalance_factored, rebalanceTail_factored]
  exact onSuccess_if _ _ _ _ trivial (rebalanceTail_activeFeeSafe _ (checkpoint_activeFeeSafe s zeroId zeroId h))

theorem withdrawSource_activeFeeSafe (s : State) (burned : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (withdrawSource s burned) := h

theorem harvestFunding_activeFeeSafe (s : State) (burned : Nat) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (harvestFunding s burned) :=
  let slice := harvestSlice (harvestable s) s.book.source s.book.protocol burned
  bookFunding_activeFeeSafe _ (s.book.source-slice.1) (s.book.protocol-slice.2) s.basis (withdrawSource_activeFeeSafe s burned h)

theorem harvestAll_activeFeeSafe (s : State) (minimum : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (harvestAll s minimum) := by
  rw [harvestProgram_exact]
  have hn := checkpoint_activeFeeSafe s zeroId zeroId h
  exact harvestProgram_preserves harvestable sourceValue quoteCollateral splitHarvest compoundFunds
    ActiveFeeSafe (checkpoint s zeroId zeroId) minimum hn
    (harvestFunding_activeFeeSafe (checkpoint s zeroId zeroId) (harvestBurn (checkpoint s zeroId zeroId)) hn)
    compoundFunds_activeFeeSafe (fun _ hx => hx)

theorem raw_compound_activeFeeSafe (s : State) (caller a b n : Nat) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s ⟨24, caller, a, b, n⟩) := by
  change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
    else if n == 0 then .error 2 else if s.collateral[caller]! < n then .error 15
    else if n < b then .error 28 else do
      let next ← compoundFunds { s with collateral := s.collateral.set! caller (s.collateral[caller]!-n) }
        n 0 n 0
      pure (next, 0))
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · apply onSuccess_if
        · trivial
        · rw [onSuccess_bind]
          intro next heq
          change ActiveFeeSafe next
          exact onSuccess_of_eq (compoundFunds_activeFeeSafe
            { s with collateral := s.collateral.set! caller (s.collateral[caller]!-n) } n 0 n 0 h) heq

theorem rawRunCall_activeFeeSafe (s : State) (action : Action) (h : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => ActiveFeeSafe result.1) (rawRunCall s action) := by
  by_cases unsupported : 31 ≤ action.op
  · rw [rawRunCall_unsupported s action unsupported]
    trivial
  · rcases action with ⟨op, caller, a, b, n⟩
    have hop : op ≤ 30 := by change ¬ 31 ≤ op at unsupported; omega
    interval_cases op
    · exact raw_deposit_activeFeeSafe s caller a b n h
    · exact h
    · exact transfer_result_activeFeeSafe s caller b n h
    · exact raw_transferFrom_activeFeeSafe s caller a b n h
    · exact raw_request_activeFeeSafe s caller a b n h
    · exact raw_startUnwinds_activeFeeSafe s caller a b n h
    · exact raw_pokeSettle_activeFeeSafe s caller a b n h
    · exact raw_claim_activeFeeSafe s caller a b n h
    · change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
        else .ok (checkpoint s zeroId zeroId, harvestable (checkpoint s zeroId zeroId)))
      exact onSuccess_if _ _ _ _ trivial (checkpoint_activeFeeSafe s zeroId zeroId h)
    · exact raw_rebalance_activeFeeSafe s caller a b n h
    · exact h
    · exact h
    · exact h
    · exact h
    · change OnSuccess _ (if n != 0 && (s.paused || s.sourcePaused) then .error 1
        else if n == 0 && !s.paused && !s.sourcePaused then .error 22
        else .ok ({ s with paused := n != 0 }, 0))
      split_ifs <;> trivial
    · exact h
    · exact h
    · exact h
    · exact h
    · exact h
    · exact h
    · exact h
    · change OnSuccess _ (.ok (maintainPegState s))
      unfold maintainPegState
      split <;> exact h
    · change OnSuccess _ (if s.paused || s.sourcePaused then .error 1 else harvestAll s n)
      exact onSuccess_if _ _ _ _ trivial (harvestAll_activeFeeSafe s n h)
    · exact raw_compound_activeFeeSafe s caller a b n h
    · exact h
    · exact h
    · change OnSuccess _ (if a == 0 then .ok ({ s with
          feesCollateral := 0, collateral := s.collateral.set! 3 (s.collateral[3]!+s.feesCollateral) }, 0)
        else .ok ({ s with feesHollar := 0, treasuryCash := s.treasuryCash+s.feesHollar }, 0))
      split <;> exact h
    · exact h
    · exact h
    · exact h

theorem rawExecute_activeFeeSafe (s : State) (a : Action) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (rawExecute s a).1 := by
  have hn := rawRunCall_activeFeeSafe s a h
  cases heq : rawRunCall s a with
  | error code => simpa only [rawExecute, heq] using h
  | ok result =>
    have hr := onSuccess_of_eq hn heq
    simpa only [rawExecute, heq] using hr

theorem rawReplay_activeFeeSafe (s : State) (actions : List Action) (h : ActiveFeeSafe s) :
    ActiveFeeSafe (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => exact h
  | cons a rest ih => exact ih (rawExecute s a).1 (rawExecute_activeFeeSafe s a h)

theorem rawReplay_genesis_activeFeeSafe (actions : List Action) :
    ActiveFeeSafe (rawReplay ({} : State) actions) := rawReplay_activeFeeSafe _ actions activeFeeSafe_genesis

theorem rawReplay_genesis_zeroActiveFee (actions : List Action) :
    ZeroActiveFee (rawReplay ({} : State) actions) := (rawReplay_genesis_activeFeeSafe actions).2

theorem validSolidityReachable_activeFeeSafe {initial s : State}
    (reachable : ValidSolidityReachable initial s) (h : ActiveFeeSafe initial) : ActiveFeeSafe s := by
  induction reachable with
  | genesis => exact h
  | step reachable a valid ih => exact rawExecute_activeFeeSafe _ a ih

end Juicer.PublicCalls
