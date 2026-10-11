import JuicerLean.FixedPoint.PublicCertificates
import JuicerLean.FixedPoint.PublicPreservation
import JuicerLean.FixedPoint.PublicTransferProofs
import JuicerLean.FixedPoint.PublicClaimProofs
import JuicerLean.FixedPoint.PublicCheckpointProofs
import JuicerLean.FixedPoint.PublicCompoundProofs
import JuicerLean.FixedPoint.PublicRequestPreparation
import JuicerLean.FixedPoint.PublicDepositProofs
import JuicerLean.FixedPoint.SolidityDispatch

set_option maxRecDepth 4000
set_option maxHeartbeats 2000000

namespace Juicer.PublicCalls

def InvariantAdmissible (s : State) (a : Action) : Prop :=
  OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rawRunCall s a)

instance (s : State) (a : Action) : Decidable (InvariantAdmissible s a) := by
  unfold InvariantAdmissible OnSuccess
  cases rawRunCall s a <;> infer_instance

def StructuralOpcode (op : Nat) : Prop :=
  op = 1 ∨ op = 10 ∨ op = 11 ∨ op = 12 ∨ op = 13 ∨ op = 14 ∨ op = 15 ∨
  op = 16 ∨ op = 17 ∨ op = 18 ∨ op = 19 ∨ op = 20 ∨ op = 21 ∨ op = 22 ∨ op = 24 ∨
  op = 25 ∨ op = 26 ∨ op = 27 ∨ op = 28 ∨ op = 29 ∨ op = 30

instance (op : Nat) : Decidable (StructuralOpcode op) := by
  unfold StructuralOpcode
  infer_instance

private theorem approve_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) : InvariantAdmissible s ⟨1, caller, a, b, n⟩ := by
  simp only [InvariantAdmissible, rawRunCall]
  simp only [List.contains_eq_mem, List.mem_cons, OfNat.ofNat, false_or, reduceCtorEq]
  simp only [OnSuccess]
  unfold PublicInvariant at h ⊢
  rcases h with ⟨hcoll, hsource, hcash, hlife, hslack, hop⟩
  refine ⟨hcoll, hsource, hcash, hlife, hslack, ?_⟩
  unfold OperationalInvariant at hop ⊢
  simpa [Array.size_setIfInBounds] using hop

private theorem warp_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨10, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem repay_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨11, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem pull_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨12, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem repayLimit_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) : InvariantAdmissible s ⟨13, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem rawRunCall_pause (s : State) (caller a b n : Nat) :
    rawRunCall s ⟨14, caller, a, b, n⟩ =
      if n != 0 && (s.paused || s.sourcePaused) then .error 1
      else if n == 0 && !s.paused && !s.sourcePaused then .error 22
      else .ok ({ s with paused := n != 0 }, 0) := by
  rfl

private theorem paused_frame (s : State) (value : Bool) (h : PublicInvariant s) :
    PublicInvariant { s with paused := value } := by
  simpa [PublicInvariant, OperationalInvariant, sourceProjection, cashProjection,
    publicProjection, publicSlack, publicParked, publicLifecycle, activeRequests,
    waitingRequests] using h

private theorem pause_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨14, caller, a, b, n⟩ := by
  unfold InvariantAdmissible
  rw [rawRunCall_pause]
  by_cases hguard : n != 0 && (s.paused || s.sourcePaused)
  · rw [if_pos hguard]
    trivial
  · rw [if_neg hguard]
    by_cases hunpause : n == 0 && !s.paused && !s.sourcePaused
    · rw [if_pos hunpause]
      trivial
    · rw [if_neg hunpause]
      exact paused_frame s (n != 0) h

private theorem depositsPause_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) : InvariantAdmissible s ⟨15, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem sourcePause_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) : InvariantAdmissible s ⟨16, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem reprice_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) : InvariantAdmissible s ⟨17, caller, a, b, n⟩ := by
  simp only [InvariantAdmissible, rawRunCall, OnSuccess]
  unfold PublicInvariant at h ⊢
  rcases h with ⟨hcoll, hsource, hcash, hlife, hslack, hop⟩
  refine ⟨hcoll, hsource, hcash, hlife, hslack, ?_⟩
  unfold OperationalInvariant at hop ⊢
  rcases hop with ⟨hw, ha, hc, hap, hpos, hunwind, hsupply, hunits, hout,
    hfs, hfr, hfee, hsourceCash, hactive, hpending, hqueued, howed, hqd,
    hvault, hassets, hliquid⟩
  refine ⟨hw, ha, hc, hap, hpos, hunwind, hsupply, hunits, hout, hfs, hfr,
    hfee, ?_, hactive, hpending, hqueued, howed, hqd, hvault, hassets, hliquid⟩
  intro hexpanded
  have hold := hsourceCash hexpanded
  simp only [sourceValue] at hold ⊢
  omega

