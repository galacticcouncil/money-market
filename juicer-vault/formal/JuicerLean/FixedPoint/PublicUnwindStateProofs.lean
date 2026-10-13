import JuicerLean.FixedPoint.PublicActivationProofs
import JuicerLean.FixedPoint.PublicSourceExitProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

structure UnwindNumbers where
  shares : Nat
  owed : Nat
  debt : Nat
  synth : Nat
  slice : Nat
  basis : Nat
  claim : Nat
  rounding : Nat
  active : MainPosition
  exit : MainPosition
  total : Nat
  vested : SourceFee

structure UnwindFacts (s : State) (q : UnwindNumbers) : Prop where
  source : SourceExitFacts s q.active q.exit q.total q.slice q.claim q.vested
  shares_eq : q.shares = (request s s.unwind).claim.shares+(waitingExit s).folded
  redemption : 0 < q.owed ∨ (q.shares = 0 ∧ q.debt = 0)
  reserve : q.rounding ≤ s.reserve
  backing : s.owed+q.owed ≤ s.assets+q.rounding

def coverExit (s : State) (amount reinvest : Nat) : State :=
  { s with reserve := s.reserve-amount,assets := s.assets+amount,reinvest }

theorem coverExit_collateral (s : State) (amount reinvest : Nat) (h : CollateralConserved s) (hb : amount ≤ s.reserve) :
    CollateralConserved (coverExit s amount reinvest) := by
  change s.assets+amount+(s.reserve-amount) = s.supplied+s.liquid
  change s.assets+s.reserve = s.supplied+s.liquid at h
  omega

theorem coverExit_operational (s : State) (amount reinvest : Nat) (h : OperationalInvariant s) :
    OperationalInvariant (coverExit s amount reinvest) := by
  rcases h with ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets,hliquid⟩
  exact ⟨hw,ha,hc,hap,hpos,hu,hsupply,hmain,hout,hfs,hfr,hfee,hsourceCash,
    hvalid,hpend,hqueued,howed,hqd,hvault,hassets.trans (Nat.le_add_right _ _),hliquid⟩

theorem coverExit_liability (s : State) (amount reinvest : Nat) :
    publicLiability (advanceWaiting (coverExit s amount reinvest)) = publicLiability (advanceWaiting s) := by
  rw [publicLiability_parts,publicLiability_parts]
  rfl

def unwindBooked (s : State) (q : UnwindNumbers) : State :=
  sourceExitState (prepareExitOwnership s) q.active q.exit q.total q.slice q.basis q.claim q.vested

def unwindCovered (s : State) (q : UnwindNumbers) : State :=
  coverExit (unwindBooked s q) q.rounding (s.reinvest-s.reinvest*q.shares/activeSupply s)

def unwindCommitted (s : State) (q : UnwindNumbers) : State :=
  activateWaiting (unwindCovered s q) q.shares q.owed q.debt q.synth

theorem unwindCommitted_liability (s : State) (q : UnwindNumbers) :
    publicLiability (unwindCommitted s q) = publicLiability (prepareWaitingExit s) := by
  unfold unwindCommitted
  rw [activateWaiting_liability]
  unfold unwindCovered
  rw [coverExit_liability]
  unfold unwindBooked
  rw [sourceExitState_liability,← prepareWaitingExit_eq]

theorem unwindCommitted_book (s : State) (q : UnwindNumbers) :
    (unwindCommitted s q).book = (prepareWaitingExit s).book := rfl

theorem prepared_source_facts (s : State) (q : UnwindNumbers) (h : UnwindFacts s q) :
    SourceExitFacts (prepareExitOwnership s) q.active q.exit q.total q.slice q.claim q.vested := by
  dsimp only [prepareExitOwnership,foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount]
  refine ⟨?_,?_,?_,?_,h.source.claim_eq,h.source.slice_le,?_,h.source.fee⟩
  · simpa only [position] using h.source.units
  · simpa only [position] using h.source.units_le
  · simpa only [position] using h.source.cash
  · simpa only [position] using h.source.remaining
  · simpa only [sourceValue] using h.source.value_eq

theorem prepareExitOwnership_vault (s : State) (hw : s.wallets.size = actors) :
    wallet (prepareExitOwnership s) vaultId = wallet s vaultId+(waitingExit s).folded := by
  have hfund : fundId < (commitExitAccount s).wallets.size := by change fundId < s.wallets.size; simp [hw,fundId,actors]
  have hvault : vaultId < (commitExitAccount s).wallets.size := by change vaultId < s.wallets.size; simp [hw,vaultId,actors]
  simpa only [wallet,fundId,vaultId,ite_true,beq_iff_eq,reduceCtorEq,ite_false] using
    moveWallets_wallet (commitExitAccount s) fundId vaultId (waitingExit s).folded vaultId hfund hvault

