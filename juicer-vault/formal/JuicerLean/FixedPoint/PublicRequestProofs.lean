import JuicerLean.FixedPoint.PublicRequestPreparation

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem onSuccess_if {ε α : Type} (p : α → Prop) (c : Prop) [Decidable c]
    (x y : Except ε α) (hx : OnSuccess p x) (hy : OnSuccess p y) :
    OnSuccess p (if c then x else y) := by
  split <;> assumption

def commitTaken (s : State) (owner escrow taken left : Nat) : State :=
  appendRequest (setAccount s owner { account s owner with units := left }) owner escrow taken

theorem commitTaken_public (s : State) (owner escrow taken left : Nat)
    (h : PublicInvariant s) (ho : owner < 5) (hc : CurrentAccount s owner)
    (he : s.pending+s.queued+escrow ≤ wallet s vaultId)
    (hsum : left+taken = (account s owner).units) : PublicInvariant (commitTaken s owner escrow taken left) := by
  apply appendRequest_public
  · exact setRequestUnits_public s owner left taken h ho hc hsum
  · exact he
  · have ha : owner < s.accounts.size := by
      have hh : s.accounts.size = actors := h.2.2.2.2.2.2.1
      rw [hh]
      exact ho.trans (by decide : 5 < actors)
    rw [setRequestUnits_liability s owner left taken ho ha hc hsum]
    exact (publicSlack_lt_iff s).1 h.2.2.2.2.1

def requestOutcome (s : State) (owner escrow : Nat) (value : Option (Nat × Nat)) : Except Nat State :=
  match value with
  | none => .error 12
  | some (taken,left) => .ok (commitTaken s owner escrow taken left)

theorem requestOutcome_public (s : State) (owner escrow : Nat) (value : Option (Nat × Nat))
    (h : PublicInvariant s) (ho : owner < 5) (hc : CurrentAccount s owner)
    (he : s.pending+s.queued+escrow ≤ wallet s vaultId)
    (hv : ∀ taken left, value = some (taken,left) → left+taken = (account s owner).units) :
    OnSuccess PublicInvariant (requestOutcome s owner escrow value) := by
  cases value with
  | none => trivial
  | some pair =>
    rcases pair with ⟨taken,left⟩
    exact commitTaken_public s owner escrow taken left h ho hc he (hv taken left rfl)

def commitRequest (s : State) (owner escrow amount : Nat) : Except Nat State :=
  if escrow < amount then
    if fundedOf (wallet s fundId) s.book.total (account s owner).units < amount-escrow then .error 11
    else requestOutcome s owner escrow
      (take (wallet s fundId) s.book.total (account s owner).units (amount-escrow))
  else .ok (appendRequest s owner escrow 0)

theorem commitRequest_property (p : State → Prop) (s : State) (owner escrow amount : Nat)
    (ht : OnSuccess p (requestOutcome s owner escrow
      (take (wallet s fundId) s.book.total (account s owner).units (amount-escrow))))
    (ha : p (appendRequest s owner escrow 0)) :
    OnSuccess p (commitRequest s owner escrow amount) :=
  onSuccess_if p (escrow < amount) _ _
    (onSuccess_if p (fundedOf (wallet s fundId) s.book.total (account s owner).units < amount-escrow)
      _ _ trivial ht) ha

theorem requestOutcome_take_public (s : State) (owner escrow amount : Nat) (h : PublicInvariant s)
    (ho : owner < 5) (hc : CurrentAccount s owner)
    (he : s.pending+s.queued+escrow ≤ wallet s vaultId) :
    OnSuccess PublicInvariant (requestOutcome s owner escrow
      (take (wallet s fundId) s.book.total (account s owner).units (amount-escrow))) :=
  requestOutcome_public s owner escrow
    (take (wallet s fundId) s.book.total (account s owner).units (amount-escrow)) h ho hc he
    (fun taken left htake => (Nat.add_comm left taken).trans (take_conserves _ _ _ _ _ _ htake))

theorem zero_commit_bound (value bound : Nat) (h : value < bound) : value+0*ray < bound := by
  simpa only [Nat.zero_mul,Nat.add_zero] using h

theorem appendUnfunded_public (s : State) (owner escrow : Nat) (h : PublicInvariant s)
    (he : s.pending+s.queued+escrow ≤ wallet s vaultId) :
    PublicInvariant (appendRequest s owner escrow 0) :=
  appendRequest_public s owner escrow 0 h he
    (zero_commit_bound _ _ ((publicSlack_lt_iff s).1 h.2.2.2.2.1))

theorem commitRequest_public (s : State) (owner escrow amount : Nat) (h : PublicInvariant s)
    (ho : owner < 5) (hc : CurrentAccount s owner)
    (he : s.pending+s.queued+escrow ≤ wallet s vaultId) :
    OnSuccess PublicInvariant (commitRequest s owner escrow amount) :=
  commitRequest_property PublicInvariant s owner escrow amount
    (requestOutcome_take_public s owner escrow amount h ho hc he)
    (appendUnfunded_public s owner escrow h he)

theorem checkpoint_current_first (s : State) (a b : Nat)
    (ha : a < 5) (hs : s.accounts.size = actors) :
    CurrentAccount (checkpoint s a b) a := by
  rw [checkpoint_factored]
  dsimp only
  have hsize : (if !pendingAccounting s then allocateState s else s).accounts.size = actors := by
    split <;> exact hs
  have hc := settleOwner_current (if !pendingAccounting s then allocateState s else s) a ha
    (by rw [hsize]; exact ha.trans (by decide : 5 < actors))
  split
  · exact hc
  · exact settleOwner_preserves_current _ a b hc

