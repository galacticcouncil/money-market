import JuicerLean.FixedPoint.PublicCalls

set_option maxRecDepth 4000
set_option maxHeartbeats 2000000

namespace Juicer.PublicCalls

inductive DispatchTarget where
  | vault
  | source
  | pool
  | environment
  | market
  | fees
  | harvester
  | mainDebt
  | swapper
  deriving Repr, DecidableEq

inductive DispatchSelector where
  | deposit
  | approve
  | transfer
  | transferFrom
  | requestRedeem
  | startUnwinds
  | pokeSettle
  | claim
  | sync
  | rebalance
  | warp
  | repay
  | setPullBps
  | setRepayLimit
  | pause
  | unpause
  | pauseDeposits
  | unpauseDeposits
  | setEmergencyPaused
  | reprice
  | setProtocolFeeBps
  | setCostBps
  | accrueInterest
  | setPrice
  | maintainPeg
  | harvest
  | compound
  | setDebtRounding
  | fundReserve
  | claimProtocolFees
  | setHaircut
  | setTvlCap
  | fundPosition
  | setRebalanceBand
  | setAdmissionMaxDeficitBps
  deriving Repr, DecidableEq

structure SolidityCall where
  target : DispatchTarget
  selector : DispatchSelector
  action : Action
  deriving Repr

def SolidityCall.arguments (call : SolidityCall) : List Nat :=
  let a := call.action
  match call.selector with
  | .deposit => [a.amount, a.b]
  | .approve | .transfer => [a.b, a.amount]
  | .transferFrom => [a.a, a.b, a.amount]
  | .requestRedeem => [a.amount, a.a]
  | .startUnwinds => [a.amount]
  | .claim => [a.amount, a.b]
  | .warp | .repay | .setPullBps | .setRepayLimit | .reprice | .setProtocolFeeBps
  | .setCostBps | .accrueInterest | .setPrice | .harvest | .fundReserve
  | .setHaircut | .setTvlCap | .fundPosition | .setAdmissionMaxDeficitBps => [a.amount]
  | .setEmergencyPaused => [(a.amount != 0).toNat]
  | .compound => [a.amount, a.b]
  | .setDebtRounding => [a.a, a.amount]
  | .claimProtocolFees => [(a.a != 0).toNat]
  | .setRebalanceBand => [a.a, a.b, a.amount]
  | _ => []

def decodeAction (a : Action) : Option SolidityCall :=
  match a.op with
  | 0 => some ⟨.vault, .deposit, a⟩
  | 1 => some ⟨.vault, .approve, a⟩
  | 2 => some ⟨.vault, .transfer, a⟩
  | 3 => some ⟨.vault, .transferFrom, a⟩
  | 4 => some ⟨.vault, .requestRedeem, a⟩
  | 5 => some ⟨.vault, .startUnwinds, a⟩
  | 6 => some ⟨.vault, .pokeSettle, a⟩
  | 7 => some ⟨.vault, .claim, a⟩
  | 8 => some ⟨.vault, .sync, a⟩
  | 9 => some ⟨.vault, .rebalance, a⟩
  | 10 => some ⟨.environment, .warp, a⟩
  | 11 => some ⟨.pool, .repay, a⟩
  | 12 => some ⟨.source, .setPullBps, a⟩
  | 13 => some ⟨.pool, .setRepayLimit, a⟩
  | 14 => some ⟨.vault, if a.amount = 0 then .unpause else .pause, a⟩
  | 15 => some ⟨.vault, if a.amount = 0 then .unpauseDeposits else .pauseDeposits, a⟩
  | 16 => some ⟨.source, .setEmergencyPaused, a⟩
  | 17 => some ⟨.market, .reprice, a⟩
  | 18 => some ⟨.fees, .setProtocolFeeBps, a⟩
  | 19 => some ⟨.market, .setCostBps, a⟩
  | 20 => some ⟨.pool, .accrueInterest, a⟩
  | 21 => some ⟨.pool, .setPrice, a⟩
  | 22 => some ⟨.vault, .maintainPeg, a⟩
  | 23 => some ⟨.harvester, .harvest, a⟩
  | 24 => some ⟨.vault, .compound, a⟩
  | 25 => some ⟨.pool, .setDebtRounding, a⟩
  | 26 => some ⟨.mainDebt, .fundReserve, a⟩
  | 27 => some ⟨.fees, .claimProtocolFees, a⟩
  | 28 => some ⟨.swapper, .setHaircut, a⟩
  | 29 => some ⟨.vault, .setTvlCap, a⟩
  | 30 => some ⟨.mainDebt, .fundPosition, a⟩
  | 31 => some ⟨.source, .setRebalanceBand, a⟩
  | 32 => some ⟨.source, .setAdmissionMaxDeficitBps, a⟩
  | _ => none

def solidityDispatch (s : State) (a : Action) : Result :=
  match decodeAction a with
  | some call => rawRunCall s call.action
  | none => .error 99

def solidityExecute (s : State) (a : Action) : State × Nat × Nat :=
  match solidityDispatch s a with
  | .ok (next, value) => (next, 0, value)
  | .error code => (s, code, 0)

