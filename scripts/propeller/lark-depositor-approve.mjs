// Lark only: hydration asset precompiles revert approve() above u128, so the
// deposits bot's maxUint256 approval fails. pre-approve u128 max per user/vault.
import assert from 'node:assert/strict';
import {context,v,testAccount,live} from './lark-context.mjs';
const MAX_U128=2n**128n-1n;
const abi=v.parseAbi(['function approve(address,uint256) returns(bool)','function allowance(address,address) view returns(uint256)']);
const c=await context();
try{
 const {pub,r,save}=c;
 assert.ok(r.depositor,'run lark-depositor-setup.mjs first');
 r.depositor.approvals??=[];
 const chain={id:222222,name:'Lark 4 Hydration',nativeCurrency:{name:'WETH',symbol:'WETH',decimals:18},rpcUrls:{default:{http:['https://node4.lark.hydration.cloud']}}};
 for(const u of r.depositor.users)for(const p of r.depositor.plan){
  const account=testAccount(u.index);assert.equal(account.address,u.address);
  const allowance=await pub.readContract({address:p.asset,abi,functionName:'allowance',args:[u.address,p.vault]});
  if(allowance>=MAX_U128/2n)continue;
  await pub.simulateContract({address:p.asset,abi,functionName:'approve',args:[p.vault,MAX_U128],account});
  if(!live){console.log('would approve',u.index,p.name);continue;}
  const wallet=v.createWalletClient({account,chain,transport:v.http('https://node4.lark.hydration.cloud',{timeout:60000})});
  const hash=await wallet.writeContract({address:p.asset,abi,functionName:'approve',args:[p.vault,MAX_U128],gas:80000n,gasPrice:await pub.getGasPrice()*2n,type:'legacy'});
  const receipt=await pub.waitForTransactionReceipt({hash,timeout:180000});assert.equal(receipt.status,'success');
  r.depositor.approvals.push({user:u.index,vault:p.name,hash,block:Number(receipt.blockNumber),allowance:MAX_U128.toString(),reason:'precompile rejects maxUint256 approvals'});save();
  console.log('APPROVED',u.index,p.name,hash);
 }
}finally{await c.api.disconnect();}
