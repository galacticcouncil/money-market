import JuicerLean.FixedPoint.PublicStateProofs

set_option maxRecDepth 4000
set_option maxHeartbeats 500000

namespace Juicer.PublicCalls
open Runtime


theorem sum_range_update (count i value : Nat) (f : Nat → Nat) (hi : i < count) :
    ((List.range count).map fun j => if i = j then value else f j).sum + f i =
      ((List.range count).map f).sum + value := by
  induction count with
  | zero => omega
  | succ n ih =>
    rw [List.sum_range_succ, List.sum_range_succ]
    by_cases he : i = n
    · subst i
      have hm : ((List.range n).map fun j => if n = j then value else f j) =
          (List.range n).map f := by
        apply List.map_congr_left
        intro j hj
        have hjn := List.mem_range.mp hj
        simp [show n ≠ j by omega]
      rw [hm]
      simp
      omega
    · have hlt : i < n := by omega
      have hh := ih hlt
      simp only [if_neg he]
      omega

theorem list_sum_set_balance (xs : List Nat) (i value : Nat) (hi : i < xs.length) :
    (xs.set i value).sum + xs[i]?.getD 0 = xs.sum + value := by
  induction xs generalizing i with
  | nil => simp at hi
  | cons x xs ih =>
    cases i with
    | zero => simp; omega
    | succ i =>
      have hh := ih i (by simpa using hi)
      simp only [List.set_cons_succ, List.sum_cons, List.getElem?_cons_succ]
      omega

theorem wallet_setWallet (s : State) (i value j : Nat) (hi : i < s.wallets.size) :
    wallet (setWallet s i value) j = if i = j then value else wallet s j := by
  by_cases hij : i = j
  · subst j
    simp [setWallet, wallet, Array.set!_eq_setIfInBounds, hi]
  · simp only [setWallet, wallet, Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds,
      if_neg hij]

theorem wallet_range_sum (s : State) :
    ((List.range s.wallets.size).map (wallet s)).sum = s.wallets.toList.sum := by
  have h := congrArg List.sum (list_range_values s.wallets.toList 0)
  simpa only [← Array.size_eq_length_toList, Array.getElem?_toList, wallet] using h

theorem waiting_weight (s : State) :
    ((List.range (s.requests.size - s.unwind)).map fun i =>
      (request s (s.unwind+i)).claim.shares).sum =
      ((waitingRequests s).map fun r => r.claim.shares).sum := by
  have h := congrArg (fun xs : List Request => (xs.map fun r => r.claim.shares).sum)
    (list_range_values (s.requests.toList.drop s.unwind) ({} : Request))
  simpa only [List.length_drop, ← Array.size_eq_length_toList, List.map_map,
    Function.comp_apply, List.getElem?_drop, Array.getElem?_toList, waitingRequests, request] using h

theorem lifecycle_partition_of_operational (s : State) (h : OperationalInvariant s) :
    lazyWeight (publicProjection s).ledger.accounts + (publicProjection s).funded +
      (publicProjection s).queued + (publicProjection s).parked = (publicProjection s).supply := by
  have hsize : s.wallets.size = actors := h.1
  have hsum : s.supply = s.wallets.toList.sum := h.2.2.2.2.2.2.1
  have hwaiting : s.pending = ((waitingRequests s).map fun r => r.claim.shares).sum :=
    h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  have hescrow : s.pending + s.queued ≤ wallet s vaultId :=
    h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  have hsum8 : ((List.range 8).map (wallet s)).sum = s.supply := by
    simpa [hsize, actors] using (wallet_range_sum s).trans hsum.symm
  have htail : ((List.range 8).map (wallet s)).sum =
      ((List.range 5).map (wallet s)).sum + wallet s 5 + wallet s 6 + wallet s 7 := by
    rw [List.sum_range_succ (wallet s) 7, List.sum_range_succ (wallet s) 6,
      List.sum_range_succ (wallet s) 5]
  change lazyWeight (publicLifecycle s (publicSlack s) (publicParked s)).ledger.accounts +
    wallet s fundId + s.queued + publicParked s = s.supply
  rw [lifecycle_weight, waiting_weight, ← hwaiting]
  simp only [publicParked, vaultId, fundId, zeroId] at hescrow ⊢
  omega

