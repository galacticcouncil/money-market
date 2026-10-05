import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {context,GOV,live} from './lark-context.mjs';
const c=await context();
try{
 assert.ok(live);const core=JSON.parse(readFileSync('/tmp/propeller-lark-20261005.json','utf8'));
 assert.equal(core.genesis,c.r.genesis);assert.ok(core.addresses.aSynthetic);
 const debt=core.market.hollarDebt;
 c.r.previousDiscount={token:await c.readSig(debt,'function getDiscountToken() view returns(address)'),strategy:await c.readSig(debt,'function getDiscountRateStrategy() view returns(address)')};
 assert.equal(c.r.previousDiscount.strategy.toLowerCase(),'0x33a7c640140febafecc9801af723a0c14420eed7','unexpected existing discount policy');
 const deployment=JSON.parse(readFileSync(new URL('../../deployments/hydration/ZeroDiscountRateStrategy.json',import.meta.url),'utf8'));
 assert.equal((await c.pub.getBytecode({address:c.r.previousDiscount.strategy})).toLowerCase(),deployment.deployedBytecode.toLowerCase(),'baseline is not the recorded zero-discount strategy');
 c.r.addresses.discount=await c.deploy('PropellerDiscount',[debt,core.addresses.synth,core.addresses.aSynthetic,GOV,'0x146a5e57fa0b8b1e13c53bcf1d05183b1c02b51b']);
 c.r.discountBps=0;c.save();
}finally{await c.api.disconnect()}