theorem unwindCovered_escrow (s : State) (q : UnwindNumbers) (h : OperationalInvariant s)
    (hi : s.unwind < s.requests.size) (hq : UnwindFacts s q) :
    (unwindCovered s q).pending-(request (unwindCovered s q) (unwindCovered s q).unwind).claim.shares+
      (unwindCovered s q).queued+q.shares ≤ wallet (unwindCovered s q) vaultId := by
  have he := waiting_head_escrow s h hi
  have hv := prepareExitOwnership_vault s h.1
  have hescrow := h.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  dsimp only [request,wallet,unwindCovered,coverExit,unwindBooked,sourceExitState,setPosition]
  dsimp only [prepareExitOwnership,foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount]
  change s.pending-(request s s.unwind).claim.shares+s.queued+q.shares ≤ wallet (prepareExitOwnership s) vaultId
  rw [hv]
  have hshares := hq.shares_eq
  omega

theorem unwindCommitted_public (s : State) (q : UnwindNumbers) (h : PublicInvariant s)
    (hi : s.unwind < s.requests.size) (ho : (request s s.unwind).owner < 5) (hq : UnwindFacts s q) :
    PublicInvariant (unwindCommitted s q) := by
  have hop := h.2.2.2.2.2
  have hp := prepareExitOwnership_operational s hop
  have hf := prepared_source_facts s q hq
  have hib : 0 < (prepareExitOwnership s).positions.size := by
    simpa only [prepareExitOwnership,foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount]
      using hop.2.2.2.2.1
  have hb := sourceExitState_operational (prepareExitOwnership s) q.active q.exit q.total q.slice q.basis q.claim q.vested hp hf
  have hc := coverExit_operational (unwindBooked s q) q.rounding (s.reinvest-s.reinvest*q.shares/activeSupply s) hb
  have hpsource : (sourceProjection (prepareExitOwnership s)).valid := by
    simpa only [sourceProjection,prepareExitOwnership,foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount]
      using h.2.1
  have hpcash : (cashProjection (prepareExitOwnership s)).valid := by
    simpa only [cashProjection,prepareExitOwnership,foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount]
      using h.2.2.1
  have hbcoll : CollateralConserved (unwindBooked s q) := by
    simpa only [CollateralConserved,unwindBooked,sourceExitState,setPosition,prepareExitOwnership,
      foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount] using h.1
  have hfsource := sourceExitState_source (prepareExitOwnership s) q.active q.exit q.total q.slice q.basis q.claim q.vested hpsource hib hf
  have hfcash := sourceExitState_cash (prepareExitOwnership s) q.active q.exit q.total q.slice q.basis q.claim q.vested hpcash hib hf
  have hrb : q.rounding ≤ (unwindBooked s q).reserve := by
    simpa only [unwindBooked,sourceExitState,setPosition,prepareExitOwnership,foldExitWallets,
      moveWallets,setWallet,commitExitAccount,setAccount] using hq.reserve
  have hcoll := coverExit_collateral (unwindBooked s q) q.rounding (s.reinvest-s.reinvest*q.shares/activeSupply s) hbcoll hrb
  have hac : (request s s.unwind).owner < s.accounts.size := by
    have ha : s.accounts.size = actors := hop.2.1
    rw [ha]
    exact ho.trans (by decide : 5 < actors)
  have hic : (unwindCovered s q).unwind < (unwindCovered s q).requests.size := by
    simpa only [unwindCovered,coverExit,unwindBooked,sourceExitState,setPosition,prepareExitOwnership,
      foldExitWallets,moveWallets,setWallet,commitExitAccount,setAccount] using hi
  apply public_of_operational
  · simpa only [CollateralConserved] using hcoll
  · simpa only [sourceProjection] using hfsource
  · simpa only [cashProjection] using hfcash
  · apply (publicSlack_lt_iff _).2
    rw [unwindCommitted_liability,unwindCommitted_book]
    exact (publicSlack_lt_iff _).1 (prepareWaitingExit_slack s h.2.2.2.2.1 hi ho hac hop.1)
  · exact activateWaiting_operational (unwindCovered s q) q.shares q.owed q.debt q.synth
      hc hic hq.redemption (unwindCovered_escrow s q hop hi hq)

theorem unwindCommitted_queueBacking (s : State) (q : UnwindNumbers) (h : QueueBacking s) (hq : UnwindFacts s q) :
    QueueBacking (unwindCommitted s q) := by
  dsimp only [QueueBacking,unwindCommitted,activateWaiting,unwindCovered,coverExit,unwindBooked,
    sourceExitState,setPosition,request,prepareExitOwnership,foldExitWallets,moveWallets,setWallet,
    commitExitAccount,setAccount]
  refine ⟨?_,?_⟩
  · change s.owed+q.owed ≤ s.assets+q.rounding
    exact hq.backing
  have hn := h.2
  simpa only [Array.size_push,Array.set!_eq_setIfInBounds,Array.size_setIfInBounds]
    using congrArg (fun n => n+1) hn

end Juicer.PublicCalls
