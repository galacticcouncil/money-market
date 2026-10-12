import JuicerLean.FixedPoint.PublicTransferProofs

set_option maxRecDepth 4000
set_option maxHeartbeats 500000

namespace Juicer.PublicCalls
open Runtime

def AccountHistory (b : Book) (a : Account) : Prop :=
  a.epoch ≤ b.epoch ∧ (a.epoch = b.epoch → a.scale ≤ b.scale)

def BookProgress (b next : Book) : Prop :=
  b.epoch ≤ next.epoch ∧ (b.epoch = next.epoch → b.scale ≤ next.scale)

def PublicMetadata (s : State) : Prop :=
  (∀ i < s.accounts.size, AccountHistory s.book (account s i)) ∧
  (∀ i < s.requests.size, AccountHistory s.book (request s i).account)

instance (s : State) : Decidable (PublicMetadata s) := by
  unfold PublicMetadata AccountHistory
  infer_instance

theorem bookProgress_refl (b : Book) : BookProgress b b := ⟨le_rfl, fun _ => le_rfl⟩

theorem bookProgress_trans {a b c : Book} (hab : BookProgress a b) (hbc : BookProgress b c) :
    BookProgress a c := by
  refine ⟨hab.1.trans hbc.1, ?_⟩
  intro he
  have hab' : a.epoch = b.epoch := by have := hab.1; have := hbc.1; omega
  have hbc' : b.epoch = c.epoch := by omega
  exact (hab.2 hab').trans (hbc.2 hbc')

theorem accountHistory_progress {a : Account} {b next : Book}
    (h : AccountHistory b a) (hp : BookProgress b next) : AccountHistory next a := by
  refine ⟨h.1.trans hp.1, ?_⟩
  intro he
  have hb : a.epoch = b.epoch := by have := h.1; have := hp.1; omega
  exact (h.2 hb).trans (hp.2 (by omega))

theorem trimLoss_progress (b : Book) (available : Nat) : BookProgress b (trimLoss b available) := by
  unfold trimLoss
  split <;> exact bookProgress_refl b

theorem rescale_progress (n : Nat) (b : Book) (limit : Nat) :
    BookProgress b (rescale n b limit) := by
  induction n generalizing b with
  | zero => exact bookProgress_refl b
  | succ n ih =>
    unfold rescale
    split
    · apply bookProgress_trans (b := { b with
        total := b.total >>> 64
        index := b.index >>> 64
        scale := b.scale+64 })
      · exact ⟨le_rfl, fun _ => by dsimp only; omega⟩
      · exact ih _
    · exact bookProgress_refl b

theorem rescale_epoch (n : Nat) (b : Book) (limit : Nat) : (rescale n b limit).epoch = b.epoch := by
  induction n generalizing b with
  | zero => rfl
  | succ n ih =>
    simp only [rescale]
    split
    · exact ih _
    · rfl

theorem rescale_scale_le (n : Nat) (b : Book) (limit : Nat) : b.scale ≤ (rescale n b limit).scale := by
  exact (rescale_progress n b limit).2 (rescale_epoch n b limit).symm

def allocationUpdate (b : Book) (reward fee minted outside : Nat) : Book :=
  { b with
    source := b.source+reward
    protocol := b.protocol+fee
    total := b.total+minted
    index := b.index+(if outside != 0 then minted*ray/outside else 0) }

theorem allocationUpdate_epoch (b : Book) (reward fee minted outside : Nat) :
    (allocationUpdate b reward fee minted outside).epoch = b.epoch := rfl

theorem allocationUpdate_scale (b : Book) (reward fee minted outside : Nat) :
    (allocationUpdate b reward fee minted outside).scale = b.scale := rfl

