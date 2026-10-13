// Differential calibration against the archived REAL-CONTRACT stationary run.
// This is a regression fixture, not an extension of the 90-day market horizon.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {simulate,asPool} from './historical-apy-model.mjs';
import {parseMetrics} from './tune-operations.mjs';
const [archive,output='/tmp/historical-model-calibration.json']=process.argv.slice(2);
assert.ok(archive,'usage: validate-historical-model.mjs archived-contract-evidence output.json');
// The old MockDispatch has constant 5bp oracle fills. Match that boundary here,
// instead of attributing additional official-curve impact to accounting error.
const stable={calculate_out_given_in:(reserves,assetIn,_out,amount,_amp,fee,pegs)=> {
  const r=JSON.parse(reserves),p=JSON.parse(pegs),i=r.findIndex(x=>x.asset_id===assetIn),o=1-i;
  const gross=BigInt(amount)*10n**BigInt(r[o].decimals)*BigInt(p[i][0])*BigInt(p[o][1])/
    (10n**BigInt(r[i].decimals)*BigInt(p[i][1])*BigInt(p[o][0]));
  return String(gross*BigInt(Math.round((1-Number(fee))*1e6))/1000000n);
}};
const rows=[];
for(let hour=0;hour<=8760;hour++) {
  const p={t:hour*3600,block:hour,hash:'fixture',reserves:['500000000000','531240605000000000000000'],
    pegs:[{num:'106248121',den:'100000000'},{num:'1',den:'1'}],amplification:100,feePermill:500,
    prices:[2658.21456299,84389.27019765,1.06248121,1],
    income:(1+.054996515959088414/8760)**hour,debt:(1+.044016888917752794/8760)**hour};
  p.ideal=asPool(p);rows.push(p);
}
const comparisons=[];
for(const asset of ['ETH','BTC']) {
  const path=`${archive}/r3-threshold-30-ramp-1h-${asset}.log`,bytes=readFileSync(path),contract=parseMetrics(bytes.toString());
  const tailBps=(1-(1-(asset==='ETH'?60:100)/10000)/.9995)*10000;
  const r=simulate(rows,{stable},asset,{tailBps},'perfect');
  const differenceUsd=r.fundedCryptoUsd-contract.fundedCryptoUsd;
  assert.ok(Math.abs(differenceUsd)<.25,`${asset}: material divergence from Solidity fixture`);
  assert.equal(r.harvests,contract.harvests);
  assert.ok(Math.abs(r.firstCrypto-contract.firstCryptoHour/24)<1/24);
  assert.ok(r.maxAccountingError<1e-5);
  comparisons.push({asset,source:path.split('/').at(-1),sha256:createHash('sha256').update(bytes).digest('hex'),
    contractFundedUsd:contract.fundedCryptoUsd,modelFundedUsd:r.fundedCryptoUsd,differenceUsd,
    contractFirstCryptoDay:contract.firstCryptoHour/24,modelFirstCryptoDay:r.firstCrypto,
    harvests:r.harvests,unconvertedUserUsd:r.unconvertedUserUsd,maxAccountingError:r.maxAccountingError});
}
writeFileSync(output,JSON.stringify({comparisons,
  scope:'Matched flat-price, positive-carry, no-unwind fixture only; this does not establish contract parity for historical price moves, exits or ownership cohorts.'},null,2)+'\n');
console.log(JSON.stringify(comparisons,null,2));
