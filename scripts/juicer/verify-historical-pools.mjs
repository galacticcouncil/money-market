// Independent archive-storage checks across the expanded 90-day data set.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
const {ApiPromise,WsProvider}=createRequire(import.meta.url)('@polkadot/api');
const [input,output]=process.argv.slice(2),bytes=readFileSync(input),h=JSON.parse(bytes);
const points=h.snapshots.flatMap(s=>s.points).filter(p=>p.t>=h.start&&p.t<h.end);
const change=points.findIndex((p,i)=>i&&p.issuance!==points[i-1].issuance);
assert.ok(change>0);
const selected=[points[0],points[Math.floor(points.length/3)],points[Math.floor(points.length*2/3)],
  points[change-1],points[change],points.at(-1)];
const endpoint='wss://hdx.tarn.hydration.cloud',api=await ApiPromise.create({provider:new WsProvider(endpoint),noInitWarn:true});
const checked=[];
try {
  for(const p of selected) {
    const hash=(await api.rpc.chain.getBlockHash(p.block)).toHex();assert.equal(hash,p.hash);
    const at=await api.at(hash),account=h.snapshots[0].account.address;
    const r=await Promise.all([at.call.currenciesApi.freeBalance(43,account),at.call.currenciesApi.freeBalance(222,account),
      at.query.stableswap.poolPegs(143),at.query.tokens.totalIssuance(143),at.query.timestamp.now(),at.query.stableswap.pools(143)]);
    assert.deepEqual(r.slice(0,2).map(x=>x.toString()),p.reserves);
    assert.deepEqual(r[2].toJSON().current.map(v=>v.map(n=>BigInt(n).toString())),p.pegs.map(v=>[v.num,v.den]));
    assert.equal(r[3].toString(),p.issuance);assert.equal(Number(r[4].toString())/1000,p.t);
    assert.equal(r[5].unwrap().toJSON().fee,p.feePermill);
    checked.push({block:p.block,hash,time:p.time,reserves:p.reserves,pegs:p.pegs,issuance:p.issuance,feePermill:p.feePermill});
    console.log('verified',p.block,p.time);
  }
  writeFileSync(output,JSON.stringify({endpoint,retrievedAt:new Date().toISOString(),
    inputSha256:createHash('sha256').update(bytes).digest('hex'),checked},null,2)+'\n');
} finally {await api.disconnect();}
