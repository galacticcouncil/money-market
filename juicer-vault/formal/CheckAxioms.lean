import JuicerLean
import Lean.Util.CollectAxioms

open Lean Elab Command in
run_cmd do
  let mut checked := 0
  for (name, info) in (← getEnv).constants.toList do
    if name.toString.startsWith "Juicer." then
      if let .thmInfo _ := info then
        for axiomName in ← collectAxioms name do
          unless #[`propext, `Classical.choice, `Quot.sound].contains axiomName do
            throwError "{name} depends on {axiomName}"
        checked := checked + 1
  logInfo m!"checked axioms of {checked} Juicer theorem declarations (including generated lemmas)"
