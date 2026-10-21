import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {ICE,WETH,LOOP_ABI,CONTROLLER_ABI,icePlan} from './lark-ice-plan.mjs';
const src=name=>readFileSync(join(fileURLToPath(new URL('../../juicer-vault/src/',import.meta.url)),name),'utf8');
const lane=n=>`0x${String(n).repeat(64)}`;
const fresh={intentTtl:0,intentDriftBps:0,keepers:[{address:'0xk1',hasRole:false},{address:'0xk2',hasRole:false}],
 lanes:[{name:'entry',lane:lane(1),maximum:2500n*10n**18n,async:false},{name:'unwind',lane:lane(2),maximum:2500n*10n**6n,async:false}],
 feeCurrency:null,weth:0n,hdx:0n};
const wired={...fresh,intentTtl:ICE.ttl,intentDriftBps:ICE.driftBps,keepers:fresh.keepers.map(k=>({...k,hasRole:true})),
 lanes:fresh.lanes.map(l=>({...l,async:true})),feeCurrency:WETH,weth:ICE.callbackWeth,hdx:ICE.hdx};

test('a fresh loop gets intents, keeper roles, async lanes and a WETH fee currency in one batch', () => {
 assert.deepEqual(icePlan(fresh),[
  {kind:'intents',ttl:300,driftBps:2},
  {kind:'keeper',keeper:'0xk1'},{kind:'keeper',keeper:'0xk2'},
  {kind:'async',name:'entry',lane:lane(1)},{kind:'async',name:'unwind',lane:lane(2)},
  {kind:'fee-currency'},{kind:'hdx',amount:10n**13n},{kind:'weth',amount:10n**16n},
 ]);
});

test('a wired loop needs nothing, and a half-wired one only the rest', () => {
 assert.deepEqual(icePlan(wired),[]);
 const half={...wired,keepers:[{address:'0xk1',hasRole:true},{address:'0xk2',hasRole:false}],lanes:[wired.lanes[0],{...wired.lanes[1],async:false}],
  feeCurrency:222,weth:ICE.callbackWeth/2n-1n};
 assert.deepEqual(icePlan(half).map(a=>a.kind),['keeper','async','fee-currency','weth']);
 assert.equal(icePlan(half).at(-1).amount,ICE.callbackWeth/2n+1n,'tops WETH back up to the callback budget');
 assert.deepEqual(icePlan({...wired,intentDriftBps:5}),[{kind:'intents',ttl:300,driftBps:2}]);
});

test('intent ttl is seconds under a day, and lanes must exist first', () => {
 for(const ttl of [0,86400,300000])assert.throws(()=>icePlan(fresh,{...ICE,ttl}),/seconds/);
 assert.throws(()=>icePlan(fresh,{...ICE,driftBps:9999}),/drift/);
 assert.throws(()=>icePlan({...fresh,lanes:[{...fresh.lanes[0],maximum:0n}]}),/wire the execution lanes/);
 assert.throws(()=>icePlan({...fresh,keepers:[{address:undefined,hasRole:false}]}),/keeper/);
});

test('the step speaks the contracts\' interfaces and units', () => {
 const loop=src('SubLoop.sol'),logic=src('lib/SubLoopLogic.sol'),controller=src('ExecutionController.sol');
 assert.match(loop,/function configureIntents\(uint32 \w+, uint16 \w+\) external onlyRole\(ADMIN_ROLE\)/);
 assert.match(loop,/if \(ttl >= 1 days \|\| driftBps >= 9_999\) revert InvalidParameters\(\);/);
 assert.match(logic,/uint64 deadline = uint64\(\(block\.timestamp \+ intentTtl\) \* 1000\);/,'ttl is seconds');
 assert.match(logic,/uint32 public intentTtl;/);assert.match(logic,/uint16 public intentDriftBps;/);
 assert.match(loop,/bytes32 public constant KEEPER_ROLE = keccak256\("KEEPER_ROLE"\);/);
 assert.match(loop,/function pokeBorrowQuoted\(uint256\)\s+external override onlyRole\(KEEPER_ROLE\)/);
 assert.match(controller,/function configureAsync\(bytes32 \w+, bool \w+\) external onlyRole\(DEFAULT_ADMIN_ROLE\)/);
 assert.match(controller,/mapping\(bytes32 => bool\) public asyncLanes;/);
 assert.match(controller,/if \(limits\[key\]\.maximum == 0\) revert InvalidPolicy\(\);/,'async needs a configured lane');
 assert.match(logic,/executionController\.recordAsync\(keccak256\(abi\.encode\(address\(this\), tokenIn, tokenOut\)\)/,'the lane key the journal records');
 assert.equal(LOOP_ABI.length,6);assert.equal(CONTROLLER_ABI.length,3);
});
