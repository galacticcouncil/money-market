import { test } from "node:test";
import assert from "node:assert/strict";
import {
  timestamp,
  quantile,
  classifyActions,
  poolSeries,
  reserveSummary,
} from "./neckwork-calibration.mjs";
test("timestamps are UTC for dates and ClickHouse strings", () => {
  assert.equal(timestamp("2026-09-01"), timestamp("2026-09-01 00:00:00"));
  assert.equal(timestamp("2026-09-01"), timestamp("2026-09-01T00:00:00Z"));
});
test("quantiles leave inputs unchanged and handle missing observations", () => {
  const x = [3, 1, 2];
  assert.equal(quantile(x, 0.5), 2);
  assert.deepEqual(x, [3, 1, 2]);
  assert.equal(quantile([], 0.9), null);
});
test("PRIME actions are deduplicated, windowed and stripped of wrapper conversions", () => {
  const row = {
    timestamp: "2026-09-01 12:00:00",
    blockHeight: 1,
    eventIndex: 1,
    type: "trade",
    assetIn: { assetId: 43 },
    assetOut: { assetId: 222 },
    amountIn: "1000001",
    amountOut: "1000000000000000000",
    valueUsd: 1.06,
  };
  const c = classifyActions(
    [
      row,
      row,
      { ...row, eventIndex: 2, assetOut: { assetId: 1043 } },
      { ...row, eventIndex: 3, assetOut: { assetId: 43 } },
      { ...row, eventIndex: 4, timestamp: "2026-09-02 00:00:00" },
    ],
    timestamp("2026-09-01"),
    timestamp("2026-09-02")
  );
  assert.equal(c.accepted.length, 1);
  assert.equal(c.totalPrimeSoldRaw, "1000001");
  assert.equal(c.duplicates, 1);
  assert.equal(c.excludedWrappers, 1);
  assert.equal(c.excludedUnresolved, 1);
});
const detail = {
  poolId: 143,
  history: {
    buckets: ["2026-09-01", "2026-09-02", "2026-09-03"],
    composition: [
      { asset: { assetId: 43, symbol: "PRIME" }, amounts: [null, 10, 15] },
    ],
    pegs: [{ asset: { assetId: 43 }, prices: [1.05, 1.05, 1.06] }],
    issuance: [100, 100, 150],
    tvlUsd: [null, 12, 18],
  },
};
test("reserve series align pegs and do not silently convert unknown amounts to zero", () => {
  const rows = poolSeries(
    detail,
    timestamp("2026-09-01"),
    timestamp("2026-09-04")
  );
  assert.equal(rows[0].amounts[43], null);
  assert.equal(rows[2].pegs[43], 1.06);
  assert.equal(rows[2].issuance, 150);
});
test("sample changes and LP issuance are reported separately", () => {
  const r = reserveSummary(
    detail,
    timestamp("2026-09-01"),
    timestamp("2026-09-04")
  );
  assert.equal(r.assets[43].points, 2);
  assert.equal(r.assets[43].min, 10);
  assert.equal(r.assets[43].sumPositiveSampleChanges, 5);
  assert.equal(r.issuanceChanges.length, 1);
  assert.equal(r.issuanceChanges[0].delta, 50);
  assert.match(r.caveat, /not measured arbitrage/);
});
