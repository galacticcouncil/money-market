import JuicerLean.Solidity.Bodies

namespace Juicer.Solidity

def accountingShiftIndex : Expr .word :=
  (.choose (.eq (.parameter 0) (.literal 0)) (.literal 0) (.add (.shr (.sub (.parameter 0) (.literal 1)) (.parameter 1)) (.literal 1)))

def vaultDepositBody : BodyBinding := {
  semantic := .vaultDeposit
  contract := .vault
  selector := 0x6e553f65
  source := "src/CollateralVault.sol"
  functionName := "deposit"
  astSha256 := "02df1ed7b157708fe806f5ae91207d86c50731ef6aec30841784f1bbbf71a10b"
  parameterCount := 2
  returnCount := 1
  statementCount := 21
  trace := [
    ⟨.block, "begin", 0⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.revert, "ZeroAddress", 2⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.revert, "DepositsArePaused", 2⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.revert, "ZeroAmount", 2⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.revert, "ZeroAddress", 2⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.revert, "DeleverPending", 2⟩,
    ⟨.call, "beforeDeposit", 1⟩,
    ⟨.call, "checkpoint", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.call, "totalSupply", 1⟩,
    ⟨.call, "hasRole", 1⟩,
    ⟨.call, "_depositCaller", 1⟩,
    ⟨.revert, "BootstrapRequired", 2⟩,
    ⟨.bind, "totalA", 1⟩,
    ⟨.call, "totalAssets", 1⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.revert, "ExceedsTvlCap", 2⟩,
    ⟨.bind, "supply", 1⟩,
    ⟨.call, "totalSupply", 1⟩,
    ⟨.write, "shares", 1⟩,
    ⟨.call, "_previewShares", 1⟩,
    ⟨.bind, "minimumAssets", 1⟩,
    ⟨.call, "ceilDiv", 1⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.call, "totalSupply", 1⟩,
    ⟨.call, "_mint", 2⟩,
    ⟨.call, "_mint", 1⟩,
    ⟨.call, "functionDelegateCall", 1⟩,
    ⟨.call, "encodeCall", 1⟩,
    ⟨.write, "reinvestAssets", 1⟩,
    ⟨.call, "_refreshDiscount", 1⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.call, "synthLtBps", 1⟩,
    ⟨.call, "balanceOf", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.revert, "PrincipalNotFloored", 2⟩,
    ⟨.call, "_coverRounding", 1⟩,
    ⟨.emit, "Deposited", 1⟩,
    ⟨.block, "end", 0⟩
  ]
}

def accountingBeginHarvestBody : BodyBinding := {
  semantic := .accountingBeginHarvest
  contract := .accounting
  selector := 0x1def7faa
  source := "src/JuicerYieldAccounting.sol"
  functionName := "beginHarvest"
  astSha256 := "062517e59200e9147e914284dd0e0aa6c1fdaae8c4ddb9efa888fcdf3b121709"
  parameterCount := 1
  returnCount := 0
  statementCount := 6
  trace := [
    ⟨.block, "begin", 0⟩,
    ⟨.bind, "available", 1⟩,
    ⟨.call, "harvestableShares", 1⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.revert, "InvalidHarvest", 2⟩,
    ⟨.write, "harvestUnits", 1⟩,
    ⟨.bind, "reserved", 1⟩,
    ⟨.call, "reservedShares", 1⟩,
    ⟨.bind, "service", 1⟩,
    ⟨.bind, "realized", 1⟩,
    ⟨.write, "harvestRewardUnits", 1⟩,
    ⟨.call, "mulDiv", 1⟩,
    ⟨.write, "harvestProtocolUnits", 1⟩,
    ⟨.write, "sourceShares", 1⟩,
    ⟨.write, "protocolShares", 1⟩,
    ⟨.block, "end", 0⟩
  ]
}

def accountingSplitHarvestBody : BodyBinding := {
  semantic := .accountingSplitHarvest
  contract := .accounting
  selector := 0xad81f8c0
  source := "src/JuicerYieldAccounting.sol"
  functionName := "splitHarvest"
  astSha256 := "6ffbbe3a30a2b6d2fcb4f6bbebb8b01c9cff29ce66288c0bf2096cf3eb834247"
  parameterCount := 1
  returnCount := 3
  statementCount := 3
  trace := [
    ⟨.block, "begin", 0⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.revert, "InvalidHarvest", 2⟩,
    ⟨.write, "reward", 1⟩,
    ⟨.call, "mulDiv", 1⟩,
    ⟨.write, "fee", 1⟩,
    ⟨.call, "mulDiv", 1⟩,
    ⟨.write, "service", 1⟩,
    ⟨.bind, "serviceFee", 1⟩,
    ⟨.call, "mulDiv", 1⟩,
    ⟨.call, "_fee", 1⟩,
    ⟨.write, "fee", 1⟩,
    ⟨.write, "service", 1⟩,
    ⟨.write, "harvestUnits", 1⟩,
    ⟨.write, "harvestRewardUnits", 1⟩,
    ⟨.write, "harvestProtocolUnits", 1⟩,
    ⟨.block, "end", 0⟩
  ]
}

