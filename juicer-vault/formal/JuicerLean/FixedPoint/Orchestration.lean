import JuicerLean.FixedPoint.PolicyQueue

namespace Juicer.Runtime

structure SourceBatch where
  amount : ℕ
  cost : ℕ
  total : ℕ
  weight : ℕ := 0
  credited : ℕ := 0
  charged : ℕ := 0
  cursor : ℕ := 0
  tail : ℕ
  pending : List ℕ
  laterCash : ℕ := 0
  laterCost : ℕ := 0
  laterClaims : List ℕ := []
  deriving Repr

def SourceBatch.valid (b : SourceBatch) : Prop :=
  0 < b.amount + b.cost ∧ b.amount + b.cost ≤ b.total ∧
  b.weight + b.pending.sum = b.total ∧ b.cursor + b.pending.length = b.tail ∧
  b.credited = batchCash b.amount b.cost b.total b.weight ∧
  b.credited + b.charged = batchReduction b.amount b.cost b.total b.weight

def SourceBatch.begin (amount cost : ℕ) (weights : List ℕ) : SourceBatch :=
  { amount, cost, total := weights.sum, tail := weights.length, pending := weights }

theorem source_batch_begin_valid (a c : ℕ) (weights : List ℕ)
    (hp : 0 < a + c) (hb : a + c ≤ weights.sum) : (SourceBatch.begin a c weights).valid := by
  simp [SourceBatch.begin, SourceBatch.valid, batchCash, batchReduction, hp, hb]

def SourceBatch.one (b : SourceBatch) : SourceBatch :=
  match b.pending with
  | [] => b
  | w :: rest =>
    let part := batchSegment b.amount b.cost b.total b.weight w
    { b with
      weight := b.weight + w
      credited := b.credited + part.1
      charged := b.charged + part.2
      cursor := b.cursor + 1
      pending := rest }

def SourceBatch.run : ℕ → SourceBatch → SourceBatch
  | 0, b => b
  | n + 1, b => SourceBatch.run n b.one

def SourceBatch.receive (b : SourceBatch) (cash cost : ℕ) : SourceBatch :=
  { b with laterCash := b.laterCash + cash, laterCost := b.laterCost + cost }

def SourceBatch.enqueue (b : SourceBatch) (claim : ℕ) : SourceBatch :=
  { b with laterClaims := b.laterClaims ++ [claim] }

theorem source_batch_one_preserves (b : SourceBatch) (h : b.valid) : b.one.valid := by
  rcases h with ⟨hp, hb, hw, hi, hc, hd⟩
  cases he : b.pending with
  | nil =>
    simp only [SourceBatch.one, he]
    exact ⟨hp, hb, hw, hi, hc, hd⟩
  | cons w rest =>
    have hpart := batchSegment_conserved b.amount b.cost b.total b.weight w hp
    have hmono : batchReduction b.amount b.cost b.total b.weight ≤
        batchReduction b.amount b.cost b.total (b.weight + w) :=
      Nat.div_le_div_right (Nat.mul_le_mul_left _ (by omega))
    have hcash : batchCash b.amount b.cost b.total b.weight ≤
        batchCash b.amount b.cost b.total (b.weight + w) :=
      Nat.div_le_div_right (Nat.mul_le_mul_right _ hmono)
    simp only [SourceBatch.one, he, SourceBatch.valid, List.sum_cons, List.length_cons] at *
    refine ⟨hp, hb, by omega, by omega, ?_, ?_⟩
    · simp only [batchSegment]
      omega
    · omega

theorem source_batch_run_preserves (b : SourceBatch) (n : ℕ) (h : b.valid) :
    (b.run n).valid := by
  induction n generalizing b with
  | zero => exact h
  | succ n ih => exact ih b.one (source_batch_one_preserves b h)

theorem source_batch_run_pending (b : SourceBatch) (n : ℕ) :
    (b.run n).pending = b.pending.drop n := by
  induction n generalizing b with
  | zero => simp [SourceBatch.run]
  | succ n ih =>
    rw [SourceBatch.run, ih]
    cases he : b.pending <;> simp [SourceBatch.one, he]

theorem source_batch_run_frame (b : SourceBatch) (n : ℕ) :
    (b.run n).amount = b.amount ∧ (b.run n).cost = b.cost ∧ (b.run n).total = b.total ∧
    (b.run n).tail = b.tail ∧ (b.run n).laterCash = b.laterCash ∧
    (b.run n).laterCost = b.laterCost ∧ (b.run n).laterClaims = b.laterClaims := by
  induction n generalizing b with
  | zero => simp [SourceBatch.run]
  | succ n ih =>
    have h := ih b.one
    cases he : b.pending <;> simpa [SourceBatch.run, SourceBatch.one, he] using h

theorem source_batch_run_cursor (b : SourceBatch) (n : ℕ) (h : b.valid) :
    (b.run n).cursor = b.cursor + min n b.pending.length := by
  have h' := (source_batch_run_preserves b n h).2.2.2.1
  rw [source_batch_run_pending, List.length_drop, (source_batch_run_frame b n).2.2.2.1] at h'
  have hi := h.2.2.2.1
  omega

