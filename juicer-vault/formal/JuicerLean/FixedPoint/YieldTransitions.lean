import JuicerLean.FixedPoint.Rounding

namespace Juicer.Runtime

theorem proportional_le (amount part whole : ℕ) (h : part ≤ whole) :
    amount * part / whole ≤ amount := by
  calc _ ≤ amount * whole / whole := Nat.div_le_div_right (Nat.mul_le_mul_left _ h)
       _ ≤ amount := Nat.div_le_of_le_mul (by rw [Nat.mul_comm])

theorem proportional_sum_le (amount left right whole : ℕ) (h : left + right ≤ whole) :
    amount * left / whole + amount * right / whole ≤ amount := by
  calc _ ≤ (amount * left + amount * right) / whole := Nat.add_div_le_add_div _ _ _
       _ = amount * (left + right) / whole := by rw [Nat.mul_add]
       _ ≤ amount := proportional_le _ _ _ h

theorem settle_idempotent (b : Book) (a : Account) (w : ℕ) :
    settle b (settle b a w) w = settle b a w := by
  simp [settle, accountUnits, ceilShift, ceilDiv]

theorem old_epoch_forgets_units (b : Book) (a : Account) (w : ℕ) (h : a.epoch ≠ b.epoch) :
    accountUnits b a w = min b.total (w * b.index / ray) := by
  simp [accountUnits, h]

theorem rescale_assets (n : ℕ) (b : Book) (limit : ℕ) :
    (rescale n b limit).source = b.source ∧ (rescale n b limit).protocol = b.protocol := by
  induction n generalizing b with
  | zero => simp [rescale]
  | succ n ih => simp only [rescale]; split <;> simp_all

theorem shift_refines (u k : ℕ) :
    (u >>> k) * 2 ^ k ≤ u ∧ u < ((u >>> k) + 1) * 2 ^ k := by
  simpa [Nat.shiftRight_eq_div_pow] using mulDiv_bounds u 1 (2 ^ k) (by positivity)

theorem trimLoss_reserved (b : Book) (a : ℕ) :
    (trimLoss b a).source + (trimLoss b a).protocol = min a (b.source + b.protocol) := by
  unfold trimLoss
  split
  · have h := proportional_le a b.source (b.source + b.protocol) (by omega)
    rw [Nat.mul_comm b.source a]
    simp only
    omega
  · simp_all

theorem trimLoss_junior (b : Book) (a : ℕ) :
    (trimLoss b a).source ≤ b.source ∧ (trimLoss b a).source + (trimLoss b a).protocol ≤ a := by
  have hr := trimLoss_reserved b a
  constructor
  · unfold trimLoss
    split
    · exact proportional_le _ _ _ (by omega)
    · exact le_rfl
  · omega

theorem finishAllocation_reserved (b : Book) (v : AllocationInput) (a before : ℕ) (hf : v.fee ≤ 10000) :
    (finishAllocation b v a before).source + (finishAllocation b v a before).protocol = b.source + b.protocol + a := by
  unfold finishAllocation
  have h := proportional_le (a - min (a * v.equity / v.held) (v.basis - v.required) * v.held / v.equity) v.fee 10000 hf
  have hf' := h.trans (Nat.sub_le _ _)
  have ha := rescale_assets 4 b
  simp only at h ⊢
  rw [(ha _).1, (ha _).2]
  omega

theorem allocate_reserved_bounded (b : Book) (v : AllocationInput) (hf : v.fee ≤ 10000) :
    (allocate b v).source + (allocate b v).protocol ≤ allocationAvailable v := by
  have h := (trimLoss_junior b (allocationAvailable v)).2
  simp only [allocate]
  split_ifs
  all_goals try rw [finishAllocation_reserved _ _ _ _ hf]
  all_goals try dsimp only
  all_goals omega

