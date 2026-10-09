// Lark only: a 0 bps floor never clears real ETH/tBTC routes (14-66 bps measured
// at test sizes). 100 bps on harvest and interest-sale lanes plus the vault floor.
import assert from 'node:assert/strict';
import {context,artifact,live} from './lark-context.mjs';
const BPS=100;
const c=await context();
try{
 const {r,govEvm,enact,save}=c;
 r.testnetApprovals??=[];
 if(!r.testnetApprovals.some(a=>a.id==='collateral-hundred-bps'))r.testnetApprovals.push({id:'collateral-hundred-bps',scope:'Lark only; ETH/tBTC harvest and Main interest-sale lanes, vault compound floor',maxShortfallBps:BPS,userAnswer:'0 price floor is unrealistic; make harvest work'});
 const lanes=r.executionPolicy.limits.filter(l=>l.consumer.toLowerCase()!==r.addresses.source.toLowerCase());
 assert.equal(lanes.length,6);
 const calls=[...lanes.map(l=>govEvm(r.addresses.controller,artifact('ExecutionController').abi,'configurePrice',[l.lane,BPS,l.safety],500000)),
  ...r.vaults.map(x=>govEvm(x.address,artifact('CollateralVault').abi,'setCompoundSlippageBps',[BPS],500000))];
 await enact('approved-lark-only-collateral-hundred-bps',calls);
 if(live){for(const l of lanes)l.maxShortfallBps=BPS;r.compoundSlippageBps=BPS;save();console.log('POLICY',BPS,'bps on',lanes.length,'lanes and',r.vaults.length,'vaults');}
}finally{await c.api.disconnect();}
