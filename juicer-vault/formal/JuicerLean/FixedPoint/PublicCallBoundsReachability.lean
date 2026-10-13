import JuicerLean.FixedPoint.PublicCallBounds
import JuicerLean.FixedPoint.PublicMetadataReachability
import JuicerLean.FixedPoint.PublicReachability

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem initialMint_callBounds (s : State) (h : PublicCallBounds s) : PublicCallBounds (initialMint s) := by
  unfold initialMint
  split <;> exact h

theorem mintWallet_callBounds (s : State) (receiver shares : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (mintWallet s receiver shares) := h

theorem depositAssets_callBounds (s : State) (caller amount : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (depositAssets s caller amount) := h

theorem depositResult_callBounds (s : State) (caller receiver amount shares needed : Nat)
    (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1)
      (depositResult s caller receiver amount shares needed) := by
  unfold depositResult
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · rw [onSuccess_bind]
      intro next heq
      have hm := mintWallet_callBounds (initialMint s) receiver shares (initialMint_callBounds s h)
      have ha := depositAssets_callBounds (mintWallet (initialMint s) receiver shares) caller amount hm
      have hn := onSuccess_of_eq (cover_callBounds _ _ ha) heq
      exact hn

theorem raw_deposit_callBounds (s : State) (caller a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s ⟨0, caller, a, b, n⟩) := by
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
                        · exact depositResult_callBounds _ caller b n _ _
                            (checkpoint_callBounds _ zeroId b
                              (callBounds_synth (pay s 0 0).1 s.synth (pay_callBounds s 0 0 h)))

theorem transfer_result_callBounds (s : State) (a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1)
      (do let next ← transfer s a b n; pure (next, 1)) := by
  rw [onSuccess_bind]
  intro next heq
  change PublicCallBounds next
  exact onSuccess_of_eq (transfer_callBounds s a b n h) heq

theorem raw_transferFrom_callBounds (s : State) (caller a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s ⟨3, caller, a, b, n⟩) := by
  rw [rawRunCall_transferFrom]
  dsimp only
  split
  · split
    · trivial
    · exact transfer_result_callBounds _ a b n h
  · exact transfer_result_callBounds s a b n h

theorem requestTail_callBounds (s : State) (owner escrow amount : Nat)
    (h : PublicCallBounds s) (ho : owner < 5) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (requestTail s owner escrow amount) := by
  rw [requestTail_factored, onSuccess_bind]
  intro next heq
  change PublicCallBounds next
  exact onSuccess_of_eq (commitRequest_callBounds s owner escrow amount h ho) heq

theorem raw_request_callBounds (s : State) (caller a b n : Nat)
    (h : PublicCallBounds s) (ho : a < 5) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s ⟨4, caller, a, b, n⟩) := by
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
        have hp := onSuccess_of_eq (spend_callBounds _ a caller _ (checkpoint_callBounds s a zeroId h)) hpaid
        rw [onSuccess_bind]
        intro moved hmoved
        exact requestTail_callBounds moved a _ _ (onSuccess_of_eq (transfer_callBounds paid a vaultId _ hp) hmoved) ho

theorem raw_startUnwinds_callBounds (s : State) (caller a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s ⟨5, caller, a, b, n⟩) := by
  rw [raw_startUnwinds_factored]
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · exact h
    · rw [onSuccess_map]
      exact startMany_callBounds n s s.unwind h

theorem pokeSettleTail_callBounds (s : State) (h : PublicCallBounds s) : PublicCallBounds (pokeSettleTail s) := by
  unfold pokeSettleTail
  apply settleMany_callBounds 32
  exact callBounds_delever (pay s 0 s.delever).1 _ (pay_callBounds s 0 s.delever h)

theorem raw_pokeSettle_callBounds (s : State) (caller a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s ⟨6, caller, a, b, n⟩) :=
  let gross := s.freed*s.pullBps/10000
  let cost := gross*s.costBps/10000
  let next := { s with freed := s.freed-gross, sourceCash := s.sourceCash-gross, sourceCost := s.sourceCost+cost }
  let hn : PublicCallBounds next := h
  let hc := credit_callBounds next (gross-cost) cost hn
  (congrArg (OnSuccess (fun result : State × Nat => PublicCallBounds result.1))
    (raw_pokeSettle_factored s caller a b n)).mpr (pokeSettleTail_callBounds _ hc)

theorem claimState_callBounds (s : State) (i receiver : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (claimState s i receiver) :=
  callBounds_setRequest s i _ h (h.2.2 i)

theorem raw_claim_callBounds (s : State) (caller a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s ⟨7, caller, a, b, n⟩) := by
  rw [rawRunCall_claim]
  split_ifs <;> first | trivial | exact claimState_callBounds s n _ h

theorem mintMainPosition_callBounds (s : State) (units principal : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (mintMainPosition s units principal) := h

theorem depositSourceState_callBounds (s : State) (shares amount : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (depositSourceState s shares amount) := h

theorem depositSource_callBounds (s : State) (amount : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (depositSource s amount) := depositSourceState_callBounds s _ amount h

theorem callBounds_debtSynth (s : State) (debt synth : Nat) (h : PublicCallBounds s) :
    PublicCallBounds { s with debt := debt, synth := synth } := h

theorem borrowSource_callBounds (s : State) (amount supplied : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (borrowSource s amount supplied) :=
  callBounds_debtSynth _ _ supplied (depositSource_callBounds _ amount (mintMainPosition_callBounds s _ _ h))

theorem borrowResult_callBounds (s : State) (amount : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (borrowResult s amount) := by
  unfold borrowResult
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · trivial
    · exact onSuccess_if _ _ _ _ trivial (borrowSource_callBounds s amount _ h)

theorem rebalanceEnter_callBounds (s : State) (resize : Bool) (coll8 debt8 target : Nat)
    (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rebalanceEnter s resize coll8 debt8 target) := by
  unfold rebalanceEnter
  apply onSuccess_if
  · trivial
  · rw [borrowResult_factored]
    exact borrowResult_callBounds _ _ (callBounds_synth (pay s 0 0).1 s.synth (pay_callBounds s 0 0 h))

theorem activeDelever_callBounds (s : State) (slice basis : Nat) (f : SourceFee) (h : PublicCallBounds s) :
    PublicCallBounds (addActiveFee (unwindActiveSource s slice basis) f) := h

theorem rebalanceDelever_callBounds (s : State) (debt8 target : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rebalanceDelever s debt8 target) := by
  unfold rebalanceDelever
  dsimp only
  apply onSuccess_if
  · exact onSuccess_if _ _ _ _ trivial (activeDelever_callBounds s _ _ _ h)
  · exact h

theorem rebalanceTail_callBounds (s : State) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rebalanceTail s) := by
  unfold rebalanceTail
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · exact h
    · apply onSuccess_if
      · exact rebalanceEnter_callBounds s _ _ _ _ h
      · exact onSuccess_if _ _ _ _ (rebalanceDelever_callBounds s _ _ h) h

theorem raw_rebalance_callBounds (s : State) (caller a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s ⟨9, caller, a, b, n⟩) := by
  rw [raw_rebalance_factored, rebalanceTail_factored]
  exact onSuccess_if _ _ _ _ trivial (rebalanceTail_callBounds _ (checkpoint_callBounds s zeroId zeroId h))

theorem withdrawSource_callBounds (s : State) (burned : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (withdrawSource s burned) := h

theorem harvestFunding_callBounds (s : State) (burned : Nat) (h : PublicCallBounds s) :
    PublicCallBounds (harvestFunding s burned) :=
  let slice := harvestSlice (harvestable s) s.book.source s.book.protocol burned
  bookFunding_callBounds _ (s.book.source-slice.1) (s.book.protocol-slice.2) s.basis (withdrawSource_callBounds s burned h)

theorem harvestAll_callBounds (s : State) (minimum : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (harvestAll s minimum) := by
  rw [harvestProgram_exact]
  have hn := checkpoint_callBounds s zeroId zeroId h
  exact harvestProgram_preserves harvestable sourceValue quoteCollateral splitHarvest compoundFunds
    PublicCallBounds (checkpoint s zeroId zeroId) minimum hn
    (harvestFunding_callBounds (checkpoint s zeroId zeroId) (harvestBurn (checkpoint s zeroId zeroId)) hn)
    compoundFunds_callBounds (fun _ hx => hx)

theorem raw_compound_callBounds (s : State) (caller a b n : Nat) (h : PublicCallBounds s) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s ⟨24, caller, a, b, n⟩) := by
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
          change PublicCallBounds next
          exact onSuccess_of_eq (compoundFunds_callBounds
            { s with collateral := s.collateral.set! caller (s.collateral[caller]!-n) } n 0 n 0 h) heq

theorem rawRunCall_callBounds (s : State) (action : Action) (h : PublicCallBounds s)
    (fixture : FixtureAction action) :
    OnSuccess (fun result : State × Nat => PublicCallBounds result.1) (rawRunCall s action) := by
  rcases action with ⟨op, caller, a, b, n⟩
  rcases fixture with ⟨hop, _, _, _, _, _, ho, _, _, hp, _, hf, hc, _, _⟩
  change op ≤ 30 at hop
  interval_cases op
  · exact raw_deposit_callBounds s caller a b n h
  · exact h
  · exact transfer_result_callBounds s caller b n h
  · exact raw_transferFrom_callBounds s caller a b n h
  · exact raw_request_callBounds s caller a b n h (Nat.lt_trans (ho rfl).2 (by decide : 4 < 5))
  · exact raw_startUnwinds_callBounds s caller a b n h
  · exact raw_pokeSettle_callBounds s caller a b n h
  · exact raw_claim_callBounds s caller a b n h
  · change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
      else .ok (checkpoint s zeroId zeroId, harvestable (checkpoint s zeroId zeroId)))
    exact onSuccess_if _ _ _ _ trivial (checkpoint_callBounds s zeroId zeroId h)
  · exact raw_rebalance_callBounds s caller a b n h
  · exact h
  · exact h
  · exact ⟨⟨hp rfl, h.1.2⟩, h.2⟩
  · exact h
  · change OnSuccess _ (if n != 0 && (s.paused || s.sourcePaused) then .error 1
      else if n == 0 && !s.paused && !s.sourcePaused then .error 22
      else .ok ({ s with paused := n != 0 }, 0))
    split_ifs <;> trivial
  · exact h
  · exact h
  · exact h
  · exact ⟨h.1, (hf rfl).2, h.2.2⟩
  · exact ⟨⟨h.1.1, hc rfl⟩, h.2⟩
  · exact h
  · exact h
  · change OnSuccess _ (.ok (maintainPegState s))
    unfold maintainPegState
    split <;> exact h
  · change OnSuccess _ (if s.paused || s.sourcePaused then .error 1 else harvestAll s n)
    exact onSuccess_if _ _ _ _ trivial (harvestAll_callBounds s n h)
  · exact raw_compound_callBounds s caller a b n h
  · exact h
  · exact h
  · change OnSuccess _ (if a == 0 then .ok ({ s with
        feesCollateral := 0, collateral := s.collateral.set! 3 (s.collateral[3]!+s.feesCollateral) }, 0)
      else .ok ({ s with feesHollar := 0, treasuryCash := s.treasuryCash+s.feesHollar }, 0))
    split <;> exact h
  · exact h
  · exact h
  · exact h

theorem rawExecute_callBounds (s : State) (a : Action) (h : PublicCallBounds s)
    (fixture : FixtureAction a) : PublicCallBounds (rawExecute s a).1 := by
  have hn := rawRunCall_callBounds s a h fixture
  cases heq : rawRunCall s a with
  | error code => simpa only [rawExecute, heq] using h
  | ok result =>
    have hr := onSuccess_of_eq hn heq
    simpa only [rawExecute, heq] using hr

theorem rawReplay_callBounds (s : State) (actions : List Action) (h : PublicCallBounds s)
    (fixture : ∀ a ∈ actions, FixtureAction a) : PublicCallBounds (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => exact h
  | cons a rest ih =>
    exact ih (rawExecute s a).1 (rawExecute_callBounds s a h (fixture a List.mem_cons_self))
      (fun b hb => fixture b (List.mem_cons_of_mem _ hb))

theorem rawReplay_genesis_callBounds (actions : List Action)
    (fixture : ∀ a ∈ actions, FixtureAction a) : PublicCallBounds (rawReplay ({} : State) actions) :=
  rawReplay_callBounds _ actions callBounds_genesis fixture

theorem rawReplay_genesis_sourcePullBounds (actions : List Action)
    (fixture : ∀ a ∈ actions, FixtureAction a) : SourcePullBounds (rawReplay ({} : State) actions) :=
  (rawReplay_genesis_callBounds actions fixture).1

theorem rawReplay_genesis_feeBound (actions : List Action)
    (fixture : ∀ a ∈ actions, FixtureAction a) : (rawReplay ({} : State) actions).feeBps ≤ 10000 :=
  (rawReplay_genesis_callBounds actions fixture).2.1

theorem rawReplay_genesis_requestOwners (actions : List Action)
    (fixture : ∀ a ∈ actions, FixtureAction a) : RequestOwners (rawReplay ({} : State) actions) :=
  (rawReplay_genesis_callBounds actions fixture).2.2

theorem rawReplay_genesis_waitingOwners (actions : List Action)
    (fixture : ∀ a ∈ actions, FixtureAction a) : WaitingOwners (rawReplay ({} : State) actions) :=
  callBounds_waitingOwners _ (rawReplay_genesis_callBounds actions fixture)

theorem validSolidityReachable_callBounds {initial s : State}
    (reachable : ValidSolidityReachable initial s) (h : PublicCallBounds initial) : PublicCallBounds s := by
  induction reachable with
  | genesis => exact h
  | step reachable a valid ih => exact rawExecute_callBounds _ a ih valid.1

theorem reachable_pokeSettle_action_valid {initial s : State} {a : Action}
    (reachable : ValidSolidityReachable initial s) (bounds : PublicCallBounds initial)
    (fixture : FixtureAction a) (op : a.op = 6) (credit : CreditReady s) (queue : QueueBacking s) :
    ValidSolidityAction s a :=
  pokeSettle_action_valid fixture op credit queue (validSolidityReachable_callBounds reachable bounds).1

theorem reachable_startUnwinds_action_valid {initial s : State} {a : Action}
    (reachable : ValidSolidityReachable initial s) (metadata : PublicMetadata initial)
    (bounds : PublicCallBounds initial) (fixture : FixtureAction a) (op : a.op = 5)
    (queue : QueueBacking s) : ValidSolidityAction s a := by
  have hb := validSolidityReachable_callBounds reachable bounds
  exact startUnwinds_action_valid fixture op
    ⟨validSolidityReachable_metadata reachable metadata, queue, callBounds_waitingOwners s hb, hb.2.1⟩

end Juicer.PublicCalls