private theorem fee_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨18, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem cost_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨19, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem accrue_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨20, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem price_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨21, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem synth_frame (s : State) (value : Nat) (h : PublicInvariant s) :
    PublicInvariant { s with synth := value } := by
  simpa [PublicInvariant, OperationalInvariant, sourceProjection, cashProjection,
    publicProjection, publicSlack, publicParked, publicLifecycle, activeRequests,
    waitingRequests] using h

private theorem maintainPegState_invariant (s : State) (h : PublicInvariant s) :
    PublicInvariant (maintainPegState s).1 := by
  unfold maintainPegState
  split
  · exact h
  · exact synth_frame s (s.synth + (Runtime.buffered s.debt 9800 - s.synth)) h

private theorem peg_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨22, caller, a, b, n⟩ := by
  simp only [InvariantAdmissible, rawRunCall, bind, Except.bind, pure, Except.pure,
    OnSuccess]
  exact maintainPegState_invariant s h

private theorem rounding_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨25, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem reserve_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨26, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, Runtime.CashBook.valid, publicProjection, publicSlack,
    publicParked, publicLifecycle, activeRequests, waitingRequests] using h

private theorem feeClaim_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) : InvariantAdmissible s ⟨27, caller, a, b, n⟩ := by
  have hc : s.collateral.size = actors := h.2.2.2.2.2.2.2.1
  by_cases ha : a = 0
  · simp only [InvariantAdmissible, rawRunCall, ha, bind, Except.bind, pure,
      Except.pure, OnSuccess]
    unfold PublicInvariant at h ⊢
    rcases h with ⟨hcoll, hsource, hcash, hlife, hslack, hop⟩
    refine ⟨?_, hsource, hcash, hlife, hslack, ?_⟩
    · simpa [CollateralConserved] using hcoll
    · unfold OperationalInvariant at hop ⊢
      simpa [Array.size_setIfInBounds, hc] using hop
  · simpa [InvariantAdmissible, rawRunCall, ha, bind, Except.bind, pure,
      Except.pure, OnSuccess, PublicInvariant, OperationalInvariant, sourceProjection,
      cashProjection, publicProjection, publicSlack, publicParked, publicLifecycle,
      activeRequests, waitingRequests] using h

private theorem haircut_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨28, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem cap_admissible (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    InvariantAdmissible s ⟨29, caller, a, b, n⟩ := by
  simpa [InvariantAdmissible, rawRunCall, OnSuccess, PublicInvariant, OperationalInvariant,
    sourceProjection, cashProjection, publicProjection, publicSlack, publicParked,
    publicLifecycle, activeRequests, waitingRequests] using h

private theorem fundPosition_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) : InvariantAdmissible s ⟨30, caller, a, b, n⟩ := by
  simp only [InvariantAdmissible, rawRunCall, bind, Except.bind, pure, Except.pure,
    OnSuccess]
  cases hrows : s.positions.toList with
  | nil =>
      have hz : s.positions.size = 0 := by
        rw [Array.size_eq_length_toList, hrows]
        rfl
      have hpos : 0 < s.positions.size := h.2.2.2.2.2.2.2.2.2.1
      omega
  | cons p rest =>
      have hget : s.positions[0]? = some p := by
        rw [← Array.getElem?_toList]
        simp [hrows]
      simp only [PublicInvariant] at h ⊢
      rcases h with ⟨hcoll, hsource, hcash, hlife, hslack, hop⟩
      refine ⟨hcoll, ?_, ?_, hlife, hslack, ?_⟩
      · simpa [sourceProjection, setPosition, Array.toList_setIfInBounds, hrows,
          position, hget] using hsource
      · simp only [cashProjection, Runtime.CashBook.valid] at hcash ⊢
        simp [setPosition, Array.toList_setIfInBounds, hrows, position, hget] at hcash ⊢
        omega
      · unfold OperationalInvariant at hop ⊢
        simpa [setPosition, Array.size_setIfInBounds, Array.toList_setIfInBounds,
          hrows, position, hget] using hop

