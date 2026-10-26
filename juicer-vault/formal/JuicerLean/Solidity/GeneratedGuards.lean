import JuicerLean.Solidity.Guards

namespace Juicer.Solidity

def accountingOnlyVault : GuardPlan := .onlyVault
def mainOnlyVault : GuardPlan := .onlyVault
def regularNonReentrant : GuardPlan := .nonReentrant 2 1
def vaultNonReentrant : GuardPlan := .nonReentrant 2 1
def vaultTransferGuard : TransferGuard := ⟨2⟩

def guardPrefix : GuardContract → Nat → List GuardPlan
  | .accounting, 0x1def7faa => [accountingOnlyVault]
  | .accounting, 0x362a4dce => [accountingOnlyVault]
  | .accounting, 0x5518312e => [accountingOnlyVault]
  | .accounting, 0x92669141 => [accountingOnlyVault]
  | .accounting, 0xad81f8c0 => [accountingOnlyVault]
  | .accounting, 0xbb55b7fc => [accountingOnlyVault]
  | .accounting, 0xe493d299 => [accountingOnlyVault]
  | .mainDebt, 0x16a2ec1f => [mainOnlyVault,regularNonReentrant]
  | .mainDebt, 0x1b2522bc => [regularNonReentrant]
  | .mainDebt, 0x1c58ce14 => [regularNonReentrant]
  | .mainDebt, 0x573fef0a => [mainOnlyVault,regularNonReentrant]
  | .mainDebt, 0x75c54224 => [regularNonReentrant]
  | .mainDebt, 0x7c3db456 => [mainOnlyVault]
  | .mainDebt, 0x7f2dea43 => [mainOnlyVault,regularNonReentrant]
  | .mainDebt, 0x895a7485 => [mainOnlyVault,regularNonReentrant]
  | .mainDebt, 0x9151cbdc => [regularNonReentrant]
  | .mainDebt, 0xddc63262 => [mainOnlyVault,regularNonReentrant]
  | .mainDebt, 0xf5189ee3 => [mainOnlyVault,regularNonReentrant]
  | .vault, 0x107703ab => [vaultNonReentrant]
  | .vault, 0x1b727f39 => [vaultNonReentrant]
  | .vault, 0x526be9a8 => [vaultNonReentrant]
  | .vault, 0x5e737548 => [vaultNonReentrant]
  | .vault, 0x6e553f65 => [vaultNonReentrant]
  | .vault, 0x7b96a8e1 => [vaultNonReentrant]
  | .vault, 0x7d7c2a1c => [vaultNonReentrant]
  | .vault, 0xb49c201c => [vaultNonReentrant]
  | .vault, 0xe891ab49 => [vaultNonReentrant]
  | .vault, 0xeebca7b6 => [vaultNonReentrant]
  | .vault, 0xfff6cae9 => [vaultNonReentrant]
  | .controller, 0x04ad1cea => [regularNonReentrant]
  | .controller, 0x308521bb => [regularNonReentrant]
  | .controller, 0x8e9b05c6 => [regularNonReentrant]
  | _, _ => []

end Juicer.Solidity
