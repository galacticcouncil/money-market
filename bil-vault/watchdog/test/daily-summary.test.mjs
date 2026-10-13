import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DailySummary, isPositionIssue } from '../dist/daily-summary.js';

const DAY = 86400;
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'bil-summary-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return join(dir, 'summary.json');
}

test('growing backlog sends once per day, even with a shorter configured interval', t => {
  const path = fixture(t);
  const summary = new DailySummary(path, 100, 60);
  for (let now = 100; now < 100 + DAY; now += 60) assert.equal(summary.reserve(now, true), false);
  assert.equal(summary.reserve(100 + DAY, true), true);
  assert.equal(summary.reserve(100 + DAY + 60, true), false);
  assert.equal(summary.reserve(100 + DAY * 2, true), true);
});

test('restart, clock rollback and ambiguous delivery cannot repeat a summary', t => {
  const path = fixture(t);
  new DailySummary(path, 100);
  const restarted = new DailySummary(path, 100 + DAY - 1);
  assert.equal(restarted.reserve(100 + DAY - 1, true), false);
  assert.equal(restarted.reserve(100 + DAY, true), true);
  // Simulate a crash or a timed-out HTTP response immediately after reservation.
  const afterSend = new DailySummary(path, 100 + DAY + 1);
  assert.equal(afterSend.reserve(100 + DAY + 1, true), false);
  assert.equal(afterSend.reserve(0, true), false);
  assert.equal(afterSend.reserve(100 + 2 * DAY, true), true);
});

test('one daily all-clear, then quiet until there is a new backlog', t => {
  const summary = new DailySummary(fixture(t), 100);
  assert.equal(summary.reserve(100 + DAY, false), false);
  assert.equal(summary.reserve(100 + DAY, true), true);
  assert.equal(summary.reserve(101 + DAY, false), false);
  assert.equal(summary.reserve(100 + 2 * DAY, false), true);
  assert.equal(summary.reserve(100 + 3 * DAY, false), false);
});

test('invalid persisted state fails closed', t => {
  const path = fixture(t);
  writeFileSync(path, '{broken');
  assert.throws(() => new DailySummary(path, 100));
});

test('position warnings and claims are daily; service faults remain immediate', () => {
  for (const key of ['pos:1', 'ready:25', 'claim:333']) assert.equal(isPositionIssue(key), true);
  for (const key of ['claim:disabled', 'keeper:gas', 'vault:paused']) assert.equal(isPositionIssue(key), false);
});

test('runCycle aggregates many arriving/resolved positions without individual alerts', async t => {
  process.env.SUMMARY_STATE_FILE = fixture(t);
  process.env.VAULT_ADDRESS = '0x0000000000000000000000000000000000000001';
  process.env.ALERT_WEBHOOK = 'https://example.invalid/never-called';
  const { BILWatchdog } = await import('../dist/watchdog.js');
  const watchdog = new BILWatchdog();
  const posts = [];
  watchdog.post = async (...args) => { posts.push(args); };
  let issues = new Map();
  const snapshot = {
    matured: [],
    decentral: { waitingCount: 0, waitingPrincipal: 0n, waitingYield: 0n, slowCount: 0, overdueCount: 0, oldestWait: 0, poolHollar: 0n },
  };
  watchdog.scan = async () => ({ issues, now: 1000000, snapshot });
  for (let n = 1; n <= 25; n++) {
    issues.set(`pos:${n}`, { level: 'error', text: `Position ${n} stuck` });
    issues.set(`ready:${n}`, { level: 'error', text: `Position ${n} ready` });
    await watchdog.runCycle();
  }
  assert.equal(posts.length, 0);
  issues.delete('pos:1');
  issues.delete('ready:1');
  await watchdog.runCycle();
  assert.equal(posts.length, 0);
  // Move the persisted window back one day, then reload as on restart.
  const saved = JSON.parse(readFileSync(process.env.SUMMARY_STATE_FILE, 'utf8'));
  saved.lastAttempt -= DAY;
  writeFileSync(process.env.SUMMARY_STATE_FILE, JSON.stringify(saved));
  watchdog.summary = new DailySummary(process.env.SUMMARY_STATE_FILE, 0);
  await watchdog.runCycle();
  assert.equal(posts.length, 1);
  assert.equal(posts[0][1], 'BIL — daily position summary');
  assert.match(posts[0][2], /24 positions not progressing/);
  assert.ok(posts[0][2].length < 1000);
  await watchdog.runCycle();
  assert.equal(posts.length, 1);
  issues.set('keeper:gas', { level: 'warn', text: 'Low keeper gas' });
  await watchdog.runCycle();
  assert.equal(posts.length, 2);
  assert.match(posts[1][2], /Low keeper gas/);
});
