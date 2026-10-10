import JuicerLean.FixedPoint.LazyOwnership

namespace Juicer.Runtime

def normalizeAccount (b : Book) (a : Account) (weight : ℕ) : LazyAccount ray :=
  let current := a.epoch == b.epoch
  let shift := if current then b.scale - a.scale else 0
  ⟨if current then a.units >>> shift else 0,
    if current then min b.index (ceilShift a.index shift) else 0, weight⟩

theorem normalized_claim (b : Book) (a : Account) (w : ℕ) :
    (normalizeAccount b a w).claim b.total b.index = accountUnits b a w := by
  rfl

theorem normalized_settlement (b : Book) (a : Account) (w : ℕ) :
    normalizeAccount b (settle b a w) w = (normalizeAccount b a w).settled b.total b.index := by
  unfold LazyAccount.settled
  rw [normalized_claim]
  simp [normalizeAccount, settle]

theorem normalized_weight_change (b : Book) (a : Account) (before after : ℕ) :
    normalizeAccount b (settle b a before) after =
      { (normalizeAccount b a before).settled b.total b.index with weight := after } := by
  unfold LazyAccount.settled
  rw [normalized_claim]
  simp [normalizeAccount, settle]

theorem normalized_index_change (b : Book) (a : Account) (w m delta : ℕ) :
    (normalizeAccount b a w).index ≤
      (normalizeAccount { b with total := b.total + m, index := b.index + delta } a w).index := by
  by_cases he : a.epoch = b.epoch
  · simp [normalizeAccount, he]
  · simp [normalizeAccount, he]

theorem normalized_rescale (b : Book) (a : Account) (w k : ℕ)
    (hs : a.epoch = b.epoch → a.scale ≤ b.scale) :
    normalizeAccount { b with total := b.total >>> k, index := b.index >>> k, scale := b.scale + k } a w =
      (normalizeAccount b a w).shift b.index k := by
  by_cases he : a.epoch = b.epoch
  · have hshift : b.scale + k - a.scale = (b.scale - a.scale) + k := by
      have := hs he
      omega
    simp [normalizeAccount, he, hshift, LazyAccount.shift, Nat.shiftRight_add,
      ceilShift_add, min_floor_ceil_min]
  · simp [normalizeAccount, he, LazyAccount.shift]

theorem normalized_writeOff (b : Book) (a : Account) (w : ℕ) (he : a.epoch ≤ b.epoch) :
    normalizeAccount { b with total := 0, index := 0, scale := 0, epoch := b.epoch + 1 } a w =
      ⟨0, 0, w⟩ := by
  have hne : a.epoch ≠ b.epoch + 1 := by omega
  simp [normalizeAccount, hne]

def normalizeLedger (b : Book) (accounts : List (Account × ℕ)) (slack : ℕ) : LazyLedger ray :=
  ⟨b.total, b.index, slack, accounts.map (fun (a, w) => normalizeAccount b a w)⟩

theorem runtime_lazy_claims_bound (b : Book) (accounts : List (Account × ℕ)) (slack : ℕ)
    (h : (normalizeLedger b accounts slack).valid) :
    (accounts.map (fun (a, w) => accountUnits b a w)).sum ≤ b.total + slack / ray := by
  simpa [normalizeLedger, List.map_map, Function.comp_def, normalized_claim] using
    lazy_claims_bound (normalizeLedger b accounts slack) h (by norm_num [ray])

theorem runtime_lazy_trace_bound (initial : LazyLedger ray) (b : Book)
    (accounts : List (Account × ℕ)) (slack : ℕ) (h : initial.valid)
    (steps : Relation.ReflTransGen LazyLedger.Step initial (normalizeLedger b accounts slack)) :
    (accounts.map (fun (a, w) => accountUnits b a w)).sum ≤ b.total + slack / ray :=
  runtime_lazy_claims_bound b accounts slack (lazy_trace_preserves _ _ h steps)

theorem runtime_lazy_funded_bound (b : Book) (accounts : List (Account × ℕ)) (slack funded : ℕ)
    (h : (normalizeLedger b accounts slack).valid) (ht : 0 < b.total) :
    (accounts.map (fun (a, w) => fundedOf funded b.total (accountUnits b a w))).sum ≤
      funded + funded * (slack / ray) / b.total := by
  simpa [normalizeLedger, List.map_map, Function.comp_def, normalized_claim, fundedOf,
    Nat.ne_of_gt ht] using
    lazy_funded_claims_bound (normalizeLedger b accounts slack) funded h (by norm_num [ray]) ht

def rescaleExampleBook : Book := ⟨2, 0, 2 ^ 64 + 1, 2 ^ 64, 0, 0⟩
def rescaleExampleInput : AllocationInput := ⟨2 * 10 ^ 38, 2 * 10 ^ 38, 0, 2 * ray, 0, 0, 0, 0⟩
def rescaleExampleOld : Account := ⟨2 ^ 64 - 1, 2 ^ 64 - 1, 0, 0⟩
def rescaleExampleWaiting : Account := ⟨0, 2 ^ 64 - 1, 0, 0⟩

theorem rescale_example_initial_valid :
    (normalizeLedger rescaleExampleBook
      [(rescaleExampleOld, 0), (rescaleExampleWaiting, ray), (rescaleExampleWaiting, ray)] 0).valid := by
  norm_num [normalizeLedger, normalizeAccount, rescaleExampleBook, rescaleExampleOld,
    rescaleExampleWaiting, LazyLedger.valid, lazyLiability, LazyAccount.numerator, ray]

theorem runtime_rescale_ceil_index_closes_excess :
    accountUnits rescaleExampleBook rescaleExampleOld 0 +
      2 * accountUnits rescaleExampleBook rescaleExampleWaiting ray = rescaleExampleBook.total ∧
    (allocate rescaleExampleBook rescaleExampleInput).scale = 64 ∧
    accountUnits (allocate rescaleExampleBook rescaleExampleInput) rescaleExampleOld 0 = 0 ∧
    2 * accountUnits (allocate rescaleExampleBook rescaleExampleInput) rescaleExampleWaiting ray =
      (allocate rescaleExampleBook rescaleExampleInput).total - 1 := by decide

end Juicer.Runtime
