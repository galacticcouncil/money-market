import JuicerLean.FixedPoint.PublicInitializationTransitions
import JuicerLean.FixedPoint.PublicReachability

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem initialMint_locked (s : State) (h : InitializationSafe s) : 0 < wallet (initialMint s) 4 := by
  unfold initialMint
  split
  · rw [wallet_setWallet { s with supply := 1000 } 4 1000 4 h.2.2]
    simp only [ite_true]; decide
  · rcases h.2.1 with hz | hp
    · simp_all
    · exact hp

theorem initialMint_initializationSafe (s : State) (h : InitializationSafe s) :
    InitializationSafe (initialMint s) := by
  refine ⟨?_, Or.inr (initialMint_locked s h), ?_⟩
  · unfold initialMint
    split
    · intro hz; change 1000 = 0 at hz; omega
    · exact h.1
  · unfold initialMint
    split
    · simpa only [setWallet, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using h.2.2
    · exact h.2.2

theorem mintWallet_initializationSafe (s : State) (receiver shares : Nat)
    (h : InitializationSafe s) (locked : 0 < wallet s 4) : InitializationSafe (mintWallet s receiver shares) := by
  refine ⟨?_, Or.inr ?_, ?_⟩
  · intro hz; change s.supply + shares = 0 at hz; exact h.1 (by omega)
  · unfold mintWallet
    by_cases hr : receiver = 4
    · subst receiver
      rw [wallet_setWallet { s with supply := s.supply+shares } 4 _ 4 h.2.2]
      change 0 < wallet s 4 + shares
      omega
    · rw [wallet_set_other _ receiver _ hr]
      exact locked
  · simpa only [mintWallet, setWallet, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using h.2.2

theorem depositAssets_initializationSafe (s : State) (caller amount : Nat) (h : InitializationSafe s) :
    InitializationSafe (depositAssets s caller amount) := h

theorem depositResult_initializationSafe (s : State) (caller receiver amount shares needed : Nat)
    (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1)
      (depositResult s caller receiver amount shares needed) := by
  unfold depositResult
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · rw [onSuccess_bind]
      intro next heq
      have hm := mintWallet_initializationSafe (initialMint s) receiver shares (initialMint_initializationSafe s h) (initialMint_locked s h)
      have ha := depositAssets_initializationSafe (mintWallet (initialMint s) receiver shares) caller amount hm
      have hn := onSuccess_of_eq (cover_initializationSafe _ _ ha) heq
      exact hn

theorem raw_deposit_initializationSafe (s : State) (caller a b n : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s ⟨0, caller, a, b, n⟩) := by
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
                        · exact depositResult_initializationSafe _ caller b n _ _
                            (checkpoint_initializationSafe _ zeroId b
                              (initializationSafe_synth (pay s 0 0).1 s.synth (pay_initializationSafe s 0 0 h)))

theorem transfer_result_initializationSafe (s : State) (a b n : Nat) (h : InitializationSafe s) (ha : a ≠ 4) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1)
      (do let next ← transfer s a b n; pure (next, 1)) := by
  rw [onSuccess_bind]
  intro next heq
  change InitializationSafe next
  exact onSuccess_of_eq (transfer_initializationSafe s a b n h ha) heq

theorem raw_transferFrom_initializationSafe (s : State) (caller a b n : Nat) (h : InitializationSafe s) (ha : a ≠ 4) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s ⟨3, caller, a, b, n⟩) := by
  rw [rawRunCall_transferFrom]
  dsimp only
  split
  · split
    · trivial
    · exact transfer_result_initializationSafe _ a b n h ha
  · exact transfer_result_initializationSafe s a b n h ha

theorem requestTail_initializationSafe (s : State) (owner escrow amount : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (requestTail s owner escrow amount) := by
  rw [requestTail_factored, onSuccess_bind]
  intro next heq
  change InitializationSafe next
  exact onSuccess_of_eq (commitRequest_initializationSafe s owner escrow amount h) heq

theorem raw_request_initializationSafe (s : State) (caller a b n : Nat) (h : InitializationSafe s) (ha : a ≠ 4) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s ⟨4, caller, a, b, n⟩) := by
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
        have hp := onSuccess_of_eq (spend_initializationSafe _ a caller _ (checkpoint_initializationSafe s a zeroId h)) hpaid
        rw [onSuccess_bind]
        intro moved hmoved
        exact requestTail_initializationSafe moved a _ _ (onSuccess_of_eq (transfer_initializationSafe paid a vaultId _ hp ha) hmoved)