theorem structural_opcode_admissible (s : State) (action : Action)
    (h : PublicInvariant s) (hop : StructuralOpcode action.op) :
    InvariantAdmissible s action := by
  rcases action with ⟨op, caller, a, b, n⟩
  simp only [StructuralOpcode] at hop
  rcases hop with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
  · exact approve_admissible s caller a b n h
  · exact warp_admissible s caller a b n h
  · exact repay_admissible s caller a b n h
  · exact pull_admissible s caller a b n h
  · exact repayLimit_admissible s caller a b n h
  · exact pause_admissible s caller a b n h
  · exact depositsPause_admissible s caller a b n h
  · exact sourcePause_admissible s caller a b n h
  · exact reprice_admissible s caller a b n h
  · exact fee_admissible s caller a b n h
  · exact cost_admissible s caller a b n h
  · exact accrue_admissible s caller a b n h
  · exact price_admissible s caller a b n h
  · exact peg_admissible s caller a b n h
  · exact raw_compound_public s caller a b n h
  · exact rounding_admissible s caller a b n h
  · exact reserve_admissible s caller a b n h
  · exact feeClaim_admissible s caller a b n h
  · exact haircut_admissible s caller a b n h
  · exact cap_admissible s caller a b n h
  · exact fundPosition_admissible s caller a b n h

theorem transfer_result_public (s : State) (a b n : Nat)
    (h : PublicInvariant s) (ha : a < 5) (hb : b < actors) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1)
      (do let next ← transfer s a b n; pure (next,1)) := by
  rw [onSuccess_bind]
  intro next heq
  change PublicInvariant next
  exact onSuccess_of_eq (transfer_public s a b n h ha hb) heq

theorem transfer_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) (ha : caller < 5) (hb : b < actors) :
    InvariantAdmissible s ⟨2,caller,a,b,n⟩ := by
  change OnSuccess (fun result : State × Nat => PublicInvariant result.1)
    (do let next ← transfer s caller b n; pure (next,1))
  exact transfer_result_public s caller b n h ha hb

theorem rawRunCall_transferFrom (s : State) (caller a b n : Nat) :
    rawRunCall s ⟨3,caller,a,b,n⟩ = (
      let allowed := s.approvals[a*4+caller]?.getD 0
      if allowed != Runtime.max256 then
        if allowed < n then .error 16
        else do
          let next ← transfer { s with approvals := s.approvals.set! (a*4+caller) (allowed-n) } a b n
          pure (next,1)
      else do let next ← transfer s a b n; pure (next,1)) := by
  rfl

theorem transferFrom_admissible (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) (ha : a < 5) (hb : b < actors) :
    InvariantAdmissible s ⟨3,caller,a,b,n⟩ := by
  unfold InvariantAdmissible
  rw [rawRunCall_transferFrom]
  dsimp only
  split
  · split
    · trivial
    · exact transfer_result_public _ a b n (approvals_public s _ _ h) ha hb
  · exact transfer_result_public s a b n h ha hb


def StructuralAction (a : Action) : Prop :=
  StructuralOpcode a.op ∨
    (a.op = 2 ∧ a.caller < 5 ∧ a.b < actors) ∨
    (a.op = 3 ∧ a.a < 5 ∧ a.b < actors)

instance (a : Action) : Decidable (StructuralAction a) := by
  unfold StructuralAction
  infer_instance

theorem structural_action_admissible (s : State) (action : Action)
    (h : PublicInvariant s) (ha : StructuralAction action) : InvariantAdmissible s action := by
  rcases action with ⟨op,caller,a,b,n⟩
  change StructuralOpcode op ∨ (op = 2 ∧ caller < 5 ∧ b < actors) ∨
    (op = 3 ∧ a < 5 ∧ b < actors) at ha
  rcases ha with hop | ⟨hop,holder,target⟩ | ⟨hop,holder,target⟩
  · exact structural_opcode_admissible s ⟨op,caller,a,b,n⟩ h hop
  · subst op
    exact transfer_admissible s caller a b n h holder target
  · subst op
    exact transferFrom_admissible s caller a b n h holder target

def StateStructuralAction (s : State) (a : Action) : Prop :=
  (a.op = 7 ∧ a.amount < s.unwind) ∨ (a.op = 8 ∧ PublicMetadata s) ∨
  (a.op = 4 ∧ PublicMetadata s ∧ a.a < 5) ∨
  (a.op = 0 ∧ PublicMetadata s ∧ InitialMintSafe s ∧ a.b < actors)

