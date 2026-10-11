// What the SubLoop needs before its entries and routine exits go through ICE intents:
// the intent config, KEEPER_ROLE for both keepers (quoted pokes), async controller lanes
// and a fee currency for the lazy-executor callback. Pure; lark-ice-wiring.mjs reads the
// state and turns the actions into one referendum.
export const WETH=20;
// what the step reads and calls, checked against the contract sources by its test
export const LOOP_ABI=['function configureIntents(uint32,uint16)','function grantRole(bytes32,address)','function hasRole(bytes32,address) view returns(bool)','function KEEPER_ROLE() view returns(bytes32)','function intentTtl() view returns(uint32)','function intentDriftBps() view returns(uint16)'];
export const CONTROLLER_ABI=['function configureAsync(bytes32,bool)','function asyncLanes(bytes32) view returns(bool)','function limits(bytes32) view returns(bytes32,uint128,uint128)'];
export const ICE={
 // seconds: the loop sets each deadline to (block.timestamp + ttl) * 1000 ms
 ttl:300,
 // keeper-quote tolerance beside the solver's 1 bp haircut, as the keeper's own QUOTE_DRIFT_BPS
 driftBps:2,
 // an EVM account pays fees in WETH unless its first token deposit, holding no HDX, picks
 // that token; the spike's callbacks cost ~0.57 HDX (~$0.004, ~1.5e12 wei of WETH) each
 callbackWeth:10n**16n,
 // any HDX keeps the first-deposit hook from ever switching the fee currency to HOLLAR
 hdx:10n*10n**12n,
};
// state: {intentTtl, intentDriftBps, keepers:[{address,hasRole}], lanes:[{name,lane,maximum,async}],
// feeCurrency (asset id or null), weth, hdx (raw balances of the loop's mapped account)}
export function icePlan(state,config=ICE){
 const {ttl,driftBps,callbackWeth,hdx}=config;
 if(!(Number.isInteger(ttl)&&ttl>0&&ttl<86400))throw Error(`intent ttl ${ttl}: seconds, above 0 and under a day`);
 if(!(Number.isInteger(driftBps)&&driftBps>=0&&driftBps<9999))throw Error(`intent drift ${driftBps} bps out of range`);
 for(const l of state.lanes)if(!(BigInt(l.maximum)>0n))throw Error(`${l.name} lane has no limit; wire the execution lanes first`);
 if(state.keepers.length<1||state.keepers.some(k=>!k.address))throw Error('keeper signers missing');
 const actions=[];
 if(Number(state.intentTtl)!==ttl||Number(state.intentDriftBps)!==driftBps)actions.push({kind:'intents',ttl,driftBps});
 for(const k of state.keepers)if(!k.hasRole)actions.push({kind:'keeper',keeper:k.address});
 for(const l of state.lanes)if(!l.async)actions.push({kind:'async',name:l.name,lane:l.lane});
 if(state.feeCurrency!==WETH)actions.push({kind:'fee-currency'});
 if(BigInt(state.hdx)===0n)actions.push({kind:'hdx',amount:hdx});
 if(BigInt(state.weth)*2n<callbackWeth)actions.push({kind:'weth',amount:callbackWeth-BigInt(state.weth)});
 return actions;
}