theorem allocation_respects_Main_backing (b : Book) (v : AllocationInput) (hf : v.fee ≤ 10000) :
    (allocate b v).source + (allocate b v).protocol ≤ v.held := by
  have h := allocate_reserved_bounded b v hf
  have hav : allocationAvailable v ≤ v.held := by
    unfold allocationAvailable
    split
    · rw [Nat.mul_comm]
      exact proportional_le _ _ _ (Nat.sub_le _ _)
    · exact Nat.zero_le _
  omega

theorem allocated_value_is_junior (b : Book) (v : AllocationInput) (hf : v.fee ≤ 10000) :
    v.equity * ((allocate b v).source + (allocate b v).protocol) / v.held ≤ v.equity - v.required := by
  have h := allocate_reserved_bounded b v hf
  unfold allocationAvailable at h
  split at h
  · rename_i he
    have hq := Nat.div_mul_le_self ((v.equity - v.required) * v.held) v.equity
    have hm := Nat.mul_le_mul_left v.equity h
    apply Nat.div_le_of_le_mul
    nlinarith
  · have hz : (allocate b v).source + (allocate b v).protocol = 0 := by omega
    simp [hz]

theorem allocation_retains_Main_backing (b : Book) (v : AllocationInput) (hf : v.fee ≤ 10000) :
    min v.required v.equity ≤
      v.equity - v.equity * ((allocate b v).source + (allocate b v).protocol) / v.held := by
  have h := allocated_value_is_junior b v hf
  omega

theorem startExit_source_conserved (b : Book) (o r : Account) (w s f : ℕ) :
    (startExit b o r w s f).book.source + (startExit b o r w s f).reward = b.source := by
  simp only [startExit]
  apply Nat.sub_add_cancel
  exact proportional_le _ _ _ (min_le_left _ _)

theorem startExit_fee_conserved (b : Book) (o r : Account) (w s f : ℕ) :
    (startExit b o r w s f).book.protocol + (startExit b o r w s f).fee = b.protocol := by
  have hr : (startExit b o r w s f).reward ≤ b.source := by
    simp only [startExit]; exact proportional_le _ _ _ (min_le_left _ _)
  change b.protocol - (startExit b o r w s f).fee + (startExit b o r w s f).fee = b.protocol
  apply Nat.sub_add_cancel
  simp only [startExit]
  split
  · exact Nat.zero_le _
  · exact proportional_le _ _ _ hr

theorem splitHarvest_conserved (c h r p fee : ℕ) (hr : r + p ≤ h) (hf : fee ≤ 10000) :
    (splitHarvest c h r p fee).1 + (splitHarvest c h r p fee).2.1 +
      (splitHarvest c h r p fee).2.2 = c := by
  have ha := proportional_sum_le c r p h hr
  have hb := proportional_le (c - c * r / h - c * p / h) fee 10000 hf
  simp only [splitHarvest]
  omega

def indexedAccrual (minted supply weight : ℕ) : ℕ := weight * (minted * ray / supply) / ray

theorem indexedAccrual_bound (m s w : ℕ) : indexedAccrual m s w * s ≤ m * w := by
  have hi := Nat.div_mul_le_self (m * ray) s
  have ha := Nat.div_mul_le_self (w * (m * ray / s)) ray
  have h1 := Nat.mul_le_mul_left w hi
  have h2 := Nat.mul_le_mul_right s ha
  dsimp [indexedAccrual]
  have hr : 0 < ray := by norm_num [ray]
  nlinarith

theorem indexedAccrual_pair (m s a b : ℕ) (hs : 0 < s) (hw : a + b ≤ s) :
    indexedAccrual m s a + indexedAccrual m s b ≤ m := by
  have h1 := indexedAccrual_bound m s a
  have h2 := indexedAccrual_bound m s b
  have h3 := Nat.mul_le_mul_left m hw
  nlinarith

theorem allocation_pair_no_overclaim (total a b m s wa wb : ℕ)
    (h : a + b ≤ total) (hs : 0 < s) (hw : wa + wb ≤ s) :
    (a + indexedAccrual m s wa) + (b + indexedAccrual m s wb) ≤ total + m := by
  have := indexedAccrual_pair m s wa wb hs hw
  omega

