import JuicerLean.FixedPoint.PolicyQueue

namespace Juicer.Runtime

def roundingQuantum (index : ℕ) : ℕ := 2 * ceilDiv index ray

def exactReceipt (before after amount : ℕ) : Prop := after = before + amount

def exactPayment (before after receiverBefore receiverAfter amount : ℕ) : Prop :=
  after + amount = before ∧ receiverAfter = receiverBefore + amount

theorem exactReceipt_no_shortfall (b a amount : ℕ) (h : exactReceipt b a amount) : a - b = amount := by
  unfold exactReceipt at h
  omega

theorem exactPayment_conserved (b a rb ra amount : ℕ) (h : exactPayment b a rb ra amount) :
    a + ra = b + rb := by
  rcases h with ⟨h1, h2⟩
  omega

theorem zero_debt_has_no_pending_HF_division (p : Intent) (input output price coll lt hf : ℕ)
    (h : (inFlight p input output price).2 ≠ 0)
    (unwinding : Bool := false) (cash reserved : ℕ := 0) :
    (effectiveAccount p input output price coll 0 lt hf unwinding cash reserved).2.2 = max256 := by
  have he : effectiveExtra p input output price unwinding cash reserved ≠ 0 := by
    unfold effectiveExtra
    omega
  simp [effectiveAccount, he]

theorem filled_observation_threshold (p : Intent) (i o : ℕ) (h : (outcome p i o).1 = 2) :
    p.outBase < o ∧ arrivalThreshold p.minimum ≤ o - p.outBase := by
  unfold outcome at h
  split_ifs at h <;> simp_all

theorem matching_callback_requires_minimum (p : Intent) (last amount : ℕ)
    (auth asset : Bool) (h : callback p last p.nonce p.kind amount auth asset = 2) :
    auth = true ∧ asset = true ∧ p.minimum ≤ amount := by
  simp only [callback] at h
  split_ifs at h <;> simp_all

theorem observation_is_not_origin_authentication :
    outcome ⟨1, 1, 100, 100, 0, 0⟩ 0 99 = (2, 99) := by decide

theorem observed_near_minimum_is_not_a_valid_callback :
    callback ⟨1, 1, 100, 100, 0, 0⟩ 1 1 1 99 true true = 0 := by decide

end Juicer.Runtime
