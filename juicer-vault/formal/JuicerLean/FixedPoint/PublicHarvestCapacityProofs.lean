import JuicerLean.FixedPoint.PublicHarvestProofs

set_option maxHeartbeats 1000000

namespace Juicer.PublicCalls
open Runtime

theorem harvestBurn_le_quote (s : State) : harvestBurn s ≤ harvestable s := Nat.min_le_left _ _

theorem harvestBurn_le_owned (s : State) : harvestBurn s ≤ s.held := Nat.min_le_right _ _

theorem harvestSlice_realized_le (available rewards protocol burned : Nat)
    (hb : burned ≤ available) : burned - (available - (rewards + protocol)) ≤ rewards + protocol := by
  omega

theorem harvestSlice_bounds (available rewards protocol burned : Nat) (hb : burned ≤ available) :
    (harvestSlice available rewards protocol burned).1 ≤ rewards ∧
    (harvestSlice available rewards protocol burned).2 ≤ protocol ∧
    (harvestSlice available rewards protocol burned).1 +
      (harvestSlice available rewards protocol burned).2 = burned - (available - (rewards + protocol)) := by
  have ht := harvestSlice_realized_le available rewards protocol burned hb
  generalize he : burned - (available - (rewards + protocol)) = realized at ht
  unfold harvestSlice
  dsimp only
  rw [he]
  by_cases hz : rewards + protocol = 0
  · have hr : rewards = 0 := by omega
    have hp : protocol = 0 := by omega
    have hm : realized = 0 := by omega
    simp [hr, hp, hm]
  · simp only [beq_iff_eq, if_neg hz]
    have hd : 0 < rewards + protocol := by omega
    have hr : realized * rewards / (rewards + protocol) ≤ rewards :=
      Nat.div_le_of_le_mul (by nlinarith)
    have hm : realized * rewards / (rewards + protocol) ≤ realized :=
      proportional_le realized rewards (rewards + protocol) (by omega)
    have hp : realized - protocol ≤ realized * rewards / (rewards + protocol) := by
      apply (Nat.le_div_iff_mul_le hd).2
      by_cases hsmall : realized ≤ protocol
      · simp only [Nat.sub_eq_zero_of_le hsmall, Nat.zero_mul, Nat.zero_le]
      · have hs : realized - protocol + protocol = realized := by omega
        nlinarith
    exact ⟨hr, by omega, by omega⟩

theorem harvestSlice_full (available rewards protocol : Nat) (h : rewards + protocol ≤ available) :
    harvestSlice available rewards protocol available = (rewards, protocol) := by
  have he : available - (available - (rewards + protocol)) = rewards + protocol := by omega
  unfold harvestSlice
  dsimp only
  rw [he]
  by_cases hz : rewards + protocol = 0
  · have hr : rewards = 0 := by omega
    have hp : protocol = 0 := by omega
    simp [hr, hp]
  · simp only [beq_iff_eq, if_neg hz, Nat.mul_div_cancel_left _ (by omega : 0 < rewards + protocol)]
    congr 1; omega

theorem harvestFunding_reserves_bounded (s : State) :
    (harvestFunding s (harvestBurn s)).book.source ≤ s.book.source ∧
    (harvestFunding s (harvestBurn s)).book.protocol ≤ s.book.protocol :=
  ⟨Nat.sub_le _ _, Nat.sub_le _ _⟩

theorem harvestFunding_reserves_accounted (s : State) :
    let burned := harvestBurn s
    let slice := harvestSlice (harvestable s) s.book.source s.book.protocol burned
    (harvestFunding s burned).book.source + slice.1 = s.book.source ∧
    (harvestFunding s burned).book.protocol + slice.2 = s.book.protocol := by
  have h := harvestSlice_bounds (harvestable s) s.book.source s.book.protocol (harvestBurn s)
    (harvestBurn_le_quote s)
  exact ⟨Nat.sub_add_cancel h.1, Nat.sub_add_cancel h.2.1⟩

end Juicer.PublicCalls
