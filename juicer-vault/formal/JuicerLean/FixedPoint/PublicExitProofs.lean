import JuicerLean.FixedPoint.PublicCreditEntryProofs

set_option maxRecDepth 12000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def advanceWaiting (s : State) : State := { s with unwind := s.unwind+1 }

theorem waiting_head (s : State) (hi : s.unwind < s.requests.size) :
    waitingRequests s = request s s.unwind :: s.requests.toList.drop (s.unwind+1) := by
  unfold waitingRequests
  rw [List.drop_eq_getElem_cons (show s.unwind < s.requests.toList.length by simpa using hi)]
  congr 1
  simp only [Array.getElem_toList,request,Array.getElem?_eq_getElem hi,Option.getD_some]

theorem advanceWaiting_liability (s : State) (hi : s.unwind < s.requests.size) :
    publicLiability (advanceWaiting s)+requestLiability s (request s s.unwind) = publicLiability s := by
  have he := List.drop_eq_getElem_cons (show s.unwind < s.requests.toList.length by simpa using hi)
  have hg := List.getElem?_eq_getElem (show s.unwind < s.requests.toList.length by simpa using hi)
  simp only [Array.getElem?_toList] at hg
  have hr : s.requests.toList[s.unwind] = request s s.unwind := by
    simp only [Array.getElem_toList,request,hg,Option.getD_some]
  rw [publicLiability_list,publicLiability_list]
  change holderLiability s+((s.requests.toList.drop (s.unwind+1)).map (requestLiability s)).sum+
    requestLiability s (request s s.unwind) =
    holderLiability s+((s.requests.toList.drop s.unwind).map (requestLiability s)).sum
  rw [he,hr,List.map_cons,List.sum_cons]
  omega

theorem bookTotals_liability (s : State) (total source protocol : Nat) :
    publicLiability { s with book := { s.book with total,source,protocol } } = publicLiability s := by
  rw [publicLiability_parts,publicLiability_parts]
  rfl

theorem bookAllocationMetadata_liability (s : State) (book : Book)
    (hi : book.index = s.book.index) (he : book.epoch = s.book.epoch)
    (hs : book.scale = s.book.scale) :
    publicLiability { s with book := book } = publicLiability s := by
  have hn (a : Account) (weight : Nat) :
      normalizeAccount book a weight = normalizeAccount s.book a weight := by
    simp only [normalizeAccount,hi,he,hs]
  rw [publicLiability_parts,publicLiability_parts]
  simp only [account,wallet,request]
  simp_rw [hn]
  rw [hi]

theorem startExit_liability_consumed (book : Book) (owner request : Account) (wallet shares funded : Nat) :
    (startExit book owner request wallet shares funded).owned*ray+
      (startExit book owner request wallet shares funded).burned*ray ≤
    (normalizeAccount book owner wallet).numerator book.index+
      (normalizeAccount book request shares).numerator book.index := by
  rw [normalized_exit_owner,normalized_exit_burn]
  have h := exit_liability_consumed book.total book.index
    (normalizeAccount book owner wallet) (normalizeAccount book request shares)
  simpa only [exitOwner,LazyAccount.numerator,Nat.sub_self,Nat.mul_zero,Nat.add_zero] using h

def waitingExit (s : State) : ExitResult :=
  let r := request s s.unwind
  startExit s.book (account s r.owner) r.account (wallet s r.owner) r.claim.shares (wallet s fundId)

def commitExitAccount (s : State) : State :=
  let r := request s s.unwind
  let out := waitingExit s
  let next := setAccount s r.owner ⟨out.owned,s.book.index,s.book.epoch,s.book.scale⟩
  { next with book := out.book }

def commitExitOwnership (s : State) : State := advanceWaiting (commitExitAccount s)

