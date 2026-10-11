import JuicerLean.FixedPoint.Lifecycle

namespace Juicer.Runtime

theorem exit_ratio_zero_branch (owned shares wallet : ℕ) :
    (if owned == 0 || shares == 0 then 0 else owned * shares / (wallet + shares)) =
      owned * shares / (wallet + shares) := by
  by_cases ho : owned = 0 <;> by_cases hs : shares = 0 <;> simp [ho, hs]

theorem normalized_request_created (b : Book) (units shares : ℕ) :
    normalizeAccount b ⟨units, b.index, b.epoch, b.scale⟩ shares = ⟨units, b.index, shares⟩ := by
  simp [normalizeAccount]

theorem normalized_exit_burn (b : Book) (owner request : Account) (wallet shares funded : ℕ) :
    (startExit b owner request wallet shares funded).burned =
      exitBurned b.total b.index (normalizeAccount b owner wallet) (normalizeAccount b request shares) := by
  simp only [startExit, exit_ratio_zero_branch, exitBurned, exitTaken, exitOwned, normalized_claim]
  rfl

theorem normalized_exit_owner (b : Book) (owner request : Account) (wallet shares funded : ℕ) :
    (startExit b owner request wallet shares funded).owned =
      (exitOwner b.total b.index (normalizeAccount b owner wallet) (normalizeAccount b request shares)).units := by
  simp only [startExit, exit_ratio_zero_branch, exitOwner, exitTaken, exitOwned, normalized_claim]
  rfl

theorem normalized_exit_total (b : Book) (owner request : Account) (wallet shares funded : ℕ) :
    (startExit b owner request wallet shares funded).book.total =
      b.total - exitBurned b.total b.index (normalizeAccount b owner wallet) (normalizeAccount b request shares) := by
  rw [← normalized_exit_burn b owner request wallet shares funded]
  rfl

theorem normalized_exit_fold (b : Book) (owner request : Account) (wallet shares funded : ℕ) :
    (startExit b owner request wallet shares funded).folded =
      fundedOf funded b.total
        (exitBurned b.total b.index (normalizeAccount b owner wallet) (normalizeAccount b request shares)) := by
  rw [← normalized_exit_burn b owner request wallet shares funded]
  change funded * (startExit b owner request wallet shares funded).burned / b.total =
    fundedOf funded b.total (startExit b owner request wallet shares funded).burned
  by_cases ht : b.total = 0 <;> simp [fundedOf, ht]

theorem successful_take_admits_escrow (funded total owned shares taken remaining : ℕ)
    (h : take funded total owned shares = some (taken, remaining)) :
    taken ≤ owned ∧ remaining = owned - taken := by
  have := take_conserves funded total owned shares taken remaining h
  omega

theorem runtime_exit_preserves_all_liabilities (b : Book) (owner request : Account)
    (wallet shares funded slack : ℕ) (rest : List (LazyAccount ray))
    (h : (LazyLedger.mk b.total b.index slack
      (normalizeAccount b owner wallet :: normalizeAccount b request shares :: rest)).valid) :
    (LazyLedger.mk (startExit b owner request wallet shares funded).book.total b.index slack
      (⟨(startExit b owner request wallet shares funded).owned, b.index, wallet⟩ :: rest)).valid := by
  simpa only [normalized_exit_total, normalized_exit_owner, exitOwner, normalizeAccount] using
    exit_ledger_preserves b.total b.index slack (normalizeAccount b owner wallet)
      (normalizeAccount b request shares) rest h

end Juicer.Runtime
