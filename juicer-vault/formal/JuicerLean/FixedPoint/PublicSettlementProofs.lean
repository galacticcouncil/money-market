import JuicerLean.FixedPoint.PublicRequestProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

structure SettlementUpdate (before after : RedemptionState) : Prop where
  valid : after.valid
  shares : after.shares = before.shares
  owed : after.owed = before.owed
  debt : after.debt = before.debt
  burned : after.burned = before.burned
  claimed : after.claimed = before.claimed
  repaid : before.repaid ≤ after.repaid
  settled : before.settled ≤ after.settled

theorem settlement_update (r : RedemptionState) (paid : Nat) (h : r.valid) :
    SettlementUpdate r (settleRedemption r paid) :=
  ⟨redemption_settle_preserves r paid h,rfl,rfl,rfl,rfl,rfl,Nat.le_add_right _ _,Nat.le_add_right _ _⟩

def QueueBacking (s : State) : Prop := s.owed ≤ s.assets ∧ s.positions.size = s.unwind+1

instance (s : State) : Decidable (QueueBacking s) := by unfold QueueBacking; infer_instance

theorem settled_liquid_bound (before after delta liquid supplied assets reserve : Nat)
    (hchange : after = before+delta) (hbefore : before ≤ liquid) (hafter : after ≤ assets)
    (hbacking : assets+reserve = supplied+liquid) : after ≤ liquid+min delta supplied := by omega

theorem settlement_debt_balance (before after debt total next : Nat)
    (hbefore : before ≤ after) (hafter : after ≤ debt)
    (hsum : next+(debt-before) = total+(debt-after)) : next = total-(after-before) := by omega

theorem settlement_sum_change (before after total next : Nat) (hbefore : before ≤ after)
    (hsum : next+before = total+after) : next = total+(after-before) := by omega

theorem settleRecord_waiting (s : State) (i : Nat) (next : RedemptionState) (hi : i < s.unwind) :
    waitingRequests (settleRecord s i (request s i) next) = waitingRequests s :=
  waiting_replace s i { request s i with claim := next } hi

theorem settleRecord_liability (s : State) (i : Nat) (next : RedemptionState) (hi : i < s.unwind) :
    publicLiability (settleRecord s i (request s i) next) = publicLiability s := by
  rw [publicLiability_list,publicLiability_list,settleRecord_waiting s i next hi]
  rfl

theorem settleRecord_claims_valid (s : State) (i : Nat) (next : RedemptionState)
    (h : ∀ r ∈ activeRequests s, r.claim.valid) (hn : next.valid) :
    ∀ r ∈ activeRequests (settleRecord s i (request s i) next), r.claim.valid := by
  intro r hr
  change r ∈ (s.requests.set! i { request s i with claim := next }).toList.take s.unwind at hr
  simp only [Array.set!_eq_setIfInBounds,Array.toList_setIfInBounds,List.take_set] at hr
  rcases List.mem_or_eq_of_mem_set hr with hm | rfl
  · exact h r hm
  · exact hn

theorem claims_settled_le_owed (rs : List Request) (h : ∀ r ∈ rs, r.claim.valid) :
    (rs.map fun r => r.claim.settled).sum ≤ (rs.map fun r => r.claim.owed-r.claim.claimed).sum := by
  apply List.sum_le_sum
  intro r hr
  have hb := redemption_claimed_bounded r.claim (h r hr)
  omega

