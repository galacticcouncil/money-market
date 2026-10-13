import JuicerLean.FixedPoint.Orchestration

namespace Juicer.Runtime

structure SourceClaims where
  active : ℕ
  exits : List ℕ
  outstanding : ℕ
  deriving Repr

def SourceClaims.valid (s : SourceClaims) : Prop := s.active + s.exits.sum = s.outstanding

inductive SourceClaims.Step : SourceClaims → SourceClaims → Prop
  | expect (s : SourceClaims) (amount : ℕ) :
      Step s { s with active := s.active + amount, outstanding := s.outstanding + amount }
  | start (s : SourceClaims) (claim : ℕ) :
      Step s { s with exits := s.exits ++ [claim], outstanding := s.outstanding + claim }
  | creditActive (s : SourceClaims) (reduction : ℕ) (hr : reduction ≤ s.active) :
      Step s { s with active := s.active - reduction, outstanding := s.outstanding - reduction }
  | creditExit (active outstanding weight reduction : ℕ) (before after : List ℕ)
      (hr : reduction ≤ weight) :
      Step ⟨active, before ++ weight :: after, outstanding⟩
        ⟨active, before ++ (weight - reduction) :: after, outstanding - reduction⟩
  | advanceHead (s : SourceClaims) (rest : List ℕ) (hz : s.exits = 0 :: rest) :
      Step s { s with exits := rest }

theorem source_claims_step_preserves (s s' : SourceClaims) (h : s.valid) (step : s.Step s') : s'.valid := by
  cases step <;> simp_all [SourceClaims.valid, List.sum_append] <;> omega

theorem source_claims_trace_preserves (s s' : SourceClaims) (h : s.valid)
    (steps : Relation.ReflTransGen SourceClaims.Step s s') : s'.valid := by
  induction steps with
  | refl => exact h
  | tail steps step ih => exact source_claims_step_preserves _ _ ih step

theorem source_claims_genesis_partition (s : SourceClaims)
    (steps : Relation.ReflTransGen SourceClaims.Step ⟨0, [], 0⟩ s) :
    s.outstanding = s.active + s.exits.sum :=
  (source_claims_trace_preserves _ _ (by rfl) steps).symm

theorem reachable_source_batch_valid (s : SourceClaims) (a c : ℕ)
    (steps : Relation.ReflTransGen SourceClaims.Step ⟨0, [], 0⟩ s)
    (hp : 0 < a + c) (guard : a + c ≤ s.outstanding) :
    (SourceBatch.begin a c (s.active :: s.exits)).valid := by
  apply source_batch_begin_valid _ _ _ hp
  simpa [source_claims_genesis_partition s steps] using guard

theorem source_batch_credit_admissible (a c total cursor weight : ℕ)
    (hp : 0 < a + c) (ht : 0 < total) (hb : a + c ≤ total) :
    (batchSegment a c total cursor weight).1 + (batchSegment a c total cursor weight).2 ≤ weight :=
  batchSegment_never_overcredits a c total cursor weight hp ht hb

structure CashBook where
  cohorts : List ℕ
  unallocated : ℕ
  owned : ℕ
  reserve : ℕ
  deriving Repr

def CashBook.valid (s : CashBook) : Prop := s.cohorts.sum + s.unallocated = s.owned

inductive CashBook.Step : CashBook → CashBook → Prop
  | sourceReceipt (s : CashBook) (amount : ℕ) :
      Step s { s with unallocated := s.unallocated + amount, owned := s.owned + amount }
  | join (s : CashBook) : Step s { s with cohorts := s.cohorts ++ [0] }
  | fund (cash unallocated owned reserve amount : ℕ) (rest : List ℕ) :
      Step ⟨cash :: rest, unallocated, owned, reserve⟩ ⟨(cash + amount) :: rest, unallocated, owned + amount, reserve⟩
  | assign (cash unallocated owned reserve amount : ℕ) (rest : List ℕ) (ha : amount ≤ unallocated) :
      Step ⟨cash :: rest, unallocated, owned, reserve⟩ ⟨(cash + amount) :: rest, unallocated - amount, owned, reserve⟩
  | pay (cash unallocated owned reserve amount : ℕ) (rest : List ℕ) (ha : amount ≤ cash) :
      Step ⟨cash :: rest, unallocated, owned, reserve⟩ ⟨(cash - amount) :: rest, unallocated, owned - amount, reserve⟩
  | draw (cash unallocated owned reserve amount : ℕ) (rest : List ℕ) (ha : amount ≤ reserve) :
      Step ⟨cash :: rest, unallocated, owned, reserve⟩ ⟨(cash + amount) :: rest, unallocated, owned + amount, reserve - amount⟩
  | giveBack (cash unallocated owned reserve amount : ℕ) (rest : List ℕ) (ha : amount ≤ cash) :
      Step ⟨cash :: rest, unallocated, owned, reserve⟩ ⟨(cash - amount) :: rest, unallocated, owned - amount, reserve + amount⟩
  | reorder (s : CashBook) (cohorts : List ℕ) (hp : s.cohorts.Perm cohorts) :
      Step s { s with cohorts }

theorem cash_book_step_preserves (s s' : CashBook) (h : s.valid) (step : s.Step s') : s'.valid := by
  cases step with
  | reorder s cohorts hp => simpa only [CashBook.valid, hp.sum_eq] using h
  | _ => simp_all [CashBook.valid] <;> omega

theorem cash_book_trace_preserves (s s' : CashBook) (h : s.valid)
    (steps : Relation.ReflTransGen CashBook.Step s s') : s'.valid := by
  induction steps with
  | refl => exact h
  | tail steps step ih => exact cash_book_step_preserves _ _ ih step

theorem cash_book_genesis_partition (reserve : ℕ) (s : CashBook)
    (steps : Relation.ReflTransGen CashBook.Step ⟨[], 0, 0, reserve⟩ s) :
    s.cohorts.sum + s.unallocated = s.owned :=
  cash_book_trace_preserves _ _ (by rfl) steps

theorem cash_cohort_payment_does_not_underflow_total (cash unallocated owned reserve amount : ℕ)
    (rest : List ℕ) (h : (CashBook.mk (cash :: rest) unallocated owned reserve).valid)
    (ha : amount ≤ cash) : amount ≤ owned := by
  simp only [CashBook.valid, List.sum_cons] at h
  omega

theorem source_assignment_does_not_spend_other_cohorts (cash unallocated owned reserve amount : ℕ)
    (rest : List ℕ) (h : (CashBook.mk (cash :: rest) unallocated owned reserve).valid)
    (ha : amount ≤ unallocated) : cash + amount + rest.sum ≤ owned := by
  simp only [CashBook.valid, List.sum_cons] at h
  omega

end Juicer.Runtime
