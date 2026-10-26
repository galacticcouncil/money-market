import JuicerLean.FixedPoint.PublicCallBoundsReachability
import JuicerLean.FixedPoint.PublicActiveFeeReachability
import JuicerLean.FixedPoint.PublicCreditTransitions
import JuicerLean.FixedPoint.PublicReachability

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem initialMint_creditReady (s : State) (h : CreditReadyHistory s) : CreditReadyHistory (initialMint s) := by
  unfold initialMint
  split <;> exact h

theorem mintWallet_creditReady (s : State) (receiver shares : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (mintWallet s receiver shares) := h

theorem depositAssets_creditReady (s : State) (caller amount : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (depositAssets s caller amount) := h

theorem depositResult_creditReady (s : State) (caller receiver amount shares needed : Nat)
    (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1)
      (depositResult s caller receiver amount shares needed) := by
  unfold depositResult
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · rw [onSuccess_bind]
      intro next heq
      have hm := mintWallet_creditReady (initialMint s) receiver shares (initialMint_creditReady s h)
      have ha := depositAssets_creditReady (mintWallet (initialMint s) receiver shares) caller amount hm
      have hn := onSuccess_of_eq (cover_creditReady _ _ ha) heq
      exact hn

theorem raw_deposit_creditReady (s : State) (caller a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s ⟨0, caller, a, b, n⟩) := by
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
                        · exact depositResult_creditReady _ caller b n _ _
                            (checkpoint_creditReady _ zeroId b
                              (creditReady_synth (pay s 0 0).1 s.synth (pay_creditReady s 0 0 h)))

theorem transfer_result_creditReady (s : State) (a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1)
      (do let next ← transfer s a b n; pure (next, 1)) := by
  rw [onSuccess_bind]
  intro next heq
  change CreditReadyHistory next
  exact onSuccess_of_eq (transfer_creditReady s a b n h) heq

theorem raw_transferFrom_creditReady (s : State) (caller a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s ⟨3, caller, a, b, n⟩) := by
  rw [rawRunCall_transferFrom]
  dsimp only
  split
  · split
    · trivial
    · exact transfer_result_creditReady _ a b n h
  · exact transfer_result_creditReady s a b n h

theorem requestTail_creditReady (s : State) (owner escrow amount : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (requestTail s owner escrow amount) := by
  rw [requestTail_factored, onSuccess_bind]
  intro next heq
  change CreditReadyHistory next
  exact onSuccess_of_eq (commitRequest_creditReady s owner escrow amount h) heq

theorem raw_request_creditReady (s : State) (caller a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s ⟨4, caller, a, b, n⟩) := by
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
        have hp := onSuccess_of_eq (spend_creditReady _ a caller _ (checkpoint_creditReady s a zeroId h)) hpaid
        rw [onSuccess_bind]
        intro moved hmoved
        exact requestTail_creditReady moved a _ _ (onSuccess_of_eq (transfer_creditReady paid a vaultId _ hp) hmoved)

theorem raw_startUnwinds_creditReady (s : State) (caller a b n : Nat) (h : CreditReadyHistory s)
    (hpublic : PublicInvariant s) (hactive : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s ⟨5, caller, a, b, n⟩) := by
  rw [raw_startUnwinds_factored]
  split
  · trivial
  · split
    · exact h
    · rename_i hguard
      have hz : s.activeRemaining = 0 := by
        simp only [Bool.or_eq_true, bne_iff_ne] at hguard
        omega
      have align : s.sourceFees.size = s.positions.size := hpublic.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
      have hp := startMany_creditReady n s s.unwind ⟨h, align, hactive.2 hz⟩
      rw [onSuccess_map]
      cases heq : startMany n s s.unwind with
      | error code => trivial
      | ok result => exact (onSuccess_of_eq hp heq).1

theorem pokeSettleTail_creditReady (s : State) (h : CreditReadyHistory s) : CreditReadyHistory (pokeSettleTail s) := by
  unfold pokeSettleTail
  apply settleMany_creditReady 32
  exact creditReady_delever (pay s 0 s.delever).1 _ (pay_creditReady s 0 s.delever h)

theorem sourceCredit_ready (s : State) (gross cost : Nat) (hpublic : PublicInvariant s)
    (h : CreditReadyHistory s) (hg : gross ≤ s.freed) (hc : cost ≤ gross) :
    CreditReadyHistory (credit { s with
      freed := s.freed-gross, sourceCash := s.sourceCash-gross, sourceCost := s.sourceCost+cost } (gross-cost) cost) := by
  have he : gross-cost+cost = gross := Nat.sub_add_cancel hc
  let pulled := { s with
    freed := s.freed-gross, sourceCash := s.sourceCash-gross, sourceCost := s.sourceCost+cost }
  have hreceived : receiveCredit pulled (gross-cost) cost = pullCreditState s (gross-cost) cost := by
    simp only [receiveCredit, pulled, pullCreditState, he]
  have hcredit : credit pulled (gross-cost) cost = creditReceived (pullCreditState s (gross-cost) cost) := by
    rw [credit_factored, hreceived]
  have hn := creditReceived_ready (pullCreditState s (gross-cost) cost)
    (pullCreditState_public s _ _ hpublic (by omega)) ⟨pullCreditState_ready s _ _ h.1, h.2⟩
  exact (congrArg CreditReadyHistory hcredit).mpr hn

theorem raw_pokeSettle_creditReady (s : State) (caller a b n : Nat) (h : CreditReadyHistory s)
    (hpublic : PublicInvariant s) (bounds : SourcePullBounds s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s ⟨6, caller, a, b, n⟩) :=
  let gross := s.freed*s.pullBps/10000
  let cost := gross*s.costBps/10000
  let hn := sourceCredit_ready s gross cost hpublic h
    (proportional_le _ _ _ bounds.1) (proportional_le _ _ _ bounds.2)
  (congrArg (OnSuccess (fun result : State × Nat => CreditReadyHistory result.1))
    (raw_pokeSettle_factored s caller a b n)).mpr (pokeSettleTail_creditReady _ hn)

theorem claimState_creditReady (s : State) (i receiver : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (claimState s i receiver) := h

theorem raw_claim_creditReady (s : State) (caller a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s ⟨7, caller, a, b, n⟩) := by
  rw [rawRunCall_claim]
  split_ifs <;> trivial

theorem mintMainPosition_creditReady (s : State) (units principal : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (mintMainPosition s units principal) :=
  setPosition_creditReady { s with mainUnits := s.mainUnits+units } 0 _ h rfl le_rfl

theorem depositSourceState_creditReady (s : State) (shares amount : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (depositSourceState s shares amount) := h

theorem depositSource_creditReady (s : State) (amount : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (depositSource s amount) := depositSourceState_creditReady s _ amount h

theorem creditReady_debtSynth (s : State) (debt synth : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory { s with debt := debt, synth := synth } := h

theorem borrowSource_creditReady (s : State) (amount supplied : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (borrowSource s amount supplied) :=
  creditReady_debtSynth _ _ supplied (depositSource_creditReady _ amount (mintMainPosition_creditReady s _ _ h))

theorem borrowResult_creditReady (s : State) (amount : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (borrowResult s amount) := by
  unfold borrowResult
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · trivial
    · exact onSuccess_if _ _ _ _ trivial (borrowSource_creditReady s amount _ h)

theorem rebalanceEnter_creditReady (s : State) (resize : Bool) (coll8 debt8 target : Nat)
    (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rebalanceEnter s resize coll8 debt8 target) := by
  unfold rebalanceEnter
  apply onSuccess_if
  · trivial
  · rw [borrowResult_factored]
    exact borrowResult_creditReady _ _ (creditReady_synth (pay s 0 0).1 s.synth (pay_creditReady s 0 0 h))



theorem rebalanceDelever_creditReady (s : State) (debt8 target : Nat) (h : CreditReadyHistory s) (hfees : 0 < s.sourceFees.size) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rebalanceDelever s debt8 target) := by
  unfold rebalanceDelever
  dsimp only
  apply onSuccess_if
  · exact onSuccess_if _ _ _ _ trivial (activeDelever_creditReady s _ _ h hfees)
  · exact h

theorem rebalanceTail_creditReady (s : State) (h : CreditReadyHistory s) (hfees : 0 < s.sourceFees.size) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rebalanceTail s) := by
  unfold rebalanceTail
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · exact h
    · apply onSuccess_if
      · exact rebalanceEnter_creditReady s _ _ _ _ h
      · exact onSuccess_if _ _ _ _ (rebalanceDelever_creditReady s _ _ h hfees) h

theorem raw_rebalance_creditReady (s : State) (caller a b n : Nat) (h : CreditReadyHistory s) (hactive : ActiveFeeSafe s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s ⟨9, caller, a, b, n⟩) := by
  rw [raw_rebalance_factored, rebalanceTail_factored]
  exact onSuccess_if _ _ _ _ trivial (rebalanceTail_creditReady _ (checkpoint_creditReady s zeroId zeroId h) (checkpoint_activeFeeSafe s zeroId zeroId hactive).1)

theorem withdrawSource_creditReady (s : State) (burned : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (withdrawSource s burned) := h

theorem harvestFunding_creditReady (s : State) (burned : Nat) (h : CreditReadyHistory s) :
    CreditReadyHistory (harvestFunding s burned) :=
  let slice := harvestSlice (harvestable s) s.book.source s.book.protocol burned
  bookFunding_creditReady _ (s.book.source-slice.1) (s.book.protocol-slice.2) s.basis (withdrawSource_creditReady s burned h)

theorem harvestAll_creditReady (s : State) (minimum : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (harvestAll s minimum) := by
  rw [harvestProgram_exact]
  have hn := checkpoint_creditReady s zeroId zeroId h
  exact harvestProgram_preserves harvestable sourceValue quoteCollateral splitHarvest compoundFunds
    CreditReadyHistory (checkpoint s zeroId zeroId) minimum hn
    (harvestFunding_creditReady (checkpoint s zeroId zeroId) (harvestBurn (checkpoint s zeroId zeroId)) hn)
    compoundFunds_creditReady (fun _ hx => hx)

theorem raw_compound_creditReady (s : State) (caller a b n : Nat) (h : CreditReadyHistory s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s ⟨24, caller, a, b, n⟩) := by
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
          change CreditReadyHistory next
          exact onSuccess_of_eq (compoundFunds_creditReady
            { s with collateral := s.collateral.set! caller (s.collateral[caller]!-n) } n 0 n 0 h) heq

theorem rawRunCall_creditReady (s : State) (action : Action) (h : CreditReadyHistory s)
    (hpublic : PublicInvariant s) (hactive : ActiveFeeSafe s) (bounds : SourcePullBounds s) :
    OnSuccess (fun result : State × Nat => CreditReadyHistory result.1) (rawRunCall s action) := by
  by_cases unsupported : 33 ≤ action.op
  · rw [rawRunCall_unsupported s action unsupported]
    trivial
  · rcases action with ⟨op, caller, a, b, n⟩
    have hop : op ≤ 32 := by change ¬ 33 ≤ op at unsupported; omega
    interval_cases op
    · exact raw_deposit_creditReady s caller a b n h
    · exact h
    · exact transfer_result_creditReady s caller b n h
    · exact raw_transferFrom_creditReady s caller a b n h
    · exact raw_request_creditReady s caller a b n h
    · exact raw_startUnwinds_creditReady s caller a b n h hpublic hactive
    · exact raw_pokeSettle_creditReady s caller a b n h hpublic bounds
    · exact raw_claim_creditReady s caller a b n h
    · change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
        else .ok (checkpoint s zeroId zeroId, harvestable (checkpoint s zeroId zeroId)))
      exact onSuccess_if _ _ _ _ trivial (checkpoint_creditReady s zeroId zeroId h)
    · exact raw_rebalance_creditReady s caller a b n h hactive
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
      exact onSuccess_if _ _ _ _ trivial (harvestAll_creditReady s n h)
    · exact raw_compound_creditReady s caller a b n h
    · exact h
    · exact h
    · change OnSuccess _ (if a == 0 then .ok ({ s with
          feesCollateral := 0, collateral := s.collateral.set! 3 (s.collateral[3]!+s.feesCollateral) }, 0)
        else .ok ({ s with feesHollar := 0, treasuryCash := s.treasuryCash+s.feesHollar }, 0))
      split <;> exact h
    · exact h
    · exact h
    · exact setPosition_creditReady s 0 _ h rfl (Nat.le_add_right _ _)
    · exact onSuccess_setBand _ s _ _ _ _ (fun _ => h)
    · exact onSuccess_setAdmission _ s _ _ _ _ (fun _ => h)

theorem rawExecute_creditReady (s : State) (a : Action) (h : CreditReadyHistory s)
    (hpublic : PublicInvariant s) (hactive : ActiveFeeSafe s) (bounds : SourcePullBounds s) :
    CreditReadyHistory (rawExecute s a).1 := by
  have hn := rawRunCall_creditReady s a h hpublic hactive bounds
  cases heq : rawRunCall s a with
  | error code => simpa only [rawExecute, heq] using h
  | ok result =>
    have hr := onSuccess_of_eq hn heq
    simpa only [rawExecute, heq] using hr

theorem validSolidityReachable_creditReady {initial s : State}
    (reachable : ValidSolidityReachable initial s) (h : CreditReadyHistory initial)
    (hactive : ActiveFeeSafe initial) (bounds : PublicCallBounds initial) : CreditReadyHistory s := by
  induction reachable with
  | genesis => exact h
  | step reachable a valid ih =>
    exact rawExecute_creditReady _ a ih (validSolidityReachable_invariant reachable)
      (validSolidityReachable_activeFeeSafe reachable hactive)
      (validSolidityReachable_callBounds reachable bounds).1

theorem validSolidityTrace_creditReady (s : State) (actions : List Action)
    (hpublic : PublicInvariant s) (h : CreditReadyHistory s) (hactive : ActiveFeeSafe s)
    (bounds : PublicCallBounds s) (valid : ValidSolidityTrace s actions) :
    CreditReadyHistory (rawReplay s actions) :=
  validSolidityReachable_creditReady (validSolidityTrace_reachable (.genesis hpublic) valid) h hactive bounds

end Juicer.PublicCalls