theorem settleRecord_operational (s : State) (i : Nat) (next : RedemptionState)
    (h : OperationalInvariant s) (hi : i < s.unwind)
    (hn : SettlementUpdate (request s i).claim next) (hb : s.owed ≤ s.assets)
    (hcoll : CollateralConserved s) : OperationalInvariant (settleRecord s i (request s i) next) := by
  rcases h with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  let updated := { request s i with claim := next }
  let after := settleRecord s i (request s i) next
  have hshares := active_sum_replace s i updated (fun r => r.claim.shares-r.claim.burned) hi hu
  have howeds := active_sum_replace s i updated (fun r => r.claim.owed-r.claim.claimed) hi hu
  have hdebts := active_sum_replace s i updated (fun r => r.claim.debt-r.claim.repaid) hi hu
  have hsettled := active_sum_replace s i updated (fun r => r.claim.settled) hi hu
  change ((activeRequests after).map fun r => r.claim.shares-r.claim.burned).sum+
    ((request s i).claim.shares-(request s i).claim.burned) =
    ((activeRequests s).map fun r => r.claim.shares-r.claim.burned).sum+(next.shares-next.burned) at hshares
  change ((activeRequests after).map fun r => r.claim.owed-r.claim.claimed).sum+
    ((request s i).claim.owed-(request s i).claim.claimed) =
    ((activeRequests s).map fun r => r.claim.owed-r.claim.claimed).sum+(next.owed-next.claimed) at howeds
  change ((activeRequests after).map fun r => r.claim.debt-r.claim.repaid).sum+
    ((request s i).claim.debt-(request s i).claim.repaid) =
    ((activeRequests s).map fun r => r.claim.debt-r.claim.repaid).sum+(next.debt-next.repaid) at hdebts
  change ((activeRequests after).map fun r => r.claim.settled).sum+(request s i).claim.settled =
    ((activeRequests s).map fun r => r.claim.settled).sum+next.settled at hsettled
  rw [hn.shares,hn.burned] at hshares
  rw [hn.owed,hn.claimed] at howeds
  rw [hn.debt,← hqd] at hdebts
  have haqueued := (Nat.add_right_cancel hshares).trans hqueued.symm
  have haowed := (Nat.add_right_cancel howeds).trans howed.symm
  have han := settleRecord_claims_valid s i next hvalid hn.valid
  have hasettled : ((activeRequests after).map fun r => r.claim.settled).sum ≤ s.assets :=
    (claims_settled_le_owed (activeRequests after) han).trans (haowed ▸ hb)
  refine ⟨hw,ha,hc,hap,hpos,?_,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    han,?_,haqueued.symm,haowed.symm,?_,hvault,hasettled,?_⟩
  · simpa only [settleRecord,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hu
  · rw [settleRecord_waiting s i next hi]
    exact hpend
  · exact (settlement_debt_balance _ _ _ _ _ hn.repaid (hn.debt ▸ hn.valid.2.1) hdebts).symm
  · exact settled_liquid_bound _ _ _ _ _ _ s.reserve
      (settlement_sum_change _ _ _ _ hn.settled hsettled) hliquid hasettled hcoll

theorem settleRecord_public (s : State) (i : Nat) (next : RedemptionState)
    (h : PublicInvariant s) (hi : i < s.unwind)
    (hn : SettlementUpdate (request s i).claim next) (hb : s.owed ≤ s.assets) :
    PublicInvariant (settleRecord s i (request s i) next) := by
  apply public_of_operational
  · exact settleRecord_collateral s i (request s i) next h.1
  · exact h.2.1
  · exact h.2.2.1
  · apply (publicSlack_lt_iff _).2
    rw [settleRecord_liability s i next hi]
    exact (publicSlack_lt_iff s).1 h.2.2.2.2.1
  · exact settleRecord_operational s i next h.2.2.2.2.2 hi hn hb h.1

theorem head_public (s : State) (head : Nat) (h : PublicInvariant s) :
    PublicInvariant { s with head } := h

theorem finishSettle_public (s : State) (i paid : Nat) (h : PublicInvariant s)
    (hi : i < s.unwind) (hb : s.owed ≤ s.assets) :
    PublicInvariant (finishSettle s i (request s i) paid).1 := by
  have hu : s.unwind ≤ s.requests.size := h.2.2.2.2.2.2.2.2.2.2.1
  have hv : (request s i).claim.valid := by
    rcases h.2.2.2.2.2 with ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,hv,_,_,_,_,_,_,_⟩
    exact hv (request s i) (active_request_mem s i hi hu)
  have hn := settleRecord_public s i (settleRedemption (request s i).claim paid) h hi
    (settlement_update (request s i).claim paid hv) hb
  unfold finishSettle
  dsimp only
  split
  · exact hn
  · exact head_public _ (i+1) hn

theorem finishSettle_backing (s : State) (i : Nat) (r : Request) (paid : Nat) (h : QueueBacking s) :
    QueueBacking (finishSettle s i r paid).1 := by
  unfold finishSettle
  dsimp only
  split <;> exact h

theorem pay_queueBacking (s : State) (key limit : Nat) (h : QueueBacking s) :
    QueueBacking (pay s key limit).1 := by
  rw [pay_state_factored]
  refine ⟨h.1,?_⟩
  simpa only [paymentState,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using h.2

theorem pay_request (s : State) (key limit i : Nat) :
    request (pay s key limit).1 i = request s i := by
  rw [pay_state_factored]
  rfl

theorem pay_unwind (s : State) (key limit : Nat) : (pay s key limit).1.unwind = s.unwind := by
  rw [pay_state_factored]
  rfl

theorem settleOne_preserves (s : State) (h : PublicInvariant s) (hb : QueueBacking s) :
    PublicInvariant (settleOne s).1 ∧ QueueBacking (settleOne s).1 := by
  unfold settleOne
  split
  · exact ⟨h,hb⟩
  next hguard =>
    have hi : s.head < s.unwind := by
      clear h hb
      simp only [Bool.or_eq_true,bne_iff_ne,decide_eq_true_eq] at hguard
      omega
    dsimp only
    by_cases hd : ((request s s.head).claim.debt == (request s s.head).claim.repaid) = true
    · simp only [hd,ite_true]
      exact ⟨finishSettle_public s s.head 0 h hi hb.1,finishSettle_backing s s.head _ 0 hb⟩
    · simp only [hd]
      let p := pay s (s.head+1) ((request s s.head).claim.debt-(request s s.head).claim.repaid)
      have hip : s.head+1 < s.positions.size := by have hh := hb.2; clear h hb; omega
      have hp : PublicInvariant p.1 := pay_public s _ _ hip h
      have hpb : QueueBacking p.1 := pay_queueBacking s _ _ hb
      have hir : s.head < p.1.unwind := by rw [pay_unwind]; exact hi
      have hr : request p.1 s.head = request s s.head := pay_request s _ _ s.head
      change PublicInvariant (finishSettle p.1 s.head (request s s.head) p.2.1).1 ∧
        QueueBacking (finishSettle p.1 s.head (request s s.head) p.2.1).1
      rw [← hr]
      exact ⟨finishSettle_public p.1 s.head p.2.1 hp hir hpb.1,finishSettle_backing p.1 s.head _ p.2.1 hpb⟩

theorem settleMany_preserves (fuel : Nat) (s : State) (h : PublicInvariant s) (hb : QueueBacking s) :
    PublicInvariant (settleMany fuel s) ∧ QueueBacking (settleMany fuel s) := by
  induction fuel generalizing s with
  | zero => exact ⟨h,hb⟩
  | succ fuel ih =>
    have hn := settleOne_preserves s h hb
    rcases heq : settleOne s with ⟨next,more⟩
    rw [heq] at hn
    simp only [settleMany,heq]
    split
    · exact ih next hn.1 hn.2
    · exact hn

end Juicer.PublicCalls