theorem raw_startUnwinds_initializationSafe (s : State) (caller a b n : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s ⟨5, caller, a, b, n⟩) := by
  rw [raw_startUnwinds_factored]
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · exact h
    · rw [onSuccess_map]
      exact startMany_initializationSafe n s s.unwind h

theorem pokeSettleTail_initializationSafe (s : State) (h : InitializationSafe s) : InitializationSafe (pokeSettleTail s) := by
  unfold pokeSettleTail
  apply settleMany_initializationSafe 32
  exact initializationSafe_delever (pay s 0 s.delever).1 _ (pay_initializationSafe s 0 s.delever h)

theorem raw_pokeSettle_initializationSafe (s : State) (caller a b n : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s ⟨6, caller, a, b, n⟩) :=
  let gross := s.freed*s.pullBps/10000
  let cost := gross*s.costBps/10000
  let next := { s with freed := s.freed-gross, sourceCash := s.sourceCash-gross, sourceCost := s.sourceCost+cost }
  let hn : InitializationSafe next := h
  let hc := credit_initializationSafe next (gross-cost) cost hn
  (congrArg (OnSuccess (fun result : State × Nat => InitializationSafe result.1))
    (raw_pokeSettle_factored s caller a b n)).mpr (pokeSettleTail_initializationSafe _ hc)

theorem claimState_initializationSafe (s : State) (i receiver : Nat) (h : InitializationSafe s)
    (hop : OperationalInvariant s) (hi : i < s.unwind) (hp : 0 < (request s i).claim.settled) :
    InitializationSafe (claimState s i receiver) := by
  have wallet_eq : wallet (claimState s i receiver) 4 = wallet s 4 :=
    wallet_set_other s vaultId _ (by decide)
  have hn := claimState_operational s i receiver hop hi hp
  refine ⟨?_, ?_, ?_⟩
  · intro hz
    rcases h.2.1 with hs | hw
    · exact h.1 hs
    · have hb := wallet_le_supply (claimState s i receiver) 4 hn (by decide)
      rw [wallet_eq, hz] at hb
      omega
  · rcases h.2.1 with hs | hw
    · exact Or.inl (by simp only [claimState, hs, Nat.zero_sub])
    · exact Or.inr (wallet_eq ▸ hw)
  · simpa only [claimState, setWallet, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using h.2.2

theorem raw_claim_initializationSafe (s : State) (caller a b n : Nat) (h : InitializationSafe s)
    (hop : OperationalInvariant s) (hi : n < s.unwind) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s ⟨7, caller, a, b, n⟩) := by
  rw [rawRunCall_claim]
  split_ifs
  all_goals try trivial
  all_goals
    apply claimState_initializationSafe s n _ h hop hi
    have hp : ¬((request s n).claim.settled == 0) = true := by assumption
    simp only [beq_iff_eq] at hp
    omega

theorem mintMainPosition_initializationSafe (s : State) (units principal : Nat) (h : InitializationSafe s) :
    InitializationSafe (mintMainPosition s units principal) := h

theorem depositSourceState_initializationSafe (s : State) (shares amount : Nat) (h : InitializationSafe s) :
    InitializationSafe (depositSourceState s shares amount) := h

theorem depositSource_initializationSafe (s : State) (amount : Nat) (h : InitializationSafe s) :
    InitializationSafe (depositSource s amount) := depositSourceState_initializationSafe s _ amount h

theorem initializationSafe_debtSynth (s : State) (debt synth : Nat) (h : InitializationSafe s) :
    InitializationSafe { s with debt := debt, synth := synth } := h

theorem borrowSource_initializationSafe (s : State) (amount supplied : Nat) (h : InitializationSafe s) :
    InitializationSafe (borrowSource s amount supplied) :=
  initializationSafe_debtSynth _ _ supplied (depositSource_initializationSafe _ amount (mintMainPosition_initializationSafe s _ _ h))

