import JuicerLean.FixedPoint.PublicMetadataTransitions
import JuicerLean.FixedPoint.PublicReachability

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem initialMint_metadata (s : State) (h : PublicMetadata s) : PublicMetadata (initialMint s) := by
  unfold initialMint
  split <;> exact h

theorem mintWallet_metadata (s : State) (receiver shares : Nat) (h : PublicMetadata s) :
    PublicMetadata (mintWallet s receiver shares) := h

theorem depositAssets_metadata (s : State) (caller amount : Nat) (h : PublicMetadata s) :
    PublicMetadata (depositAssets s caller amount) := h

theorem depositResult_metadata (s : State) (caller receiver amount shares needed : Nat)
    (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1)
      (depositResult s caller receiver amount shares needed) := by
  unfold depositResult
  rw [onSuccess_bind]
  intro next heq
  have hm := mintWallet_metadata (initialMint s) receiver shares (initialMint_metadata s h)
  have ha := depositAssets_metadata (mintWallet (initialMint s) receiver shares) caller amount hm
  have hn := onSuccess_of_eq (cover_metadata _ _ ha) heq
  change OnSuccess _ (if next.synth*9800/10000 < next.debt then .error 23 else .ok (next, shares))
  exact onSuccess_if _ _ _ _ trivial hn

theorem raw_deposit_metadata (s : State) (caller a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s ⟨0, caller, a, b, n⟩) := by
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
                    · exact depositResult_metadata _ caller b n _ _
                        (checkpoint_metadata _ zeroId b
                          (metadata_synth (pay s 0 0).1 s.synth (pay_metadata s 0 0 h)))

theorem transfer_result_metadata (s : State) (a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1)
      (do let next ← transfer s a b n; pure (next, 1)) := by
  rw [onSuccess_bind]
  intro next heq
  change PublicMetadata next
  exact onSuccess_of_eq (transfer_metadata s a b n h) heq

theorem raw_transferFrom_metadata (s : State) (caller a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s ⟨3, caller, a, b, n⟩) := by
  rw [rawRunCall_transferFrom]
  dsimp only
  split
  · split
    · trivial
    · exact transfer_result_metadata _ a b n h
  · exact transfer_result_metadata s a b n h

