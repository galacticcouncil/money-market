import JuicerLean.FixedPoint.PublicPaymentProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def holderLiability (s : State) : Nat :=
  ((List.range 5).map fun i =>
    (normalizeAccount s.book (account s i) (wallet s i)).numerator s.book.index).sum

def requestLiability (s : State) (r : Request) : Nat :=
  (normalizeAccount s.book r.account r.claim.shares).numerator s.book.index

theorem publicLiability_list (s : State) : publicLiability s =
    holderLiability s+((waitingRequests s).map (requestLiability s)).sum := by
  rw [publicLiability_parts]
  have hh := congrArg (fun xs : List Request => (xs.map (requestLiability s)).sum)
    (list_range_values (s.requests.toList.drop s.unwind) ({} : Request))
  simpa only [holderLiability,requestLiability,waitingRequests,List.length_drop,
    ← Array.size_eq_length_toList,List.map_map,Function.comp_apply,List.getElem?_drop,
    Array.getElem?_toList,request] using congrArg (fun n => holderLiability s+n) hh

def appendRequest (s : State) (owner escrow committed : Nat) : State :=
  let r : Request := {
    owner,eligible := s.time+10,claim := ⟨escrow,0,0,0,0,0,0,true⟩,
    account := ⟨committed,s.book.index,s.book.epoch,s.book.scale⟩ }
  { s with requests := s.requests.push r,pending := s.pending+escrow }

theorem appendRequest_active (s : State) (owner escrow committed : Nat) (hu : s.unwind ≤ s.requests.size) :
    activeRequests (appendRequest s owner escrow committed) = activeRequests s := by
  simp only [appendRequest,activeRequests,Array.toList_push]
  rw [List.take_append_of_le_length (by simpa using hu)]

theorem appendRequest_waiting (s : State) (owner escrow committed : Nat) (hu : s.unwind ≤ s.requests.size) :
    waitingRequests (appendRequest s owner escrow committed) = waitingRequests s ++
      [{
        owner,eligible := s.time+10,claim := ⟨escrow,0,0,0,0,0,0,true⟩,
        account := ⟨committed,s.book.index,s.book.epoch,s.book.scale⟩ }] := by
  simp only [appendRequest,waitingRequests,Array.toList_push]
  rw [List.drop_append_of_le_length (by simpa using hu)]

theorem appendRequest_liability (s : State) (owner escrow committed : Nat) (hu : s.unwind ≤ s.requests.size) :
    publicLiability (appendRequest s owner escrow committed) = publicLiability s+committed*ray := by
  rw [publicLiability_list,publicLiability_list,appendRequest_waiting s owner escrow committed hu]
  have hh : holderLiability (appendRequest s owner escrow committed) = holderLiability s := by
    simp only [holderLiability,account,wallet,appendRequest]
  have hf : requestLiability (appendRequest s owner escrow committed) = requestLiability s := rfl
  rw [hh,hf]
  simp only [List.map_append,List.sum_append,List.map_cons,List.map_nil,List.sum_cons,List.sum_nil,
    requestLiability,normalized_request_created,LazyAccount.numerator,
    Nat.sub_self,Nat.mul_zero,Nat.add_zero,Nat.add_assoc]

theorem appendRequest_operational (s : State) (owner escrow committed : Nat)
    (h : OperationalInvariant s) (he : s.pending+s.queued+escrow ≤ wallet s vaultId) :
    OperationalInvariant (appendRequest s owner escrow committed) := by
  have hu : s.unwind ≤ s.requests.size := h.2.2.2.2.2.1
  have ha := appendRequest_active s owner escrow committed hu
  have hw := appendRequest_waiting s owner escrow committed hu
  rcases h with ⟨hws,has,hc,hap,hpos,hunwind,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  refine ⟨hws,has,hc,hap,hpos,?_,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    ?_,?_,?_,?_,?_,?_,?_,?_⟩
  · simpa only [appendRequest,Array.size_push] using (show s.unwind ≤ s.requests.size+1 by omega)
  · rw [ha]; exact hvalid
  · rw [hw]
    simp only [List.map_append,List.sum_append,List.map_cons,List.map_nil,List.sum_cons,List.sum_nil,Nat.add_zero]
    exact congrArg (fun n => n+escrow) hpend
  · rw [ha]; exact hqueued
  · rw [ha]; exact howed
  · rw [ha]; exact hqd
  · change s.pending+escrow+s.queued ≤ wallet s vaultId; omega
  · rw [ha]; exact hassets
  · rw [ha]; exact hliquid

theorem appendRequest_public (s : State) (owner escrow committed : Nat)
    (h : PublicInvariant s) (he : s.pending+s.queued+escrow ≤ wallet s vaultId)
    (hl : publicLiability s+committed*ray < s.book.total*ray+ray) :
    PublicInvariant (appendRequest s owner escrow committed) := by
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · apply (publicSlack_lt_iff _).2
    rw [appendRequest_liability s owner escrow committed h.2.2.2.2.2.2.2.2.2.2.1]
    exact hl
  · exact appendRequest_operational s owner escrow committed h.2.2.2.2.2 he

theorem setRequestUnits_liability (s : State) (owner left committed : Nat)
    (ho : owner < 5) (ha : owner < s.accounts.size) (hc : CurrentAccount s owner)
    (hs : left+committed = (account s owner).units) :
    publicLiability (setAccount s owner { account s owner with units := left })+committed*ray =
      publicLiability s := by
  have hh := setAccount_liability_balance s owner { account s owner with units := left } ho ha
  rw [current_numerator s.book (account s owner) _ hc.1 hc.2.1 hc.2.2,
    current_numerator s.book { account s owner with units := left } _ hc.1 hc.2.1 hc.2.2] at hh
  change publicLiability (setAccount s owner { account s owner with units := left })+
    (account s owner).units*ray = publicLiability s+left*ray at hh
  have hm : (account s owner).units*ray = left*ray+committed*ray := by
    rw [← hs,Nat.add_mul]
  rw [hm] at hh
  omega

theorem setRequestUnits_public (s : State) (owner left committed : Nat)
    (h : PublicInvariant s) (ho : owner < 5) (hc : CurrentAccount s owner)
    (hs : left+committed = (account s owner).units) :
    PublicInvariant (setAccount s owner { account s owner with units := left }) := by
  have ha : owner < s.accounts.size := by
    have hh : s.accounts.size = actors := h.2.2.2.2.2.2.1
    rw [hh]
    exact ho.trans (by decide : 5 < actors)
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · apply (publicSlack_lt_iff _).2
    have he := (publicSlack_lt_iff s).1 h.2.2.2.2.1
    have hh := setRequestUnits_liability s owner left committed ho ha hc hs
    change publicLiability (setAccount s owner { account s owner with units := left }) < s.book.total*ray+ray
    clear h hc
    omega
  · simpa only [setAccount,OperationalInvariant,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds]
      using h.2.2.2.2.2


end Juicer.PublicCalls

