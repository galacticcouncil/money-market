import JuicerLean.FixedPoint.PublicInitializationReachability
import JuicerLean.FixedPoint.PublicQueueReachability
import JuicerLean.FixedPoint.PublicCreditReachability
import JuicerLean.FixedPoint.PublicHarvestCapacityProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls

structure PublicReady (s : State) : Prop where
  financial : PublicInvariant s
  metadata : PublicMetadata s
  bounds : PublicCallBounds s
  initialization : InitializationSafe s
  activeFee : ActiveFeeSafe s
  queue : QueueBacking s
  credit : CreditReadyHistory s

theorem publicReady_genesis : PublicReady ({} : State) :=
  ⟨by decide, metadata_genesis, callBounds_genesis, initializationSafe_genesis,
    activeFeeSafe_genesis, queue_genesis, creditReadyHistory_genesis⟩

def fixtureGenesis (fixture : Nat) : State :=
  if fixture = 2 then
    { expanded := true, feeBps := 1000,
      collateral := #[10^30, 10^30, 10^30, 10^30, 0, 0, 0, 0] }
  else if fixture = 1 then
    { expanded := true, feeBps := 1000 }
  else
    {}

theorem fixtureGenesis_ready (fixture : Nat) (h : fixture ≤ 2) : PublicReady (fixtureGenesis fixture) := by
  interval_cases fixture <;>
    exact ⟨by decide, by decide, by decide, by decide, by decide, by decide, by decide⟩

def OrdinaryAction (s : State) (a : Action) : Prop :=
  FixtureAction a ∧ (a.op = 2 → a.caller < 4) ∧
    (a.op = 7 → a.amount < s.unwind ∨ RawReverting s a)

instance (s : State) (a : Action) : Decidable (OrdinaryAction s a) := by
  unfold OrdinaryAction; infer_instance

theorem ordinaryAction_locked {s : State} {a : Action} (h : OrdinaryAction s a) : LockedAddressAction a := by
  intro hop
  have hi := h.2.1 hop
  omega

theorem ordinaryAction_valid (s : State) (a : Action) (h : PublicReady s) (ordinary : OrdinaryAction s a) :
    ValidSolidityAction s a := by
  have fixture := ordinary.1
  have hop : a.op ≤ 32 := fixture.1
  rcases a with ⟨op, caller, owner, receiver, amount⟩
  change op ≤ 32 at hop
  interval_cases op
  · exact deposit_action_valid fixture rfl h.metadata h.initialization.1
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact transfer_action_valid fixture rfl ((ordinary.2.1 rfl).trans (by decide))
  · exact transferFrom_action_valid fixture rfl
  · exact request_action_valid fixture rfl h.metadata
  · exact startUnwinds_action_valid fixture rfl ⟨h.metadata, h.queue, callBounds_waitingOwners s h.bounds, h.bounds.2.1⟩
  · exact pokeSettle_action_valid fixture rfl h.credit.1 h.queue h.bounds.1
  · rcases ordinary.2.2 rfl with started | reverting
    · exact claim_action_valid fixture rfl started
    · exact ⟨fixture, .inr (.inr reverting)⟩
  · exact sync_action_valid fixture rfl h.metadata
  · exact rebalance_action_valid fixture rfl h.metadata h.activeFee.2
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact harvest_action_valid fixture rfl h.metadata (harvestBound_all s)
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])
  · exact structural_action_valid fixture (by norm_num [StructuralOpcode])

theorem ordinaryAction_preserves (s : State) (a : Action) (h : PublicReady s) (ordinary : OrdinaryAction s a) :
    PublicReady (rawExecute s a).1 := by
  have valid := ordinaryAction_valid s a h ordinary
  exact ⟨rawExecute_preserves_of_valid s a h.financial valid,
    rawExecute_metadata s a h.metadata, rawExecute_callBounds s a h.bounds ordinary.1,
    rawExecute_initializationSafe s a h.initialization h.financial valid (ordinaryAction_locked ordinary),
    rawExecute_activeFeeSafe s a h.activeFee,
    rawExecute_queue s a h.queue h.financial h.metadata h.bounds,
    rawExecute_creditReady s a h.credit h.financial h.activeFee h.bounds.1⟩

def OrdinaryTrace : State → List Action → Prop
  | _, [] => True
  | s, a :: rest => OrdinaryAction s a ∧ OrdinaryTrace (rawExecute s a).1 rest

theorem ordinaryTrace_preserves (s : State) (actions : List Action) (h : PublicReady s)
    (ordinary : OrdinaryTrace s actions) : PublicReady (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => exact h
  | cons a rest ih => exact ih _ (ordinaryAction_preserves s a h ordinary.1) ordinary.2

theorem ordinaryTrace_valid (s : State) (actions : List Action) (h : PublicReady s)
    (ordinary : OrdinaryTrace s actions) : ValidSolidityTrace s actions := by
  induction actions generalizing s with
  | nil => trivial
  | cons a rest ih =>
    exact ⟨ordinaryAction_valid s a h ordinary.1,
      ih _ (ordinaryAction_preserves s a h ordinary.1) ordinary.2⟩

theorem ordinaryTrace_genesis_ready (actions : List Action) (h : OrdinaryTrace {} actions) :
    PublicReady (rawReplay {} actions) := ordinaryTrace_preserves {} actions publicReady_genesis h

theorem ordinaryTrace_genesis_financial (actions : List Action) (h : OrdinaryTrace {} actions) :
    PublicInvariant (rawReplay {} actions) := (ordinaryTrace_genesis_ready actions h).financial

theorem ordinaryTrace_fixture_ready (fixture : Nat) (actions : List Action) (hfixture : fixture ≤ 2)
    (h : OrdinaryTrace (fixtureGenesis fixture) actions) :
    PublicReady (rawReplay (fixtureGenesis fixture) actions) :=
  ordinaryTrace_preserves _ actions (fixtureGenesis_ready fixture hfixture) h

end Juicer.PublicCalls
