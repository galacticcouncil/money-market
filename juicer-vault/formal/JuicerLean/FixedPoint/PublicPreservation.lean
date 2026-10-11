import JuicerLean.FixedPoint.PublicInvariants

set_option maxRecDepth 4000
set_option maxHeartbeats 2000000

namespace Juicer.PublicCalls

open Runtime

def OnSuccess (p : α → Prop) : Except ε α → Prop
  | .ok a => p a
  | .error _ => True

@[simp] theorem onSuccess_pure (p : α → Prop) (a : α) :
    OnSuccess p (pure a : Except ε α) ↔ p a := Iff.rfl

@[simp] theorem onSuccess_error (p : α → Prop) (e : ε) :
    OnSuccess p (.error e) := trivial

theorem onSuccess_ite (p : α → Prop) (c : Prop) [Decidable c] (x y : Except ε α) :
    OnSuccess p (if c then x else y) ↔ if c then OnSuccess p x else OnSuccess p y := by
  split <;> rfl

theorem onSuccess_bind (p : β → Prop) (x : Except ε α) (f : α → Except ε β) :
    OnSuccess p (x >>= f) ↔ ∀ a, x = .ok a → OnSuccess p (f a) := by
  cases x <;> simp [OnSuccess, bind, Except.bind]

theorem onSuccess_of_eq {p : α → Prop} {x : Except ε α} {a : α}
    (h : OnSuccess p x) (heq : x = .ok a) : p a := by
  simpa [heq, OnSuccess] using h

@[simp] theorem setWallet_custody (s : State) (i n : Nat) : custody (setWallet s i n) = custody s := rfl
@[simp] theorem setAccount_custody (s : State) (i : Nat) (a : Account) :
    custody (setAccount s i a) = custody s := rfl
@[simp] theorem setPosition_custody (s : State) (i : Nat) (p : MainPosition) :
    custody (setPosition s i p) = custody s := rfl

theorem spend_custody (s : State) (owner caller amount : Nat) :
    OnSuccess (fun next => custody next = custody s) (spend s owner caller amount) := by
  unfold spend
  simp only [bind, pure, Except.bind, Except.pure]
  split_ifs <;> simp_all [OnSuccess, custody]

theorem transfer_custody (s : State) (a b n : Nat) :
    OnSuccess (fun next => custody next = custody s) (transfer s a b n) := by
  unfold transfer
  simp only [bind, pure, Except.bind, Except.pure]
  repeat' first | simp_all [OnSuccess] | split at *
  all_goals subst_vars; simp_all

end Juicer.PublicCalls
