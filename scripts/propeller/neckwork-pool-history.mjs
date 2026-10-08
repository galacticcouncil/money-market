// Public, read-only API collection. Keep raw responses and coverage separate
// from calibration: trading volume is not guaranteed external replenishment.
import { readFileSync, writeFileSync } from "node:fs";

const snapshot = JSON.parse(readFileSync(process.argv[2]));
const output = process.argv[3] || "/tmp/propeller-neckwork-history.json";
const base = (
  process.env.NECKWORK_API || "https://hydration-explorer.neckwork.net/api"
).replace(/\/$/, "");
const end = Math.floor(Number(snapshot.blockTimestampMs) / 86400000) * 86400;
const start = end - 90 * 86400,
  detailStart = end - 30 * 86400;
const day = (t) => new Date(t * 1000).toISOString().slice(0, 10);
const result = {
  api: base,
  retrievedAt: new Date().toISOString(),
  window: { from: day(start), toExclusive: day(end) },
  snapshotBlock: snapshot.block,
  sources: {},
  errors: {},
};
function save() {
  writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
}
async function get(key, path, optional = false) {
  const url = `${base}${path}`;
  const began = Date.now();
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(120000) });
    if (!response.ok)
      throw new Error(
        `HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`
      );
    const data = await response.json();
    result.sources[key] = {
      url,
      retrievedAt: new Date().toISOString(),
      elapsedMs: Date.now() - began,
      data,
    };
    save();
    console.log(
      key,
      Array.isArray(data) ? data.length : "ok",
      Date.now() - began
    );
    return data;
  } catch (e) {
    result.errors[key] = { url, error: e.message };
    save();
    if (!optional) throw e;
    return null;
  }
}
await get("indexer", "/indexer");
await get("hollar", "/explorer/hollar");
for (const id of [43, 222])
  await get(
    `hourly-${id}`,
    `/candles?baseId=${id}&quoteId=10&interval=1h&from=${start}&to=${end}`
  );
const assets = [
  ...new Set(
    Object.values(snapshot.pools).flatMap((p) => p.reserves.map((r) => r.id))
  ),
];
for (const id of assets)
  await get(
    `daily-${id}`,
    `/candles?baseId=${id}&quoteId=10&interval=1d&from=${start}&to=${end}`,
    true
  );
for (const [id, pool] of Object.entries(snapshot.pools)) {
  await get(`pool-state-${id}`, `/explorer/pool/${id}`, true);
  await get(
    `pool-history-${id}`,
    `/explorer/address/${pool.poolAccount}/history`,
    true
  );
}

const activity = [];
let exhausted = false;
const limit = 100,
  maxRows = 5000;
for (let offset = 0; offset < maxRows; offset += limit) {
  const rows = await get(
    `prime-trades-${offset}`,
    `/explorer/activity?asset=43&type=trade&limit=${limit}&offset=${offset}&from=${day(
      detailStart
    )}&to=${day(end - 86400)}`,
    true
  );
  if (!Array.isArray(rows)) break;
  activity.push(...rows);
  if (rows.length < limit) {
    exhausted = true;
    break;
  }
}
const unique = new Map(
  activity.map((row) => [
    `${row.blockHeight}:${row.eventIndex}:${row.type}`,
    row,
  ])
);
result.activityCoverage = {
  requestedFrom: day(detailStart),
  requestedTo: day(end - 86400),
  fetched: activity.length,
  unique: unique.size,
  exhausted,
  maxRows,
  oldest: activity.at(-1)?.timestamp || null,
  note: "Asset-level economic actions; includes lending-wrapper conversions. Not every row is a pool swap.",
};
// Verify representative largest actual swaps through their individual route
// details. Do not call all asset-level trades pool-143 volume or arbitrage.
const selected = [...unique.values()]
  .filter(
    (r) =>
      r.assetIn?.assetId !== 1043 &&
      r.assetOut?.assetId !== 1043 &&
      r.extrinsicIndex !== null
  )
  .sort((a, b) => (b.valueUsd || 0) - (a.valueUsd || 0))
  .slice(0, 20);
for (const r of selected)
  await get(
    `route-${r.blockHeight}-${r.extrinsicIndex}`,
    `/explorer/trade/${r.blockHeight}/${r.extrinsicIndex}`,
    true
  );
save();
console.log(output, result.activityCoverage, "errors", result.errors);
