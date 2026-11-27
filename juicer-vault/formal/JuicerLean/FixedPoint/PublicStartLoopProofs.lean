import JuicerLean.FixedPoint.PublicStartProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem onSuccess_map (p : β → Prop) (f : α → β) (result : Except ε α) :
    OnSuccess p (result.map f) ↔ OnSuccess (fun a => p (f a)) result := by
  cases result <;> rfl

theorem checkpoint_withUnwind (s : State) (cursor : Nat) :
    withUnwind (checkpoint s zeroId zeroId) cursor = checkpoint (withUnwind s cursor) zeroId zeroId := by
  rw [checkpoint_zero_factored,checkpoint_zero_factored]
  change withUnwind (if !pendingAccounting s then allocateState s else s) cursor =
    if !pendingAccounting s then allocateState (withUnwind s cursor) else withUnwind s cursor
  split <;> rfl

theorem startOne_cursor (s : State) (cursor : Nat) :
    (startOne s cursor).map (fun next => withUnwind next (cursor+1)) =
      unwindHead (checkpoint (withUnwind s cursor) zeroId zeroId) := by
  rw [startOne_program,startProgram_head,startHead_exact,checkpoint_withUnwind]

theorem startOne_cursor_preserves (s : State) (cursor : Nat)
    (h : PublicInvariant (withUnwind s cursor)) (hr : UnwindReady (withUnwind s cursor))
    (hi : cursor < s.requests.size) :
    OnSuccess (fun next => PublicInvariant (withUnwind next (cursor+1)) ∧
      UnwindReady (withUnwind next (cursor+1))) (startOne s cursor) := by
  apply (onSuccess_map (fun next => PublicInvariant next ∧ UnwindReady next)
    (fun next => withUnwind next (cursor+1)) (startOne s cursor)).mp
  rw [startOne_cursor]
  exact checkpoint_unwindHead_preserves (withUnwind s cursor) h hr hi

theorem startMany_preserves (fuel : Nat) (s : State) (cursor : Nat)
    (h : PublicInvariant (withUnwind s cursor)) (hr : UnwindReady (withUnwind s cursor)) :
    OnSuccess (fun result : State × Nat => PublicInvariant (withUnwind result.1 result.2) ∧
      UnwindReady (withUnwind result.1 result.2)) (startMany fuel s cursor) := by
  induction fuel generalizing s cursor with
  | zero => exact ⟨h,hr⟩
  | succ fuel ih =>
    change OnSuccess _ (if s.requests.size ≤ cursor || s.time < (request s cursor).eligible then
      .ok (s,cursor) else startOne s cursor >>= fun next => startMany fuel next (cursor+1))
    split
    · exact ⟨h,hr⟩
    next hguard =>
      rw [onSuccess_bind]
      intro next heq
      have hi : cursor < s.requests.size := by
        simp only [Bool.or_eq_true,decide_eq_true_eq,not_or] at hguard
        omega
      have hn := onSuccess_of_eq (startOne_cursor_preserves s cursor h hr hi) heq
      exact ih next (cursor+1) hn.1 hn.2

theorem raw_startUnwinds_factored (s : State) (caller a b n : Nat) :
    rawRunCall s ⟨5,caller,a,b,n⟩ =
      if s.paused || s.sourcePaused then .error 1
      else if s.delever != 0 || s.activeRemaining != 0 then .ok (s,0)
      else (startMany n s s.unwind).map (fun result => (withUnwind result.1 result.2,0)) := rfl

theorem raw_startUnwinds_public (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) (hr : UnwindReady s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rawRunCall s ⟨5,caller,a,b,n⟩) := by
  rw [raw_startUnwinds_factored]
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · exact h
    · rw [onSuccess_map]
      have hp := startMany_preserves n s s.unwind h hr
      cases heq : startMany n s s.unwind with
      | error e => trivial
      | ok result => exact (onSuccess_of_eq hp heq).1

end Juicer.PublicCalls
