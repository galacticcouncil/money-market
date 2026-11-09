import JuicerLean.FixedPoint.PublicPreservation
import JuicerLean.FixedPoint.PublicCertificates

open Juicer.PublicCalls Juicer.Runtime

namespace Juicer.PublicCalls

theorem normalized_index_bound (s : State) (a : Account) (w : Nat) :
    (normalizeAccount s.book a w).index ≤ s.book.index := by
  by_cases he : a.epoch = s.book.epoch
  · simp [normalizeAccount, he]
  · simp [normalizeAccount, he]

theorem list_range_values {α : Type} (xs : List α) (fallback : α) :
    ((List.range xs.length).map fun i => xs[i]?.getD fallback) = xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.length_cons, List.range_succ_eq_map, List.map_cons,
      List.getElem?_cons_zero, Option.getD_some, List.map_map]
    simpa only [Function.comp_apply, List.getElem?_cons_succ] using congrArg (List.cons x) ih

theorem ledger_valid (s : State) : (publicProjection s).ledger.valid := by
  constructor
  · intro a ha
    simp only [publicProjection, publicLifecycle, List.mem_append, List.mem_map] at ha
    rcases ha with h | h
    all_goals
      obtain ⟨i, _, rfl⟩ := h
      apply normalized_index_bound
  · change lazyLiability s.book.index _ ≤ s.book.total * ray + publicSlack s
    unfold publicSlack
    simp only [publicProjection, publicLifecycle]
    omega

def publicLiability (s : State) : Nat :=
  lazyLiability s.book.index (publicLifecycle s 0 0).ledger.accounts

theorem publicLiability_parts (s : State) : publicLiability s =
    ((List.range 5).map fun i => (normalizeAccount s.book (account s i) (wallet s i)).numerator s.book.index).sum +
    ((List.range (s.requests.size - s.unwind)).map fun i =>
      (normalizeAccount s.book (request s (s.unwind+i)).account
        (request s (s.unwind+i)).claim.shares).numerator s.book.index).sum := by
  simp [publicLiability, publicLifecycle, lazyLiability, List.map_map, Function.comp_def]

theorem lifecycle_weight (s : State) (slack parked : Nat) :
    lazyWeight (publicLifecycle s slack parked).ledger.accounts =
      ((List.range 5).map (wallet s)).sum +
      ((List.range (s.requests.size - s.unwind)).map fun i =>
        (request s (s.unwind+i)).claim.shares).sum := by
  simp [publicLifecycle, lazyWeight, normalizeAccount, List.map_map, Function.comp_def]

theorem settleOwner_book (s : State) (i : Nat) : (settleOwner s i).book = s.book := by
  unfold settleOwner
  split <;> rfl

theorem settleOwner_wallets (s : State) (i : Nat) : (settleOwner s i).wallets = s.wallets := by
  unfold settleOwner
  split <;> rfl

theorem settleOwner_numerator (s : State) (i j : Nat) :
    (normalizeAccount (settleOwner s i).book (account (settleOwner s i) j)
      (wallet (settleOwner s i) j)).numerator s.book.index ≤
    (normalizeAccount s.book (account s j) (wallet s j)).numerator s.book.index := by
  rw [settleOwner_book]
  unfold settleOwner
  split
  · exact le_rfl
  · dsimp only [setAccount, wallet, account]
    simp only [Array.set!_eq_setIfInBounds, Array.getElem?_setIfInBounds]
    by_cases hij : i = j
    · subst j
      simp only [ite_true]
      by_cases hi : i < s.accounts.size
      · simp only [if_pos hi, Option.getD_some]
        rw [← account, normalized_settlement]
        exact lazy_settlement_reduces_liability _ _ _
      · simp [hi]
    · simp [hij]

theorem settleOwner_liability (s : State) (i : Nat) :
    publicLiability (settleOwner s i) ≤ publicLiability s := by
  rw [publicLiability_parts, publicLiability_parts]
  have hholders := List.sum_le_sum (l := List.range 5)
    (fun j _ => settleOwner_numerator s i j)
  simp only [settleOwner_book] at hholders
  have hwaiting :
      ((List.range ((settleOwner s i).requests.size - (settleOwner s i).unwind)).map fun j =>
        (normalizeAccount (settleOwner s i).book
          (request (settleOwner s i) ((settleOwner s i).unwind+j)).account
          (request (settleOwner s i) ((settleOwner s i).unwind+j)).claim.shares).numerator
          (settleOwner s i).book.index).sum =
      ((List.range (s.requests.size-s.unwind)).map fun j =>
        (normalizeAccount s.book (request s (s.unwind+j)).account
          (request s (s.unwind+j)).claim.shares).numerator s.book.index).sum := by
    unfold settleOwner
    split <;> rfl
  rw [hwaiting, settleOwner_book]
  exact Nat.add_le_add_right hholders _

theorem settleOwner_operational (s : State) (i : Nat) (h : OperationalInvariant s) :
    OperationalInvariant (settleOwner s i) := by
  unfold settleOwner
  split
  · exact h
  · simpa only [setAccount, OperationalInvariant, Array.set!_eq_setIfInBounds,
      Array.size_setIfInBounds] using h

theorem settleOwner_public (s : State) (i : Nat) (h : PublicInvariant s) :
    PublicInvariant (settleOwner s i) := by
  rcases h with ⟨hc, hs, hm, hl, he, ho⟩
  refine ⟨?_, ?_, ?_, ⟨ledger_valid _, ?_⟩, ?_, settleOwner_operational s i ho⟩
  · exact collateral_of_custody (settleOwner_custody s i).symm hc
  · unfold settleOwner
    split
    · exact hs
    · exact hs
  · unfold settleOwner
    split
    · exact hm
    · exact hm
  · have hp := hl.2
    change lazyWeight (publicLifecycle s (publicSlack s) (publicParked s)).ledger.accounts +
      wallet s fundId + s.queued + publicParked s = s.supply at hp
    change lazyWeight (publicLifecycle (settleOwner s i)
      (publicSlack (settleOwner s i)) (publicParked (settleOwner s i))).ledger.accounts +
      wallet (settleOwner s i) fundId + (settleOwner s i).queued +
      publicParked (settleOwner s i) = (settleOwner s i).supply
    rw [lifecycle_weight] at hp ⊢
    unfold settleOwner
    split
    · exact hp
    · exact hp
  · have hb := settleOwner_liability s i
    have hn := Nat.sub_le_sub_right hb (s.book.total*ray)
    change publicLiability s - s.book.total * ray < ray at he
    change publicLiability (settleOwner s i) - (settleOwner s i).book.total * ray < ray
    rw [settleOwner_book]
    exact hn.trans_lt he

end Juicer.PublicCalls

