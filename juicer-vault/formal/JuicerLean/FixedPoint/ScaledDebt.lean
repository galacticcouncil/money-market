import JuicerLean.FixedPoint.Runtime

namespace Juicer.Runtime

def rayMulHalf (a b : ℕ) := (a * b + ray / 2) / ray
def rayDivHalf (a b : ℕ) := (a * ray + b / 2) / b

theorem rayMulHalf_interval (a b : ℕ) :
    rayMulHalf a b * ray ≤ a * b + ray / 2 ∧
    a * b + ray / 2 < rayMulHalf a b * ray + ray := by
  have hr : 0 < ray := by decide
  have hd := Nat.div_mul_le_self (a * b + ray / 2) ray
  have hu := Nat.lt_div_mul_add (a := a * b + ray / 2) (b := ray) hr
  exact ⟨hd, hu⟩

theorem rayDivHalf_interval (a b : ℕ) (hb : 0 < b) :
    rayDivHalf a b * b ≤ a * ray + b / 2 ∧
    a * ray + b / 2 < rayDivHalf a b * b + b := by
  have hd := Nat.div_mul_le_self (a * ray + b / 2) b
  have hu := Nat.lt_div_mul_add (a := a * ray + b / 2) (b := b) hb
  exact ⟨hd, hu⟩

structure ScaledDebt where
  index : ℕ := ray
  balances : Array ℕ := Array.replicate 4 0
  previous : Array ℕ := Array.replicate 4 0
  deriving Repr

def scaledDebtCall (s : ScaledDebt) (op actor amount : ℕ) : Option ScaledDebt := do
  if actor ≥ s.balances.size then none else
  if op == 2 then
    if amount < s.index || 2 ^ 128 ≤ amount then none
    else some { s with index := amount }
  else
    let scaled := rayDivHalf amount s.index
    let prior := s.balances[actor]!
    if scaled == 0 || 2 ^ 128 ≤ scaled then none else
    if op == 0 then
      if 2 ^ 128 ≤ prior + scaled then none else
      let balances := s.balances.set! actor (prior + scaled)
      let previous := s.previous.set! actor s.index
      some { s with balances, previous }
    else if op == 1 then
      if prior < scaled then none else
      let balances := s.balances.set! actor (prior - scaled)
      let previous := s.previous.set! actor s.index
      some { s with balances, previous }
    else none

def scaledDebtSnapshot (s : ScaledDebt) : Array ℕ :=
  #[s.index, s.balances.sum, rayMulHalf s.balances.sum s.index] ++
    s.balances ++ s.balances.map (fun n => rayMulHalf n s.index) ++ s.previous

end Juicer.Runtime
