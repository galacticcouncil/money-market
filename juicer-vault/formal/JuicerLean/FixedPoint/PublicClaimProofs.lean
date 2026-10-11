import JuicerLean.FixedPoint.PublicTransferProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 500000

namespace Juicer.PublicCalls
open Runtime

theorem list_sum_map_set {α : Type} (xs : List α) (i : Nat) (value fallback : α)
    (f : α → Nat) (hi : i < xs.length) :
    ((xs.set i value).map f).sum + f (xs[i]?.getD fallback) = (xs.map f).sum + f value := by
  induction xs generalizing i with
  | nil => simp at hi
  | cons x xs ih =>
    cases i with
    | zero => simp; omega
    | succ i =>
      have hh := ih i (by simpa using hi)
      simp only [List.set_cons_succ, List.map_cons, List.sum_cons, List.getElem?_cons_succ]
      omega

theorem active_sum_replace (s : State) (i : Nat) (r : Request) (f : Request → Nat)
    (hi : i < s.unwind) (hu : s.unwind ≤ s.requests.size) :
    (((s.requests.set! i r).toList.take s.unwind).map f).sum + f (request s i) =
      ((activeRequests s).map f).sum + f r := by
  have hlen : i < (s.requests.toList.take s.unwind).length := by
    simp only [List.length_take, ← Array.size_eq_length_toList]
    omega
  have hh := list_sum_map_set (s.requests.toList.take s.unwind) i r {} f hlen
  simp only [Array.set!_eq_setIfInBounds, Array.toList_setIfInBounds, List.take_set]
  simpa only [List.getElem?_take, if_pos hi, Array.getElem?_toList, request, activeRequests] using hh

theorem waiting_replace (s : State) (i : Nat) (r : Request) (hi : i < s.unwind) :
    (s.requests.set! i r).toList.drop s.unwind = waitingRequests s := by
  simp only [Array.set!_eq_setIfInBounds, Array.toList_setIfInBounds,
    List.drop_set_of_lt hi, waitingRequests]

theorem active_request_mem (s : State) (i : Nat) (hi : i < s.unwind)
    (hu : s.unwind ≤ s.requests.size) : request s i ∈ activeRequests s := by
  have hlen : i < (s.requests.toList.take s.unwind).length := by
    simp only [List.length_take, ← Array.size_eq_length_toList]
    omega
  have hg := List.getElem?_eq_getElem hlen
  have hm := List.getElem_mem hlen
  simp only [List.getElem?_take, if_pos hi, Array.getElem?_toList] at hg
  simpa only [request, hg, Option.getD_some, activeRequests] using hm

theorem claim_burn_balance (r : RedemptionState) (h : r.valid) (hs : 0 < r.settled) :
    (claimRedemption r).1.burned = r.burned + (claimRedemption r).2.2 ∧
      (claimRedemption r).2.2 ≤ r.shares-r.burned := by
  have hb := redemption_burned_bounded r h
  have hp := redemption_claimed_bounded r h
  have htotal : r.burned ≤ r.shares * (r.claimed+r.settled) / r.owed := by
    rw [h.2.2.2.1]
    exact Nat.div_le_div_right (Nat.mul_le_mul_left _ (by omega))
  have hmax : r.shares * (r.claimed+r.settled) / r.owed ≤ r.shares :=
    proportional_le _ _ _ (by omega)
  refine ⟨rfl, ?_⟩
  change (if r.debt ≤ r.repaid then r.shares-r.burned
    else r.shares*(r.claimed+r.settled)/r.owed-r.burned) ≤ r.shares-r.burned
  split
  · exact le_rfl
  · exact Nat.sub_le_sub_right hmax r.burned

theorem map_value_le_sum {α : Type} (f : α → Nat) (xs : List α) (x : α) (hx : x ∈ xs) :
    f x ≤ (xs.map f).sum := by
  induction xs with
  | nil => simp at hx
  | cons y ys ih =>
    simp only [List.mem_cons] at hx
    simp only [List.map_cons, List.sum_cons]
    rcases hx with rfl | hx
    · omega
    · have hh := ih hx
      omega

def claimState (s : State) (i receiver : Nat) : State :=
  let r := request s i
  let next := (claimRedemption r.claim).1
  let burned := (claimRedemption r.claim).2.2
  let paid := r.claim.settled
  { setWallet s vaultId (wallet s vaultId-burned) with
    supply := s.supply-burned
    assets := s.assets-(if receiver == vaultId then 0 else paid)
    liquid := s.liquid-(if receiver == vaultId then 0 else paid)
    queued := s.queued-burned
    owed := s.owed-paid
    requests := s.requests.set! i { r with claim := next }
    collateral := s.collateral.set! receiver (s.collateral[receiver]!+paid) }

theorem claimState_waiting (s : State) (i receiver : Nat) (hi : i < s.unwind) :
    waitingRequests (claimState s i receiver) = waitingRequests s :=
  waiting_replace s i _ hi

