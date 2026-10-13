import JuicerLean.FixedPoint.PublicCompoundProofs
import JuicerLean.FixedPoint.PublicRequestProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

def mintWallet (s : State) (receiver amount : Nat) : State :=
  setWallet { s with supply := s.supply+amount } receiver (wallet s receiver+amount)

theorem mintWallet_liability (s : State) (receiver amount : Nat) (hi : receiver < s.wallets.size)
    (hc : receiver < 5 → (normalizeAccount s.book (account s receiver) (wallet s receiver)).index = s.book.index) :
    publicLiability (mintWallet s receiver amount) = publicLiability s := by
  rw [publicLiability_parts,publicLiability_parts]
  apply congrArg (fun n => n+(_ : Nat))
  apply congrArg List.sum
  apply List.map_congr_left
  intro i hi5
  change (normalizeAccount s.book (account s i)
    (wallet (setWallet s receiver (wallet s receiver+amount)) i)).numerator s.book.index = _
  rw [wallet_setWallet s receiver _ i hi]
  by_cases heq : receiver = i
  · subst i
    rw [if_pos rfl]
    exact normalized_current_weight s.book (account s receiver) _ _ (hc (List.mem_range.mp hi5))
  · rw [if_neg heq]

theorem mintWallet_public (s : State) (receiver amount : Nat) (h : PublicInvariant s)
    (hi : receiver < actors)
    (hc : receiver < 5 → (normalizeAccount s.book (account s receiver) (wallet s receiver)).index = s.book.index) :
    PublicInvariant (mintWallet s receiver amount) := by
  have hw : s.wallets.size = actors := h.2.2.2.2.2.1
  have hiw : receiver < s.wallets.size := by rw [hw]; exact hi
  have hsum := wallet_sum_set_balance s receiver (wallet s receiver+amount) hiw
  have hv : wallet s vaultId ≤ wallet (mintWallet s receiver amount) vaultId := by
    change wallet s vaultId ≤ wallet (setWallet s receiver (wallet s receiver+amount)) vaultId
    rw [wallet_setWallet s receiver _ vaultId hiw]
    split
    next heq => subst receiver; exact Nat.le_add_right _ _
    · exact le_rfl
  apply public_of_operational
  · exact h.1
  · exact h.2.1
  · exact h.2.2.1
  · apply (publicSlack_lt_iff _).2
    change publicLiability (mintWallet s receiver amount) < s.book.total*ray+ray
    rw [mintWallet_liability s receiver amount hiw hc]
    exact (publicSlack_lt_iff s).1 h.2.2.2.2.1
  · rcases h.2.2.2.2.2 with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨?_,ha,hc,hap,hpos,hu,?_,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault.trans hv,hassets,hliquid⟩
    · simpa only [mintWallet,setWallet,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hw
    · change s.supply+amount = (setWallet s receiver (wallet s receiver+amount)).wallets.toList.sum
      omega

def depositAssets (s : State) (caller amount : Nat) : State :=
  { s with
    assets := s.assets+amount,supplied := s.supplied+amount,reinvest := s.reinvest+amount,
    collateral := s.collateral.set! caller (s.collateral[caller]!-amount) }

theorem depositAssets_public (s : State) (caller amount : Nat) (h : PublicInvariant s) :
    PublicInvariant (depositAssets s caller amount) := by
  rcases h with ⟨hc,hs,hm,hl,he,ho⟩
  refine ⟨?_,hs,hm,hl,he,?_⟩
  · change s.assets+amount+s.reserve = s.supplied+amount+s.liquid
    change s.assets+s.reserve = s.supplied+s.liquid at hc
    omega
  · rcases ho with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
    refine ⟨hw,ha,?_,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
      hvalid,hpend,hqueued,howed,hqd,hvault,hassets.trans (Nat.le_add_right _ _),hliquid⟩
    simpa only [depositAssets,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hc

theorem cover_public (s : State) (amount : Nat) (h : PublicInvariant s) :
    OnSuccess PublicInvariant (cover s amount) := by
  unfold cover
  split
  · trivial
  next hn =>
    rcases h with ⟨hc,hs,hm,hl,he,ho⟩
    refine ⟨?_,hs,hm,hl,he,?_⟩
    · change s.assets+amount+(s.reserve-amount) = s.supplied+s.liquid
      change s.assets+s.reserve = s.supplied+s.liquid at hc
      omega
    · rcases ho with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
        hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
      exact ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
        hvalid,hpend,hqueued,howed,hqd,hvault,hassets.trans (Nat.le_add_right _ _),hliquid⟩

theorem wallet_le_supply (s : State) (owner : Nat) (h : OperationalInvariant s) (ho : owner < actors) :
    wallet s owner ≤ s.supply := by
  have hs : s.supply = s.wallets.toList.sum := h.2.2.2.2.2.2.1
  rw [hs,← wallet_range_sum]
  exact map_value_le_sum (wallet s) (List.range s.wallets.size) owner
    (List.mem_range.mpr (by rw [h.1]; exact ho))

def initialMint (s : State) : State :=
  if s.supply == 0 then setWallet { s with supply := 1000 } 4 1000 else s

def InitialMintSafe (s : State) : Prop := s.supply = 0 → s.book.index = 0

instance (s : State) : Decidable (InitialMintSafe s) := by unfold InitialMintSafe; infer_instance

theorem initialMint_zero_eq (s : State) (h : PublicInvariant s) (hz : s.supply = 0) :
    initialMint s = mintWallet s 4 1000 := by
  have hw : wallet s 4 = 0 := Nat.eq_zero_of_le_zero (hz ▸ wallet_le_supply s 4 h.2.2.2.2.2 (by decide))
  simp only [initialMint,hz,beq_self_eq_true,ite_true,mintWallet,hw,Nat.zero_add]

theorem initialMint_public (s : State) (h : PublicInvariant s) (hz : InitialMintSafe s) :
    PublicInvariant (initialMint s) := by
  by_cases hs : s.supply = 0
  · rw [initialMint_zero_eq s h hs]
    apply mintWallet_public s 4 1000 h (by decide)
    intro _
    have hh := normalized_index_bound s (account s 4) (wallet s 4)
    rw [hz hs] at hh ⊢
    exact Nat.eq_zero_of_le_zero hh
  · simpa only [initialMint,beq_iff_eq,if_neg hs] using h

theorem initialMint_current (s : State) (i : Nat) (hc : CurrentAccount s i) :
    CurrentAccount (initialMint s) i := by
  unfold initialMint
  split <;> exact hc

theorem allocate_zero_index (b : Book) (v : AllocationInput) (hi : b.index = 0) (hs : v.supply = 0) :
    (allocate b v).index = 0 := by
  have ht : (trimLoss b (allocationAvailable v)).index = 0 := by
    unfold trimLoss
    split <;> exact hi
  unfold allocate
  simp only [hs,bne_self_eq_false,Bool.and_false,Bool.false_and,Bool.not_false,
    Bool.and_true,ite_true]
  split_ifs <;> first | exact ht | rfl

theorem allocateState_initialMintSafe (s : State) (h : InitialMintSafe s) :
    InitialMintSafe (allocateState s) := by
  intro hs
  change s.supply = 0 at hs
  exact allocate_zero_index s.book (allocationInput s) (h hs)
    (by change s.supply-s.queued = 0; rw [hs,Nat.zero_sub])

theorem settleOwner_initialMintSafe (s : State) (owner : Nat) (h : InitialMintSafe s) :
    InitialMintSafe (settleOwner s owner) := by
  unfold settleOwner
  split <;> exact h

theorem checkpoint_initialMintSafe (s : State) (a b : Nat) (h : InitialMintSafe s) :
    InitialMintSafe (checkpoint s a b) := by
  rw [checkpoint_factored]
  dsimp only
  have ht : InitialMintSafe (if !pendingAccounting s then allocateState s else s) := by
    split
    · exact allocateState_initialMintSafe s h
    · exact h
  split
  · exact settleOwner_initialMintSafe _ a ht
  · exact settleOwner_initialMintSafe _ b (settleOwner_initialMintSafe _ a ht)

theorem checkpoint_current_second (s : State) (a b : Nat) (hb : b < 5)
    (hs : s.accounts.size = actors) : CurrentAccount (checkpoint s a b) b := by
  rw [checkpoint_factored]
  dsimp only
  have hsize : (if !pendingAccounting s then allocateState s else s).accounts.size = actors := by
    split <;> exact hs
  split
  next heq =>
    have heq' : a = b := beq_iff_eq.mp heq
    subst a
    exact settleOwner_current _ b hb (by rw [hsize]; exact hb.trans (by decide : 5 < actors))
  · apply settleOwner_current _ b hb
    have hc : (settleOwner (if !pendingAccounting s then allocateState s else s) a).accounts.size = actors := by
      unfold settleOwner
      split
      · exact hsize
      · simpa only [setAccount,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds] using hsize
    rw [hc]
    exact hb.trans (by decide : 5 < actors)

def depositResult (s : State) (caller receiver amount shares needed : Nat) : Result := do
  let next ← cover (depositAssets (mintWallet (initialMint s) receiver shares) caller amount) (needed-amount)
  if next.synth*9800/10000 < next.debt then throw 23
  return (next,shares)

theorem depositResult_public (s : State) (caller receiver amount shares needed : Nat)
    (h : PublicInvariant s) (hz : InitialMintSafe s) (hr : receiver < actors)
    (hc : receiver < 5 → CurrentAccount s receiver) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1)
      (depositResult s caller receiver amount shares needed) := by
  unfold depositResult
  rw [onSuccess_bind]
  intro next heq
  have hm := mintWallet_public (initialMint s) receiver shares (initialMint_public s h hz) hr
    (fun h5 => current_normalized _ receiver (initialMint_current s receiver (hc h5)))
  have hn := onSuccess_of_eq (cover_public _ _ (depositAssets_public _ caller amount hm)) heq
  change OnSuccess _ (if next.synth*9800/10000 < next.debt then .error 23 else .ok (next,shares))
  exact onSuccess_if _ _ _ _ trivial hn

def depositTail (s : State) (caller receiver amount : Nat) : Result :=
  if s.supply == 0 && caller != 0 then .error 5
  else if s.assets+amount > s.tvlCap then .error 6
  else if activeSupply s == 0 && amount ≤ 1000 then .error 7
  else if activeSupply s != 0 && activeAssets s == 0 then .error 8
  else
    let shares := if activeSupply s == 0 then amount-1000 else ceilDiv (amount*activeSupply s) (activeAssets s)
    let needed := if activeSupply s == 0 then amount else ceilDiv (shares*activeAssets s) (activeSupply s)
    depositResult s caller receiver amount shares needed

theorem depositTail_public (s : State) (caller receiver amount : Nat)
    (h : PublicInvariant s) (hz : InitialMintSafe s) (hr : receiver < actors)
    (hc : receiver < 5 → CurrentAccount s receiver) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1)
      (depositTail s caller receiver amount) := by
  unfold depositTail
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · apply onSuccess_if
        · trivial
        · exact depositResult_public s caller receiver amount _ _ h hz hr hc