theorem commitExitOwnership_liability (s : State) (hi : s.unwind < s.requests.size)
    (ho : (request s s.unwind).owner < 5) (ha : (request s s.unwind).owner < s.accounts.size) :
    publicLiability (commitExitOwnership s)+(waitingExit s).burned*ray ≤ publicLiability s := by
  let r := request s s.unwind
  let out := waitingExit s
  let next := setAccount s r.owner ⟨out.owned,s.book.index,s.book.epoch,s.book.scale⟩
  have hset := setAccount_liability_balance s r.owner
    ⟨out.owned,s.book.index,s.book.epoch,s.book.scale⟩ ho ha
  have hcurrent := current_numerator s.book
    ⟨out.owned,s.book.index,s.book.epoch,s.book.scale⟩ (wallet s r.owner) rfl rfl rfl
  rw [hcurrent] at hset
  have hadv := advanceWaiting_liability next hi
  have hexit := startExit_liability_consumed s.book (account s r.owner) r.account
    (wallet s r.owner) r.claim.shares (wallet s fundId)
  change out.owned*ray+out.burned*ray ≤
    (normalizeAccount s.book (account s r.owner) (wallet s r.owner)).numerator s.book.index+
      requestLiability s r at hexit
  change publicLiability (advanceWaiting next)+requestLiability s r = publicLiability next at hadv
  change publicLiability next+
    (normalizeAccount s.book (account s r.owner) (wallet s r.owner)).numerator s.book.index =
    publicLiability s+out.owned*ray at hset
  have hbook : publicLiability (commitExitOwnership s) = publicLiability (advanceWaiting next) := by
    change publicLiability { advanceWaiting next with book := out.book } =
      publicLiability (advanceWaiting next)
    apply bookAllocationMetadata_liability
    · simp only [out,waitingExit,startExit_index,advanceWaiting,next,setAccount]
    · simp only [out,waitingExit,startExit_epoch,advanceWaiting,next,setAccount]
    · simp only [out,waitingExit,startExit_scale,advanceWaiting,next,setAccount]
  rw [hbook]
  change publicLiability (advanceWaiting next)+out.burned*ray ≤ publicLiability s
  omega

theorem consumed_slack_bound (before after total next burned : Nat)
    (hbefore : before < total*ray+ray) (hconsumed : after+burned*ray ≤ before)
    (htotal : next+burned = total) : after < next*ray+ray := by
  have he := congrArg (fun n => n*ray) htotal
  simp only [Nat.add_mul] at he
  omega

theorem commitExitOwnership_slack (s : State) (h : publicSlack s < ray)
    (hi : s.unwind < s.requests.size) (ho : (request s s.unwind).owner < 5)
    (ha : (request s s.unwind).owner < s.accounts.size) : publicSlack (commitExitOwnership s) < ray := by
  apply (publicSlack_lt_iff _).2
  exact consumed_slack_bound _ _ _ _ _ ((publicSlack_lt_iff s).1 h)
    (commitExitOwnership_liability s hi ho ha)
    (startExit_units_conserved s.book (account s (request s s.unwind).owner)
      (request s s.unwind).account (wallet s (request s s.unwind).owner)
      (request s s.unwind).claim.shares (wallet s fundId))

def foldExitWallets (s : State) (folded : Nat) : State := moveWallets s fundId vaultId folded

theorem foldExitWallets_liability (s : State) (folded : Nat) (hw : s.wallets.size = actors) :
    publicLiability (foldExitWallets s folded) ≤ publicLiability s := by
  apply moveWallets_liability s fundId vaultId folded
  · simp only [hw,actors,fundId]; omega
  · simp only [hw,actors,vaultId]; omega
  · intro hbad
    simp only [vaultId] at hbad
    omega

def prepareWaitingExit (s : State) : State := foldExitWallets (commitExitOwnership s) (waitingExit s).folded

def prepareExitOwnership (s : State) : State := foldExitWallets (commitExitAccount s) (waitingExit s).folded

theorem prepareWaitingExit_eq (s : State) : prepareWaitingExit s = advanceWaiting (prepareExitOwnership s) := rfl