theorem requestTail_metadata (s : State) (owner escrow amount : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (requestTail s owner escrow amount) := by
  rw [requestTail_factored, onSuccess_bind]
  intro next heq
  change PublicMetadata next
  exact onSuccess_of_eq (commitRequest_metadata s owner escrow amount h) heq

theorem raw_request_metadata (s : State) (caller a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s ⟨4, caller, a, b, n⟩) := by
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
        have hp := onSuccess_of_eq (spend_metadata _ a caller _ (checkpoint_metadata s a zeroId h)) hpaid
        rw [onSuccess_bind]
        intro moved hmoved
        exact requestTail_metadata moved a _ _ (onSuccess_of_eq (transfer_metadata paid a vaultId _ hp) hmoved)

theorem raw_startUnwinds_metadata (s : State) (caller a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s ⟨5, caller, a, b, n⟩) := by
  rw [raw_startUnwinds_factored]
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · exact h
    · rw [onSuccess_map]
      exact startMany_metadata n s s.unwind h

theorem pokeSettleTail_metadata (s : State) (h : PublicMetadata s) : PublicMetadata (pokeSettleTail s) := by
  unfold pokeSettleTail
  apply settleMany_metadata 32
  exact metadata_delever (pay s 0 s.delever).1 _ (pay_metadata s 0 s.delever h)

theorem raw_pokeSettle_metadata (s : State) (caller a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s ⟨6, caller, a, b, n⟩) :=
  let gross := s.freed*s.pullBps/10000
  let cost := gross*s.costBps/10000
  let next := { s with freed := s.freed-gross, sourceCash := s.sourceCash-gross, sourceCost := s.sourceCost+cost }
  let hn : PublicMetadata next := h
  let hc := credit_metadata next (gross-cost) cost hn
  (congrArg (OnSuccess (fun result : State × Nat => PublicMetadata result.1))
    (raw_pokeSettle_factored s caller a b n)).mpr (pokeSettleTail_metadata _ hc)

theorem claimState_metadata (s : State) (i receiver : Nat) (h : PublicMetadata s) :
    PublicMetadata (claimState s i receiver) :=
  metadata_setRequest s i _ h (metadata_request s i h)

theorem raw_claim_metadata (s : State) (caller a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s ⟨7, caller, a, b, n⟩) := by
  rw [rawRunCall_claim]
  split_ifs <;> first | trivial | exact claimState_metadata s n _ h

theorem mintMainPosition_metadata (s : State) (units principal : Nat) (h : PublicMetadata s) :
    PublicMetadata (mintMainPosition s units principal) := h

theorem depositSourceState_metadata (s : State) (shares amount : Nat) (h : PublicMetadata s) :
    PublicMetadata (depositSourceState s shares amount) := h

theorem depositSource_metadata (s : State) (amount : Nat) (h : PublicMetadata s) :
    PublicMetadata (depositSource s amount) := depositSourceState_metadata s _ amount h

theorem metadata_debtSynth (s : State) (debt synth : Nat) (h : PublicMetadata s) :
    PublicMetadata { s with debt := debt, synth := synth } := h

theorem borrowSource_metadata (s : State) (amount supplied : Nat) (h : PublicMetadata s) :
    PublicMetadata (borrowSource s amount supplied) :=
  metadata_debtSynth _ _ supplied (depositSource_metadata _ amount (mintMainPosition_metadata s _ _ h))

theorem borrowResult_metadata (s : State) (amount : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (borrowResult s amount) := by
  unfold borrowResult
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · trivial
    · exact onSuccess_if _ _ _ _ trivial (borrowSource_metadata s amount _ h)

theorem rebalanceEnter_metadata (s : State) (resize : Bool) (coll8 debt8 target : Nat)
    (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rebalanceEnter s resize coll8 debt8 target) := by
  unfold rebalanceEnter
  apply onSuccess_if
  · trivial
  · rw [borrowResult_factored]
    exact borrowResult_metadata _ _ (metadata_synth (pay s 0 0).1 s.synth (pay_metadata s 0 0 h))

theorem activeDelever_metadata (s : State) (slice basis : Nat) (f : SourceFee) (h : PublicMetadata s) :
    PublicMetadata (addActiveFee (unwindActiveSource s slice basis) f) := h

theorem rebalanceDelever_metadata (s : State) (debt8 target : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rebalanceDelever s debt8 target) := by
  unfold rebalanceDelever
  dsimp only
  apply onSuccess_if
  · exact onSuccess_if _ _ _ _ trivial (activeDelever_metadata s _ _ _ h)
  · exact h

theorem rebalanceTail_metadata (s : State) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rebalanceTail s) := by
  unfold rebalanceTail
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · exact h
    · apply onSuccess_if
      · exact rebalanceEnter_metadata s _ _ _ _ h
      · exact onSuccess_if _ _ _ _ (rebalanceDelever_metadata s _ _ h) h

theorem raw_rebalance_metadata (s : State) (caller a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s ⟨9, caller, a, b, n⟩) := by
  rw [raw_rebalance_factored, rebalanceTail_factored]
  exact onSuccess_if _ _ _ _ trivial (rebalanceTail_metadata _ (checkpoint_metadata s zeroId zeroId h))

theorem withdrawSource_metadata (s : State) (burned : Nat) (h : PublicMetadata s) :
    PublicMetadata (withdrawSource s burned) := h

theorem harvestFunding_metadata (s : State) (burned : Nat) (h : PublicMetadata s) :
    PublicMetadata (harvestFunding s burned) :=
  bookFunding_metadata _ 0 0 s.basis (withdrawSource_metadata s burned h)

theorem harvestAll_metadata (s : State) (minimum : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (harvestAll s minimum) := by
  rw [harvestProgram_exact]
  have hn := checkpoint_metadata s zeroId zeroId h
  exact harvestProgram_preserves harvestable sourceValue quoteCollateral splitHarvest compoundFunds
    PublicMetadata (checkpoint s zeroId zeroId) minimum hn
    (harvestFunding_metadata (checkpoint s zeroId zeroId) (harvestable (checkpoint s zeroId zeroId)) hn)
    compoundFunds_metadata (fun _ hx => hx)

theorem raw_compound_metadata (s : State) (caller a b n : Nat) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s ⟨24, caller, a, b, n⟩) := by
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
          change PublicMetadata next
          exact onSuccess_of_eq (compoundFunds_metadata
            { s with collateral := s.collateral.set! caller (s.collateral[caller]!-n) } n 0 n 0 h) heq

theorem rawRunCall_metadata (s : State) (action : Action) (h : PublicMetadata s) :
    OnSuccess (fun result : State × Nat => PublicMetadata result.1) (rawRunCall s action) := by
  by_cases unsupported : 31 ≤ action.op
  · rw [rawRunCall_unsupported s action unsupported]
    trivial
  · rcases action with ⟨op, caller, a, b, n⟩
    have hop : op ≤ 30 := by change ¬ 31 ≤ op at unsupported; omega
    interval_cases op
    · exact raw_deposit_metadata s caller a b n h
    · exact h
    · exact transfer_result_metadata s caller b n h
    · exact raw_transferFrom_metadata s caller a b n h
    · exact raw_request_metadata s caller a b n h
    · exact raw_startUnwinds_metadata s caller a b n h
    · exact raw_pokeSettle_metadata s caller a b n h
    · exact raw_claim_metadata s caller a b n h
    · change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
        else .ok (checkpoint s zeroId zeroId, harvestable (checkpoint s zeroId zeroId)))
      exact onSuccess_if _ _ _ _ trivial (checkpoint_metadata s zeroId zeroId h)
    · exact raw_rebalance_metadata s caller a b n h
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
      exact onSuccess_if _ _ _ _ trivial (harvestAll_metadata s n h)
    · exact raw_compound_metadata s caller a b n h
    · exact h
    · exact h
    · change OnSuccess _ (if a == 0 then .ok ({ s with
          feesCollateral := 0, collateral := s.collateral.set! 3 (s.collateral[3]!+s.feesCollateral) }, 0)
        else .ok ({ s with feesHollar := 0, treasuryCash := s.treasuryCash+s.feesHollar }, 0))
      split <;> exact h
    · exact h
    · exact h
    · exact h

