// Lark only: test subsidy that lifts the PRIME source back above its principal
// after deployment entry costs, so deposits and ramping resume. never yield.
import assert from 'node:assert/strict';
import {context,v,HOLLAR,deployer,live} from './lark-context.mjs';
const arg=name=>process.argv.find(a=>a.startsWith(`--${name}=`))?.split('=')[1];
const round=arg('round'),amount=BigInt(Math.round(Number(arg('hollar'))*1e6))*10n**12n;
assert.ok(round&&amount>0n,'usage: --round=<tag> --hollar=<amount> [--live]');
const c=await context();
try{
 const {r,read,readSig,evmSend,save}=c;
 const source=r.addresses.source,balance=a=>readSig(HOLLAR,'function balanceOf(address) view returns(uint256)',[a]);
 const state=async()=>({
  negativeCarryBps:await readSig(source,'function negativeCarryBps() view returns(uint256)'),
  equity:await readSig(source,'function totalEquity() view returns(uint256)'),
  principal:await readSig(source,'function principalEquity() view returns(uint256)'),
  underfunded:Object.fromEntries(await Promise.all(r.vaults.map(async x=>[x.name,await read('CollateralVault',x.address,'isUnderfunded')]))),
 });
 console.log('BEFORE',JSON.stringify(await state(),(_,x)=>typeof x==='bigint'?x.toString():x));
 r.testSubsidies??=[];
 if(live&&!r.testSubsidies.some(s=>s.round===round)){
  if(await balance(deployer.address)<amount)await c.mintTestHollar(`deployer.mint-recap-${round}`,deployer.address,amount);
  await evmSend(`recap-${round}.source.transfer`,HOLLAR,v.encodeFunctionData({abi:v.parseAbi(['function transfer(address,uint256) returns(bool)']),functionName:'transfer',args:[source,amount]}));
  r.testSubsidies.push({round,source,hollar:amount.toString(),reason:'deployment entry cost left the source below principal'});save();
 }
 console.log('AFTER',JSON.stringify(await state(),(_,x)=>typeof x==='bigint'?x.toString():x));
}finally{await c.api.disconnect();}
