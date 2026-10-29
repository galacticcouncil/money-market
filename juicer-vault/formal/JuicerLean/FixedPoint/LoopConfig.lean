import JuicerLean.FixedPoint.PublicCalls

namespace Juicer.LoopConfig

structure Stored where
  target : Nat := 0
  relever : Nat := 0
  delever : Nat := 0

-- SubLoop's per-vault rebalance bands and its admission bound, over vault ids
structure Registry where
  vaults : List Nat := []
  bands : Nat → Stored := fun _ => {}
  admission : Nat := 50

def bandAccepted (target relever delever : Nat) : Prop :=
  (target = 0 ∧ relever = 0 ∧ delever = 0) ∨
    (relever ≠ 0 ∧ delever ≠ 0 ∧ target ≤ 5000 ∧ relever ≤ 5000 ∧ delever ≤ 2500)

instance (target relever delever : Nat) : Decidable (bandAccepted target relever delever) := by
  unfold bandAccepted
  infer_instance

def bandOf (r : Registry) (v : Nat) : Nat × Nat × Nat :=
  let b := r.bands v
  if b.relever = 0 then (0, 500, 300) else (b.target, b.relever, b.delever)

def setBand (r : Registry) (v target relever delever : Nat) : Option Registry :=
  if v ∈ r.vaults ∧ bandAccepted target relever delever then
    some { r with bands := Function.update r.bands v ⟨target, relever, delever⟩ }
  else none

def setAdmission (r : Registry) (bps : Nat) : Option Registry :=
  if bps ≤ 10000 then some { r with admission := bps } else none

def Valid (r : Registry) : Prop :=
  (∀ v, bandAccepted (r.bands v).target (r.bands v).relever (r.bands v).delever) ∧ r.admission ≤ 10000

theorem initial_valid (vaults : List Nat) : Valid { vaults } := by
  exact ⟨fun _ => .inl ⟨rfl, rfl, rfl⟩, (by decide : (50 : Nat) ≤ 10000)⟩

theorem setBand_valid {r r' : Registry} {v target relever delever : Nat} (h : Valid r)
    (hs : setBand r v target relever delever = some r') : Valid r' := by
  unfold setBand at hs
  split at hs
  · next hok =>
    cases hs
    refine ⟨fun w => ?_, h.2⟩
    by_cases hw : w = v
    · subst hw
      simpa [Function.update_self] using hok.2
    · simpa [Function.update_of_ne hw] using h.1 w
  · cases hs

theorem setAdmission_valid {r r' : Registry} {bps : Nat} (h : Valid r)
    (hs : setAdmission r bps = some r') : Valid r' := by
  unfold setAdmission at hs
  split at hs
  · next hb => cases hs; exact ⟨h.1, hb⟩
  · cases hs

theorem setBand_unregistered (r : Registry) (v target relever delever : Nat) (hv : v ∉ r.vaults) :
    setBand r v target relever delever = none := by
  simp [setBand, hv]

theorem setBand_isolated {r r' : Registry} {v target relever delever : Nat}
    (hs : setBand r v target relever delever = some r') (w : Nat) (hw : w ≠ v) :
    bandOf r' w = bandOf r w := by
  unfold setBand at hs
  split at hs
  · cases hs
    simp [bandOf, Function.update_of_ne hw]
  · cases hs

theorem setBand_reads {r r' : Registry} {v target relever delever : Nat}
    (hs : setBand r v target relever delever = some r') :
    bandOf r' v = if relever = 0 then (0, 500, 300) else (target, relever, delever) := by
  unfold setBand at hs
  split at hs
  · cases hs
    simp [bandOf, Function.update_self]
  · cases hs

theorem bandOf_valid (r : Registry) (h : Valid r) (v : Nat) :
    (bandOf r v).2.1 ≠ 0 ∧ (bandOf r v).2.2 ≠ 0 ∧ (bandOf r v).1 ≤ 5000 ∧
      (bandOf r v).2.1 ≤ 5000 ∧ (bandOf r v).2.2 ≤ 2500 := by
  unfold bandOf
  dsimp only
  have hv := h.1 v
  split
  · decide
  · next hr =>
    rcases hv with ⟨_, h0, _⟩ | hv
    · exact absurd h0 hr
    · exact hv

-- what the vault model reads: every view of a valid registry is a model band
def modelBand (r : Registry) (h : Valid r) (v : Nat) : PublicCalls.Band :=
  ⟨(bandOf r v).1, (bandOf r v).2.1, (bandOf r v).2.2, bandOf_valid r h v⟩

theorem modelBand_view (r : Registry) (h : Valid r) (v : Nat) :
    ((modelBand r h v).gap, (modelBand r h v).relever, (modelBand r h v).delever) = bandOf r v := rfl

end Juicer.LoopConfig
