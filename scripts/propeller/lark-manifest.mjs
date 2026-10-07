// Bot manifest for the Swarm config: pinned genesis and mirror oracles only.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {CORE_FILE,GENESIS,DEPLOYMENT} from './lark-pins.mjs';
const r=JSON.parse(readFileSync(CORE_FILE,'utf8'));
assert.equal(r.genesis,GENESIS);
assert.equal(r.oracles?.length,3,'run lark-market-setup.mjs first');
const manifest={rpc:r.rpc,genesis:r.genesis,runtime:r.runtime,oracles:r.oracles.map(({assetId,asset,name,address})=>({assetId,asset,name,address})),addresses:r.addresses,vaults:r.vaults.map(({name,assetId,asset,address})=>({name,assetId,asset,address})),...(r.mainnetSync?{feeds:r.mainnetSync.feeds,omnipool:r.mainnetSync.omnipool}:{}),...(r.depositor?{depositor:r.depositor}:{})};
const file=`/tmp/propeller-lark-manifest-${DEPLOYMENT}.json`;
writeFileSync(file,JSON.stringify(manifest,null,2)+'\n');
console.log(file);
