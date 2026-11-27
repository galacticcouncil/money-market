// Lark only: test subsidy for an exit stuck on a sub-cent tail (its unwind cost
// left the FIFO head short), so settlement moves on. never yield.
import assert from 'node:assert/strict';
import {context,v,HOLLAR,deployer,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
// the next version checks underfunding off-chain and keeps a reserve for exit shortfalls
assert.ok(profile.legacy,`${profile.name}: no nurse or Main cushions on the next version`);
const arg=name=>process.argv.find(a=>a.startsWith(`--${name}=`))?.split('=')[1];
const name=arg('vault'),request=BigInt(arg('request')??-1),amount=BigInt(Math.round(Number(arg('hollar'))*1e6))*10n**12n;
assert.ok(name&&request>=0n&&amount>0n,'usage: --vault=<ETH|TBTC> --request=<id> --hollar=<amount> [--live]');
const c=await context();
try{
 const {r,readSig,evmSend,save}=c;
 const vault=r.vaults.find(x=>x.name===name);assert.ok(vault,`unknown vault ${name}`);
 const label=`exit-${name}-${request}`;
 const req=()=>readSig(vault.address,'function redemptions(uint256) view returns(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool)',[request]);
 const before=await req();console.log('BEFORE debtShare',before[3],'repaid',before[5],'head',await readSig(vault.address,'function queueHead() view returns(uint256)'));
 r.testSubsidies??=[];
 if(live&&!r.testSubsidies.some(s=>s.label===label)){
  if(await readSig(HOLLAR,'function balanceOf(address) view returns(uint256)',[deployer.address])<amount)await c.mintTestHollar(`deployer.mint-${label}`,deployer.address,amount);
  await evmSend(`${label}.approve`,HOLLAR,v.encodeFunctionData({abi:v.parseAbi(['function approve(address,uint256) returns(bool)']),functionName:'approve',args:[vault.mainDebt,amount]}));
  // exits are keyed id+1 in the Main ledger; 0 is the active cohort
  await evmSend(`${label}.fund`,vault.mainDebt,v.encodeFunctionData({abi:v.parseAbi(['function fundPosition(uint256,uint256)']),functionName:'fundPosition',args:[request+1n,amount]}));
  await evmSend(`${label}.settle`,vault.address,v.encodeFunctionData({abi:v.parseAbi(['function pokeSettle() returns(uint256)']),functionName:'pokeSettle'}));
  r.testSubsidies.push({label,vault:vault.address,request:request.toString(),hollar:amount.toString(),reason:'exit unwind cost left the FIFO head short'});save();
 }
 const after=await req();console.log('AFTER debtShare',after[3],'repaid',after[5],'head',await readSig(vault.address,'function queueHead() view returns(uint256)'));
}finally{await c.api.disconnect();}