theorem spend_request_public (s : State) (owner caller amount : Nat)
    (h : PublicInvariant s) (hc : CurrentAccount s owner) :
    OnSuccess (fun next => PublicInvariant next ∧ CurrentAccount next owner)
      (spend s owner caller amount) := by
  unfold spend
  simp only [bind,pure,Except.bind,Except.pure]
  split_ifs
  all_goals try exact ⟨h,hc⟩
  all_goals try trivial
  exact ⟨approvals_public s _ _ h,hc⟩

theorem transfer_to_vault (s : State) (owner amount : Nat) :
    transfer s owner vaultId amount = finishTransfer s owner vaultId amount := by
  unfold transfer finishTransfer
  simp only [bne_self_eq_false,Bool.and_false,Bool.false_and,Bool.false_eq_true,ite_false]
  rfl

theorem transfer_to_vault_request (s : State) (owner amount : Nat)
    (h : PublicInvariant s) (ho : owner < 5) (hc : CurrentAccount s owner) :
    OnSuccess (fun next => PublicInvariant next ∧ CurrentAccount next owner ∧
      next.pending+next.queued+amount ≤ wallet next vaultId)
      (transfer s owner vaultId amount) := by
  rw [transfer_to_vault]
  unfold finishTransfer
  simp only [bind,pure,Except.bind,Except.pure]
  split_ifs with hz hp hn
  all_goals try trivial
  have hw : s.wallets.size = actors := h.2.2.2.2.2.1
  have hv : s.pending+s.queued ≤ wallet s vaultId := by
    rcases h.2.2.2.2.2 with ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,hv,_,_⟩
    exact hv
  refine ⟨moveWallets_public s owner vaultId amount h ho (by decide) (by omega)
    (by intro hn; exact (Nat.lt_irrefl 5 hn).elim),hc,?_⟩
  change s.pending+s.queued+amount ≤ wallet (moveWallets s owner vaultId amount) vaultId
  rw [moveWallets_wallet s owner vaultId amount vaultId
    (by rw [hw]; exact ho.trans (by decide : 5 < actors)) (by rw [hw]; decide)]
  have hov : (owner == vaultId) = false := by simp only [beq_eq_false_iff_ne,vaultId]; omega
  simpa only [if_pos rfl,hov,Bool.false_eq_true,ite_false] using Nat.add_le_add_right hv amount

def requestTail (input : State) (owner escrow amount : Nat) : Result := do
  let mut s := input
  let mut owned := (account s owner).units
  let mut committed := 0
  if escrow < amount then
    if fundedOf (wallet s fundId) s.book.total owned < amount-escrow then throw 11
    match take (wallet s fundId) s.book.total owned (amount-escrow) with
    | none => throw 12
    | some (taken,left) => committed := taken; owned := left
    s := setAccount s owner { account s owner with units := owned }
  let r : Request := {
    owner,eligible := s.time+10,claim := ⟨escrow,0,0,0,0,0,0,true⟩,
    account := ⟨committed,s.book.index,s.book.epoch,s.book.scale⟩ }
  return ({ s with requests := s.requests.push r,pending := s.pending+escrow },s.requests.size)

theorem requestTail_factored (s : State) (owner escrow amount : Nat) :
    requestTail s owner escrow amount = (do
      let next ← commitRequest s owner escrow amount
      pure (next,s.requests.size)) := by
  unfold requestTail commitRequest requestOutcome commitTaken appendRequest
  simp only [bind,pure,Except.bind,Except.pure]
  split_ifs
  all_goals try rfl
  all_goals
    split
    · rfl
    · rfl

theorem requestTail_public (s : State) (owner escrow amount : Nat) (h : PublicInvariant s)
    (ho : owner < 5) (hc : CurrentAccount s owner)
    (he : s.pending+s.queued+escrow ≤ wallet s vaultId) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1)
      (requestTail s owner escrow amount) := by
  rw [requestTail_factored,onSuccess_bind]
  intro next heq
  change PublicInvariant next
  exact onSuccess_of_eq (commitRequest_public s owner escrow amount h ho hc he) heq

theorem raw_request_factored (s : State) (caller owner receiver amount : Nat) :
    rawRunCall s ⟨4,caller,owner,receiver,amount⟩ =
      (if s.paused || s.sourcePaused then .error 1
      else
        let checkpointed := checkpoint s owner zeroId
        if amount == max256 && caller != owner then .error 9
        else
          let n := if amount == max256 then balance checkpointed owner else amount
          if n == 0 || toAssets checkpointed n == 0 then .error 2
          else do
            let paid ← spend checkpointed owner caller n
            let escrow := min n (wallet paid owner)
            let moved ← transfer paid owner vaultId escrow
            requestTail moved owner escrow n) := by
  rfl

theorem raw_request_public (s : State) (caller owner receiver amount : Nat)
    (h : PublicInvariant s) (hm : PublicMetadata s) (ho : owner < 5) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1)
      (rawRunCall s ⟨4,caller,owner,receiver,amount⟩) := by
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
        have hp := onSuccess_of_eq (spend_request_public _ owner caller _
          (checkpoint_public s owner zeroId h hm)
          (checkpoint_current_first s owner zeroId ho h.2.2.2.2.2.2.1)) hpaid
        rw [onSuccess_bind]
        intro moved hmoved
        have ht := onSuccess_of_eq (transfer_to_vault_request paid owner _ hp.1 ho hp.2) hmoved
        exact requestTail_public moved owner _ _ ht.1 ho ht.2.1 ht.2.2

end Juicer.PublicCalls