def depositTailRaw (input : State) (caller receiver amount : Nat) : Result := do
  let mut s := input
  if s.supply == 0 && caller != 0 then throw 5
  if s.assets+amount > s.tvlCap then throw 6
  let supply := activeSupply s
  if supply == 0 && amount ≤ 1000 then throw 7
  if supply != 0 && activeAssets s == 0 then throw 8
  let shares := if supply == 0 then amount-1000 else ceilDiv (amount*supply) (activeAssets s)
  let needed := if supply == 0 then amount else ceilDiv (shares*activeAssets s) supply
  if s.supply == 0 then s := setWallet { s with supply := 1000 } 4 1000
  s := setWallet s receiver (wallet s receiver+shares)
  s := { s with
    supply := s.supply+shares,assets := s.assets+amount,supplied := s.supplied+amount,
    reinvest := s.reinvest+amount,collateral := s.collateral.set! caller (s.collateral[caller]!-amount) }
  s ← cover s (needed-amount)
  if s.synth*9800/10000 < s.debt then throw 23
  return (s,shares)

theorem depositTail_factored (s : State) (caller receiver amount : Nat) :
    depositTailRaw s caller receiver amount = depositTail s caller receiver amount := by
  unfold depositTailRaw depositTail depositResult initialMint
  simp only [bind,pure,Except.bind,Except.pure]
  split_ifs <;> rfl