theorem prepareWaitingExit_slack (s : State) (h : publicSlack s < ray)
    (hi : s.unwind < s.requests.size) (ho : (request s s.unwind).owner < 5)
    (ha : (request s s.unwind).owner < s.accounts.size) (hw : s.wallets.size = actors) :
    publicSlack (prepareWaitingExit s) < ray := by
  have hn := (publicSlack_lt_iff _).1 (commitExitOwnership_slack s h hi ho ha)
  apply (publicSlack_lt_iff _).2
  exact (foldExitWallets_liability (commitExitOwnership s) (waitingExit s).folded hw).trans_lt hn

theorem vault_fund_le_supply (s : State) (h : OperationalInvariant s) :
    wallet s vaultId+wallet s fundId ≤ s.supply := by
  have hs := wallet_range_sum s
  have hw := h.1
  have ht := h.2.2.2.2.2.2.1
  rw [hw,← ht] at hs
  simp only [actors] at hs
  rw [List.sum_range_succ (wallet s) 7,List.sum_range_succ (wallet s) 6,
    List.sum_range_succ (wallet s) 5] at hs
  simp only [vaultId,fundId]
  omega

theorem waiting_head_escrow (s : State) (h : OperationalInvariant s) (hi : s.unwind < s.requests.size) :
    (request s s.unwind).claim.shares ≤ s.pending := by
  have hp := h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  rw [waiting_head s hi,List.map_cons,List.sum_cons] at hp
  omega

theorem waitingExit_shares_le_active (s : State) (h : OperationalInvariant s) (hi : s.unwind < s.requests.size) :
    (request s s.unwind).claim.shares+(waitingExit s).folded ≤ activeSupply s := by
  have hf := startExit_fold_le s.book (account s (request s s.unwind).owner) (request s s.unwind).account
    (wallet s (request s s.unwind).owner) (request s s.unwind).claim.shares (wallet s fundId)
  change (waitingExit s).folded ≤ wallet s fundId at hf
  have he := waiting_head_escrow s h hi
  have hw := vault_fund_le_supply s h
  have hescrow := h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  unfold activeSupply
  omega

theorem rounded_exit_backing (assets owed shares supply : Nat) (hback : owed ≤ assets) (hshares : shares ≤ supply) :
    owed+ceilDiv ((assets-owed)*shares) supply ≤
      assets+(ceilDiv ((assets-owed)*shares) supply-(assets-owed)*shares/supply) := by
  have hf := proportional_le (assets-owed) shares supply hshares
  have hr : (assets-owed)*shares/supply ≤ ceilDiv ((assets-owed)*shares) supply :=
    floorDiv_le_ceilDiv (a := supply) (b := (assets-owed)*shares)
  omega

theorem startExit_source_bounds (book : Book) (owner request : Account) (wallet shares funded : Nat) :
    (startExit book owner request wallet shares funded).reward ≤ book.source ∧
    (startExit book owner request wallet shares funded).fee ≤ book.protocol := by
  have hr : book.source*(startExit book owner request wallet shares funded).burned/book.total ≤ book.source :=
    proportional_le _ _ _ (min_le_left _ _)
  change (startExit book owner request wallet shares funded).reward ≤ book.source at hr
  refine ⟨hr,?_⟩
  change (if book.source == 0 then 0 else
    book.protocol*(startExit book owner request wallet shares funded).reward/book.source) ≤ book.protocol
  split
  · exact Nat.zero_le _
  · exact proportional_le _ _ _ hr

theorem exit_source_slice_bound (held source protocol reward fee shares supply : Nat)
    (hreserved : source+protocol ≤ held) (hr : reward ≤ source) (hf : fee ≤ protocol) (hs : shares ≤ supply) :
    (held-(source-reward)-(protocol-fee)-reward-fee)*shares/supply+reward+fee ≤ held := by
  have hp := proportional_le (held-(source-reward)-(protocol-fee)-reward-fee) shares supply hs
  omega