theorem rescale_pair_no_overclaim (total a b k : ℕ) (h : a + b ≤ total) :
    (a >>> k) + (b >>> k) ≤ total >>> k := by
  simp only [Nat.shiftRight_eq_div_pow]
  calc _ ≤ (a + b) / 2 ^ k := Nat.add_div_le_add_div _ _ _
       _ ≤ _ := Nat.div_le_div_right h

theorem transfer_pair_conserved (a b x : ℕ) (h : x ≤ a) : (a - x) + (b + x) = a + b := by omega

theorem exit_pair_no_overclaim (total a b x : ℕ) (h : a + b ≤ total) (hx : x ≤ a) :
    (a - x) + b ≤ total - x := by omega

theorem indexedAccrual_sum_bound (m s : ℕ) (weights : List ℕ) :
    ((weights.map (indexedAccrual m s)).sum) * s ≤ m * weights.sum := by
  induction weights with
  | nil => simp
  | cons w rest ih =>
    have h := indexedAccrual_bound m s w
    simp only [List.map_cons, List.sum_cons]
    nlinarith

theorem indexedAccrual_all_holders (m s : ℕ) (weights : List ℕ)
    (hs : 0 < s) (hw : weights.sum ≤ s) : (weights.map (indexedAccrual m s)).sum ≤ m := by
  have h := indexedAccrual_sum_bound m s weights
  have h1 := Nat.mul_le_mul_left m hw
  nlinarith

theorem lazy_index_rescale_error (current previous k : ℕ) (h : previous ≤ current) :
    (current - previous) / 2 ^ k ≤ (current >>> k) - (previous >>> k) ∧
    (current >>> k) - (previous >>> k) ≤ ceilDiv (current - previous) (2 ^ k) := by
  simpa [Nat.shiftRight_eq_div_pow, Nat.sub_sub_self h] using
    transfer_debit_refines 1 (2 ^ k) current (current - previous) (by positivity) (Nat.sub_le _ _)

structure Ownership where
  total : ℕ
  first : ℕ
  rest : ℕ
  deriving Repr

def Ownership.valid (o : Ownership) : Prop := o.first + o.rest ≤ o.total

inductive Ownership.Step : Ownership → Ownership → Prop
  | allocate (o : Ownership) (m s a b : ℕ) (hs : 0 < s) (hw : a + b ≤ s) :
      Step o ⟨o.total + m, o.first + indexedAccrual m s a, o.rest + indexedAccrual m s b⟩
  | rescale (o : Ownership) (k : ℕ) :
      Step o ⟨o.total >>> k, o.first >>> k, o.rest >>> k⟩
  | transfer (o : Ownership) (x : ℕ) (h : x ≤ o.first) :
      Step o ⟨o.total, o.first - x, o.rest + x⟩
  | exit (o : Ownership) (x : ℕ) (h : x ≤ o.first) :
      Step o ⟨o.total - x, o.first - x, o.rest⟩
  | writeOff (o : Ownership) : Step o ⟨0, 0, 0⟩

theorem ownership_step_preserves (a b : Ownership) (h : a.valid) (step : a.Step b) : b.valid := by
  cases step with
  | allocate m s a b hs hw => exact allocation_pair_no_overclaim _ _ _ _ _ _ _ h hs hw
  | rescale k => exact rescale_pair_no_overclaim _ _ _ _ h
  | transfer x hx =>
    change (a.first - x) + (a.rest + x) ≤ a.total
    rw [transfer_pair_conserved _ _ _ hx]
    exact h
  | exit x hx => exact exit_pair_no_overclaim _ _ _ _ h hx
  | writeOff => simp [Ownership.valid]

theorem ownership_trace_preserves (a b : Ownership) (h : a.valid)
    (steps : Relation.ReflTransGen Ownership.Step a b) : b.valid := by
  induction steps with
  | refl => exact h
  | tail steps step ih => exact ownership_step_preserves _ _ ih step

end Juicer.Runtime