theorem public_of_operational (s : State)
    (hc : CollateralConserved s) (hs : (sourceProjection s).valid)
    (hm : (cashProjection s).valid) (he : publicSlack s < ray)
    (ho : OperationalInvariant s) : PublicInvariant s :=
  ⟨hc, hs, hm, ⟨ledger_valid s, lifecycle_partition_of_operational s ho⟩, he, ho⟩

theorem publicSlack_lt_iff (s : State) :
    publicSlack s < ray ↔ publicLiability s < s.book.total * ray + ray := by
  change publicLiability s - s.book.total * ray < ray ↔ _
  have hr : 0 < ray := by norm_num [ray]
  omega

theorem normalized_weight_monotone (book : Book) (a : Account) (before after : Nat)
    (h : after ≤ before) :
    (normalizeAccount book a after).numerator book.index ≤
      (normalizeAccount book a before).numerator book.index := by
  change (normalizeAccount book a 0).units * ray +
    after * (book.index - (normalizeAccount book a 0).index) ≤
      (normalizeAccount book a 0).units * ray +
        before * (book.index - (normalizeAccount book a 0).index)
  exact Nat.add_le_add_left (Nat.mul_le_mul_right _ h) _

theorem normalized_current_weight (book : Book) (a : Account) (before after : Nat)
    (h : (normalizeAccount book a before).index = book.index) :
    (normalizeAccount book a after).numerator book.index =
      (normalizeAccount book a before).numerator book.index := by
  change (normalizeAccount book a 0).index = book.index at h
  change (normalizeAccount book a 0).units * ray +
    after * (book.index - (normalizeAccount book a 0).index) =
      (normalizeAccount book a 0).units * ray +
        before * (book.index - (normalizeAccount book a 0).index)
  simp only [h, Nat.sub_self, Nat.mul_zero]

theorem wallet_sum_set_balance (s : State) (i value : Nat) (hi : i < s.wallets.size) :
    (setWallet s i value).wallets.toList.sum + wallet s i =
      s.wallets.toList.sum + value := by
  have h := list_sum_set_balance s.wallets.toList i value
    (by simpa only [← Array.size_eq_length_toList] using hi)
  simpa only [setWallet, wallet, Array.set!_eq_setIfInBounds,
    Array.toList_setIfInBounds, Array.getElem?_toList] using h

def moveWallets (s : State) (a b amount : Nat) : State :=
  setWallet (setWallet s a (wallet s a - amount)) b
    ((if a == b then wallet s b - amount else wallet s b) + amount)

