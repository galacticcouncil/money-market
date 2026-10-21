import JuicerLean.FixedPoint.PublicQueueTransitions
import JuicerLean.FixedPoint.PublicCallBoundsReachability
import JuicerLean.FixedPoint.PublicReachability

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem initialMint_queue (s : State) (h : QueueBacking s) : QueueBacking (initialMint s) := by
  unfold initialMint
  split <;> exact h

theorem mintWallet_queue (s : State) (receiver shares : Nat) (h : QueueBacking s) :
    QueueBacking (mintWallet s receiver shares) := h

theorem depositAssets_queue (s : State) (caller amount : Nat) (h : QueueBacking s) :
    QueueBacking (depositAssets s caller amount) := ⟨h.1.trans (Nat.le_add_right _ _), h.2⟩

theorem depositResult_queue (s : State) (caller receiver amount shares needed : Nat)
    (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1)
      (depositResult s caller receiver amount shares needed) := by
  unfold depositResult
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · rw [onSuccess_bind]
      intro next heq
      have hm := mintWallet_queue (initialMint s) receiver shares (initialMint_queue s h)
      have ha := depositAssets_queue (mintWallet (initialMint s) receiver shares) caller amount hm
      have hn := onSuccess_of_eq (cover_queue _ _ ha) heq
      exact hn

theorem raw_deposit_queue (s : State) (caller a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s ⟨0, caller, a, b, n⟩) := by
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
                        · exact depositResult_queue _ caller b n _ _
                            (checkpoint_queue _ zeroId b
                              (queue_synth (pay s 0 0).1 s.synth (pay_queue s 0 0 h)))

theorem transfer_result_queue (s : State) (a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1)
      (do let next ← transfer s a b n; pure (next, 1)) := by
  rw [onSuccess_bind]
  intro next heq
  change QueueBacking next
  exact onSuccess_of_eq (transfer_queue s a b n h) heq

theorem raw_transferFrom_queue (s : State) (caller a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s ⟨3, caller, a, b, n⟩) := by
  rw [rawRunCall_transferFrom]
  dsimp only
  split
  · split
    · trivial
    · exact transfer_result_queue _ a b n h
  · exact transfer_result_queue s a b n h

