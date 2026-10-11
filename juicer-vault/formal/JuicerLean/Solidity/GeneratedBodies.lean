import JuicerLean.Solidity.Expressions

namespace Juicer.Solidity

def accountingShiftIndex : Expr .word :=
  (.choose (.eq (.parameter 0) (.literal 0)) (.literal 0) (.add (.shr (.sub (.parameter 0) (.literal 1)) (.parameter 1)) (.literal 1)))

end Juicer.Solidity
