import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { CONFIG } from '../src/config.js';

const stack = readFileSync(new URL('../docker-stack.yml', import.meta.url), 'utf8');
const fallback = (name: string) => stack.match(new RegExp(`\\$\\{${name}:-([^}]*)\\}`))?.[1];

test('the shipped stack keeps the code defaults for the deficit stop', () => {
  for (const name of ['DEFICIT_STOP_BPS', 'DEFICIT_RESUME_BPS'] as const) {
    assert.equal(fallback(name), String(CONFIG[name]), name);
  }
});

test('the shipped stack keeps the routine sync limits', () => {
  for (const name of ['SYNC_EVERY', 'SYNC_MIN_INTERVAL_SECONDS', 'SYNC_PRICE_CHANGE_BPS'] as const) {
    assert.equal(fallback(name), String(CONFIG[name]), name);
  }
});
