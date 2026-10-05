// Finite, explicitly recorded test inventory; no mainnet transactions or yield.
import assert from 'node:assert/strict';
import {context,live} from './lark-context.mjs';
const c=await context();
try{
 assert.ok(live,'--live required');
 await c.sign(c.api.tx.currencies.transfer(c.arb.address,222,(50000n*10n**18n).toString()),'arb.refill-hollar-for-post-catchup-unwind');
}finally{await c.api.disconnect();}
