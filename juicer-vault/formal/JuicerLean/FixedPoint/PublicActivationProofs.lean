import JuicerLean.FixedPoint.PublicExitProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def activatedRequest (r : Request) (shares owed debt synth : Nat) : Request :=
  { r with claim := freshRedemption shares owed debt,synth,account := {} }

def activateWaiting (s : State) (shares owed debt synth : Nat) : State :=
  let r := request s s.unwind
  { s with
    pending := s.pending-r.claim.shares,queued := s.queued+shares,owed := s.owed+owed,
    queuedDebt := s.queuedDebt+debt,unwind := s.unwind+1,
    requests := s.requests.set! s.unwind (activatedRequest r shares owed debt synth) }

theorem activeRequests_activate (s : State) (shares owed debt synth : Nat) (hi : s.unwind < s.requests.size) :
    activeRequests (activateWaiting s shares owed debt synth) = activeRequests s ++
      [activatedRequest (request s s.unwind) shares owed debt synth] := by
  simp only [activateWaiting,activeRequests,Array.set!_eq_setIfInBounds,Array.toList_setIfInBounds]
  rw [List.take_succ_eq_append_getElem (by simpa using hi),List.take_set_of_le (Nat.le_refl _),List.getElem_set_self]

theorem waitingRequests_activate (s : State) (shares owed debt synth : Nat) :
    waitingRequests (activateWaiting s shares owed debt synth) = s.requests.toList.drop (s.unwind+1) := by
  simp only [activateWaiting,waitingRequests,Array.set!_eq_setIfInBounds,Array.toList_setIfInBounds,
    List.drop_set_of_lt (Nat.lt_succ_self _)]

theorem activateWaiting_liability (s : State) (shares owed debt synth : Nat) :
    publicLiability (activateWaiting s shares owed debt synth) = publicLiability (advanceWaiting s) := by
  rw [publicLiability_list,publicLiability_list,waitingRequests_activate]
  rfl

theorem activateWaiting_operational (s : State) (shares owed debt synth : Nat) (h : OperationalInvariant s)
    (hi : s.unwind < s.requests.size) (ho : 0 < owed)
    (he : s.pending-(request s s.unwind).claim.shares+s.queued+shares ≤ wallet s vaultId) :
    OperationalInvariant (activateWaiting s shares owed debt synth) := by
  have hactive := activeRequests_activate s shares owed debt synth hi
  have hwaiting := waitingRequests_activate s shares owed debt synth
  have hhead := waiting_head s hi
  rcases h with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  refine ⟨hw,ha,hc,hap,hpos,?_,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    ?_,?_,?_,?_,?_,?_,?_,?_⟩
  · simpa only [activateWaiting,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hi
  · intro r hr
    rw [hactive,List.mem_append,List.mem_singleton] at hr
    rcases hr with hold | rfl
    · exact hvalid r hold
    · exact fresh_redemption_valid shares owed debt ho
  · rw [hwaiting]
    rw [hhead,List.map_cons,List.sum_cons] at hpend
    change s.pending-(request s s.unwind).claim.shares = _
    omega
  · rw [hactive]
    simp only [List.map_append,List.sum_append,List.map_singleton,List.sum_singleton,
      activatedRequest,freshRedemption,Nat.sub_zero]
    exact congrArg (fun n => n+shares) hqueued
  · rw [hactive]
    simp only [List.map_append,List.sum_append,List.map_singleton,List.sum_singleton,
      activatedRequest,freshRedemption,Nat.sub_zero]
    exact congrArg (fun n => n+owed) howed
  · rw [hactive]
    simp only [List.map_append,List.sum_append,List.map_singleton,List.sum_singleton,
      activatedRequest,freshRedemption,Nat.sub_zero]
    exact congrArg (fun n => n+debt) hqd
  · simpa only [activateWaiting,Nat.add_assoc] using he
  · rw [hactive]
    simpa only [List.map_append,List.sum_append,List.map_singleton,List.sum_singleton,
      activatedRequest,freshRedemption,Nat.add_zero] using hassets
  · rw [hactive]
    simpa only [List.map_append,List.sum_append,List.map_singleton,List.sum_singleton,
      activatedRequest,freshRedemption,Nat.add_zero] using hliquid

end Juicer.PublicCalls