theorem borrowResult_initializationSafe (s : State) (amount : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (borrowResult s amount) := by
  unfold borrowResult
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · trivial
    · exact onSuccess_if _ _ _ _ trivial (borrowSource_initializationSafe s amount _ h)

theorem rebalanceEnter_initializationSafe (s : State) (resize : Bool) (coll8 debt8 target : Nat)
    (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rebalanceEnter s resize coll8 debt8 target) := by
  unfold rebalanceEnter
  apply onSuccess_if
  · trivial
  · rw [borrowResult_factored]
    exact borrowResult_initializationSafe _ _ (initializationSafe_synth (pay s 0 0).1 s.synth (pay_initializationSafe s 0 0 h))

theorem activeDelever_initializationSafe (s : State) (slice basis : Nat) (h : InitializationSafe s) :
    InitializationSafe (addActiveFee (unwindActiveSource s slice basis)
      (vestFee (sourceValue s slice) basis ((sourceValue s slice-basis)*s.feeBps/10000))) := h

theorem rebalanceDelever_initializationSafe (s : State) (debt8 target : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rebalanceDelever s debt8 target) := by
  unfold rebalanceDelever
  dsimp only
  apply onSuccess_if
  · exact onSuccess_if _ _ _ _ trivial (activeDelever_initializationSafe s _ _ h)
  · exact h

theorem rebalanceTail_initializationSafe (s : State) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rebalanceTail s) := by
  unfold rebalanceTail
  apply onSuccess_if
  · exact h
  · apply onSuccess_if
    · exact h
    · apply onSuccess_if
      · exact rebalanceEnter_initializationSafe s _ _ _ _ h
      · exact onSuccess_if _ _ _ _ (rebalanceDelever_initializationSafe s _ _ h) h

theorem raw_rebalance_initializationSafe (s : State) (caller a b n : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s ⟨9, caller, a, b, n⟩) := by
  rw [raw_rebalance_factored, rebalanceTail_factored]
  exact onSuccess_if _ _ _ _ trivial (rebalanceTail_initializationSafe _ (checkpoint_initializationSafe s zeroId zeroId h))

theorem withdrawSource_initializationSafe (s : State) (burned : Nat) (h : InitializationSafe s) :
    InitializationSafe (withdrawSource s burned) := h

theorem harvestFunding_initializationSafe (s : State) (burned : Nat) (h : InitializationSafe s) :
    InitializationSafe (harvestFunding s burned) :=
  let slice := harvestSlice (harvestable s) s.book.source s.book.protocol burned
  bookFunding_initializationSafe _ (s.book.source-slice.1) (s.book.protocol-slice.2) s.basis (withdrawSource_initializationSafe s burned h)

theorem harvestAll_initializationSafe (s : State) (minimum : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (harvestAll s minimum) := by
  rw [harvestProgram_exact]
  have hn := checkpoint_initializationSafe s zeroId zeroId h
  exact harvestProgram_preserves harvestable sourceValue quoteCollateral splitHarvest compoundFunds
    InitializationSafe (checkpoint s zeroId zeroId) minimum hn
    (harvestFunding_initializationSafe (checkpoint s zeroId zeroId) (harvestBurn (checkpoint s zeroId zeroId)) hn)
    compoundFunds_initializationSafe (fun _ hx => hx)

theorem raw_compound_initializationSafe (s : State) (caller a b n : Nat) (h : InitializationSafe s) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s ⟨24, caller, a, b, n⟩) := by
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
          change InitializationSafe next
          exact onSuccess_of_eq (compoundFunds_initializationSafe
            { s with collateral := s.collateral.set! caller (s.collateral[caller]!-n) } n 0 n 0 h) heq

