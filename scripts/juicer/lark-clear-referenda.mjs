// A refork restarts block numbers, so mainnet referenda carried in the state keep their
// deciding slots with alarms millions of blocks away and the root queue never moves.
// Alice is the fork's only TC member: whitelist a root batch cancelling them and dispatch
// it on the whitelisted caller track, which is fast and starts empty.
import assert from 'node:assert/strict';
import {context, live} from './lark-context.mjs';

const {api, r, sign, save} = await context();
const head = (await api.rpc.chain.getHeader()).number.toNumber();
const stale = [];
for (const [key, info] of await api.query.referenda.referendumInfoFor.entries()) {
  const o = info.unwrap();
  if (o.isOngoing && o.asOngoing.submitted.toNumber() > head) stale.push(key.args[0].toNumber());
}
stale.sort((a, b) => a - b);
console.log('STALE', stale.join(', ') || 'none');
if (!stale.length) process.exit(0);

const inner = api.tx.utility.batchAll(stale.map(i => api.tx.referenda.cancel(i)));
const dry = await api.call.dryRunApi.dryRunCall({system: 'Root'}, inner, 4);
assert.ok(dry.isOk && dry.asOk.executionResult.isOk, `cancel dry run failed: ${dry}`);
if (!live) process.exit(0);

const hash = inner.method.hash.toHex();
const label = `clear-referenda-${stale.join('-')}`;
const tc = await api.query.technicalCommittee.members();
assert.equal(tc.length, 1, 'expected the fork to leave alice as the only TC member');
if (!(await api.query.whitelist.whitelistedCall(hash)).isSome) {
  const call = api.tx.whitelist.whitelistCall(hash);
  await sign(api.tx.technicalCommittee.propose(1, call, call.method.encodedLength), `${label}.whitelist`);
}
assert.ok((await api.query.whitelist.whitelistedCall(hash)).isSome, 'whitelist did not land');

const outer = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(inner);
const outerHash = outer.method.hash.toHex(), len = outer.method.encodedLength;
let rec = r.governance.find(g => g.label === label);
if (!rec) { rec = {label, hash: outerHash, len, cancels: stale}; r.governance.push(rec); save(); }
if (rec.ref === undefined) {
  try { await sign(api.tx.preimage.notePreimage(outer.method.toHex()), `${label}.preimage`); } catch (e) { if (!/AlreadyNoted/.test(String(e))) throw e; }
  const result = await sign(api.tx.referenda.submit({Origins: 'WhitelistedCaller'}, {Lookup: {hash: outerHash, len}}, {After: 1}), `${label}.submit`);
  rec.ref = result.events.find(e => e.section === 'referenda' && e.method === 'Submitted').data[0]; save();
  await sign(api.tx.referenda.placeDecisionDeposit(rec.ref), `${label}.decision-deposit`);
  await sign(api.tx.convictionVoting.vote(rec.ref, {Standard: {vote: {aye: true, conviction: 'Locked6x'}, balance: (4000000000n * 10n ** 12n).toString()}}), `${label}.vote`);
}
const until = Date.now() + 600000;
for (;;) {
  const left = [];
  for (const i of stale) { const info = await api.query.referenda.referendumInfoFor(i); if (info.isSome && info.unwrap().isOngoing) left.push(i); }
  if (!left.length) break;
  assert.ok(Date.now() < until, `still ongoing after 10 min: ${left.join(', ')}`);
  await new Promise(resolve => setTimeout(resolve, 6000));
}
rec.verified = true; save();
console.log('CLEARED', stale.join(', '), 'root deciding', (await api.query.referenda.decidingCount(0)).toNumber());
await api.disconnect();
