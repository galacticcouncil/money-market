import JuicerLean.FixedPoint.PublicMetadataProofs
import JuicerLean.FixedPoint.RoundingResidue

set_option maxRecDepth 4000
set_option maxHeartbeats 500000

namespace Juicer.PublicCalls
open Runtime

def normalizedLiability (b : Book) (accounts : List (Account × Nat)) : Nat :=
  lazyLiability b.index (accounts.map fun p => normalizeAccount b p.1 p.2)

def NormalizedSafe (b : Book) (accounts : List (Account × Nat)) : Prop :=
  normalizedLiability b accounts < b.total*ray+ray

def HistoriesValid (b : Book) (accounts : List (Account × Nat)) : Prop :=
  ∀ p ∈ accounts, AccountHistory b p.1

theorem normalizedLedger_valid (b : Book) (accounts : List (Account × Nat)) :
    (normalizeLedger b accounts (normalizedLiability b accounts-b.total*ray)).valid := by
  constructor
  · intro a ha
    obtain ⟨p, _, rfl⟩ := List.mem_map.mp ha
    exact normalized_index_bound { book := b } p.1 p.2
  · change normalizedLiability b accounts ≤ b.total*ray+(normalizedLiability b accounts-b.total*ray)
    omega

theorem normalized_slack_lt (b : Book) (accounts : List (Account × Nat)) (h : NormalizedSafe b accounts) :
    normalizedLiability b accounts-b.total*ray < ray := by
  have hr : 0 < ray := by norm_num [ray]
  unfold NormalizedSafe at h
  omega

theorem normalized_rescale_safe (b : Book) (accounts : List (Account × Nat)) (k : Nat)
    (history : HistoriesValid b accounts) (h : NormalizedSafe b accounts) :
    NormalizedSafe { b with total := b.total >>> k, index := b.index >>> k, scale := b.scale+k } accounts := by
  let slack := normalizedLiability b accounts-b.total*ray
  let ledger := normalizeLedger b accounts slack
  have hv : ledger.valid := normalizedLedger_valid b accounts
  have hs : ledger.slack < ray := normalized_slack_lt b accounts h
  have hr := lazy_rescale_preserves ledger k hv
  have he := rescale_slack_lt_precision ledger k hs
  have hn := normalized_ledger_rescale b accounts slack k (fun p hp => (history p hp).2)
  change normalizeLedger _ _ _ = ledger.rescale k at hn
  rw [← hn] at hr
  have hl := hr.2
  change normalizedLiability { b with total := b.total >>> k, index := b.index >>> k, scale := b.scale+k }
    accounts ≤ (b.total >>> k)*ray+(b.total % 2^k*ray+slack)/2^k at hl
  change (b.total % 2^k*ray+slack)/2^k < ray at he
  change normalizedLiability { b with total := b.total >>> k, index := b.index >>> k, scale := b.scale+k }
    accounts < (b.total >>> k)*ray+ray
  omega

theorem histories_progress (b next : Book) (accounts : List (Account × Nat))
    (h : HistoriesValid b accounts) (hp : BookProgress b next) : HistoriesValid next accounts := by
  intro p hm
  exact accountHistory_progress (h p hm) hp

theorem normalized_rescaleN_safe (n : Nat) (b : Book) (accounts : List (Account × Nat)) (limit : Nat)
    (history : HistoriesValid b accounts) (h : NormalizedSafe b accounts) :
    NormalizedSafe (rescale n b limit) accounts := by
  induction n generalizing b with
  | zero => exact h
  | succ n ih =>
    simp only [rescale]
    split
    · apply ih
      · apply histories_progress b _ accounts history
        exact ⟨le_rfl, fun _ => by dsimp only; omega⟩
      · exact normalized_rescale_safe b accounts 64 history h
    · exact h

theorem normalized_numerator_growth (b : Book) (a : Account) (weight minted delta : Nat) :
    (normalizeAccount { b with total := b.total+minted, index := b.index+delta } a weight).numerator
        (b.index+delta) ≤ (normalizeAccount b a weight).numerator b.index+weight*delta := by
  have hi := normalized_index_change b a weight minted delta
  have hb := normalized_index_bound { book := b } a weight
  change (normalizeAccount b a weight).index ≤ b.index at hb
  have hd : b.index+delta-
      (normalizeAccount { b with total := b.total+minted, index := b.index+delta } a weight).index ≤
        b.index-(normalizeAccount b a weight).index+delta := by omega
  have hm := Nat.mul_le_mul_left weight hd
  rw [Nat.mul_add] at hm
  change (normalizeAccount b a weight).units*ray+
    weight*(b.index+delta-(normalizeAccount { b with total := b.total+minted, index := b.index+delta } a weight).index) ≤
    (normalizeAccount b a weight).units*ray+weight*(b.index-(normalizeAccount b a weight).index)+weight*delta
  omega

theorem normalizedLiability_growth (b : Book) (accounts : List (Account × Nat)) (minted delta : Nat) :
    normalizedLiability { b with total := b.total+minted, index := b.index+delta } accounts ≤
      normalizedLiability b accounts+(accounts.map Prod.snd).sum*delta := by
  induction accounts with
  | nil => simp [normalizedLiability,lazyLiability]
  | cons p rest ih =>
    have hp := normalized_numerator_growth b p.1 p.2 minted delta
    simp only [normalizedLiability, lazyLiability, List.map_cons, List.sum_cons] at ih ⊢
    nlinarith

