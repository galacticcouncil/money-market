import test from 'node:test';
import assert from 'node:assert/strict';
import {recoverySchedule} from './analyze-prime-recovery.mjs';

const WAD = 10n ** 18n;
const point = (t, prime, hollar, issuance = '100') => ({t,
  reserves: [String(prime), String(BigInt(hollar) * WAD)], issuance});
const run = points => recoverySchedule(points, 0, 300n * WAD, 100n * WAD, 10n);

test('elapsed time without inventory recovery never replenishes a trade budget', () => {
  const r = run([point(0, 1000, 1000), point(3600, 1000, 1000)]);
  assert.equal(r.complete, false); assert.equal(r.filledSlices, 1);
  assert.equal(r.capitalHours, null);
});

test('both reserve legs must recover; competing buys remove earlier capacity', () => {
  const r = run([point(0, 1000, 1000), point(600, 1020, 950), point(1200, 1000, 1000)]);
  assert.equal(r.complete, false); assert.equal(r.filledSlices, 1);
});

test('cumulative net recovery is credited once, and excess can serve later slices', () => {
  const r = run([point(0, 1000, 1000), point(600, 1010, 900), point(1200, 1010, 900), point(1800, 1020, 800)]);
  assert.equal(r.complete, true); assert.equal(r.completionHours, .5);
  assert.ok(Math.abs(r.capitalHours - (100 / 6 + 50)) < 1e-10);
  const one = run([point(0, 1000, 1000), point(600, 1020, 800)]);
  assert.equal(one.filledSlices, 3); assert.equal(one.completionHours, 1 / 6);
});

test('LP issuance changes and missing observations censor the schedule', () => {
  assert.equal(run([point(0, 1000, 1000), point(600, 1020, 800, '101')]).endReason, 'issuance-changed');
  assert.equal(run([point(0, 1000, 1000), point(3601, 1020, 800)]).endReason, 'observation-gap');
});

test('a one-slice order has no replenishment wait and no delay expense', () => {
  const r = recoverySchedule([point(0, 1000, 1000)], 0, 100n * WAD, 100n * WAD, 10n);
  assert.equal(r.complete, true); assert.equal(r.completionHours, 0); assert.equal(r.capitalHours, 0);
});
