import JuicerLean.FixedPoint.Checked

namespace Juicer.Solidity
open Runtime

inductive Kind where
  | word
  | boolean
  deriving DecidableEq, Repr

abbrev Value : Kind → Type
  | .word => Nat
  | .boolean => Bool

inductive Expr : Kind → Type where
  | literal (n : Nat) : Expr .word
  | parameter (index : Nat) : Expr .word
  | add (left right : Expr .word) : Expr .word
  | sub (left right : Expr .word) : Expr .word
  | shr (left right : Expr .word) : Expr .word
  | eq (left right : Expr .word) : Expr .boolean
  | choose {kind : Kind} (condition : Expr .boolean) (yes no : Expr kind) : Expr kind

def eval : {kind : Kind} → Expr kind → (Nat → Nat) → Checked (Value kind)
  | _, .literal n, _ => checkWord n
  | _, .parameter index, input => checkWord (input index)
  | _, .add left right, input => do checkedAdd (← eval left input) (← eval right input)
  | _, .sub left right, input => do checkedSub (← eval left input) (← eval right input)
  | _, .shr left right, input => do return checkedShift (← eval left input) (← eval right input)
  | _, .eq left right, input => do return (← eval left input) == (← eval right input)
  | _, .choose condition yes no, input => do
    if ← eval condition input then eval yes input else eval no input

def pairInput (first second : Nat) : Nat → Nat
  | 0 => first
  | 1 => second
  | _ => 0

def ValidValue : (kind : Kind) → Value kind → Prop
  | .word, value => value ≤ max256
  | .boolean, _ => True

theorem eval_valid {kind : Kind} (expression : Expr kind) (input : Nat → Nat) (value : Value kind)
    (h : eval expression input = .ok value) : ValidValue kind value := by
  induction expression with
  | literal n =>
    have hv := (checkWord_ok_iff n value).1 h
    exact hv.2 ▸ hv.1
  | parameter index =>
    have hv := (checkWord_ok_iff (input index) value).1 h
    exact hv.2 ▸ hv.1
  | add left right ihl ihr =>
    rcases (checked_bind_eq_ok _ _ _).1 h with ⟨a,ha,hrest⟩
    rcases (checked_bind_eq_ok _ _ _).1 hrest with ⟨b,hb,hresult⟩
    have hv := (checkedAdd_ok_iff a b value).1 hresult
    exact hv.2 ▸ hv.1
  | sub left right ihl ihr =>
    rcases (checked_bind_eq_ok _ _ _).1 h with ⟨a,ha,hrest⟩
    rcases (checked_bind_eq_ok _ _ _).1 hrest with ⟨b,hb,hresult⟩
    have hv := (checkedSub_ok_iff a b value).1 hresult
    exact hv.2 ▸ (Nat.sub_le a b).trans (ihl a ha)
  | shr left right ihl ihr =>
    rcases (checked_bind_eq_ok _ _ _).1 h with ⟨a,ha,hrest⟩
    rcases (checked_bind_eq_ok _ _ _).1 hrest with ⟨b,hb,hresult⟩
    have hv : checkedShift a b = value := Except.ok.inj hresult
    exact hv ▸ (checked_shift_bounded a b).trans (ihl a ha)
  | eq left right ihl ihr => trivial
  | choose condition yes no ihc ihy ihn =>
    rcases (checked_bind_eq_ok _ _ _).1 h with ⟨conditionValue,hcondition,hresult⟩
    cases conditionValue
    · exact ihn value hresult
    · exact ihy value hresult

theorem choose_true {kind : Kind} (condition : Expr .boolean) (yes no : Expr kind) (input : Nat → Nat)
    (h : eval condition input = .ok true) : eval (.choose condition yes no) input = eval yes input := by
  simp only [eval,h,checked_bind_ok,ite_true]

theorem choose_false {kind : Kind} (condition : Expr .boolean) (yes no : Expr kind) (input : Nat → Nat)
    (h : eval condition input = .ok false) : eval (.choose condition yes no) input = eval no input := by
  simp only [eval,h,checked_bind_ok,Bool.false_eq_true,ite_false]

end Juicer.Solidity