theorem rawRunCall_initializationSafe (s : State) (action : Action) (h : InitializationSafe s)
    (hpublic : PublicInvariant s) (fixture : FixtureAction action)
    (locked : action.op = 2 → action.caller ≠ 4)
    (started : action.op = 7 → action.amount < s.unwind) :
    OnSuccess (fun result : State × Nat => InitializationSafe result.1) (rawRunCall s action) := by
  by_cases unsupported : 33 ≤ action.op
  · rw [rawRunCall_unsupported s action unsupported]
    trivial
  · rcases action with ⟨op, caller, a, b, n⟩
    have hop : op ≤ 32 := by change ¬ 33 ≤ op at unsupported; omega
    interval_cases op
    · exact raw_deposit_initializationSafe s caller a b n h
    · exact h
    · exact transfer_result_initializationSafe s caller b n h (locked rfl)
    · exact raw_transferFrom_initializationSafe s caller a b n h (by
        have ha := (fixture.2.2.2.2.2.1 rfl).2.1; change a < 4 at ha; omega)
    · exact raw_request_initializationSafe s caller a b n h (by
        have ha := (fixture.2.2.2.2.2.2.1 rfl).2; change a < 4 at ha; omega)
    · exact raw_startUnwinds_initializationSafe s caller a b n h
    · exact raw_pokeSettle_initializationSafe s caller a b n h
    · exact raw_claim_initializationSafe s caller a b n h hpublic.2.2.2.2.2 (started rfl)
    · change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
        else .ok (checkpoint s zeroId zeroId, harvestable (checkpoint s zeroId zeroId)))
      exact onSuccess_if _ _ _ _ trivial (checkpoint_initializationSafe s zeroId zeroId h)
    · exact raw_rebalance_initializationSafe s caller a b n h
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
      exact onSuccess_if _ _ _ _ trivial (harvestAll_initializationSafe s n h)
    · exact raw_compound_initializationSafe s caller a b n h
    · exact h
    · exact h
    · change OnSuccess _ (if a == 0 then .ok ({ s with
          feesCollateral := 0, collateral := s.collateral.set! 3 (s.collateral[3]!+s.feesCollateral) }, 0)
        else .ok ({ s with feesHollar := 0, treasuryCash := s.treasuryCash+s.feesHollar }, 0))
      split <;> exact h
    · exact h
    · exact h
    · exact h
    · exact onSuccess_setBand _ s _ _ _ _ (fun _ => h)
    · exact onSuccess_setAdmission _ s _ _ _ _ (fun _ => h)

def LockedAddressAction (a : Action) : Prop := a.op = 2 → a.caller ≠ 4

instance (a : Action) : Decidable (LockedAddressAction a) := by
  unfold LockedAddressAction; infer_instance

theorem rawExecute_initializationSafe (s : State) (a : Action) (h : InitializationSafe s)
    (hpublic : PublicInvariant s) (valid : ValidSolidityAction s a) (locked : LockedAddressAction a) :
    InitializationSafe (rawExecute s a).1 := by
  cases heq : rawRunCall s a with
  | error code => simpa only [rawExecute, heq] using h
  | ok result =>
    have started : a.op = 7 → a.amount < s.unwind := by
      intro hop
      have hv := valid_success_input valid heq
      simp [StructuralAction, StructuralOpcode, StateStructuralAction, hop] at hv
      exact hv
    have hn := rawRunCall_initializationSafe s a h hpublic valid.1 locked started
    simpa only [rawExecute, heq] using onSuccess_of_eq hn heq

def LockedSolidityTrace (s : State) (actions : List Action) : Prop :=
  ValidSolidityTrace s actions ∧ ∀ a ∈ actions, LockedAddressAction a

theorem lockedSolidityTrace_initializationSafe (s : State) (actions : List Action)
    (hpublic : PublicInvariant s) (h : InitializationSafe s) (valid : LockedSolidityTrace s actions) :
    InitializationSafe (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => exact h
  | cons a rest ih =>
    exact ih (rawExecute s a).1 (rawExecute_preserves_of_valid s a hpublic valid.1.1)
      (rawExecute_initializationSafe s a h hpublic valid.1.1 (valid.2 a (by simp)))
      ⟨valid.1.2, fun b hb => valid.2 b (by simp [hb])⟩

theorem lockedSolidityTrace_initialMintSafe (s : State) (actions : List Action)
    (hpublic : PublicInvariant s) (h : InitializationSafe s) (valid : LockedSolidityTrace s actions) :
    InitialMintSafe (rawReplay s actions) :=
  (lockedSolidityTrace_initializationSafe s actions hpublic h valid).1

end Juicer.PublicCalls