theorem waitingExit_source_slice (s : State) (shares : Nat) (hs : shares ≤ activeSupply s)
    (hb : s.book.source+s.book.protocol ≤ s.held) :
    (s.held-(waitingExit s).book.source-(waitingExit s).book.protocol-
      (waitingExit s).reward-(waitingExit s).fee)*shares/activeSupply s+
      (waitingExit s).reward+(waitingExit s).fee ≤ s.held := by
  have hf := startExit_source_bounds s.book (account s (request s s.unwind).owner)
    (request s s.unwind).account (wallet s (request s s.unwind).owner)
    (request s s.unwind).claim.shares (wallet s fundId)
  simp only [waitingExit,startExit_source,startExit_protocol]
  exact exit_source_slice_bound s.held s.book.source s.book.protocol
    (waitingExit s).reward (waitingExit s).fee shares (activeSupply s) hb hf.1 hf.2 hs

theorem checkpoint_reserved (s : State) (hp : pendingAccounting s = false) (hf : s.feeBps ≤ 10000) :
    (checkpoint s zeroId zeroId).book.source+(checkpoint s zeroId zeroId).book.protocol ≤ s.held := by
  rw [checkpoint_factored]
  simp only [hp,Bool.not_false,ite_true,beq_self_eq_true,settleOwner_book]
  exact allocation_respects_Main_backing s.book (allocationInput s) hf

theorem setAccount_operational (s : State) (owner : Nat) (value : Account) (h : OperationalInvariant s) :
    OperationalInvariant (setAccount s owner value) := by
  simpa only [OperationalInvariant,setAccount,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using h

theorem bookEdit_operational (s : State) (book : Book) (h : OperationalInvariant s) :
    OperationalInvariant { s with book } := h

theorem commitExitAccount_operational (s : State) (h : OperationalInvariant s) :
    OperationalInvariant (commitExitAccount s) :=
  bookEdit_operational _ _ (setAccount_operational s (request s s.unwind).owner
    ⟨(waitingExit s).owned,s.book.index,s.book.epoch,s.book.scale⟩ h)

theorem foldExitWallets_operational (s : State) (folded : Nat) (h : OperationalInvariant s)
    (hf : folded ≤ wallet s fundId) : OperationalInvariant (foldExitWallets s folded) := by
  have hw : s.wallets.size = actors := h.1
  have hfund : fundId < s.wallets.size := by simp only [hw,actors,fundId]; omega
  have hvault : vaultId < s.wallets.size := by simp only [hw,actors,vaultId]; omega
  have hsum := moveWallets_sum s fundId vaultId folded hfund hvault hf
  have hget : wallet (foldExitWallets s folded) vaultId = wallet s vaultId+folded := by
    simpa only [foldExitWallets,fundId,vaultId,ite_true,beq_iff_eq,reduceCtorEq,ite_false] using
      moveWallets_wallet s fundId vaultId folded vaultId hfund hvault
  rcases h with ⟨hws,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hescrow,hassets,hliquid⟩
  refine ⟨?_,ha,hc,hap,hpos,hu,hsupply.trans hsum.symm,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,?_,hassets,hliquid⟩
  · simpa only [foldExitWallets,moveWallets,setWallet,Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using hws
  · rw [hget]
    exact hescrow.trans (Nat.le_add_right _ _)

theorem prepareExitOwnership_operational (s : State) (h : OperationalInvariant s) :
    OperationalInvariant (prepareExitOwnership s) :=
  foldExitWallets_operational (commitExitAccount s) (waitingExit s).folded (commitExitAccount_operational s h)
    (startExit_fold_le s.book (account s (request s s.unwind).owner) (request s s.unwind).account
      (wallet s (request s s.unwind).owner) (request s s.unwind).claim.shares (wallet s fundId))

end Juicer.PublicCalls
