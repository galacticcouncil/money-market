import assert from 'node:assert/strict';
import {context,artifact,v,deployer,role,live} from './lark-context.mjs';
const c=await context();
try{
 const {r,read,readSig,write,evmSend,save}=c;
 assert.ok(r.governance.find(g=>g.label==='testnet-guardians-and-open-bootstrap')?.verified);
 for(const vault of r.vaults){
   const seed=vault.assetId===34?10n**16n:10n**14n;
   const reserve=BigInt(vault.rounding.target),amount=seed+reserve;
   await evmSend(`bootstrap.${vault.name}.approve`,vault.asset,v.encodeFunctionData({abi:v.parseAbi(['function approve(address,uint256) returns(bool)']),functionName:'approve',args:[vault.address,amount]}));
   await write(`bootstrap.${vault.name}.rounding`,'CollateralVault',vault.address,'fundRoundingReserve',[reserve]);
   await write(`bootstrap.${vault.name}.deposit`,'CollateralVault',vault.address,'deposit',[seed,deployer.address]);
   assert.ok(await read('CollateralVault',vault.address,'totalSupply')>0n);
   assert.equal(await readSig('0x342923782cCaEBf9c38DD9cb40436e82C42c73B5','function balanceOf(address) view returns(uint256)',[vault.address]),0n,'bootstrap unexpectedly borrowed');
   assert.equal(await read('CollateralVault',vault.address,'reinvestAssets'),seed);
 }
 await c.enact('revoke-temporary-bootstrap-admin',r.vaults.map(vault=>c.govEvm(vault.address,artifact('CollateralVault').abi,'revokeRole',[role('ADMIN_ROLE'),deployer.address],500000)));
 r.checks.bootstrapNoBorrow=true;r.status='bootstrapped-awaiting-browser-and-keeper-proof';save();
}finally{await c.api.disconnect();}