theorem rawExecute_metadata (s : State) (a : Action) (h : PublicMetadata s) :
    PublicMetadata (rawExecute s a).1 := by
  have hn := rawRunCall_metadata s a h
  cases heq : rawRunCall s a with
  | error code => simpa only [rawExecute, heq] using h
  | ok result =>
    have hr := onSuccess_of_eq hn heq
    simpa only [rawExecute, heq] using hr

theorem rawReplay_metadata (s : State) (actions : List Action) (h : PublicMetadata s) :
    PublicMetadata (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => exact h
  | cons a rest ih => exact ih (rawExecute s a).1 (rawExecute_metadata s a h)

theorem rawReplay_genesis_metadata (actions : List Action) :
    PublicMetadata (rawReplay ({} : State) actions) := rawReplay_metadata _ actions metadata_genesis

theorem rawReplay_genesis_accountHistory (actions : List Action) (i : Nat) :
    AccountHistory (rawReplay ({} : State) actions).book (account (rawReplay ({} : State) actions) i) :=
  metadata_account _ i (rawReplay_genesis_metadata actions)

theorem rawReplay_genesis_requestHistory (actions : List Action) (i : Nat) :
    AccountHistory (rawReplay ({} : State) actions).book (request (rawReplay ({} : State) actions) i).account :=
  metadata_request _ i (rawReplay_genesis_metadata actions)

theorem validSolidityReachable_metadata {initial s : State}
    (reachable : ValidSolidityReachable initial s) (h : PublicMetadata initial) : PublicMetadata s := by
  induction reachable with
  | genesis => exact h
  | step reachable a valid ih => exact rawExecute_metadata _ a ih

end Juicer.PublicCalls