theorem moveWallets_wallet (s : State) (a b amount j : Nat)
    (ha : a < s.wallets.size) (hb : b < s.wallets.size) :
    wallet (moveWallets s a b amount) j =
      if b = j then (if a == b then wallet s b - amount else wallet s b) + amount
      else if a = j then wallet s a - amount else wallet s j := by
  unfold moveWallets
  rw [wallet_setWallet _ b _ j (by
    simpa only [setWallet, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hb),
    wallet_setWallet s a _ j ha]

theorem moveWallets_sum (s : State) (a b amount : Nat)
    (ha : a < s.wallets.size) (hb : b < s.wallets.size) (hn : amount ≤ wallet s a) :
    (moveWallets s a b amount).wallets.toList.sum = s.wallets.toList.sum := by
  let first := setWallet s a (wallet s a - amount)
  have hfirst := wallet_sum_set_balance s a (wallet s a-amount) ha
  have hget : wallet first b = if a == b then wallet s b-amount else wallet s b := by
    dsimp only [first]
    rw [wallet_setWallet s a _ b ha]
    by_cases hab : a = b
    · simp only [hab, beq_self_eq_true, ite_true]
    · simp only [hab, beq_iff_eq, ite_false]
  have hsecond := wallet_sum_set_balance first b
    ((if a == b then wallet s b - amount else wallet s b) + amount)
    (by simpa only [first, setWallet, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using hb)
  change (moveWallets s a b amount).wallets.toList.sum + wallet first b =
    first.wallets.toList.sum + _ at hsecond
  rw [← hget] at hsecond
  change first.wallets.toList.sum + wallet s a = s.wallets.toList.sum + _ at hfirst
  omega

theorem moveWallets_escrow (s : State) (a b amount : Nat)
    (ha : a < 5) (hsize : s.wallets.size = actors) (hb : b < actors) :
    wallet s vaultId ≤ wallet (moveWallets s a b amount) vaultId := by
  rw [moveWallets_wallet s a b amount vaultId (by simpa [hsize, actors] using ha.trans (by decide : 5 < 8))
    (by simpa [hsize] using hb)]
  have hav : a ≠ vaultId := by simp only [vaultId]; omega
  by_cases hbv : b = vaultId
  · subst b
    simp [hav]
  · simp [hbv, hav]

theorem moveWallets_liability (s : State) (a b amount : Nat)
    (ha : a < s.wallets.size) (hb : b < s.wallets.size)
    (hcurrent : b < 5 → (normalizeAccount s.book (account s b) (wallet s b)).index = s.book.index) :
    publicLiability (moveWallets s a b amount) ≤ publicLiability s := by
  rw [publicLiability_parts, publicLiability_parts]
  change
    ((List.range 5).map fun j =>
      (normalizeAccount s.book (account s j) (wallet (moveWallets s a b amount) j)).numerator s.book.index).sum +
      ((List.range (s.requests.size-s.unwind)).map fun j =>
        (normalizeAccount s.book (request s (s.unwind+j)).account
          (request s (s.unwind+j)).claim.shares).numerator s.book.index).sum ≤ _
  apply Nat.add_le_add_right
  apply List.sum_le_sum
  intro j hj
  rw [moveWallets_wallet s a b amount j ha hb]
  by_cases hbj : b = j
  · simp only [if_pos hbj]
    subst j
    exact (normalized_current_weight s.book (account s b) _ _
      (hcurrent (List.mem_range.mp hj))).le
  · simp only [if_neg hbj]
    by_cases haj : a = j
    · simp only [if_pos haj]
      subst j
      exact normalized_weight_monotone s.book (account s a) _ _ (Nat.sub_le _ _)
    · simp only [if_neg haj]
      exact le_rfl

theorem moveWallets_operational (s : State) (a b amount : Nat)
    (ho : OperationalInvariant s) (ha : a < 5) (hb : b < actors)
    (hn : amount ≤ wallet s a) : OperationalInvariant (moveWallets s a b amount) := by
  have hsize : s.wallets.size = actors := ho.1
  have haa : a < s.wallets.size := by simp only [hsize, actors]; omega
  have hbb : b < s.wallets.size := by simpa only [hsize] using hb
  rcases ho with ⟨hw, hac, hc, hap, hpos, hu, hsum, hmain, hout, hfs, hfr,
    hfees, hcash, hvalid, hpend, hqueued, howed, hqd, hescrow, hassets, hliquid⟩
  refine ⟨?_, hac, hc, hap, hpos, hu, ?_, hmain, hout, hfs, hfr, hfees,
    hcash, hvalid, hpend, hqueued, howed, hqd, ?_, hassets, hliquid⟩
  · simpa only [moveWallets, setWallet, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using hw
  · rw [moveWallets_sum s a b amount haa hbb hn]
    exact hsum
  · exact hescrow.trans (moveWallets_escrow s a b amount ha hsize hb)

theorem moveWallets_public (s : State) (a b amount : Nat)
    (h : PublicInvariant s) (ha : a < 5) (hb : b < actors)
    (hn : amount ≤ wallet s a)
    (hcurrent : b < 5 → (normalizeAccount s.book (account s b) (wallet s b)).index = s.book.index) :
    PublicInvariant (moveWallets s a b amount) := by
  have hsize : s.wallets.size = actors := h.2.2.2.2.2.1
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · apply (publicSlack_lt_iff _).2
    have hbefore := (publicSlack_lt_iff s).1 h.2.2.2.2.1
    have hliab := moveWallets_liability s a b amount
      (by simp only [hsize, actors]; omega)
      (by simpa only [hsize] using hb) hcurrent
    exact hliab.trans_lt hbefore
  · exact moveWallets_operational s a b amount h.2.2.2.2.2 ha hb hn

def CurrentAccount (s : State) (i : Nat) : Prop :=
  (account s i).index = s.book.index ∧ (account s i).epoch = s.book.epoch ∧
    (account s i).scale = s.book.scale

theorem account_setAccount (s : State) (i j : Nat) (value : Account)
    (hi : i < s.accounts.size) :
    account (setAccount s i value) j = if i = j then value else account s j := by
  by_cases hij : i = j
  · subst j
    simp [setAccount, account, Array.set!_eq_setIfInBounds, hi]
  · simp only [setAccount, account, Array.set!_eq_setIfInBounds,
      Array.getElem?_setIfInBounds, if_neg hij]

theorem account_setAccount_all (s : State) (i j : Nat) (value : Account) :
    account (setAccount s i value) j =
      if i = j ∧ i < s.accounts.size then value else account s j := by
  by_cases hi : i < s.accounts.size
  · rw [account_setAccount s i j value hi]
    simp [hi]
  · simp [setAccount, Array.set!, Array.setIfInBounds, hi, account]

theorem current_numerator (book : Book) (a : Account) (weight : Nat)
    (hi : a.index = book.index) (he : a.epoch = book.epoch) (hs : a.scale = book.scale) :
    (normalizeAccount book a weight).numerator book.index = a.units * ray := by
  simp [normalizeAccount, hi, he, hs, LazyAccount.numerator]

theorem settleOwner_current (s : State) (i : Nat) (hi : i < 5)
    (hsize : i < s.accounts.size) : CurrentAccount (settleOwner s i) i := by
  have hspecial : special i = false := by
    simp [special, vaultId, fundId, zeroId, show i ≠ 5 by omega,
      show i ≠ 6 by omega, show i ≠ 7 by omega]
  simp only [settleOwner, hspecial, Bool.false_eq_true, ite_false]
  change (account (setAccount s i _) i).index = _ ∧
    (account (setAccount s i _) i).epoch = _ ∧ (account (setAccount s i _) i).scale = _
  rw [account_setAccount s i i _ hsize]
  simp [settle, setAccount]

theorem settleOwner_preserves_current (s : State) (i j : Nat) (h : CurrentAccount s i) :
    CurrentAccount (settleOwner s j) i := by
  unfold settleOwner
  split
  · exact h
  · change (account (setAccount s j _) i).index = s.book.index ∧
      (account (setAccount s j _) i).epoch = s.book.epoch ∧
      (account (setAccount s j _) i).scale = s.book.scale
    simp only [account_setAccount_all]
    by_cases hji : j = i ∧ j < s.accounts.size
    · simp only [if_pos hji]
      simp [settle]
    · simp only [if_neg hji]
      exact h

theorem setAccount_liability_balance (s : State) (i : Nat) (value : Account)
    (hi : i < 5) (hsize : i < s.accounts.size) :
    publicLiability (setAccount s i value) +
      (normalizeAccount s.book (account s i) (wallet s i)).numerator s.book.index =
      publicLiability s +
        (normalizeAccount s.book value (wallet s i)).numerator s.book.index := by
  let before := fun j => (normalizeAccount s.book (account s j) (wallet s j)).numerator s.book.index
  let updated := (normalizeAccount s.book value (wallet s i)).numerator s.book.index
  have hm : ((List.range 5).map fun j =>
      (normalizeAccount s.book (account (setAccount s i value) j) (wallet s j)).numerator s.book.index) =
      (List.range 5).map fun j => if i = j then updated else before j := by
    apply List.map_congr_left
    intro j _
    rw [account_setAccount s i j value hsize]
    by_cases hij : i = j
    · subst j
      simp [before, updated]
    · simp [hij, before]
  have hsum := sum_range_update 5 i updated before hi
  rw [publicLiability_parts, publicLiability_parts]
  change
    ((List.range 5).map fun j =>
      (normalizeAccount s.book (account (setAccount s i value) j) (wallet s j)).numerator s.book.index).sum +
      ((List.range (s.requests.size-s.unwind)).map fun j =>
        (normalizeAccount s.book (request s (s.unwind+j)).account
          (request s (s.unwind+j)).claim.shares).numerator s.book.index).sum + before i =
      ((List.range 5).map before).sum +
      ((List.range (s.requests.size-s.unwind)).map fun j =>
        (normalizeAccount s.book (request s (s.unwind+j)).account
          (request s (s.unwind+j)).claim.shares).numerator s.book.index).sum + updated
  rw [hm]
  omega

def moveUnits (s : State) (a b taken left : Nat) : State :=
  let next := setAccount s a { account s a with units := left }
  setAccount next b { account next b with units := (account next b).units + taken }

set_option maxRecDepth 20000 in
theorem moveUnits_liability (s : State) (a b taken left : Nat)
    (ha : a < 5) (hb : b < 5) (has : a < s.accounts.size) (hbs : b < s.accounts.size)
    (hab : a ≠ b) (hca : CurrentAccount s a) (hcb : CurrentAccount s b)
    (hunits : taken + left = (account s a).units) :
    publicLiability (moveUnits s a b taken left) = publicLiability s := by
  let first := setAccount s a { account s a with units := left }
  have hget : account first b = account s b := by
    dsimp only [first]
    rw [account_setAccount s a b _ has, if_neg hab]
  have hcurrent : CurrentAccount first b := by
    unfold CurrentAccount
    rw [hget]
    exact hcb
  have hfirst := setAccount_liability_balance s a { account s a with units := left } ha has
  have hsecond := setAccount_liability_balance first b
    { account first b with units := (account first b).units + taken } hb
    (by simpa only [first, setAccount, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using hbs)
  rw [current_numerator s.book (account s a) (wallet s a) hca.1 hca.2.1 hca.2.2,
    current_numerator s.book { account s a with units := left } (wallet s a)
      hca.1 hca.2.1 hca.2.2] at hfirst
  rw [current_numerator first.book (account first b) (wallet first b)
      hcurrent.1 hcurrent.2.1 hcurrent.2.2,
    current_numerator first.book
      { account first b with units := (account first b).units + taken } (wallet first b)
      hcurrent.1 hcurrent.2.1 hcurrent.2.2] at hsecond
  change publicLiability first + (account s a).units * ray =
    publicLiability s + left * ray at hfirst
  change publicLiability (moveUnits s a b taken left) + (account first b).units * ray =
    publicLiability first + ((account first b).units + taken) * ray at hsecond
  rw [congrArg Account.units hget] at hsecond
  have hu := congrArg (fun n => n*ray) hunits
  simp only [Nat.add_mul] at hsecond hu
  omega

theorem moveUnits_operational (s : State) (a b taken left : Nat)
    (h : OperationalInvariant s) : OperationalInvariant (moveUnits s a b taken left) := by
  simpa only [moveUnits, setAccount, OperationalInvariant, Array.set!_eq_setIfInBounds,
    Array.size_setIfInBounds] using h

theorem moveUnits_public (s : State) (a b taken left : Nat)
    (h : PublicInvariant s) (ha : a < 5) (hb : b < 5) (hab : a ≠ b)
    (hca : CurrentAccount s a) (hcb : CurrentAccount s b)
    (hunits : taken + left = (account s a).units) :
    PublicInvariant (moveUnits s a b taken left) := by
  have hsize : s.accounts.size = actors := h.2.2.2.2.2.2.1
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · change publicLiability (moveUnits s a b taken left) - s.book.total * ray < ray
    rw [moveUnits_liability s a b taken left ha hb
      (by simp only [hsize, actors]; omega)
      (by simp only [hsize, actors]; omega) hab hca hcb hunits]
    exact h.2.2.2.2.1
  · exact moveUnits_operational s a b taken left h.2.2.2.2.2

theorem setUnits_current (s : State) (j units i : Nat) (h : CurrentAccount s i) :
    CurrentAccount (setAccount s j { account s j with units }) i := by
  change (account (setAccount s j _) i).index = s.book.index ∧
    (account (setAccount s j _) i).epoch = s.book.epoch ∧
    (account (setAccount s j _) i).scale = s.book.scale
  simp only [account_setAccount_all]
  by_cases hji : j = i ∧ j < s.accounts.size
  · rw [if_pos hji]
    rcases hji with ⟨rfl, _⟩
    exact h
  · simp only [if_neg hji]
    exact h

theorem moveUnits_current (s : State) (a b taken left i : Nat) (h : CurrentAccount s i) :
    CurrentAccount (moveUnits s a b taken left) i :=
  setUnits_current _ b _ i (setUnits_current s a left i h)

def prepareTransfer (s : State) (a b n : Nat) : Except Nat (State × Nat) := do
  let mut s := s
  let mut moved := n
  if a != vaultId && b != vaultId && a != fundId then
    s := settleOwner (settleOwner s a) b
    let excess := n - wallet s a
    if excess != 0 then
      if b == fundId || b == zeroId then throw 10
      let owned := (account s a).units
      if excess > fundedOf (wallet s fundId) s.book.total owned then throw 11
      if a != b then
        match take (wallet s fundId) s.book.total owned excess with
        | none => throw 12
        | some (taken, left) => s := moveUnits s a b taken left
      moved := wallet s a
  return (s, moved)

def finishTransfer (s : State) (a b n : Nat) : Except Nat State := do
  if b == zeroId then throw 13
  if s.paused then throw 14
  if wallet s a < n then throw 15
  return moveWallets s a b n

theorem finishTransfer_public (s : State) (a b n : Nat)
    (h : PublicInvariant s) (ha : a < 5) (hb : b < actors)
    (hcurrent : b < 5 → (normalizeAccount s.book (account s b) (wallet s b)).index = s.book.index) :
    OnSuccess PublicInvariant (finishTransfer s a b n) := by
  unfold finishTransfer
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs with hz hp hn
  all_goals try trivial
  exact moveWallets_public s a b n h ha hb (by omega) hcurrent

theorem current_normalized (s : State) (i : Nat) (h : CurrentAccount s i) :
    (normalizeAccount s.book (account s i) (wallet s i)).index = s.book.index := by
  simp [normalizeAccount, h.1, h.2.1, h.2.2]

theorem prepareTransfer_eq (s : State) (a b n : Nat) :
    prepareTransfer s a b n =
      if a != vaultId && b != vaultId && a != fundId then
        let t := settleOwner (settleOwner s a) b
        let excess := n - wallet t a
        if excess != 0 then
          if b == fundId || b == zeroId then .error 10
          else if excess > fundedOf (wallet t fundId) t.book.total (account t a).units then .error 11
          else if a != b then
            match take (wallet t fundId) t.book.total (account t a).units excess with
            | none => .error 12
            | some (taken,left) => .ok (moveUnits t a b taken left, wallet t a)
          else .ok (t, wallet t a)
        else .ok (t,n)
      else .ok (s,n) := by
  unfold prepareTransfer
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs
  all_goals try rfl

theorem prepareTransfer_public (s : State) (a b n : Nat)
    (h : PublicInvariant s) (ha : a < 5) (hb : b < actors) :
    OnSuccess (fun next : State × Nat => PublicInvariant next.1 ∧
      (b < 5 → CurrentAccount next.1 b)) (prepareTransfer s a b n) := by
  rw [prepareTransfer_eq]
  split
  next hnormal =>
    dsimp only
    let t := settleOwner (settleOwner s a) b
    have ht : PublicInvariant t := settleOwner_public _ b (settleOwner_public s a h)
    have hsize : s.accounts.size = actors := h.2.2.2.2.2.2.1
    have hats : a < s.accounts.size := by simp only [hsize, actors]; omega
    have has : CurrentAccount t a :=
      settleOwner_preserves_current _ a b (settleOwner_current s a ha hats)
    have hbs : b < 5 → CurrentAccount t b := by
      intro hb5
      apply settleOwner_current _ b hb5
      have hs' : (settleOwner s a).accounts.size = actors :=
        (settleOwner_public s a h).2.2.2.2.2.2.1
      simpa only [hs'] using hb
    split
    next hexcess =>
      split
      · trivial
      next hbad =>
        split
        · trivial
        next hfunded =>
          split
          next hab =>
            split
            · trivial
            next taken left htake =>
              have hb5 : b < 5 := by
                simp only [Bool.or_eq_true, beq_iff_eq, vaultId, fundId, zeroId] at hnormal hbad
                simp only [Bool.and_eq_true, bne_iff_ne] at hnormal
                simp only [actors] at hb
                omega
              have hab' : a ≠ b := by simpa only [bne_iff_ne] using hab
              have hcon := take_conserves (wallet t fundId) t.book.total
                (account t a).units (n-wallet t a) taken left htake
              exact ⟨moveUnits_public t a b taken left ht ha hb5 hab' has (hbs hb5) hcon,
                fun _ => moveUnits_current t a b taken left b (hbs hb5)⟩
          · exact ⟨ht,hbs⟩
    · exact ⟨ht,hbs⟩
  next hnormal =>
    refine ⟨h, ?_⟩
    intro hb5
    have hn : (a != vaultId && b != vaultId && a != fundId) = true := by
      simp only [Bool.and_eq_true, bne_iff_ne, vaultId, fundId]
      omega
    exact (hnormal hn).elim


theorem exceptBind_ite {ε α β : Type} (p : Prop) [Decidable p]
    (x y : Except ε α) (f : α → Except ε β) :
    Except.bind (if p then x else y) f =
      if p then Except.bind x f else Except.bind y f := by
  split <;> rfl

theorem exceptBind_ok {ε α β : Type} (a : α) (f : α → Except ε β) :
    Except.bind (.ok a) f = f a := rfl

theorem exceptBind_error {ε α β : Type} (e : ε) (f : α → Except ε β) :
    Except.bind (.error e) f = .error e := rfl

theorem transfer_decomposition (s : State) (a b n : Nat) :
    transfer s a b n = (do
      let (next, moved) ← prepareTransfer s a b n
      finishTransfer next a b moved) := by
  let t := settleOwner (settleOwner s a) b
  rcases ht : take (wallet t fundId) t.book.total (account t a).units (n-wallet t a) with
    _ | ⟨taken,left⟩
  all_goals
    dsimp only [t] at ht
    unfold transfer
    rw [prepareTransfer_eq]
    unfold finishTransfer
    simp only [bind, pure, Except.pure, throw, throwThe, MonadExceptOf.throw, ht,
      exceptBind_ite, exceptBind_ok, exceptBind_error]
    rfl


theorem transfer_public (s : State) (a b n : Nat)
    (h : PublicInvariant s) (ha : a < 5) (hb : b < actors) :
    OnSuccess PublicInvariant (transfer s a b n) := by
  rw [transfer_decomposition, onSuccess_bind]
  rintro ⟨next,moved⟩ heq
  have hp := onSuccess_of_eq (prepareTransfer_public s a b n h ha hb) heq
  exact finishTransfer_public next a b moved hp.1 ha hb
    (fun hb5 => current_normalized next b (hp.2 hb5))

theorem spend_public (s : State) (owner caller amount : Nat) (h : PublicInvariant s) :
    OnSuccess PublicInvariant (spend s owner caller amount) := by
  unfold spend
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs
  all_goals try exact h
  all_goals try trivial
  simpa only [OnSuccess, PublicInvariant, OperationalInvariant, Array.set!_eq_setIfInBounds,
    Array.size_setIfInBounds] using h

theorem approvals_public (s : State) (i amount : Nat) (h : PublicInvariant s) :
    PublicInvariant { s with approvals := s.approvals.set! i amount } := by
  simpa only [PublicInvariant, OperationalInvariant, Array.set!_eq_setIfInBounds,
    Array.size_setIfInBounds] using h

end Juicer.PublicCalls