theorem claimState_liability (s : State) (i receiver : Nat) (hi : i < s.unwind)
    (hw : s.wallets.size = actors) : publicLiability (claimState s i receiver) = publicLiability s := by
  rw [publicLiability_parts, publicLiability_parts]
  have hsize : (claimState s i receiver).requests.size = s.requests.size := by
    simp only [claimState, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds]
  rw [hsize]
  have hm : ((List.range 5).map fun j =>
      (normalizeAccount s.book (account s j) (wallet (claimState s i receiver) j)).numerator s.book.index) =
      (List.range 5).map fun j =>
        (normalizeAccount s.book (account s j) (wallet s j)).numerator s.book.index := by
    apply List.map_congr_left
    intro j hj
    have hj5 := List.mem_range.mp hj
    change (normalizeAccount s.book (account s j)
      (wallet (setWallet s vaultId _) j)).numerator s.book.index = _
    rw [wallet_setWallet s vaultId _ j (by simp only [hw, actors, vaultId]; decide)]
    rw [if_neg (by simp only [vaultId]; omega)]
  change ((List.range 5).map fun j =>
    (normalizeAccount s.book (account s j) (wallet (claimState s i receiver) j)).numerator s.book.index).sum +
    ((List.range (s.requests.size-s.unwind)).map fun j =>
      (normalizeAccount s.book (request (claimState s i receiver) (s.unwind+j)).account
        (request (claimState s i receiver) (s.unwind+j)).claim.shares).numerator s.book.index).sum = _
  rw [hm]
  apply congrArg (fun n =>
    ((List.range 5).map fun j =>
      (normalizeAccount s.book (account s j) (wallet s j)).numerator s.book.index).sum+n)
  apply congrArg List.sum
  apply List.map_congr_left
  intro j _
  have hg : request (claimState s i receiver) (s.unwind+j) = request s (s.unwind+j) := by
    simp only [claimState, request, setWallet, Array.set!_eq_setIfInBounds,
      Array.getElem?_setIfInBounds]
    rw [if_neg (by omega)]
  rw [hg]