def vaultStartUnwindsBody : BodyBinding := {
  semantic := .vaultStartUnwinds
  contract := .vault
  selector := 0x1b727f39
  source := "src/CollateralVault.sol"
  functionName := "startUnwinds"
  astSha256 := "11cde5d23cb1ff8617308b3ebca90bdb9afec9f697a6c62883213db36193c703"
  parameterCount := 1
  returnCount := 0
  statementCount := 6
  trace := [
    ⟨.block, "begin", 0⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.call, "activeSourceRemaining", 1⟩,
    ⟨.return, "return", 2⟩,
    ⟨.bind, "next", 1⟩,
    ⟨.loop, "while", 1⟩,
    ⟨.block, "begin", 2⟩,
    ⟨.branch, "if", 3⟩,
    ⟨.break, "break", 4⟩,
    ⟨.call, "_startUnwind", 3⟩,
    ⟨.write, "next", 3⟩,
    ⟨.write, "maxRequests", 3⟩,
    ⟨.block, "end", 2⟩,
    ⟨.write, "queueUnwind", 1⟩,
    ⟨.block, "end", 0⟩
  ]
}

def vaultPokeSettleBody : BodyBinding := {
  semantic := .vaultPokeSettle
  contract := .vault
  selector := 0xe891ab49
  source := "src/CollateralVault.sol"
  functionName := "pokeSettle"
  astSha256 := "0e09ffc5c9cf82808611cb667f8185023746b8d8aabc64c5a5cea3653ffb1806"
  parameterCount := 0
  returnCount := 1
  statementCount := 27
  trace := [
    ⟨.block, "begin", 0⟩,
    ⟨.bind, "debtBefore", 1⟩,
    ⟨.call, "balanceOf", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.bind, "headBefore", 1⟩,
    ⟨.bind, "accounting", 1⟩,
    ⟨.call, "pendingSourceAccounting", 1⟩,
    ⟨.bind, "assetsBefore", 1⟩,
    ⟨.call, "totalAssets", 1⟩,
    ⟨.bind, "freed", 1⟩,
    ⟨.call, "pullFreed", 1⟩,
    ⟨.call, "forceApprove", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.bind, "executionCost", 1⟩,
    ⟨.call, "creditSource", 1⟩,
    ⟨.write, "deleverTarget", 1⟩,
    ⟨.call, "min", 1⟩,
    ⟨.call, "forceApprove", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.write, "availableHollar", 1⟩,
    ⟨.call, "balanceOf", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.block, "begin", 2⟩,
    ⟨.bind, "repaid", 3⟩,
    ⟨.call, "_repayMain", 3⟩,
    ⟨.write, "deleverTarget", 3⟩,
    ⟨.call, "min", 3⟩,
    ⟨.block, "end", 2⟩,
    ⟨.block, "begin", 2⟩,
    ⟨.call, "_repayMain", 3⟩,
    ⟨.block, "end", 2⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.call, "balanceOf", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.write, "deleverTarget", 2⟩,
    ⟨.bind, "head", 1⟩,
    ⟨.bind, "end", 1⟩,
    ⟨.branch, "if", 1⟩,
    ⟨.write, "end", 2⟩,
    ⟨.loop, "while", 1⟩,
    ⟨.call, "paused", 1⟩,
    ⟨.block, "begin", 2⟩,
    ⟨.bind, "r", 3⟩,
    ⟨.bind, "remainingDebt", 3⟩,
    ⟨.branch, "if", 3⟩,
    ⟨.block, "begin", 4⟩,
    ⟨.bind, "paid", 5⟩,
    ⟨.call, "_repayMain", 5⟩,
    ⟨.branch, "if", 5⟩,
    ⟨.write, "paid", 6⟩,
    ⟨.write, "repaid", 5⟩,
    ⟨.write, "totalQueuedDebt", 5⟩,
    ⟨.block, "end", 4⟩,
    ⟨.bind, "entitled", 3⟩,
    ⟨.bind, "collRel", 3⟩,
    ⟨.branch, "if", 3⟩,
    ⟨.block, "begin", 4⟩,
    ⟨.bind, "supplied", 5⟩,
    ⟨.call, "balanceOf", 5⟩,
    ⟨.call, "address", 5⟩,
    ⟨.bind, "withdraw", 5⟩,
    ⟨.branch, "if", 5⟩,
    ⟨.call, "withdraw", 6⟩,
    ⟨.call, "address", 6⟩,
    ⟨.call, "address", 6⟩,
    ⟨.write, "collateralSettled", 5⟩,
    ⟨.block, "end", 4⟩,
    ⟨.emit, "RedeemSettled", 3⟩,
    ⟨.branch, "if", 3⟩,
    ⟨.write, "head", 4⟩,
    ⟨.break, "break", 4⟩,
    ⟨.block, "end", 2⟩,
    ⟨.write, "queueHead", 1⟩,
    ⟨.call, "_coverRounding", 1⟩,
    ⟨.call, "_refreshDiscount", 1⟩,
    ⟨.write, "work", 1⟩,
    ⟨.call, "min", 1⟩,
    ⟨.call, "balanceOf", 1⟩,
    ⟨.call, "address", 1⟩,
    ⟨.block, "end", 0⟩
  ]
}

end Juicer.Solidity