theorem source_batch_call_bounded (b : SourceBatch) (h : b.valid) :
    (b.run 64).cursor ≤ b.cursor + 64 := by
  rw [source_batch_run_cursor b 64 h]
  omega

theorem source_batch_resume (b : SourceBatch) (n m : ℕ) :
    (b.run n).run m = b.run (n + m) := by
  induction n generalizing b with
  | zero => simp [SourceBatch.run]
  | succ n ih => simpa [SourceBatch.run, Nat.succ_add] using ih b.one

theorem source_batch_complete (b : SourceBatch) (h : b.valid) (he : b.pending = []) :
    b.credited = b.amount ∧ b.charged = b.cost ∧ b.cursor = b.tail := by
  rcases h with ⟨hp, hb, hw, hi, hc, hd⟩
  have ht : 0 < b.total := by omega
  simp only [he, List.sum_nil, List.length_nil, Nat.add_zero] at hw hi
  rw [hw] at hc hd
  simp [batchCash, batchReduction, ht, hp] at hc hd
  omega

theorem source_batch_bounded_totals (b : SourceBatch) (h : b.valid) :
    b.credited ≤ b.amount ∧ b.charged ≤ b.cost := by
  let done := b.run b.pending.length
  have hd : done.valid := source_batch_run_preserves b _ h
  have he : done.pending = [] := by simp [done, source_batch_run_pending]
  have hc := source_batch_complete done hd he
  have monotone : ∀ (n : ℕ) (x : SourceBatch), x.credited ≤ (x.run n).credited ∧ x.charged ≤ (x.run n).charged := by
    intro n
    induction n with
    | zero => intro x; simp [SourceBatch.run]
    | succ n ih =>
      intro x
      have hr := ih x.one
      cases hx : x.pending <;> simp only [SourceBatch.run, SourceBatch.one, hx] at * <;> omega
  have hm := monotone b.pending.length b
  have hf := source_batch_run_frame b b.pending.length
  change b.credited ≤ done.credited ∧ b.charged ≤ done.charged at hm
  rw [hc.1, hc.2.1] at hm
  simpa only [done, hf.1, hf.2.1] using hm

theorem source_batch_receive_preserves (b : SourceBatch) (cash cost : ℕ) (h : b.valid) :
    (b.receive cash cost).valid := h

theorem source_batch_enqueue_preserves (b : SourceBatch) (claim : ℕ) (h : b.valid) :
    (b.enqueue claim).valid := h

theorem source_batch_receipts_stay_unallocated (b : SourceBatch) (h : b.valid) :
    b.amount + b.laterCash - b.credited ≥ b.laterCash ∧
    b.cost + b.laterCost - b.charged ≥ b.laterCost := by
  have := source_batch_bounded_totals b h
  omega

def retryAmount (spendable amount paid reduced quantum : ℕ) : ℕ :=
  if paid == amount && reduced < amount && paid < spendable then
    min (spendable - paid) (amount - reduced + quantum) else 0

theorem retry_uses_remaining_cash (s a p d q : ℕ) : retryAmount s a p d q ≤ s - p := by
  unfold retryAmount
  split
  · exact min_le_left _ _
  · omega

theorem partial_payment_not_retried (s a p d q : ℕ) (h : p ≠ a) : retryAmount s a p d q = 0 := by
  simp [retryAmount, h]

theorem sufficient_reduction_not_retried (s a p d q : ℕ) (h : a ≤ d) : retryAmount s a p d q = 0 := by
  simp [retryAmount, Nat.not_lt.mpr h]

theorem retry_total_within_cash (s a p d q extra : ℕ) (hp : p ≤ s)
    (he : extra ≤ retryAmount s a p d q) : p + extra ≤ s := by
  have := retry_uses_remaining_cash s a p d q
  omega

theorem two_payments_conserve_cash (a p bc mid bd md q a' p' ac ad : ℕ)
    (h : payValid a p bc mid bd md q) (h' : payValid a' p' mid ac md ad q) :
    ac + (p + p') = bc ∧ ad ≤ bd := by
  rcases h with ⟨_, hc, hd, _⟩
  rcases h' with ⟨_, hc', hd', _⟩
  omega

theorem two_payments_error_bound (a p bc mid bd md q a' p' ac ad : ℕ)
    (h : payValid a p bc mid bd md q) (h' : payValid a' p' mid ac md ad q) :
    bd - ad ≤ p + p' + 2 * q ∧ p + p' ≤ bd - ad + 2 * q := by
  have h1 := accepted_pay_bounded_error _ _ _ _ _ _ _ h
  have h2 := accepted_pay_bounded_error _ _ _ _ _ _ _ h'
  have hd := h.2.2.1
  have hd' := h'.2.2.1
  omega

end Juicer.Runtime
