import test from 'node:test';
import assert from 'node:assert/strict';
import {adoptLaunch,failedEvent} from './lark-launch.mjs';
import {resolveProfile} from './lark-pins.mjs';

const genesis=`0x${'a6'.repeat(32)}`;
const manifest=()=>({kind:'juicer-launch',genesis,deployer:'0xd1',committee:'0x146a',prediction:{creator:'0xe64c',nonce:97,aSynthetic:'0x3a31'},checks:{deployerHoldsNoRole:true},
 deployments:Array(13).fill({}),calls:[{label:'HydraAugustus.transferOwnership'}],
 market:{pool:'0x1b02',hollar:'0x531a',hollarDebt:'0x3429',prime:'0x2b',aPrime:'0x4c89',treasury:'0xe525',dispatch:'0x0401'},
 addresses:{adapter:'0xad',compoundLogic:'0xc1',vaultImpl:'0xc2',synth:'0x51',subLogic:'0xc3',subImpl:'0xc4',subLoop:'0x10',harvester:'0x11',fees:'0x12',controller:'0x13',discount:'0x14'},
 vaults:[{key:'ETH',name:'Juicer ETH',symbol:'jETH',assetId:4200,asset:'0x1068',aToken:'0x8a59',cap:'100',address:'0x21',mainDebt:'0x31',yieldAccounting:'0x41',rounding:{vault:'0x21',assetId:4200,minimum:'3000',target:'1000010000'}},{key:'TBTC'}]});
const plan={policy:{maxQuoteAge:60,budgets:[],limits:[]},values:{slippagePpm:3500,synthAssetId:5550,withdrawalDelay:60},proposal:{hash:'0x0794',len:16874},batches:[{},{},{},{},{}]};

test('the launch manifest lands where the lark steps after the referendum read it', () => {
 const r=adoptLaunch({genesis,addresses:{},testSigners:{deployer:'0xd1'}},manifest());
 assert.equal(r.addresses.source,'0x10','the loop is the source the lark tooling knows');
 assert.deepEqual([r.addresses.harvester,r.addresses.controller,r.addresses.discount,r.addresses.adapter],['0x11','0x13','0x14','0xad']);
 assert.equal(r.market.swapper,'0xad');
 assert.deepEqual(r.vaults,[{name:'ETH',symbol:'jETH',assetId:4200,asset:'0x1068',aToken:'0x8a59',cap:'100',address:'0x21',mainDebt:'0x31',yieldAccounting:'0x41',
  rounding:{vault:'0x21',assetId:4200,minimum:'3000',target:'1000010000'}}],'an undeployed vault row stays out');
 assert.deepEqual([r.feeRecipient,r.committee,r.launch.deployments,r.launch.calls],['0xe525','0x146a',13,1]);
 assert.equal(r.executionPolicy,undefined,'no policy before the plan');
});

test('the plan adds the approved policy and values, and a manifest from another chain is refused', () => {
 const r=adoptLaunch({genesis,addresses:{}},manifest(),plan);
 assert.deepEqual([r.executionPolicy,r.sourceSlippagePpm,r.synthAssetId,r.launch.proposal],[plan.policy,3500,5550,{hash:'0x0794',len:16874,batches:5}]);
 assert.throws(()=>adoptLaunch({genesis:`0x${'00'.repeat(32)}`},manifest()),/another chain/);
 assert.throws(()=>adoptLaunch({genesis},{...manifest(),kind:'other'}),/not a launch manifest/);
 assert.throws(()=>adoptLaunch({genesis},{...manifest(),vaults:[{key:'ETH'}]}),/has not finished/);
});

test('a block is clean only without failed calls, interrupted batches or dispatch errors', () => {
 assert.ok(failedEvent('evm','ExecutedFailed',['0x21']));
 assert.ok(failedEvent('utility','BatchInterrupted',[0,{}]));
 assert.ok(failedEvent('scheduler','PermanentlyOverweight',[]));
 assert.ok(failedEvent('scheduler','Dispatched',[[264,0],null,{err:{module:{index:51}}}]));
 assert.ok(failedEvent('dispatcher','TreasuryManagerCallDispatched',['0x',{err:'BadOrigin'}]));
 assert.equal(failedEvent('scheduler','Dispatched',[[264,0],null,{ok:null}]),false);
 assert.equal(failedEvent('dispatcher','AaveManagerCallDispatched',['0x',{ok:{actualWeight:null}}]),false);
 assert.equal(failedEvent('evm','Executed',['0x21']),false);
});

test('lark0eth runs the launch process on lark 0: jETH on GIGAETH alone, the pool fee left to the referendum', () => {
 const p=resolveProfile('lark0eth',{});
 assert.equal(p.launch,true);
 assert.equal(resolveProfile('lark0',{}).launch,false);
 assert.deepEqual([p.chainName,p.genesis,p.deployment],['Lark 0 Hydration','0xa637c6bb6f61286b935b883bf5c6f9dbb00aa34054d0558952f9e7284e580a2a','lark0-20261102']);
 assert.deepEqual(Object.keys(p.collateral),['ETH']);
 assert.equal(p.collateral.ETH.assetId,4200);
 assert.deepEqual(p.names.vaults,{ETH:['Juicer ETH','jETH']});
 assert.equal(p.primePool.feePpm,null,'no lark step may set the fee the launch referendum sets');
 assert.deepEqual([p.depositor.usd,p.depositor.caps,p.depositor.everyS,p.depositor.delayS],[{ETH:100000},{ETH:100n*10n**18n},600,3600]);
 assert.deepEqual(p.stack.keeperRpcUrls,['https://node0.lark.hydration.cloud','https://0.lark.hydration.cloud']);
 assert.deepEqual(p.stack.keeperEnv,resolveProfile('lark0',{}).stack.keeperEnv);
 assert.deepEqual([p.stack.name,p.stack.manifestConfig],['juicer-lark0-20261102','juicer-lark0-20261102-manifest-v1']);
});
