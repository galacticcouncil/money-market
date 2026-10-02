import assert from 'node:assert/strict';
import {test} from 'node:test';
import {executionQuotes, worthwhileHarvest, operatorTurn} from '../src/execution-policy.js';

test('small harvests batch until costs fit; debt urgency and delay never wait for profitability', () => {
  assert.equal(worthwhileHarvest(100n, 1n, 100n, 10n, false, 0n, 86400n), false);
  assert.equal(worthwhileHarvest(1000n, 1n, 100n, 10n, false, 0n, 86400n), true);
  assert.equal(worthwhileHarvest(100n, 100n, 1000n, 10n, true, 0n, 86400n), true);
  assert.equal(worthwhileHarvest(100n, 100n, 1000n, 10n, false, 86400n, 86400n), true);
  assert.equal(worthwhileHarvest(0n, 1n, 100n, 10n, true, 86400n, 86400n), false);
});

test('quotes cap input, preserve a positive floor and reject ambiguous repeated routes', () => {
  const fill = {lane: '0x1234' as const, amountIn: 5000n, amountOut: 10000n};
  assert.deepEqual(executionQuotes([fill], 2n), [{lane: fill.lane, amountIn: 5000n, minOut: 9998n}]);
  assert.throws(() => executionQuotes([fill, fill], 2n), /repeated/);
  assert.throws(() => executionQuotes([{...fill, amountOut: 1n}], 2n), /zero/);
});

test('redundant operators rotate optional work and do not depend on a leader heartbeat', () => {
  assert.equal(operatorTurn(119n, 60, 2, 1), true);
  assert.equal(operatorTurn(119n, 60, 2, 0), false);
  assert.equal(operatorTurn(120n, 60, 2, 0), true);
  assert.equal(operatorTurn(180n, 60, 2, 1), true);
});

test('interest-inclusion headroom preserves the unit price and never expands the primary slice', () => {
  const fills = [
    {lane: '0x01' as const, amountIn: 100n, amountOut: 10000n},
    {lane: '0x02' as const, amountIn: 10n, amountOut: 1000n},
  ];
  const normal = executionQuotes(fills, 2n);
  const buffered = executionQuotes(fills, 2n, new Set(['0x02']));
  assert.deepEqual(buffered[0], normal[0]);
  assert.equal(buffered[1].amountIn, normal[1].amountIn * 2n);
  assert.equal(buffered[1].minOut * normal[1].amountIn, normal[1].minOut * buffered[1].amountIn);
});