theorem finishAllocation_factored (b : Book) (v : AllocationInput) (added before : Nat) :
    finishAllocation b v added before =
      let released := min (added*v.equity/v.held) (v.basis-v.required)
      let untaxed := released*v.held/v.equity
      let feeShares := (added-untaxed)*v.fee/10000
      let rewardShares := added-feeShares
      let value := v.equity*rewardShares/v.held
      let selfValue := value*v.funded/v.supply
      let outsideSupply := v.supply-v.funded
      let outsideValue := value-selfValue
      let denominator := before+selfValue+1
      let limit := 2^160*denominator/max denominator outsideValue
      let scaled := rescale 4 b limit
      let minted := outsideValue*(scaled.total+1)/denominator
      allocationUpdate scaled rewardShares feeShares minted outsideSupply := by
  rfl


theorem allocationUpdate_preserves_progress (previous b : Book)
    (reward fee minted outside : Nat) (h : BookProgress previous b) :
    BookProgress previous (allocationUpdate b reward fee minted outside) := by
  simpa only [BookProgress, allocationUpdate_epoch, allocationUpdate_scale] using h

theorem finishAllocation_progress (b : Book) (v : AllocationInput) (added before : Nat) :
    BookProgress b (finishAllocation b v added before) := by
  rw [finishAllocation_factored]
  dsimp only
  apply allocationUpdate_preserves_progress
  exact rescale_progress 4 b _

theorem writeOff_progress (b : Book) :
    BookProgress b { b with total := 0, index := 0, scale := 0, epoch := b.epoch+1 } := by
  refine ⟨by dsimp only; omega, ?_⟩
  intro he
  dsimp only at he
  omega

theorem allocate_progress (b : Book) (v : AllocationInput) : BookProgress b (allocate b v) := by
  let trimmed := trimLoss b (allocationAvailable v)
  let added := allocationAvailable v - (trimmed.source+trimmed.protocol)
  let allocating := v.held != 0 && v.supply != 0 && added != 0
  let before := (if v.held == 0 then 0 else v.equity * trimmed.source / v.held) + v.fundedValue
  let base := if trimmed.total != 0 && before == 0 then
    { trimmed with total := 0, index := 0, scale := 0, epoch := trimmed.epoch+1 } else trimmed
  have ht : BookProgress b trimmed := trimLoss_progress b _
  have hb : BookProgress b base := by
    dsimp only [base]
    split
    · exact bookProgress_trans ht (writeOff_progress trimmed)
    · exact ht
  change BookProgress b (if trimmed.total == 0 && !allocating then trimmed
    else if !allocating then base else finishAllocation base v added before)
  split
  · exact ht
  · split
    · exact hb
    · exact bookProgress_trans hb (finishAllocation_progress base v added before)

theorem metadata_bookProgress (s : State) (next : Book) (h : PublicMetadata s)
    (hp : BookProgress s.book next) : PublicMetadata { s with book := next } := by
  constructor
  · intro i hi
    exact accountHistory_progress (h.1 i hi) hp
  · intro i hi
    exact accountHistory_progress (h.2 i hi) hp

theorem metadata_setAccount (s : State) (i : Nat) (value : Account) (h : PublicMetadata s)
    (hv : AccountHistory s.book value) : PublicMetadata (setAccount s i value) := by
  constructor
  · intro j hj
    have hj' : j < s.accounts.size := by
      simpa only [setAccount, Array.set!_eq_setIfInBounds, Array.size_setIfInBounds] using hj
    change AccountHistory s.book (account (setAccount s i value) j)
    rw [account_setAccount_all]
    split
    · exact hv
    · exact h.1 j hj'
  · intro j hj
    exact h.2 j hj

theorem settle_history (b : Book) (a : Account) (weight : Nat) :
    AccountHistory b (settle b a weight) := ⟨le_rfl, fun _ => le_rfl⟩

theorem metadata_settleOwner (s : State) (i : Nat) (h : PublicMetadata s) :
    PublicMetadata (settleOwner s i) := by
  unfold settleOwner
  split
  · exact h
  · exact metadata_setAccount s i _ h (settle_history s.book (account s i) (wallet s i))

theorem metadata_genesis : PublicMetadata ({} : State) := by decide

end Juicer.PublicCalls

