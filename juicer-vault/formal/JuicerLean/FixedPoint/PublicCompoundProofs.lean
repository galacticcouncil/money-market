import JuicerLean.FixedPoint.PublicPaymentProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1500000

namespace Juicer.PublicCalls
open Runtime

def addPositionCash (s : State) (amount : Nat) : State :=
  let next := setPosition s 0 { position s 0 with cash := (position s 0).cash+amount }
  { next with ownedCash := next.ownedCash+amount }

theorem addPositionCash_public (s : State) (amount : Nat) (h : PublicInvariant s) :
    PublicInvariant (addPositionCash s amount) := by
  have hi : 0 < s.positions.size := h.2.2.2.2.2.2.2.2.2.1
  have hh := position_sum_replace s 0 { position s 0 with cash := (position s 0).cash+amount }
    MainPosition.cash hi
  have hremaining := position_sum_replace s 0 { position s 0 with cash := (position s 0).cash+amount }
    MainPosition.remaining hi
  have hunits := position_sum_replace s 0 { position s 0 with cash := (position s 0).cash+amount }
    MainPosition.units hi
  rcases h with ⟨hc,hs,hm,hl,he,ho⟩
  refine ⟨hc,?_,?_,hl,he,?_⟩
  · change s.activeRemaining+(s.positions.toList.map MainPosition.remaining).sum = s.outstanding at hs
    change s.activeRemaining+(sourceProjection (addPositionCash s amount)).exits.sum = s.outstanding
    change (sourceProjection (addPositionCash s amount)).exits.sum+(position s 0).remaining =
      (s.positions.toList.map MainPosition.remaining).sum+(position s 0).remaining at hremaining
    omega
  · change (s.positions.toList.map MainPosition.cash).sum+s.unallocated = s.ownedCash at hm
    change (cashProjection (addPositionCash s amount)).cohorts.sum+s.unallocated = s.ownedCash+amount
    change (cashProjection (addPositionCash s amount)).cohorts.sum+(position s 0).cash =
      (s.positions.toList.map MainPosition.cash).sum+((position s 0).cash+amount) at hh
    omega
  · rcases ho with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨hw,ha,hc,hap,?_,hu,hsupply,?_,hout,?_,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    · simpa only [addPositionCash,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hpos
    · change s.mainUnits = ((addPositionCash s amount).positions.toList.map MainPosition.units).sum
      change ((addPositionCash s amount).positions.toList.map MainPosition.units).sum+(position s 0).units =
        (s.positions.toList.map MainPosition.units).sum+(position s 0).units at hunits
      omega
    · simpa only [addPositionCash,setPosition,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hfs

theorem synth_public (s : State) (amount : Nat) (h : PublicInvariant s) :
    PublicInvariant { s with synth := amount } := h

theorem bookFunding_public (s : State) (source protocol basis : Nat) (h : PublicInvariant s) :
    PublicInvariant { s with book := { s.book with source,protocol }, basis } := by
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · apply (publicSlack_lt_iff _).2
    have he := (publicSlack_lt_iff s).1 h.2.2.2.2.1
    have hn : ∀ a w, normalizeAccount { s.book with source,protocol } a w =
        normalizeAccount s.book a w := by intros; rfl
    change publicLiability { s with book := { s.book with source,protocol },basis } < s.book.total*ray+ray
    have hh : publicLiability { s with book := { s.book with source,protocol },basis } = publicLiability s := by
      rw [publicLiability_parts,publicLiability_parts]
      simp only [hn]
      rfl
    rw [hh]
    exact he
  · exact h.2.2.2.2.2

def reserveRewardState (s : State) (value : Nat) : State :=
  let v := allocationInput s
  let added := min (allocationAvailable v-s.book.source-s.book.protocol) (value*s.held/v.equity)
  { s with
    book := { s.book with source := s.book.source+added },
    basis := s.basis-min (added*v.equity/s.held) (s.basis-v.required) }

theorem reserveReward_public (s : State) (value : Nat) (h : PublicInvariant s) :
    PublicInvariant (reserveRewardState s value) :=
  bookFunding_public s _ s.book.protocol _ h

def fundCollateral (s : State) (minted returned feeAmount : Nat) : State :=
  let next := setWallet s fundId (wallet s fundId+minted)
  { next with
    supply := next.supply+minted, assets := next.assets+returned,
    supplied := next.supplied+returned, reinvest := next.reinvest+returned,
    feesCollateral := next.feesCollateral+feeAmount }

theorem fundCollateral_public (s : State) (minted returned feeAmount : Nat) (h : PublicInvariant s) :
    PublicInvariant (fundCollateral s minted returned feeAmount) := by
  have hw : s.wallets.size = actors := h.2.2.2.2.2.1
  have hf : fundId < s.wallets.size := by simp only [hw,actors,fundId]; omega
  have hsum := wallet_sum_set_balance s fundId (wallet s fundId+minted) hf
  have hv : wallet (fundCollateral s minted returned feeAmount) vaultId = wallet s vaultId := by
    change wallet (setWallet s fundId (wallet s fundId+minted)) vaultId = wallet s vaultId
    rw [wallet_setWallet s fundId _ vaultId hf]
    rfl
  apply public_of_operational
  · change s.assets+returned+s.reserve = s.supplied+returned+s.liquid
    have hc := h.1
    change s.assets+s.reserve = s.supplied+s.liquid at hc
    omega
  · exact h.2.1
  · exact h.2.2.1
  · apply (publicSlack_lt_iff _).2
    have he := (publicSlack_lt_iff s).1 h.2.2.2.2.1
    have hliab : publicLiability (fundCollateral s minted returned feeAmount) = publicLiability s := by
      rw [publicLiability_parts,publicLiability_parts]
      apply congrArg (fun n => n+(_ : Nat))
      apply congrArg List.sum
      apply List.map_congr_left
      intro i hi
      have hin : i < 5 := List.mem_range.mp hi
      have hne : fundId ≠ i := by simp only [fundId]; omega
      change (normalizeAccount s.book (account s i)
        (wallet (setWallet s fundId (wallet s fundId+minted)) i)).numerator s.book.index = _
      rw [wallet_setWallet s fundId _ i hf,if_neg hne]
    change publicLiability (fundCollateral s minted returned feeAmount) < s.book.total*ray+ray
    rw [hliab]
    exact he
  · rcases h.2.2.2.2.2 with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨?_,ha,?_,hap,hpos,hu,?_,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,?_,?_,?_⟩
    · simpa only [fundCollateral,setWallet,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hw
    · exact hc
    · change s.supply+minted = (setWallet s fundId (wallet s fundId+minted)).wallets.toList.sum
      omega
    · rw [hv]; exact hvault
    · exact hassets.trans (Nat.le_add_right _ _)
    · exact hliquid

def compoundSale (s : State) (sold : Nat) : Except Nat State := do
  if sold != 0 then
    let fair := quoteHollar s sold
    let received := fair*(10000-s.haircut)/10000
    if received < fair*9900/10000 then throw 26
    if received == 0 then throw 25
    return addPositionCash s received
  else return s

theorem compoundSale_public (s : State) (sold : Nat) (h : PublicInvariant s) :
    OnSuccess PublicInvariant (compoundSale s sold) := by
  unfold compoundSale
  simp only [bind,pure,Except.bind,Except.pure]
  split
  · split
    · trivial
    · split
      · trivial
      · exact addPositionCash_public s _ h
  · exact h

def compoundFinish (s : State) (out fresh sold reward service feeAmount cashBefore : Nat) : Except Nat State :=
  let returned := fresh-sold
  let rewardSpent := sold-service
  let next := if rewardSpent != 0 && cashBefore < spendable s 0 then
    reserveRewardState s (min (spendable s 0-cashBefore) (quoteHollar s rewardSpent)) else s
  let fundedReward := min reward returned
  let serviceRemainder := returned-fundedReward
  let minted := fundedReward*activeSupply next/(activeAssets next+serviceRemainder)
  if out != fresh+feeAmount then .error 99
  else .ok (fundCollateral next minted returned feeAmount)

theorem compoundFinish_public (s : State) (out fresh sold reward service feeAmount cashBefore : Nat)
    (h : PublicInvariant s) : OnSuccess PublicInvariant
      (compoundFinish s out fresh sold reward service feeAmount cashBefore) := by
  unfold compoundFinish
  split
  · trivial
  · apply fundCollateral_public
    split
    · exact reserveReward_public s _ h
    · exact h

def compoundTail (input : State) (out fresh sold reward service feeAmount cashBefore : Nat) : Except Nat State := do
  let mut s := input
  let returned := fresh-sold
  let rewardSpent := sold-service
  let fundedReward := min reward returned
  let serviceRemainder := returned-fundedReward
  if rewardSpent != 0 && cashBefore < spendable s 0 then
    let value := min (spendable s 0-cashBefore) (quoteHollar s rewardSpent)
    let v := allocationInput s
    let added := min (allocationAvailable v-s.book.source-s.book.protocol) (value*s.held/v.equity)
    s := { s with
      book := { s.book with source := s.book.source+added },
      basis := s.basis-min (added*v.equity/s.held) (s.basis-v.required) }
  let minted := fundedReward*activeSupply s/(activeAssets s+serviceRemainder)
  s := setWallet s fundId (wallet s fundId+minted)
  if out != fresh+feeAmount then throw 99
  return { s with
    supply := s.supply+minted,assets := s.assets+returned,
    supplied := s.supplied+returned,reinvest := s.reinvest+returned,
    feesCollateral := s.feesCollateral+feeAmount }

theorem compoundTail_eq (s : State) (out fresh sold reward service feeAmount cashBefore : Nat) :
    compoundTail s out fresh sold reward service feeAmount cashBefore =
      compoundFinish s out fresh sold reward service feeAmount cashBefore := by
  unfold compoundTail compoundFinish
  simp only [bind,pure,Except.bind,Except.pure]
  split_ifs <;> rfl

theorem compoundFunds_factored (s : State) (out reward service feeAmount : Nat) :
    compoundFunds s out reward service feeAmount = (
      let oldSynth := s.synth
      let cashBefore := spendable s 0
      let interest := mainDebtOf s.debt s.mainUnits (position s 0)-(position s 0).principal
      let fresh := reward+service
      let sold := min fresh (ceilDiv (ceilDiv ((interest-cashBefore)*10000) 9900*10^8) (s.price/10^10))
      do
        let next ← compoundSale s sold
        let next := { (pay next 0 0).1 with synth := oldSynth }
        compoundTail next out fresh sold reward service feeAmount cashBefore) := by
  unfold compoundFunds
  extract_lets (config := { onlyGivenNames := true, underBinder := false }) base oldSynth cashBefore interest fresh sold continuation
  have hcont (next : State) : continuation next PUnit.unit =
      compoundTail { (pay next 0 0).1 with synth := oldSynth }
        out fresh sold reward service feeAmount cashBefore := by
    rfl
  change _ = (do
    let next ← compoundSale base sold
    compoundTail { (pay next 0 0).1 with synth := oldSynth }
      out fresh sold reward service feeAmount cashBefore)
  simp only [hcont]
  unfold compoundSale
  simp only [bind,pure,Except.bind,Except.pure]
  split_ifs <;> rfl

theorem compoundFunds_public (s : State) (out reward service feeAmount : Nat) (h : PublicInvariant s) :
    OnSuccess PublicInvariant (compoundFunds s out reward service feeAmount) := by
  rw [compoundFunds_factored]
  dsimp only
  rw [onSuccess_bind]
  intro next heq
  have hn := onSuccess_of_eq (compoundSale_public s _ h) heq
  have hi : 0 < next.positions.size := hn.2.2.2.2.2.2.2.2.2.1
  rw [compoundTail_eq]
  exact compoundFinish_public _ _ _ _ _ _ _ _ (synth_public _ _ (pay_public next 0 0 hi hn))

theorem collateralEdit_public (s : State) (owner amount : Nat) (h : PublicInvariant s) :
    PublicInvariant { s with collateral := s.collateral.set! owner amount } := by
  rcases h with ⟨hc,hs,hm,hl,he,ho⟩
  refine ⟨hc,hs,hm,hl,he,?_⟩
  simpa only [OperationalInvariant,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using ho

theorem raw_compound_public (s : State) (caller a b n : Nat) (h : PublicInvariant s) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1) (rawRunCall s ⟨24,caller,a,b,n⟩) := by
  change OnSuccess _ (if s.paused || s.sourcePaused then .error 1
    else if n == 0 then .error 2 else if s.collateral[caller]! < n then .error 15
    else if n < b then .error 28 else do
      let next ← compoundFunds { s with collateral := s.collateral.set! caller (s.collateral[caller]!-n) }
        n 0 n 0
      pure (next,0))
  split
  · trivial
  · split
    · trivial
    · split
      · trivial
      · split
        · trivial
        · rw [onSuccess_bind]
          intro next heq
          change PublicInvariant next
          exact onSuccess_of_eq (compoundFunds_public _ n 0 n 0
            (collateralEdit_public s caller (s.collateral[caller]!-n) h)) heq

end Juicer.PublicCalls