theorem allocationUpdate_safe (b : Book) (accounts : List (Account × Nat))
    (reward fee minted outside : Nat) (h : NormalizedSafe b accounts)
    (hw : (accounts.map Prod.snd).sum ≤ outside) :
    NormalizedSafe (allocationUpdate b reward fee minted outside) accounts := by
  have hd : (if outside != 0 then minted*ray/outside else 0) = minted*ray/outside := by
    by_cases hz : outside = 0
    · simp [hz]
    · simp [hz]
  have hn := normalizedLiability_growth b accounts minted (minted*ray/outside)
  have hm := Nat.mul_le_mul_right (minted*ray/outside) hw
  have hdiv := Nat.div_mul_le_self (minted*ray) outside
  rw [Nat.mul_comm outside] at hm
  have ht : (accounts.map Prod.snd).sum*(minted*ray/outside) ≤ minted*ray := hm.trans hdiv
  change normalizedLiability (allocationUpdate b reward fee minted outside) accounts <
    (b.total+minted)*ray+ray
  have heq : normalizedLiability (allocationUpdate b reward fee minted outside) accounts =
      normalizedLiability { b with total := b.total+minted, index := b.index+minted*ray/outside } accounts := by
    simp only [normalizedLiability, allocationUpdate, normalizeAccount, hd]
  rw [heq, Nat.add_mul]
  unfold NormalizedSafe at h
  omega

theorem finishAllocation_safe (b : Book) (v : AllocationInput) (accounts : List (Account × Nat))
    (added before : Nat) (history : HistoriesValid b accounts) (h : NormalizedSafe b accounts)
    (hw : (accounts.map Prod.snd).sum ≤ v.supply-v.funded) :
    NormalizedSafe (finishAllocation b v added before) accounts := by
  rw [finishAllocation_factored]
  dsimp only
  apply allocationUpdate_safe
  · exact normalized_rescaleN_safe 4 b accounts _ history h
  · exact hw

theorem writeOff_safe (b : Book) (accounts : List (Account × Nat))
    (history : HistoriesValid b accounts) :
    NormalizedSafe { b with
      total := 0
      index := 0
      scale := 0
      epoch := b.epoch+1
      sourceLoss := 0
      protocolLoss := 0 } accounts := by
  have hm : (accounts.map fun p =>
      normalizeAccount { b with
        total := 0
        index := 0
        scale := 0
        epoch := b.epoch+1
        sourceLoss := 0
        protocolLoss := 0 } p.1 p.2) =
      accounts.map fun p => (⟨0,0,p.2⟩ : LazyAccount ray) := by
    apply List.map_congr_left
    intro p hp
    exact normalized_writeOff b p.1 p.2 (history p hp).1
  unfold NormalizedSafe normalizedLiability
  rw [hm]
  simp [lazyLiability, LazyAccount.numerator, Function.comp_def, ray]

theorem trimLoss_safe (b : Book) (accounts : List (Account × Nat)) (available : Nat)
    (h : NormalizedSafe b accounts) : NormalizedSafe (trimLoss b available) accounts := by
  unfold trimLoss
  split <;> exact h

theorem restoreLoss_safe (b : Book) (accounts : List (Account × Nat)) (added : Nat)
    (h : NormalizedSafe b accounts) : NormalizedSafe (restoreLoss b added).1 accounts := by
  simp only [restoreLoss]
  split <;> exact h

theorem allocate_safe (b : Book) (v : AllocationInput) (accounts : List (Account × Nat))
    (history : HistoriesValid b accounts) (h : NormalizedSafe b accounts)
    (hw : (accounts.map Prod.snd).sum ≤ v.supply-v.funded) :
    NormalizedSafe (allocate b v) accounts := by
  let trimmed := trimLoss b (allocationAvailable v)
  let added := allocationAvailable v-(trimmed.source+trimmed.protocol)
  let allocating := v.held != 0 && v.supply != 0 && added != 0
  let before := (if v.held == 0 then 0 else v.equity*trimmed.source/v.held)+v.fundedValue
  let base := if trimmed.total != 0 && before == 0 then
    { trimmed with
      total := 0
      index := 0
      scale := 0
      epoch := trimmed.epoch+1
      sourceLoss := 0
      protocolLoss := 0 } else trimmed
  let restored := restoreLoss base added
  let allocatingAfter := v.held != 0 && v.supply != 0 && restored.2 != 0
  let beforeAfter := (if v.held == 0 then 0 else v.equity*restored.1.source/v.held)+v.fundedValue
  have htrim : NormalizedSafe trimmed accounts := trimLoss_safe b accounts _ h
  have htHist : HistoriesValid trimmed accounts :=
    histories_progress b trimmed accounts history (trimLoss_progress b _)
  have hb : NormalizedSafe base accounts := by
    dsimp only [base]
    split
    · exact writeOff_safe trimmed accounts htHist
    · exact htrim
  have hbHist : HistoriesValid base accounts := by
    dsimp only [base]
    split
    · exact histories_progress trimmed _ accounts htHist (writeOff_progress trimmed)
    · exact htHist
  have hr : NormalizedSafe restored.1 accounts := restoreLoss_safe base accounts added hb
  have hrHist : HistoriesValid restored.1 accounts :=
    histories_progress base restored.1 accounts hbHist (restoreLoss_progress base added)
  change NormalizedSafe (if trimmed.total == 0 && !allocating then trimmed
    else if !allocatingAfter then restored.1
    else finishAllocation restored.1 v restored.2 beforeAfter) accounts
  split
  · exact htrim
  · split
    · exact hr
    · exact finishAllocation_safe restored.1 v accounts restored.2 beforeAfter hrHist hr hw

end Juicer.PublicCalls