theorem raw_deposit_factored (s : State) (caller owner receiver amount : Nat) :
    rawRunCall s ⟨0,caller,owner,receiver,amount⟩ =
      (if s.paused || s.sourcePaused then .error 1
      else if receiver == zeroId then .error 3
      else if s.depositsPaused then .error 4
      else if amount == 0 then .error 2
      else if s.delever != 0 then .error 24
      else if pendingAccounting s || s.activeRemaining != 0 then .error 18
      else depositTailRaw (checkpoint { (pay s 0 0).1 with synth := s.synth } zeroId receiver)
        caller receiver amount) := by
  rfl

theorem pay_metadata (s : State) (key limit : Nat) (h : PublicMetadata s) :
    PublicMetadata (pay s key limit).1 := by
  rw [pay_state_factored]
  exact h

theorem pay_initialMintSafe (s : State) (key limit : Nat) (h : InitialMintSafe s) :
    InitialMintSafe (pay s key limit).1 := by
  rw [pay_state_factored]
  exact h

theorem raw_deposit_public (s : State) (caller owner receiver amount : Nat)
    (h : PublicInvariant s) (hm : PublicMetadata s) (hz : InitialMintSafe s) (hr : receiver < actors) :
    OnSuccess (fun result : State × Nat => PublicInvariant result.1)
      (rawRunCall s ⟨0,caller,owner,receiver,amount⟩) := by
  rw [raw_deposit_factored]
  apply onSuccess_if
  · trivial
  · apply onSuccess_if
    · trivial
    · apply onSuccess_if
      · trivial
      · apply onSuccess_if
        · trivial
        · apply onSuccess_if
          · trivial
          · apply onSuccess_if
            · trivial
            · rw [depositTail_factored]
              let paid := { (pay s 0 0).1 with synth := s.synth }
              have hp : PublicInvariant paid := synth_public _ _
                (pay_public s 0 0 h.2.2.2.2.2.2.2.2.2.1 h)
              have hpm : PublicMetadata paid := pay_metadata s 0 0 hm
              have hpz : InitialMintSafe paid := pay_initialMintSafe s 0 0 hz
              exact depositTail_public (checkpoint paid zeroId receiver) caller receiver amount
                (checkpoint_public paid zeroId receiver hp hpm)
                (checkpoint_initialMintSafe paid zeroId receiver hpz) hr
                (fun hb => checkpoint_current_second paid zeroId receiver hb hp.2.2.2.2.2.2.1)

end Juicer.PublicCalls
