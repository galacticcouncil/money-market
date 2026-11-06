// Finite, explicitly recorded test inventory; no mainnet transactions or yield.
import assert from 'node:assert/strict';
import {context,live} from './lark-context.mjs';
const c=await context();
try{
 assert.ok(live,'--live required');
 await c.mintTestHollar(`arb.refill-hollar-${Date.now()}`,'0x'+Buffer.from(c.arb.publicKey.slice(0,20)).toString('hex'),50000n*10n**18n);
}finally{await c.api.disconnect();}
