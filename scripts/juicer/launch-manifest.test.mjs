import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {VAULTS,ROLES,launchVaults,roundingPolicy,readinessEnv,token} from './launch-manifest.mjs';
const here=fileURLToPath(new URL('.',import.meta.url));

test('jBTC launches alone, jETH joins later by name, nothing else', () => {
 assert.deepEqual(launchVaults().map(v=>[v.key,v.assetId,v.symbol]),[['TBTC',1000765,'jBTC']]);
 assert.deepEqual(launchVaults('ETH').map(v=>v.symbol),['jETH']);
 assert.throws(()=>launchVaults('TBTC,TBTC'),/comma list/);
 assert.throws(()=>launchVaults('DOT'),/unknown vault DOT/);
 assert.equal(token(VAULTS.TBTC.assetId),'0x00000000000000000000000000000001000f453d');
 assert.ok(ROLES.includes('DEFAULT_ADMIN_ROLE')&&ROLES.includes('UPGRADER_ROLE')&&ROLES.includes('MINTER_ROLE'));
});

test('the rounding reserve is sized off the collateral existential deposit, as on lark', () => {
 assert.deepEqual(roundingPolicy('0x01',1000765,'106803374987'),{vault:'0x01',assetId:1000765,minimum:'213606750974',target:'1069033749870'});
});

const manifest={addresses:{synth:'0x51',subLoop:'0x52',harvester:'0x53',controller:'0x54',adapter:'0x55',fees:'0x56',discount:'0x57'},
 market:{treasury:'0x58'},committee:'0x59',deployments:[{label:'CompoundLogic',codeHash:'0xc0de'}],
 vaults:[{address:'0x61',rounding:{vault:'0x61',assetId:1000765,minimum:'2',target:'3'}},{key:'ETH'}]};
const plan={policy:{maxQuoteAge:60},keepers:['0x71','0x72'],values:{slippagePpm:2700,primePoolFeePpm:100,withdrawalDelay:43200,synthAssetId:5550,
 harvestThreshold:'200000000000000',intentTtl:300,intentDriftBps:2,band:{relever:6500,target:7500,delever:8300},admissionMaxDeficitBps:250,
 exitHeadroom:{enabled:true,gapBps:0},revenue:{protocolFeeBps:6900,mainDiscountBps:4000,loopDiscountBps:9000},reserveHollar:'1000',loopCapHollar:'5000000'}};

test('readiness reads the manifest and the values the proposal planned, deployed vaults only', () => {
 const env=readinessEnv(manifest,plan,{slippagePpm:2700,ws:'ws://x',rpc:'http://x'});
 assert.equal(env.JUICER_VAULTS,'0x61');
 assert.equal(env.JUICER_COMPOUND_LOGIC_CODEHASH,'0xc0de');
 assert.deepEqual(JSON.parse(env.JUICER_ROUNDING_RESERVES),[manifest.vaults[0].rounding]);
 assert.deepEqual([env.JUICER_REBALANCE_BAND,env.JUICER_EXIT_HEADROOM,env.JUICER_KEEPERS,env.JUICER_LOOP_DISCOUNT_CAP],['6500,7500,8300','on,0','0x71,0x72','5000000']);
 assert.equal(readinessEnv(manifest,{...plan,values:{...plan.values,exitHeadroom:{enabled:false,gapBps:0}}},{}).JUICER_EXIT_HEADROOM,'off');
});

test('run as a script it prints the exports', () => {
 const dir=mkdtempSync(join(tmpdir(),'launch-manifest-'));
 try{
  writeFileSync(join(dir,'m.json'),JSON.stringify(manifest));writeFileSync(join(dir,'p.json'),JSON.stringify(plan));
  const r=spawnSync(process.execPath,[join(here,'launch-manifest.mjs'),join(dir,'m.json'),join(dir,'p.json')],{env:{PATH:process.env.PATH,WS:'ws://y',RPC:'http://y'},encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);
  assert.match(r.stdout,/^export WS_URL='ws:\/\/y'$/m);
  assert.match(r.stdout,/^export JUICER_SLIPPAGE_PPM='2700'$/m);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
