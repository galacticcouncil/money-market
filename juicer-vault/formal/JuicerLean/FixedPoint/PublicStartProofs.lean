import JuicerLean.FixedPoint.PublicUnwindMetadataProofs

set_option maxRecDepth 6000
set_option maxHeartbeats 200000

namespace Juicer.PublicCalls
open Runtime

def withUnwind (s : State) (cursor : Nat) : State := { s with unwind := cursor }

def startProgram (input : State) (id : Nat)
    (exitFn : Book → Account → Account → Nat → Nat → Nat → ExitResult)
    (mainFn : MainPosition → Nat → Nat → Nat → Nat → Nat → MainPosition × MainPosition × Nat) : Except Nat State := do
  let mut s := input
  let r := request s id
  let escrowed := r.claim.shares
  let supply := activeSupply s
  let settled := settle s.book (account s r.owner) (wallet s r.owner)
  let out := exitFn s.book (account s r.owner) r.account
    (wallet s r.owner) escrowed (wallet s fundId)
  s := setAccount s r.owner { settled with units := out.owned }
  s := { s with book := out.book }
  s := setWallet (setWallet s fundId (wallet s fundId - out.folded)) vaultId
    (wallet s vaultId + out.folded)
  let shares := escrowed + out.folded
  let numerator := activeAssets s * shares
  let owed := ceilDiv numerator supply
  if owed == 0 then throw 2
  s := { s with reinvest := s.reinvest - s.reinvest * shares / supply }
  let activeSlice := (s.held - s.book.source - s.book.protocol - out.reward - out.fee) * shares / supply
  let slice := activeSlice + out.reward + out.fee
  let basis := s.basis * shares / supply
  if pendingAccounting s then throw 18
  let claim := sourceValue s slice
  let sourceFee := (claim * activeSlice / slice - basis) * s.feeBps / 10000 + claim * out.fee / slice
  let vested := vestFee claim basis sourceFee
  let (active, exit, total) := mainFn (position s 0) s.mainUnits s.debt shares supply claim
  let debt := mainDebtOf s.debt total exit
  if slice == 0 && debt > (position s 0).cash * shares / supply then throw 19
  let synth := if s.debt == 0 then 0 else s.synth * debt / s.debt
  s := setPosition s 0 active
  s := { s with
    positions := s.positions.push exit,
    mainUnits := total,
    held := s.held - slice,
    basis := s.basis - (if slice == 0 then 0 else basis),
    freed := s.freed + claim,
    outstanding := s.outstanding + claim,
    sourceFees := s.sourceFees.push (if s.expanded then vested else {}),
    feeReserve := s.feeReserve + (if s.expanded then vested.feeLeft else 0) }
  s ← cover s (owed - numerator / supply)
  return { s with
    pending := s.pending - escrowed, queued := s.queued + shares,
    owed := s.owed + owed, queuedDebt := s.queuedDebt + debt,
    requests := s.requests.set! id { r with claim := freshRedemption shares owed debt, synth, account := {} } }


def startNumbers (s : State) (id : Nat) (out : ExitResult)
    (mainFn : MainPosition → Nat → Nat → Nat → Nat → Nat → MainPosition × MainPosition × Nat) : UnwindNumbers :=
  let supply := activeSupply s
  let shares := (request s id).claim.shares+out.folded
  let numerator := activeAssets s*shares
  let owed := ceilDiv numerator supply
  let activeSlice := (s.held-out.book.source-out.book.protocol-out.reward-out.fee)*shares/supply
  let slice := activeSlice+out.reward+out.fee
  let basis := s.basis*shares/supply
  let claim := sourceValue s slice
  let sourceFee := (claim*activeSlice/slice-basis)*s.feeBps/10000+claim*out.fee/slice
  let vested := if s.expanded then vestFee claim basis sourceFee else {}
  let (active,exit,total) := mainFn (position s 0) s.mainUnits s.debt shares supply claim
  let debt := mainDebtOf s.debt total exit
  let synth := if s.debt == 0 then 0 else s.synth*debt/s.debt
  ⟨shares,owed,debt,synth,slice,basis,claim,owed-numerator/supply,active,exit,total,vested⟩

def startCommitted (s : State) (id : Nat) (out : ExitResult) (q : UnwindNumbers) : State :=
  let next := setAccount s (request s id).owner ⟨out.owned,s.book.index,s.book.epoch,s.book.scale⟩
  let next := moveWallets { next with book := out.book } fundId vaultId out.folded
  let next := sourceExitState next q.active q.exit q.total q.slice q.basis q.claim q.vested
  let next := coverExit next q.rounding (s.reinvest-s.reinvest*q.shares/activeSupply s)
  activateWaiting (withUnwind next id) q.shares q.owed q.debt q.synth

def startHead (s : State) (id : Nat)
    (exitFn : Book → Account → Account → Nat → Nat → Nat → ExitResult)
    (mainFn : MainPosition → Nat → Nat → Nat → Nat → Nat → MainPosition × MainPosition × Nat) : Except Nat State :=
  let r := request s id
  let out := exitFn s.book (account s r.owner) r.account (wallet s r.owner) r.claim.shares (wallet s fundId)
  let q := startNumbers s id out mainFn
  if q.owed == 0 then .error 2
  else if pendingAccounting s then .error 18
  else if q.slice == 0 && q.debt > (position s 0).cash*q.shares/activeSupply s then .error 19
  else if s.reserve < q.rounding then .error 17
  else .ok (startCommitted s id out q)

theorem startOne_program (s : State) (id : Nat) :
    startOne s id = startProgram (checkpoint s zeroId zeroId) id startExit mainExit := rfl

theorem startHead_exact (s : State) (id : Nat) :
    startHead s id startExit mainExit = unwindHead (withUnwind s id) := rfl

theorem startProgram_head (s : State) (id : Nat)
    (exitFn : Book → Account → Account → Nat → Nat → Nat → ExitResult)
    (mainFn : MainPosition → Nat → Nat → Nat → Nat → Nat → MainPosition × MainPosition × Nat) :
    (startProgram s id exitFn mainFn).map (fun next => withUnwind next (id+1)) =
      startHead s id exitFn mainFn := by
  dsimp only [startProgram,startHead,startNumbers,startCommitted,activateWaiting,coverExit,sourceExitState,
    moveWallets,setAccount,setWallet,setPosition,withUnwind,request,account,wallet,activeSupply,activeAssets,
    sourceValue,position,pendingAccounting,settle,cover,activatedRequest,
    fundId,vaultId,bind,pure,Except.bind,Except.pure,Except.map]
  split_ifs <;> first | rfl | contradiction

end Juicer.PublicCalls
