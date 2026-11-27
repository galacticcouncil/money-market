// Lark only, before the launch referendum: what a fork needs and mainnet already has, and nothing the
// referendum does itself. the mirror signer, second keeper and ui funded, the PRIME mirror in the market
// oracle and pool 143's peg, the markets arb bound with test HOLLAR, and the treasury holding the
// collateral the referendum's bootstrap takes from it (mainnet's holds too little GIGAETH).
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {context,v,testAccount,live} from './lark-context.mjs';
import {profile,PRICES_FILE} from './lark-pins.mjs';
import {recordBuy,buyCall,checkBuys,assertBought} from './lark-collateral.mjs';
const {u8aConcat,stringToU8a}=createRequire(import.meta.url)('@polkadot/util');
assert.ok(profile.launch,`${profile.name} is not a launch-process profile`);
const ORACLE='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760',COMMITTEE='0x146a5e57fa0b8b1e13c53bcf1d05183b1c02b51b';
const UI={address:'0x3088c164994890ea0e444bf53623ccac3b307217',who:'5DALnDnFwQpdMTeL8bcRMNCbkpXpG9DJb2uBfvdosLvuC523'};
const [[name,collateral]]=Object.entries(profile.collateral);
const prices=JSON.parse(readFileSync(PRICES_FILE,'utf8'));
const c=await context();
try{
 const {r,api,readSig,govEvm,enact,save,nativeAccount}=c;
 assert.equal(r.genesis,prices.genesis);
 r.oracles=prices.oracles;r.committee=COMMITTEE;save();
 const mirrors=r.oracles.filter(o=>o.mirror!==false);
 const accounts=[
  {name:'oracle',address:testAccount(19).address,who:await nativeAccount(testAccount(19).address),balances:[[0,100n*10n**12n],[20,10n**18n]]},
  {name:'keeperSecondary',address:testAccount(20).address,who:await nativeAccount(testAccount(20).address),balances:[[0,100n*10n**12n],[20,10n**18n]]},
  {name:'ui',...UI,balances:[[0,100n*10n**12n],...(collateral.buy?[[collateral.buy.from,10n**17n]]:[[collateral.assetId,10n**15n]])]},
 ];
 r.additionalTestFunding=accounts;Object.assign(r.testSigners,Object.fromEntries(accounts.map(a=>[a.name,a.address])));save();
 const uiBuy=collateral.buy?await recordBuy(c,collateral,'ui',5n*10n**16n):null;
 const funding=accounts.flatMap(a=>[api.tx.duster.whitelistAccount(a.who),...a.balances.map(([id,amount])=>api.tx.currencies.updateBalance(a.who,id,amount.toString())),
  ...(uiBuy&&a.name==='ui'?[buyCall(api,a.who,collateral,uiBuy.amount,uiBuy.max)]:[])]);
 if(uiBuy)await checkBuys(c,'fund-bots-and-ui',funding,1,{collateral,amount:uiBuy.amount});
 await enact('fund-bots-and-ui',funding);
 // the market oracle and pool 143 follow the mirrors the mirror bot keeps on mainnet's prices
 if(!r.previousOracles){
  r.previousOracles=[];
  for(const o of mirrors)r.previousOracles.push({asset:o.asset,source:await readSig(ORACLE,'function getSourceOfAsset(address) view returns(address)',[o.asset])});
  r.previousPrimePeg=(await api.query.stableswap.poolPegs(143)).toJSON();save();
 }
 const prime=r.oracles.find(o=>o.assetId===43);assert.ok(prime&&prime.mirror!==false,'run lark-prices-deploy.mjs first: PRIME needs a mirror');
 await enact('install-testnet-mirrors',[
  govEvm(ORACLE,v.parseAbi(['function setAssetSources(address[],address[])']),'setAssetSources',[mirrors.map(o=>o.asset),mirrors.map(o=>o.address)],1000000),
  api.tx.stableswap.updateAssetPegSource(143,43,{MMOracle:prime.address}),
 ]);
 const arbEvm='0x'+Buffer.from(c.arb.publicKey.slice(0,20)).toString('hex');
 if((await api.query.evmAccounts.accountExtension(arbEvm)).isNone)await c.sign(api.tx.evmAccounts.bindEvmAddress(),'arb.bind-evm',c.arb);
 await c.mintTestHollar('arb.mint-test-hollar',arbEvm,60000n*10n**18n);
 r.testSigners.arb=arbEvm;save();
 // the referendum pays rounding and bootstrap collateral from the treasury, as it would on mainnet
 if(collateral.buy){
  const treasury=api.registry.createType('AccountId',u8aConcat(stringToU8a('modl'),api.consts.treasury.palletId.toU8a(),new Uint8Array(20))).toString();
  const held=(await api.call.currenciesApi.account(collateral.assetId,treasury)).free.toBigInt();
  r.treasuryTopUp??={asset:collateral.assetId,before:held.toString()};save();
  const buy=await recordBuy(c,collateral,'treasury',10n**15n);
  const calls=[buyCall(api,treasury,collateral,buy.amount,buy.max)];
  await checkBuys(c,`treasury-${name.toLowerCase()}-for-the-bootstrap`,calls,1,{collateral,amount:buy.amount});
  await enact(`treasury-${name.toLowerCase()}-for-the-bootstrap`,calls);
  if(live)assertBought(r,`treasury-${name.toLowerCase()}-for-the-bootstrap`);
 }
 if(live){
  for(const o of mirrors)assert.equal((await readSig(ORACLE,'function getSourceOfAsset(address) view returns(address)',[o.asset])).toLowerCase(),o.address.toLowerCase());
  assert.ok(await readSig('0x531a654d1696ED52e7275A8cede955E82620f99a','function balanceOf(address) view returns(uint256)',[arbEvm])>=60000n*10n**18n);
  if(uiBuy)assertBought(r,'fund-bots-and-ui');
  r.checks.launchMarket=true;r.status='lark-scaffold-ready-for-the-launch-deploy';save();
  console.log('LARK MARKET READY',JSON.stringify({mirrors:mirrors.map(o=>o.name),arb:arbEvm,treasury:r.treasuryTopUp}));
 }
}finally{await c.api.disconnect();}
