// Test-funding deposit hooks reserved the newly issued collateral. Move only
// the two fixture balances to free, preserving their exact totals and issuance.
import assert from 'node:assert/strict';
import {context,live} from './lark-context.mjs';
const c=await context();
try{
 const who='0x3088c164994890ea0e444bf53623ccac3b307217e1f1b600984a82454eb36a5e';
 const calls=[];
 for(const [id,expected]of [[34,10n**17n],[1000765,10n**15n]]){
  const balance=await c.api.query.tokens.accounts(who,id);
  assert.equal(BigInt(balance.free.toString())+BigInt(balance.reserved.toString()),expected,'fixture balance changed; inspect before unreserving');
  assert.equal(BigInt(balance.frozen.toString()),0n);
  calls.push(c.api.tx.tokens.setBalance(who,id,expected.toString(),'0'));
 }
 await c.enact('release-only-ui-test-funding',calls);
 if(live){for(const [id,expected]of [[34,10n**17n],[1000765,10n**15n]]){
  const balance=await c.api.query.tokens.accounts(who,id);assert.equal(BigInt(balance.free.toString()),expected);assert.equal(BigInt(balance.reserved.toString()),0n);
 }c.r.checks.uiFixtureFundingFree=true;c.save();}
}finally{await c.api.disconnect();}