instance (s : State) (a : Action) : Decidable (StateStructuralAction s a) := by
  unfold StateStructuralAction
  infer_instance

def ValidSolidityAction (s : State) (a : Action) : Prop :=
  FixtureAction a ∧ (StructuralAction a ∨
    StateStructuralAction s a ∨ InvariantAdmissible s a)

instance (s : State) (a : Action) : Decidable (ValidSolidityAction s a) := by
  unfold ValidSolidityAction
  infer_instance

theorem structural_action_valid {s : State} {a : Action}
    (fixture : FixtureAction a) (structural : StructuralOpcode a.op) :
    ValidSolidityAction s a := ⟨fixture, .inl (.inl structural)⟩

theorem transfer_action_valid {s : State} {a : Action} (fixture : FixtureAction a)
    (op : a.op = 2) (holder : a.caller < 5) : ValidSolidityAction s a := by
  exact ⟨fixture, .inl (.inr (.inl ⟨op,holder,fixture.2.2.2.2.1 op⟩))⟩

theorem transferFrom_action_valid {s : State} {a : Action} (fixture : FixtureAction a)
    (op : a.op = 3) : ValidSolidityAction s a := by
  have hf := fixture.2.2.2.2.2.1 op
  exact ⟨fixture, .inl (.inr (.inr ⟨op,hf.2.1.trans (by decide),hf.2.2⟩))⟩

theorem claim_action_valid {s : State} {a : Action} (fixture : FixtureAction a)
    (op : a.op = 7) (started : a.amount < s.unwind) : ValidSolidityAction s a :=
  ⟨fixture, .inr (.inl (.inl ⟨op,started⟩))⟩

theorem sync_action_valid {s : State} {a : Action} (fixture : FixtureAction a)
    (op : a.op = 8) (metadata : PublicMetadata s) : ValidSolidityAction s a :=
  ⟨fixture, .inr (.inl (.inr (.inl ⟨op,metadata⟩)))⟩

theorem request_action_valid {s : State} {a : Action} (fixture : FixtureAction a)
    (op : a.op = 4) (metadata : PublicMetadata s) : ValidSolidityAction s a := by
  have holder := (fixture.2.2.2.2.2.2.1 op).2
  exact ⟨fixture, .inr (.inl (.inr (.inr (.inl ⟨op,metadata,holder.trans (by decide)⟩))))⟩

theorem deposit_action_valid {s : State} {a : Action} (fixture : FixtureAction a)
    (op : a.op = 0) (metadata : PublicMetadata s) (initial : InitialMintSafe s) :
    ValidSolidityAction s a :=
  ⟨fixture, .inr (.inl (.inr (.inr (.inr ⟨op,metadata,initial,(fixture.2.2.1 op).2⟩))))⟩

theorem claim_admissible (s : State) (a : Action) (h : PublicInvariant s)
    (hop : a.op = 7) (started : a.amount < s.unwind) : InvariantAdmissible s a := by
  rcases a with ⟨op,caller,a,b,n⟩
  change op = 7 at hop
  subst op
  exact raw_claim_public s caller a b n h started

theorem state_structural_admissible (s : State) (a : Action) (h : PublicInvariant s)
    (input : StateStructuralAction s a) : InvariantAdmissible s a := by
  rcases input with ⟨hop,started⟩ | ⟨hop,metadata⟩ | ⟨hop,metadata,holder⟩ | ⟨hop,metadata,initial,receiver⟩
  · exact claim_admissible s a h hop started
  · rcases a with ⟨op,caller,a,b,n⟩
    change op = 8 at hop
    subst op
    exact raw_sync_public s caller a b n h metadata
  · rcases a with ⟨op,caller,a,b,n⟩
    change op = 4 at hop
    subst op
    exact raw_request_public s caller a b n h metadata holder
  · rcases a with ⟨op,caller,a,b,n⟩
    change op = 0 at hop
    subst op
    exact raw_deposit_public s caller a b n h metadata initial receiver

