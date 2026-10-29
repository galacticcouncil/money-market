// Fresh Lark-only oracle mirrors, public bot funding and zero-discount wiring, the loop enrolled.
// No mainnet writes. Every governance payload and receipt is recorded.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {context,artifact,v,testAccount,role,live} from './lark-context.mjs';
import {profile,PRICES_FILE} from './lark-pins.mjs';
import {recordBuy,buyCall,checkBuys,assertBought} from './lark-collateral.mjs';
const prices=JSON.parse(readFileSync(PRICES_FILE,'utf8')),{ETH:eth,TBTC:btc}=profile.collateral;
const c=await context();
try {
 const {r,api,readSig,govEvm,enact,save,nativeAccount}=c;
 assert.equal(r.genesis,prices.genesis);
 assert.ok(r.governance.find(g=>g.label==='bind-execution-controller')?.verified,'finish core wiring first');
 const oracle='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760';
 const debt='0x342923782cCaEBf9c38DD9cb40436e82C42c73B5';
 const committee='0x146a5e57fa0b8b1e13c53bcf1d05183b1c02b51b';
 r.addresses.discount=prices.addresses.discount;r.oracles=prices.oracles;r.previousDiscount=prices.previousDiscount;r.discountBps=0;r.committee=committee;
 // a collateral that keeps its forked source has a row but no mirror to install
 const mirrors=r.oracles.filter(o=>o.mirror!==false);
 const contract=(name,address,fn,args,gas=700000)=>govEvm(address,artifact(name).abi,fn,args,gas);
 const discountCalls=[
   govEvm(debt,v.parseAbi(['function updateDiscountToken(address)','function updateDiscountRateStrategy(address)']),'updateDiscountToken',[r.addresses.discount],1000000),
   govEvm(debt,v.parseAbi(['function updateDiscountToken(address)','function updateDiscountRateStrategy(address)']),'updateDiscountRateStrategy',[r.addresses.discount],1000000),
 ];
 for(const vault of r.vaults){
   discountCalls.push(contract('CollateralVault',vault.address,'setDiscountController',[r.addresses.discount]));
   discountCalls.push(contract('JuicerDiscount',r.addresses.discount,'registerVault',[vault.address]));
 }
 // the loop funds the vaults just registered; its cap is the HOLLAR the bucket can ever lend it
 if(!profile.legacy)discountCalls.push(contract('JuicerDiscount',r.addresses.discount,'registerLoop',[r.addresses.source,profile.hollarBucket]));
 discountCalls.push(contract('JuicerDiscount',r.addresses.discount,'setDiscountBps',[0]));
 await enact('install-zero-discount',discountCalls);
 if(!r.previousOracles){
   r.previousOracles=[];
   for(const o of mirrors)r.previousOracles.push({asset:o.asset,source:await readSig(oracle,'function getSourceOfAsset(address) view returns(address)',[o.asset])});
   r.previousPrimePeg=(await api.query.stableswap.poolPegs(143)).toJSON();save();
 }
 // one bounded peg catch-up; lark-approve-prime-cap restores the original
 // per-block limit once the live peg has converged
 await enact('install-fresh-testnet-prices',[
   govEvm(oracle,v.parseAbi(['function setAssetSources(address[],address[])']),'setAssetSources',[mirrors.map(o=>o.asset),mirrors.map(o=>o.address)],1000000),
   api.tx.stableswap.updateAssetPegSource(143,43,{MMOracle:r.oracles.find(o=>o.assetId===43).address}),
   api.tx.stableswap.updatePoolMaxPegUpdate(143,10000000),
 ]);
 const ui='5DALnDnFwQpdMTeL8bcRMNCbkpXpG9DJb2uBfvdosLvuC523';
 const accounts=[
   {name:'oracle',address:testAccount(19).address,who:await nativeAccount(testAccount(19).address),balances:[[0,100n*10n**12n],[20,10n**18n]]},
   {name:'keeperSecondary',address:testAccount(20).address,who:await nativeAccount(testAccount(20).address),balances:[[0,100n*10n**12n],[20,10n**18n]]},
   {name:'ui',address:'0x3088c164994890ea0e444bf53623ccac3b307217',who:ui,balances:[[0,100n*10n**12n],[34,10n**17n],[btc.assetId,10n**15n]]},
 ];
 r.additionalTestFunding=accounts;Object.assign(r.testSigners,Object.fromEntries(accounts.map(a=>[a.name,a.address])));save();
 // the ui pays a bought collateral from its ETH
 const uiBuy=eth.buy?await recordBuy(c,eth,'ui',5n*10n**16n):null;
 assert.ok(!uiBuy||BigInt(uiBuy.max)<=10n**17n,`ui: the ${eth.symbol} buy spends more than it is minted`);
 const funding=accounts.flatMap(a=>[api.tx.duster.whitelistAccount(a.who),...a.balances.map(([id,amount])=>api.tx.currencies.updateBalance(a.who,id,amount.toString())),
  ...(uiBuy&&a.name==='ui'?[buyCall(api,a.who,eth,uiBuy.amount,uiBuy.max)]:[])]);
 if(uiBuy)await checkBuys(c,'fund-bots-and-ui',funding,1,{collateral:eth,amount:uiBuy.amount});
 await enact('fund-bots-and-ui',funding);
 const arbEvm='0x'+Buffer.from(c.arb.publicKey.slice(0,20)).toString('hex');
 if((await api.query.evmAccounts.accountExtension(arbEvm)).isNone)await c.sign(api.tx.evmAccounts.bindEvmAddress(),'arb.bind-evm',c.arb);
 await c.mintTestHollar('arb.mint-test-hollar',arbEvm,50000n*10n**18n);
 r.testSigners.arb=arbEvm;save();
 const guardians=[contract('SubLoop',r.addresses.source,'grantRole',[role('GUARDIAN_ROLE'),committee])];
 for(const vault of r.vaults)guardians.push(contract('CollateralVault',vault.address,'grantRole',[role('GUARDIAN_ROLE'),committee]),contract('CollateralVault',vault.address,'unpauseDeposits',[]));
 await enact('testnet-guardians-and-open-bootstrap',guardians);
 if(live){
   for(const o of r.oracles)assert.equal((await readSig(oracle,'function getSourceOfAsset(address) view returns(address)',[o.asset])).toLowerCase(),o.address.toLowerCase());
   assert.ok(await readSig('0x531a654d1696ED52e7275A8cede955E82620f99a','function balanceOf(address) view returns(uint256)',[arbEvm])>=50000n*10n**18n);
   if(uiBuy)assertBought(r,'fund-bots-and-ui');
   r.status='markets-wired-awaiting-bootstrap';save();
 }
} finally {await c.api.disconnect();}