theorem claimState_operational (s : State) (i receiver : Nat)
    (h : OperationalInvariant s) (hi : i < s.unwind)
    (hp : 0 < (request s i).claim.settled) : OperationalInvariant (claimState s i receiver) := by
  rcases h with ⟨hw, ha, hc, hap, hpos, hu, hsum, hmain, hout, hfs, hfr,
    hfees, hcash, hvalid, hpend, hqueued, howed, hqd, hescrow, hassets, hliquid⟩
  let r := request s i
  let next := (claimRedemption r.claim).1
  let burned := (claimRedemption r.claim).2.2
  let paid := r.claim.settled
  have hm : r ∈ activeRequests s := active_request_mem s i hi hu
  have hv : r.claim.valid := hvalid r hm
  have hn : next.valid := redemption_claim_preserves r.claim hv hp
  have hb := claim_burn_balance r.claim hv hp
  have hpaid := redemption_claimed_bounded r.claim hv
  have hqbound := map_value_le_sum (fun r : Request => r.claim.shares-r.claim.burned)
    (activeRequests s) r hm
  rw [← hqueued] at hqbound
  have hsbound := map_value_le_sum (fun r : Request => r.claim.settled) (activeRequests s) r hm
  have hburned : burned ≤ wallet s vaultId := by
    have hqvault : s.queued ≤ wallet s vaultId := by omega
    exact hb.2.trans (hqbound.trans hqvault)
  have hwallet := wallet_sum_set_balance s vaultId (wallet s vaultId-burned)
    (by simp only [hw, vaultId, actors]; decide)
  have hshares := active_sum_replace s i { r with claim := next }
    (fun r => r.claim.shares-r.claim.burned) hi hu
  have howeds := active_sum_replace s i { r with claim := next }
    (fun r => r.claim.owed-r.claim.claimed) hi hu
  have hdebts := active_sum_replace s i { r with claim := next }
    (fun r => r.claim.debt-r.claim.repaid) hi hu
  have hsettled := active_sum_replace s i { r with claim := next }
    (fun r => r.claim.settled) hi hu
  have hfields : next.shares = r.claim.shares ∧ next.owed = r.claim.owed ∧
      next.debt = r.claim.debt ∧ next.repaid = r.claim.repaid ∧
      next.claimed = r.claim.claimed+paid ∧ next.settled = 0 := by
    exact ⟨rfl,rfl,rfl,rfl,rfl,rfl⟩
  change next.burned = r.claim.burned+burned ∧ burned ≤ r.claim.shares-r.claim.burned at hb
  simp only [hfields.1, hb.1] at hshares
  simp only [hfields.2.1, hfields.2.2.2.2.1] at howeds
  simp only [hfields.2.2.1, hfields.2.2.2.1] at hdebts
  simp only [hfields.2.2.2.2.2] at hsettled
  dsimp only [r, burned, paid] at *
  refine ⟨?_, ha, ?_, hap, hpos, ?_, ?_, hmain, hout, hfs, hfr, hfees,
    hcash, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · simpa only [claimState, setWallet, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hw
  · simpa only [claimState, setWallet, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hc
  · simpa only [claimState, setWallet, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hu
  · change s.supply-burned = (setWallet s vaultId (wallet s vaultId-burned)).wallets.toList.sum
    dsimp only [r,burned,paid]
    omega
  · intro row hrow
    change row ∈ (s.requests.set! i { r with claim := next }).toList.take s.unwind at hrow
    simp only [Array.set!_eq_setIfInBounds, Array.toList_setIfInBounds, List.take_set] at hrow
    rcases List.mem_or_eq_of_mem_set hrow with hold | rfl
    · exact hvalid row hold
    · exact hn
  · rw [claimState_waiting s i receiver hi]
    exact hpend
  · change s.queued-burned = (((s.requests.set! i { r with claim := next }).toList.take s.unwind).map
      fun r => r.claim.shares-r.claim.burned).sum
    dsimp only [r,burned,paid]
    omega
  · change s.owed-paid = (((s.requests.set! i { r with claim := next }).toList.take s.unwind).map
      fun r => r.claim.owed-r.claim.claimed).sum
    dsimp only [r,burned,paid]
    omega
  · change s.queuedDebt = (((s.requests.set! i { r with claim := next }).toList.take s.unwind).map
      fun r => r.claim.debt-r.claim.repaid).sum
    rw [← hqd] at hdebts
    exact (Nat.add_right_cancel hdebts).symm
  · change s.pending+(s.queued-burned) ≤ wallet (setWallet s vaultId (wallet s vaultId-burned)) vaultId
    rw [wallet_setWallet s vaultId _ vaultId (by simp only [hw,vaultId,actors]; decide), if_pos rfl]
    dsimp only [r,burned,paid]
    omega
  · change (((s.requests.set! i { r with claim := next }).toList.take s.unwind).map
      fun r => r.claim.settled).sum ≤ s.assets-(if receiver == vaultId then 0 else paid)
    dsimp only [r,burned,paid]
    split <;> omega
  · change (((s.requests.set! i { r with claim := next }).toList.take s.unwind).map
      fun r => r.claim.settled).sum ≤ s.liquid-(if receiver == vaultId then 0 else paid)
    dsimp only [r,burned,paid]
    split <;> omega

theorem claimState_public (s : State) (i receiver : Nat)
    (h : PublicInvariant s) (hi : i < s.unwind)
    (hp : 0 < (request s i).claim.settled) : PublicInvariant (claimState s i receiver) := by
  have ho := h.2.2.2.2.2
  have hu : s.unwind ≤ s.requests.size := ho.2.2.2.2.2.1
  have hm := active_request_mem s i hi hu
  have hs := map_value_le_sum (fun r : Request => r.claim.settled) (activeRequests s) (request s i) hm
  have has : ((activeRequests s).map fun r => r.claim.settled).sum ≤ s.assets :=
    ho.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  have hliq : ((activeRequests s).map fun r => r.claim.settled).sum ≤ s.liquid :=
    ho.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2
  apply public_of_operational
  · change s.assets-(if receiver == vaultId then 0 else (request s i).claim.settled)+s.reserve =
      s.supplied+(s.liquid-(if receiver == vaultId then 0 else (request s i).claim.settled))
    have hc := h.1
    change s.assets+s.reserve=s.supplied+s.liquid at hc
    dsimp only at hs
    split <;> omega
  · exact h.2.1
  · exact h.2.2.1
  · change publicLiability (claimState s i receiver)-s.book.total*ray < ray
    rw [claimState_liability s i receiver hi ho.1]
    exact h.2.2.2.2.1
  · exact claimState_operational s i receiver ho hi hp

theorem rawRunCall_claim (s : State) (caller a b n : Nat) :
    rawRunCall s ⟨7,caller,a,b,n⟩ =
      if s.paused || s.sourcePaused then .error 1
      else if !(request s n).claim.active then .error 20
      else if (if caller == (request s n).owner then b else (request s n).owner) == zeroId then .error 3
      else if (request s n).claim.settled == 0 then .error 21
      else .ok (claimState s n (if caller == (request s n).owner then b else (request s n).owner),
        (request s n).claim.settled) := by
  rfl

theorem raw_claim_public (s : State) (caller a b n : Nat)
    (h : PublicInvariant s) (hn : n < s.unwind) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1)
      (rawRunCall s ⟨7,caller,a,b,n⟩) := by
  rw [rawRunCall_claim]
  split_ifs
  all_goals try trivial
  all_goals
    apply claimState_public s n _ h hn
    have hp : ¬((request s n).claim.settled == 0) = true := by assumption
    simp only [beq_iff_eq] at hp
    omega

end Juicer.PublicCalls