theorem rawRunCall_success_preserves_of_valid {s next : State} {a : Action} {value : Nat}
    (current : PublicInvariant s) (valid : ValidSolidityAction s a)
    (h : rawRunCall s a = .ok (next, value)) :
    PublicInvariant next := by
  have admissible : InvariantAdmissible s a := valid.2.elim
    (structural_action_admissible s a current)
    (fun rest => rest.elim (state_structural_admissible s a current) id)
  simpa [InvariantAdmissible, OnSuccess, h] using admissible

theorem rawRunCall_error_admissible {s : State} {a : Action} {code : Nat}
    (h : rawRunCall s a = .error code) : InvariantAdmissible s a := by
  simp [InvariantAdmissible, h, OnSuccess]

theorem checked_eq_raw_of_admissible (s : State) (a : Action)
    (h : InvariantAdmissible s a) : runCall s a = rawRunCall s a := by
  cases hr : rawRunCall s a with
  | error code => simp [runCall, hr]
  | ok result =>
    have hp : PublicInvariant result.1 := by
      simpa [InvariantAdmissible, OnSuccess, hr] using h
    rcases result with ⟨next, value⟩
    simp [runCall, hr, hp]

theorem rawExecute_preserves_of_valid (s : State) (a : Action) (h : PublicInvariant s)
    (valid : ValidSolidityAction s a) : PublicInvariant (rawExecute s a).1 := by
  cases hr : rawRunCall s a with
  | error code => simpa [rawExecute, hr] using h
  | ok result =>
    rcases result with ⟨next, value⟩
    simpa [rawExecute, hr] using rawRunCall_success_preserves_of_valid h valid hr

def rawReplay : State → List Action → State
  | s, [] => s
  | s, a :: rest => rawReplay (rawExecute s a).1 rest

def ValidSolidityTrace : State → List Action → Prop
  | _, [] => True
  | s, a :: rest => ValidSolidityAction s a ∧
      ValidSolidityTrace (rawExecute s a).1 rest

theorem validSolidityTrace_invariant (s : State) (actions : List Action)
    (initial : PublicInvariant s) (valid : ValidSolidityTrace s actions) :
    PublicInvariant (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => simpa [rawReplay]
  | cons a rest ih =>
    exact ih (rawExecute s a).1 (rawExecute_preserves_of_valid s a initial valid.1) valid.2

inductive ValidSolidityReachable (initial : State) : State → Prop
  | genesis (certified : PublicInvariant initial) : ValidSolidityReachable initial initial
  | step {s : State} (reachable : ValidSolidityReachable initial s) (a : Action)
      (valid : ValidSolidityAction s a) :
      ValidSolidityReachable initial (rawExecute s a).1

theorem validSolidityReachable_invariant {initial s : State}
    (h : ValidSolidityReachable initial s) : PublicInvariant s := by
  induction h with
  | genesis certified => exact certified
  | step reachable a valid ih => exact rawExecute_preserves_of_valid _ _ ih valid

theorem validSolidityTrace_reachable {initial s : State} {actions : List Action}
    (reachable : ValidSolidityReachable initial s) (valid : ValidSolidityTrace s actions) :
    ValidSolidityReachable initial (rawReplay s actions) := by
  induction actions generalizing s with
  | nil => simpa [rawReplay]
  | cons a rest ih =>
    exact ih (.step reachable a valid.1) valid.2

theorem reachable_rawRunCall_success_preserves {initial s next : State}
    {a : Action} {value : Nat} (reachable : ValidSolidityReachable initial s)
    (valid : ValidSolidityAction s a) (h : rawRunCall s a = .ok (next, value)) :
    PublicInvariant next := by
  have current : PublicInvariant s := validSolidityReachable_invariant reachable
  exact rawRunCall_success_preserves_of_valid current valid h

theorem reachable_dispatch_success_preserves {initial s next : State}
    {a : Action} {value : Nat} (reachable : ValidSolidityReachable initial s)
    (valid : ValidSolidityAction s a) (h : solidityDispatch s a = .ok (next, value)) :
    PublicInvariant next := by
  rw [solidity_dispatch_corresponds] at h
  exact reachable_rawRunCall_success_preserves reachable valid h

set_option maxRecDepth 10000 in
set_option maxHeartbeats 1000000 in
theorem orphan_claim_not_certified : ¬ PublicInvariant orphanClaimState := by decide

theorem orphan_claim_not_reachable (initial : State) :
    ¬ ValidSolidityReachable initial orphanClaimState := by
  intro h
  exact orphan_claim_not_certified (validSolidityReachable_invariant h)

end Juicer.PublicCalls