theorem requestTail_queue (s : State) (owner escrow amount : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (requestTail s owner escrow amount) := by
  rw [requestTail_factored, onSuccess_bind]
  intro next heq
  change QueueBacking next
  exact onSuccess_of_eq (commitRequest_queue s owner escrow amount h) heq

theorem raw_request_queue (s : State) (caller a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s ⟨4, caller, a, b, n⟩) := by
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
        have hp := onSuccess_of_eq (spend_queue _ a caller _ (checkpoint_queue s a zeroId h)) hpaid
        rw [onSuccess_bind]
        intro moved hmoved
        exact requestTail_queue moved a _ _ (onSuccess_of_eq (transfer_queue paid a vaultId _ hp) hmoved)

theorem raw_startUnwinds_queue (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) (hr : UnwindReady s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s ⟨5, caller, a, b, n⟩) := by
  rw [raw_startUnwinds_factored]
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · exact hr.2.1
    · rw [onSuccess_map]
      have hp := startMany_preserves n s s.unwind h hr
      cases heq : startMany n s s.unwind with
      | error e => trivial
      | ok result => exact (onSuccess_of_eq hp heq).2.2.1

theorem pokeSettleTail_queue (s : State) (h : QueueBacking s) : QueueBacking (pokeSettleTail s) := by
  unfold pokeSettleTail
  apply settleMany_queue 32
  exact queue_delever (pay s 0 s.delever).1 _ (pay_queue s 0 s.delever h)

theorem raw_pokeSettle_queue (s : State) (caller a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s ⟨6, caller, a, b, n⟩) :=
  let gross := s.freed*s.pullBps/10000
  let cost := gross*s.costBps/10000
  let next := { s with freed := s.freed-gross, sourceCash := s.sourceCash-gross, sourceCost := s.sourceCost+cost }
  let hn : QueueBacking next := h
  let hc := credit_queue next (gross-cost) cost hn
  (congrArg (OnSuccess (fun result : State × Nat => QueueBacking result.1))
    (raw_pokeSettle_factored s caller a b n)).mpr (pokeSettleTail_queue _ hc)

theorem claimState_queue (s : State) (i receiver : Nat) (h : QueueBacking s) :
    QueueBacking (claimState s i receiver) := by
  refine ⟨?_, h.2⟩
  change s.owed - (request s i).claim.settled ≤
    s.assets - (if receiver == vaultId then 0 else (request s i).claim.settled)
  split
  · simpa only [Nat.sub_zero] using (Nat.sub_le s.owed (request s i).claim.settled).trans h.1
  · exact Nat.sub_le_sub_right h.1 _

theorem raw_claim_queue (s : State) (caller a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s ⟨7, caller, a, b, n⟩) := by
  rw [rawRunCall_claim]
  split_ifs <;> first | trivial | exact claimState_queue s n _ h

theorem mintMainPosition_queue (s : State) (units principal : Nat) (h : QueueBacking s) :
    QueueBacking (mintMainPosition s units principal) := queue_setPosition _ 0 _ h

theorem depositSourceState_queue (s : State) (shares amount : Nat) (h : QueueBacking s) :
    QueueBacking (depositSourceState s shares amount) := h

theorem depositSource_queue (s : State) (amount : Nat) (h : QueueBacking s) :
    QueueBacking (depositSource s amount) := depositSourceState_queue s _ amount h

theorem queue_debtSynth (s : State) (debt synth : Nat) (h : QueueBacking s) :
    QueueBacking { s with debt := debt, synth := synth } := h

theorem borrowSource_queue (s : State) (amount supplied : Nat) (h : QueueBacking s) :
    QueueBacking (borrowSource s amount supplied) :=
  queue_debtSynth _ _ supplied (depositSource_queue _ amount (mintMainPosition_queue s _ _ h))

theorem borrowResult_queue (s : State) (amount : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (borrowResult s amount) := by
  unfold borrowResult
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · trivial
    · exact onSuccess_if _ _ _ _ trivial (borrowSource_queue s amount _ h)

theorem rebalanceEnter_queue (s : State) (resize : Bool) (coll8 debt8 target : Nat)
    (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rebalanceEnter s resize coll8 debt8 target) := by
  unfold rebalanceEnter
  apply onSuccess_if
  · trivial
  · rw [borrowResult_factored]
    exact borrowResult_queue _ _ (queue_synth (pay s 0 0).1 s.synth (pay_queue s 0 0 h))

theorem activeDelever_queue (s : State) (slice basis : Nat) (f : SourceFee) (h : QueueBacking s) :
    QueueBacking (addActiveFee (unwindActiveSource s slice basis) f) := h

theorem rebalanceDelever_queue (s : State) (debt8 target : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rebalanceDelever s debt8 target) := by
  unfold rebalanceDelever
  dsimp only
  apply onSuccess_if
  · exact onSuccess_if _ _ _ _ trivial (activeDelever_queue s _ _ _ h)
  · exact h

theorem rebalanceTail_queue (s : State) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rebalanceTail s) := by
  unfold rebalanceTail
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · exact h
    · apply onSuccess_if
      · exact rebalanceEnter_queue s _ _ _ _ h
      · exact onSuccess_if _ _ _ _ (rebalanceDelever_queue s _ _ h) h

theorem raw_rebalance_queue (s : State) (caller a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s ⟨9, caller, a, b, n⟩) := by
  rw [raw_rebalance_factored, rebalanceTail_factored]
  exact onSuccess_if _ _ _ _ trivial (rebalanceTail_queue _ (checkpoint_queue s zeroId zeroId h))

theorem withdrawSource_queue (s : State) (burned : Nat) (h : QueueBacking s) :
    QueueBacking (withdrawSource s burned) := h

theorem harvestFunding_queue (s : State) (burned : Nat) (h : QueueBacking s) :
    QueueBacking (harvestFunding s burned) :=
  let slice := harvestSlice (harvestable s) s.book.source s.book.protocol burned
  bookFunding_queue _ (s.book.source-slice.1) (s.book.protocol-slice.2) s.basis (withdrawSource_queue s burned h)

theorem harvestAll_queue (s : State) (minimum : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (harvestAll s minimum) := by
  rw [harvestProgram_exact]
  have hn := checkpoint_queue s zeroId zeroId h
  exact harvestProgram_preserves harvestable sourceValue quoteCollateral splitHarvest compoundFunds
    QueueBacking (checkpoint s zeroId zeroId) minimum hn
    (harvestFunding_queue (checkpoint s zeroId zeroId) (harvestBurn (checkpoint s zeroId zeroId)) hn)
    compoundFunds_queue (fun _ hx => hx)

theorem raw_compound_queue (s : State) (caller a b n : Nat) (h : QueueBacking s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s ⟨24, caller, a, b, n⟩) := by
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
          change QueueBacking next
          exact onSuccess_of_eq (compoundFunds_queue
            { s with collateral := s.collateral.set! caller (s.collateral[caller]!-n) } n 0 n 0 h) heq

theorem rawRunCall_queue (s : State) (action : Action) (h : QueueBacking s)
    (hpublic : PublicInvariant s) (metadata : PublicMetadata s) (bounds : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => QueueBacking result.1) (rawRunCall s action) := by
  by_cases unsupported : 31 ≤ action.op
  · rw [rawRunCall_unsupported s action unsupported]
    trivial
  · rcases action with ⟨op, caller, a, b, n⟩
    have hop : op ≤ 30 := by change ¬ 31 ≤ op at unsupported; omega
    interval_cases op
    · exact raw_deposit_queue s caller a b n h
    · exact h
    · exact transfer_result_queue s caller b n h
    · exact raw_transferFrom_queue s caller a b n h
    · exact raw_request_queue s caller a b n h
    · exact raw_startUnwinds_queue s caller a b n hpublic
        ⟨metadata, h, callBounds_waitingOwners s bounds, bounds.2.1⟩
    · exact raw_pokeSettle_queue s caller a b n h
    · exact raw_claim_queue s caller a b n h
    · change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
        else .ok (checkpoint s zeroId zeroId, harvestable (checkpoint s zeroId zeroId)))
      exact onSuccess_if _ _ _ _ trivial (checkpoint_queue s zeroId zeroId h)
    · exact raw_rebalance_queue s caller a b n h
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
      exact onSuccess_if _ _ _ _ trivial (harvestAll_queue s n h)
    · exact raw_compound_queue s caller a b n h
    · exact h
    · exact h
    · change OnSuccess _ (if a == 0 then .ok ({ s with
          feesCollateral := 0, collateral := s.collateral.set! 3 (s.collateral[3]!+s.feesCollateral) }, 0)
        else .ok ({ s with feesHollar := 0, treasuryCash := s.treasuryCash+s.feesHollar }, 0))
      split <;> exact h
    · exact h
    · exact h
    · exact queue_setPosition s 0 _ h

theorem rawExecute_queue (s : State) (a : Action) (h : QueueBacking s)
    (hpublic : PublicInvariant s) (metadata : PublicMetadata s) (bounds : PublicCallBounds s) :
    QueueBacking (rawExecute s a).1 := by
  have hn := rawRunCall_queue s a h hpublic metadata bounds
  cases heq : rawRunCall s a with
  | error code => simpa only [rawExecute, heq] using h
  | ok result =>
    have hr := onSuccess_of_eq hn heq
    simpa only [rawExecute, heq] using hr

theorem validSolidityReachable_queue {initial s : State}
    (reachable : ValidSolidityReachable initial s) (h : QueueBacking initial)
    (metadata : PublicMetadata initial) (bounds : PublicCallBounds initial) : QueueBacking s := by
  induction reachable with
  | genesis => exact h
  | step reachable a valid ih =>
    exact rawExecute_queue _ a ih (validSolidityReachable_invariant reachable)
      (validSolidityReachable_metadata reachable metadata)
      (validSolidityReachable_callBounds reachable bounds)

theorem validSolidityTrace_queue (s : State) (actions : List Action) (hpublic : PublicInvariant s)
    (h : QueueBacking s) (metadata : PublicMetadata s) (bounds : PublicCallBounds s)
    (valid : ValidSolidityTrace s actions) : QueueBacking (rawReplay s actions) :=
  validSolidityReachable_queue (validSolidityTrace_reachable (.genesis hpublic) valid) h metadata bounds

end Juicer.PublicCalls
