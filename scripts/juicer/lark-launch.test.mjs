import test from 'node:test';
import assert from 'node:assert/strict';
import {adoptLaunch,failedEvent,executedBuys} from './lark-launch.mjs';
import {resolveProfile} from './lark-pins.mjs';
import {VAULTS} from './launch-manifest.mjs';

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

test('a treasury buy counts once its exact amount came out within the bound', () => {
 const buy={assetIn:222,assetOut:4200,amountOut:'6000000000000000',maxAmountIn:'20918201433238759011'};
 const rows=[{block:264,routerExecuted:[]},{block:265,routerExecuted:[['222','4200','13946170721985003238','6000000000000000']]}];
 assert.deepEqual(executedBuys(rows,[buy]),[{...buy,block:265,amountIn:'13946170721985003238',withinBound:true}]);
 assert.equal(executedBuys([{block:265,routerExecuted:[['222','4200','20918201433238759012','6000000000000000']]}],[buy])[0].withinBound,false,'over the bound');
 assert.equal(executedBuys([{block:265,routerExecuted:[['222','4200','1','5000000000000000']]}],[buy])[0].withinBound,false,'another amount');
 assert.equal(executedBuys(rows,[{...buy,assetIn:0}])[0].withinBound,false,'another input');
 assert.deepEqual(executedBuys(rows),[],'a plan without buys');
});

test('lark4main rehearses the launch on lark 4 with mainnet\'s payload, the deploy\'s cap kept, on its own files', () => {
 const p=resolveProfile('lark4main',{LARK_STATE_DIR:'/var/lark'}),eth=resolveProfile('lark0eth',{});
 assert.equal(p.launch,true);
 assert.deepEqual([p.chainName,p.genesis,p.deployment,p.commit],['Lark 4 Hydration','0xdaf700942d599e55480ab44ea14c007ffb4120e873940983f7efa446589c079c','lark4-20261104',eth.commit]);
 assert.deepEqual([p.rpc,p.ws],['https://node4.lark.hydration.cloud','wss://node4.lark.hydration.cloud']);
 assert.deepEqual(p.gateway,{rpc:'https://4.lark.hydration.cloud',ws:'wss://4.lark.hydration.cloud'});
 assert.notEqual(p.genesis,resolveProfile('lark4rc',{}).genesis,'a refork, not the 30 oct chain');
 for(const k of ['collateral','names','artifactDir','adapterArtifact','signers','images'])assert.deepEqual(p[k],eth[k],k);
 assert.equal(p.primePool.feePpm,null,'no lark step may set the fee the launch referendum sets');
 assert.deepEqual(p.depositor.caps,{ETH:VAULTS.ETH.cap},'the depositor leaves the 44.4 GIGAETH launch cap');
 assert.deepEqual([p.depositor.usd,p.depositor.durationS,p.depositor.everyS,p.depositor.delayS],[{ETH:100000},36000,600,3600]);
 assert.deepEqual([p.journal,p.prices,p.manifest,p.stack.file],['/var/lark/juicer-lark-lark4-20261104.json','/var/lark/juicer-lark-prices-lark4-20261104.json',
  '/var/lark/juicer-lark-manifest-lark4-20261104.json','/var/lark/juicer-lark-stack-lark4-20261104.json']);
 assert.deepEqual([p.stack.name,p.stack.manifestConfig],['juicer-lark4-20261104','juicer-lark4-20261104-manifest-v1']);
 assert.deepEqual(p.stack.keeperRpcUrls,['https://node4.lark.hydration.cloud','https://4.lark.hydration.cloud']);
 assert.deepEqual([p.stack.keeperEnv,p.stack.bots],[eth.stack.keeperEnv,eth.stack.bots]);
 assert.deepEqual(p.stack.botEnv,{LARK_RPC:'https://node4.lark.hydration.cloud',LARK_WS:'wss://node4.lark.hydration.cloud'});
});
