import assert from 'node:assert/strict';
import {test} from 'node:test';
import {JuicerLooper} from '../src/looper.js';
import {CONFIG} from '../src/config.js';

const VAULT = '0x0000000000000000000000000000000000000001';
const HOLLAR = '0x0000000000000000000000000000000000000002';
const U = 10n ** 18n;
function fixture() {
  const keeper = Object.create(JuicerLooper.prototype) as any;
  const state: Record<string, any> = {mainDebt: VAULT, activePosition: [120n*U,100n*U,107n*U],
    sourceFees: [0n,0n], pendingSourceAccounting: false, paused: false, emergencyPaused: false,
    ADDRESSES_PROVIDER: VAULT, getPriceOracle: VAULT, hollar: HOLLAR};
  Object.assign(keeper, {subLoop: VAULT, pool: VAULT});
  keeper.read = async (_abi: unknown, _address: string, name: string, args: any[]) => {
    if(name === 'getAssetPrice') return args[0] === HOLLAR ? 100_000_000n : 2500n*100_000_000n;
    assert(name in state, `unexpected read ${name}`);
    return state[name];
  };
  const calls: any[] = [];
  keeper.poke = async (...args: any[]) => {calls.push(args); return false;};
  return {keeper,state,calls};
}
test('idle service spends only funded interest, excluding source fees and unreceived amounts', async () => {
  const {keeper,state,calls} = fixture();
  assert.equal(await keeper.fundedInterest(VAULT),20n*U);
  state.sourceFees = [0n,105n*U];
  assert.equal(await keeper.fundedInterest(VAULT),2n*U);
  await keeper.serviceMainInterest(VAULT,100n);
  assert.equal(calls.length,1);
  assert.equal(calls[0][2],'pokeSettle');
  assert.equal(calls[0][6],true);
  state.sourceFees = [0n,108n*U];
  assert.equal(await keeper.fundedInterest(VAULT),0n);
  state.activePosition = [120n*U,100n*U,0n];
  state.activeFunds = 500n*U;
  assert.equal(await keeper.fundedInterest(VAULT),0n);
});
test('idle service skips dust and freezes, and bounds failed attempts', async () => {
  const {keeper,state,calls} = fixture();
  for(const gate of ['pendingSourceAccounting','paused','emergencyPaused']) {
    state[gate]=true;
    await keeper.serviceMainInterest(VAULT,100n);
    assert.equal(calls.length,0);
    state[gate]=false;
  }
  state.activePosition=[100n*U+CONFIG.MAIN_SERVICE_MIN_HOLLAR-1n,100n*U,107n*U];
  await keeper.serviceMainInterest(VAULT,100n);
  assert.equal(calls.length,0);
  state.activePosition=[120n*U,100n*U,107n*U];
  await keeper.serviceMainInterest(VAULT,100n);
  await keeper.serviceMainInterest(VAULT,101n);
  assert.equal(calls.length,1);
  await keeper.serviceMainInterest(VAULT,100n+CONFIG.MAIN_SERVICE_RETRY_SECONDS);
  assert.equal(calls.length,2);
});
test('service rechecks funding and rejects excessive unsponsored gas', async () => {
  const previous=CONFIG.SPONSORED_GAS;
  const {keeper,state}=fixture();
  try {
    CONFIG.SPONSORED_GAS=false;
    assert.equal(await keeper.mainServiceWorthwhile(VAULT,10n**12n),true);
    assert.equal(await keeper.mainServiceWorthwhile(VAULT,10n**16n),false);
    CONFIG.SPONSORED_GAS=true;
    assert.equal(await keeper.mainServiceWorthwhile(VAULT,10n**16n),true);
    state.activePosition=[100n*U,100n*U,87n*U];
    assert.equal(await keeper.mainServiceWorthwhile(VAULT,10n**12n),false);
  } finally {CONFIG.SPONSORED_GAS=previous;}
});
