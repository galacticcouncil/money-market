// lark 4's real identities from before the rename: deployed token names, images and state
// files. the rename script leaves this file alone, so lark 4 keeps finding its chain.
export const LARK4_IDENTITY={
 artifactDir:'/tmp/propeller-london-db0799c',
 names:{
  synth:['Propeller Synthetic HOLLAR October','psHOL-OCT'],asset:'Propeller October HOLLAR',
  aToken:['Propeller October Synthetic aToken','aPS-OCT'],variableDebt:['Propeller October Variable Debt','vdPS-OCT'],stableDebt:['Propeller October Stable Debt','sdPS-OCT'],
  vaults:{ETH:['Propeller ETH October','pETH-OCT'],TBTC:['Propeller TBTC October','pTBTC-OCT']},
 },
 images:{keeper:'galacticcouncil/propeller-lark-keeper',bots:'galacticcouncil/propeller-lark-bots'},
 stackFile:'propeller-lark-stack.json',
 statePrefix:'propeller',
};
