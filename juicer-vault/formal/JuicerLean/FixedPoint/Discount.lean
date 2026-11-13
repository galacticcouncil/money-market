import JuicerLean.FixedPoint.Runtime

namespace Juicer.Discount

def loopTag : Nat := 2 ^ 255

structure Config where
  discountBps : Nat := 0
  loopBps : Nat := 0
  loopCap : Nat := 0

-- JuicerDiscount.balanceOf(loop): storage only, tagged so the rate strategy can tell
def loopEligibility (c : Config) : Nat :=
  if c.loopBps = 0 ∨ c.loopCap = 0 then 0 else loopTag ||| c.loopCap

-- the Main-only rule before the loop discount existed
def mainRate (bps debt eligible : Nat) : Nat :=
  if debt = 0 ∨ eligible = 0 then 0 else min debt eligible * bps / debt

-- JuicerDiscount.calculateDiscountRate
def rate (c : Config) (debt eligible : Nat) : Nat :=
  if debt = 0 ∨ eligible = 0 then 0
  else if eligible &&& loopTag ≠ 0 then min debt (eligible ^^^ loopTag) * c.loopBps / debt
  else min debt eligible * c.discountBps / debt

def setDiscountBps (c : Config) (bps : Nat) : Option Config :=
  if bps ≤ 10000 then some { c with discountBps := bps } else none

def setLoopDiscountBps (c : Config) (bps : Nat) : Option Config :=
  if bps ≤ 10000 then some { c with loopBps := bps } else none

-- registerLoop and setLoopCap share the cap check
def setLoopCap (c : Config) (cap : Nat) : Option Config :=
  if cap = 0 ∨ loopTag ≤ cap then none else some { c with loopCap := cap }

def Valid (c : Config) : Prop := c.discountBps ≤ 10000 ∧ c.loopBps ≤ 10000 ∧ c.loopCap < loopTag

theorem initial_valid : Valid {} := by unfold Valid; decide

theorem setDiscountBps_valid {c c' : Config} {bps : Nat} (h : Valid c)
    (hs : setDiscountBps c bps = some c') : Valid c' := by
  unfold setDiscountBps at hs
  split at hs
  · next hb => cases hs; exact ⟨hb, h.2⟩
  · cases hs

theorem setLoopDiscountBps_valid {c c' : Config} {bps : Nat} (h : Valid c)
    (hs : setLoopDiscountBps c bps = some c') : Valid c' := by
  unfold setLoopDiscountBps at hs
  split at hs
  · next hb => cases hs; exact ⟨h.1, hb, h.2.2⟩
  · cases hs

theorem setLoopCap_valid {c c' : Config} {cap : Nat} (h : Valid c)
    (hs : setLoopCap c cap = some c') : Valid c' := by
  unfold setLoopCap at hs
  split at hs
  · cases hs
  · next hb => cases hs; exact ⟨h.1, h.2.1, show cap < loopTag by omega⟩

theorem untagged_and (e : Nat) (he : e < loopTag) : e &&& loopTag = 0 := by
  apply Nat.eq_of_testBit_eq
  intro i
  simp only [Nat.testBit_and, Nat.zero_testBit, loopTag, Nat.testBit_two_pow]
  by_cases hi : 255 = i
  · subst hi
    simp [Nat.testBit_lt_two_pow he]
  · simp [hi]

theorem tagged_and (cap : Nat) : (loopTag ||| cap) &&& loopTag ≠ 0 := by
  intro h
  have := congrArg (fun n => n.testBit 255) h
  simp only [Nat.testBit_and, Nat.testBit_or, Nat.zero_testBit, loopTag, Nat.testBit_two_pow,
    decide_true, Bool.true_or, Bool.and_self] at this
  cases this

theorem tag_roundtrip (cap : Nat) (hc : cap < loopTag) : (loopTag ||| cap) ^^^ loopTag = cap := by
  apply Nat.eq_of_testBit_eq
  intro i
  simp only [Nat.testBit_xor, Nat.testBit_or, loopTag, Nat.testBit_two_pow]
  by_cases hi : 255 = i
  · subst hi
    simp [Nat.testBit_lt_two_pow hc]
  · simp [hi]

theorem tagged_lt_word (cap : Nat) (hc : cap < loopTag) : loopTag ||| cap < 2 ^ 256 := by
  rw [show loopTag ||| cap = loopTag + cap from (Nat.two_pow_add_eq_or_of_lt hc 1).symm.trans (by
    simp [loopTag])]
  unfold loopTag at hc ⊢
  omega

-- a vault's eligibility is never mistaken for the loop's, so the Main rate is unchanged
theorem vault_rate_unchanged (c : Config) (debt e : Nat) (he : e < loopTag) :
    rate c debt e = mainRate c.discountBps debt e := by
  unfold rate mainRate
  simp [untagged_and e he]

-- the loop is discounted at its own rate on at most its cap
theorem loop_rate (c : Config) (h : Valid c) (hb : c.loopBps ≠ 0) (hc : c.loopCap ≠ 0) (debt : Nat) :
    rate c debt (loopEligibility c) = mainRate c.loopBps debt c.loopCap := by
  have htag : loopTag ||| c.loopCap ≠ 0 := by
    intro hz
    exact tagged_and c.loopCap (by rw [hz]; simp)
  unfold rate mainRate loopEligibility
  simp only [hb, hc, or_self, if_false, htag, or_false, tagged_and, ne_eq, not_false_eq_true,
    if_true, tag_roundtrip c.loopCap h.2.2]

theorem loop_disabled (c : Config) (h : c.loopBps = 0 ∨ c.loopCap = 0) (debt : Nat) :
    loopEligibility c = 0 ∧ rate c debt (loopEligibility c) = 0 := by
  have : loopEligibility c = 0 := by simp [loopEligibility, h]
  exact ⟨this, by simp [rate, this]⟩

theorem min_mul_div_le (debt e bps : Nat) : min debt e * bps / debt ≤ bps :=
  Nat.div_le_of_le_mul (Nat.mul_le_mul_right bps (min_le_left debt e))

theorem mainRate_le (bps debt e : Nat) : mainRate bps debt e ≤ bps := by
  unfold mainRate
  split
  · exact Nat.zero_le _
  · exact min_mul_div_le debt e bps

theorem mainRate_notional (bps debt e : Nat) : mainRate bps debt e * debt ≤ min debt e * bps := by
  unfold mainRate
  split
  · simp
  · exact Nat.div_mul_le_self _ _

-- every rate the debt token caches is a percentage it can store
theorem rate_le (c : Config) (h : Valid c) (debt e : Nat) : rate c debt e ≤ 10000 := by
  unfold rate
  split
  · exact Nat.zero_le _
  · split
    · exact (min_mul_div_le _ _ _).trans h.2.1
    · exact (min_mul_div_le _ _ _).trans h.1

end Juicer.Discount