def FixtureAction (a : Action) : Prop :=
  a.op ≤ 32 ∧
  (a.op = 10 ∨ a.caller < actors) ∧
  (a.op = 0 → a.caller < 4 ∧ a.b < actors) ∧
  (a.op = 1 → a.caller < 4 ∧ a.b < 4) ∧
  (a.op = 2 → a.b < actors) ∧
  (a.op = 3 → a.caller < 4 ∧ a.a < 4 ∧ a.b < actors) ∧
  (a.op = 4 → a.caller < 4 ∧ a.a < 4) ∧
  (a.op = 7 → a.b < actors) ∧
  (a.op = 24 → a.caller < 4) ∧
  (a.op = 12 → a.amount ≤ 10000) ∧
  (a.op = 17 → 0 < a.amount) ∧
  (a.op = 18 → a.caller = 0 ∧ a.amount ≤ 10000) ∧
  (a.op = 19 → a.amount ≤ 10000) ∧
  (a.op = 28 → a.amount ≤ 10000) ∧
  (a.op = 14 ∨ a.op = 15 ∨ a.op = 29 → a.caller = 0) ∧
  (a.op = 31 → a.caller = 0 ∧ a.a < 65536 ∧ a.b < 65536 ∧ a.amount < 65536) ∧
  (a.op = 32 → a.caller = 0 ∧ a.amount < 65536)

instance (a : Action) : Decidable (FixtureAction a) := by
  unfold FixtureAction
  infer_instance

theorem decodeAction_complete (a : Action) (h : a.op ≤ 32) :
    ∃ call, decodeAction a = some call := by
  rcases a with ⟨op, caller, x, y, amount⟩
  change op ≤ 32 at h
  interval_cases op <;> simp [decodeAction]

theorem decodeAction_sound {a : Action} {call : SolidityCall}
    (h : decodeAction a = some call) : a.op ≤ 32 := by
  rcases a with ⟨op, caller, x, y, amount⟩
  change op ≤ 32
  by_contra hn
  have hop : 33 ≤ op := by omega
  simp [decodeAction, show op ≠ 0 by omega, show op ≠ 1 by omega,
    show op ≠ 2 by omega, show op ≠ 3 by omega, show op ≠ 4 by omega,
    show op ≠ 5 by omega, show op ≠ 6 by omega, show op ≠ 7 by omega,
    show op ≠ 8 by omega, show op ≠ 9 by omega, show op ≠ 10 by omega,
    show op ≠ 11 by omega, show op ≠ 12 by omega, show op ≠ 13 by omega,
    show op ≠ 14 by omega, show op ≠ 15 by omega, show op ≠ 16 by omega,
    show op ≠ 17 by omega, show op ≠ 18 by omega, show op ≠ 19 by omega,
    show op ≠ 20 by omega, show op ≠ 21 by omega, show op ≠ 22 by omega,
    show op ≠ 23 by omega, show op ≠ 24 by omega, show op ≠ 25 by omega,
    show op ≠ 26 by omega, show op ≠ 27 by omega, show op ≠ 28 by omega,
    show op ≠ 29 by omega, show op ≠ 30 by omega, show op ≠ 31 by omega,
    show op ≠ 32 by omega] at h

theorem decodeAction_preserves_action {a : Action} {call : SolidityCall}
    (h : decodeAction a = some call) : call.action = a := by
  have hop := decodeAction_sound h
  rcases a with ⟨op, caller, x, y, amount⟩
  change op ≤ 32 at hop
  interval_cases op <;> simp [decodeAction] at h <;> cases h <;> rfl

theorem rawRunCall_unsupported (s : State) (a : Action) (h : 33 ≤ a.op) :
    rawRunCall s a = .error 99 := by
  rcases a with ⟨op, caller, x, y, amount⟩
  change 33 ≤ op at h
  simp [rawRunCall, show op ≠ 0 by omega, show op ≠ 1 by omega,
    show op ≠ 2 by omega, show op ≠ 3 by omega, show op ≠ 4 by omega,
    show op ≠ 5 by omega, show op ≠ 6 by omega, show op ≠ 7 by omega,
    show op ≠ 8 by omega, show op ≠ 9 by omega, show op ≠ 10 by omega,
    show op ≠ 11 by omega, show op ≠ 12 by omega, show op ≠ 13 by omega,
    show op ≠ 14 by omega, show op ≠ 15 by omega, show op ≠ 16 by omega,
    show op ≠ 17 by omega, show op ≠ 18 by omega, show op ≠ 19 by omega,
    show op ≠ 20 by omega, show op ≠ 21 by omega, show op ≠ 22 by omega,
    show op ≠ 23 by omega, show op ≠ 24 by omega, show op ≠ 25 by omega,
    show op ≠ 26 by omega, show op ≠ 27 by omega, show op ≠ 28 by omega,
    show op ≠ 29 by omega, show op ≠ 30 by omega, show op ≠ 31 by omega,
    show op ≠ 32 by omega]
  rfl

theorem solidity_dispatch_corresponds (s : State) (a : Action) :
    solidityDispatch s a = rawRunCall s a := by
  unfold solidityDispatch
  cases h : decodeAction a with
  | none =>
    have hop : 33 ≤ a.op := by
      by_contra hn
      have hle : a.op ≤ 32 := by omega
      obtain ⟨call, hc⟩ := decodeAction_complete a hle
      rw [h] at hc
      contradiction
    exact (rawRunCall_unsupported s a hop).symm
  | some call => simp only [decodeAction_preserves_action h]

theorem solidity_execute_corresponds (s : State) (a : Action) :
    solidityExecute s a = rawExecute s a := by
  unfold solidityExecute rawExecute
  rw [solidity_dispatch_corresponds]
  rfl

end Juicer.PublicCalls
