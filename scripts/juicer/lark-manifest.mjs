// Bot manifest for the Swarm config: pinned genesis, chain identity and mirror oracles only.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {profile,requirePins,CORE_FILE} from './lark-pins.mjs';
const r=JSON.parse(readFileSync(CORE_FILE,'utf8'));
assert.equal(r.genesis,requirePins().genesis);
assert.equal(r.oracles?.length,3,'run lark-market-setup.mjs first');
// lark 4's v3 config predates the identity fields; its bots fall back to the same values
const identity=profile.legacy?{}:{chainName:profile.chainName,signers:profile.signers};
const manifest={rpc:r.rpc,genesis:r.genesis,...identity,runtime:r.runtime,oracles:r.oracles.map(({assetId,asset,name,address})=>({assetId,asset,name,address})),addresses:r.addresses,vaults:r.vaults.map(({name,assetId,asset,address})=>({name,assetId,asset,address})),...(r.mainnetSync?{feeds:r.mainnetSync.feeds,omnipool:r.mainnetSync.omnipool}:{}),...(r.depositor?{depositor:r.depositor}:{})};
const file=profile.manifest;
writeFileSync(file,JSON.stringify(manifest,null,2)+'\n');
console.log(file);
