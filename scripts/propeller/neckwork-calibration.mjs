import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

export const timestamp = (s) =>
  Date.parse(
    s.includes("T")
      ? s
      : s.length === 10
      ? `${s}T00:00:00Z`
      : `${s.replace(" ", "T")}Z`
  ) / 1000;
export function quantile(values, p) {
  if (!values.length) return null;
  const a = [...values].sort((a, b) => a - b),
    position = (a.length - 1) * p;
  const low = Math.floor(position),
    high = Math.ceil(position);
  return a[low] + (a[high] - a[low]) * (position - low);
}
export function classifyActions(rows, from, to) {
  const seen = new Set(),
    days = {},
    accepted = [];
  let excludedWrappers = 0,
    excludedUnresolved = 0,
    duplicates = 0,
    buyRaw = 0n,
    sellRaw = 0n;
  for (let time = from; time < to; time += 86400)
    days[new Date(time * 1000).toISOString().slice(0, 10)] = {
      buyUsd: 0,
      sellUsd: 0,
      count: 0,
    };
  for (const row of rows) {
    const time = timestamp(row.timestamp);
    if (time < from || time >= to) continue;
    const key = `${row.blockHeight}:${row.eventIndex}:${row.type}`;
    if (seen.has(key)) {
      duplicates++;
      continue;
    }
    seen.add(key);
    if (row.assetIn?.assetId === 1043 || row.assetOut?.assetId === 1043) {
      excludedWrappers++;
      continue;
    }
    const input = row.assetIn?.assetId === 43,
      output = row.assetOut?.assetId === 43;
    if (input === output || !row.amountIn || !row.amountOut) {
      excludedUnresolved++;
      continue;
    }
    const q = BigInt(input ? row.amountIn : row.amountOut);
    if (input) sellRaw += q;
    else buyRaw += q;
    const d = days[row.timestamp.slice(0, 10)];
    assert.ok(d, "unexpected day");
    d[input ? "sellUsd" : "buyUsd"] += Number(row.valueUsd || 0);
    d.count++;
    accepted.push({
      time,
      direction: input ? "sell" : "buy",
      primeRaw: q.toString(),
      usd: Number(row.valueUsd || 0),
      block: row.blockHeight,
      event: row.eventIndex,
      extrinsic: row.extrinsicIndex,
      account: row.who?.address || null,
    });
  }
  accepted.sort((a, b) => a.time - b.time || a.event - b.event);
  return {
    days,
    accepted,
    excludedWrappers,
    excludedUnresolved,
    duplicates,
    totalPrimeSoldRaw: sellRaw.toString(),
    totalPrimeBoughtRaw: buyRaw.toString(),
  };
}
export function poolSeries(detail, from, to) {
  const h = detail.history;
  if (!h) return [];
  return h.buckets
    .map((date, i) => ({
      date,
      time: timestamp(date),
      amounts: Object.fromEntries(
        h.composition.map((a) => [a.asset.assetId, a.amounts[i] ?? null])
      ),
      pegs: Object.fromEntries(
        (h.pegs || []).map((a) => [a.asset.assetId, a.prices[i] ?? null])
      ),
      issuance: h.issuance?.[i] ?? null,
      tvlUsd: h.tvlUsd?.[i] ?? null,
    }))
    .filter((r) => r.time >= from && r.time < to);
}
export function reserveSummary(detail, from, to) {
  const rows = poolSeries(detail, from, to);
  const assets = {};
  for (const a of detail.history?.composition || []) {
    const id = a.asset.assetId,
      values = rows.map((r) => r.amounts[id]).filter((v) => v !== null);
    let increases = 0,
      decreases = 0,
      unchanged = 0;
    for (let i = 1; i < rows.length; i++) {
      const previous = rows[i - 1].amounts[id],
        current = rows[i].amounts[id];
      if (previous === null || current === null) continue;
      const change = current - previous;
      if (change > 0) increases += change;
      else decreases -= change;
      if (change === 0) unchanged++;
    }
    assets[id] = {
      symbol: a.asset.symbol,
      points: values.length,
      min: values.length ? Math.min(...values) : null,
      max: values.length ? Math.max(...values) : null,
      first: values[0] ?? null,
      last: values.at(-1) ?? null,
      netReserveIncrease: values.length ? values.at(-1) - values[0] : null,
      sumPositiveSampleChanges: increases,
      sumNegativeSampleChanges: decreases,
      unchangedPairs: unchanged,
    };
  }
  const issuanceChanges = [];
  for (let i = 1; i < rows.length; i++) {
    const a = rows[i - 1].issuance,
      b = rows[i].issuance;
    if (a !== null && b !== null && Math.abs(b - a) > Math.max(1e-6, a * 1e-9))
      issuanceChanges.push({ date: rows[i].date, delta: b - a });
  }
  return {
    poolId: detail.poolId,
    points: rows.length,
    first: rows[0]?.date,
    last: rows.at(-1)?.date,
    assets,
    issuanceChanges,
    caveat:
      "Sampled state, forward-filled by upstream. Reserve changes are net of swaps, LP actions and transfers, not measured arbitrage or guaranteed refill. Unchanged issuance cannot exclude offsetting intraday LP actions.",
  };
}
export function calibrate(history, snapshot) {
  const to = Date.parse(`${history.window.toExclusive}T00:00:00Z`) / 1000,
    from = to - 30 * 86400;
  const actions = Object.entries(history.sources)
    .filter(([key]) => key.startsWith("prime-trades-"))
    .flatMap(([, v]) => v.data);
  const classified = classifyActions(actions, from, to),
    daily = Object.values(classified.days);
  const sell = daily.map((d) => d.sellUsd),
    buy = daily.map((d) => d.buyUsd);
  const gaps = classified.accepted
    .slice(1)
    .map((r, i) => (r.time - classified.accepted[i].time) / 60);
  const material = classified.accepted.filter((r) => r.usd >= 1000);
  const materialGaps = material
    .slice(1)
    .map((r, i) => (r.time - material[i].time) / 3600);
  const hourly = history.sources["hourly-43"].data.filter(
    (r) => r.intervalStart >= from && r.intervalStart < to
  );
  const peg = history.sources["hourly-222"].data.filter(
    (r) => r.intervalStart >= from && r.intervalStart < to
  );
  const fullRequestedHours =
    (to - Date.parse(`${history.window.from}T00:00:00Z`) / 1000) / 3600;
  const poolHistoryChecks = [];
  for (const [id, p] of Object.entries(snapshot.pools)) {
    const response = history.sources[`pool-history-${id}`]?.data;
    for (const r of p.reserves) {
      const found = response?.balanceHistory?.find(
        (a) => a.asset.assetId === r.id
      );
      const onchain = Number(BigInt(r.balance)) / 10 ** r.info.decimals;
      poolHistoryChecks.push({
        poolId: Number(id),
        assetId: r.id,
        currentFromHistory: found?.current ?? null,
        pinnedOnchain: onchain,
        relativeDifference:
          found && onchain ? found.current / onchain - 1 : null,
        latestAmountConsistent:
          !!found &&
          Math.abs(found.current - onchain) <= Math.max(1, onchain * 0.03),
        note: "Different collection blocks: large discrepancies reject the history, small differences are not exact reconciliation.",
      });
    }
  }
  const verifiedRoutes = Object.entries(history.sources)
    .filter(([k]) => k.startsWith("route-"))
    .map(([k, s]) => ({
      key: k,
      url: s.url,
      success: s.data.success,
      assetIn: s.data.assetIn?.assetId,
      assetOut: s.data.assetOut?.assetId,
      valueUsd: s.data.valueUsd,
      pools:
        s.data.route?.map((r) => ({
          type: r.pool,
          id: r.poolId,
          assetIn: r.assetIn.assetId,
          assetOut: r.assetOut.assetId,
        })) || [],
    }));
  const hsm = history.sources.hollar.data.hsm.arbitrageDaily.filter(
    (d) =>
      timestamp(`${d.date} 00:00:00`) >= from &&
      timestamp(`${d.date} 00:00:00`) < to
  );
  const sum = (a) => a.reduce((x, y) => x + y, 0);
  return {
    window: {
      from: new Date(from * 1000).toISOString(),
      toExclusive: new Date(to * 1000).toISOString(),
    },
    coverage: {
      requestedHistoricalHours: fullRequestedHours,
      receivedHistoricalPrimeHours: history.sources["hourly-43"].data.filter(
        (r) => r.intervalStart < to
      ).length,
      last30PrimeHours: hourly.length,
      last30HollarHours: peg.length,
      expectedLast30Hours: 720,
      activity: history.activityCoverage,
      indexer: history.sources.indexer.data,
      missingApiSeries: Object.keys(history.errors),
    },
    prime: {
      economicActions: classified.accepted.length,
      excludedWrappers: classified.excludedWrappers,
      excludedUnresolved: classified.excludedUnresolved,
      totalPrimeSoldRaw: classified.totalPrimeSoldRaw,
      totalPrimeBoughtRaw: classified.totalPrimeBoughtRaw,
      sellUsd: sum(sell),
      buyUsd: sum(buy),
      meanSellUsdPerDay: sum(sell) / 30,
      medianSellUsdPerDay: quantile(sell, 0.5),
      p90SellUsdPerDay: quantile(sell, 0.9),
      maxSellUsdPerDay: Math.max(...sell),
      meanBuyUsdPerDay: sum(buy) / 30,
      medianGapMinutes: quantile(gaps, 0.5),
      p90GapMinutes: quantile(gaps, 0.9),
      medianMaterialGapHours: quantile(materialGaps, 0.5),
      p90MaterialGapHours: quantile(materialGaps, 0.9),
      observedDaily: classified.days,
      lastIndexedPrice: hourly.at(-1)?.close,
      moneyMarketOracle: Number(snapshot.markets.PRIME.price) / 1e8,
      referenceWarning:
        "Indexed USD prices come from market routing; not independent PRIME subscription/redemption NAV.",
    },
    hollar: {
      minHourlyClose: Math.min(...peg.map((r) => r.close)),
      maxHourlyClose: Math.max(...peg.map((r) => r.close)),
      hsmArbitrageBurn: sum(hsm.map((d) => d.hollarIn)),
      hsmArbitrageMint: sum(hsm.map((d) => d.hollarOut)),
      hsmArbDays: hsm.filter((d) => d.hollarIn + d.hollarOut > 0).length,
      note: "HSM trade and arbitrage series may overlap; never add their gross volumes blindly.",
    },
    poolHistoryChecks,
    verifiedRoutes,
    poolReserveHistory: Object.fromEntries(
      Object.entries(history.sources)
        .filter(([k]) => k.startsWith("pool-state-"))
        .map(([k, s]) => [
          s.data.poolId,
          {
            source: s.url,
            last30: reserveSummary(s.data, from, to),
            last90: reserveSummary(s.data, to - 90 * 86400, to),
          },
        ])
    ),
    interpretation: {
      observedFlowIsNotCapacity: true,
      tradeGapIsNotArbitrageLatency: true,
      observedSellsAreNotAllArbitrage: true,
      wrapperConversionsExcluded: true,
      endpointActionsNotAllPoolLegs: true,
      externalProviderCommitmentVerified: false,
    },
    calibrationScenarios: {
      observedMeanPrimeFlow: { primeDailyCapacity: sum(sell) / 30 },
      observedP90PrimeFlow: { primeDailyCapacity: quantile(sell, 0.9) },
      observedPeakPrimeFlow: { primeDailyCapacity: Math.max(...sell) },
    },
  };
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const raw = readFileSync(process.argv[2]),
    snapshot = JSON.parse(readFileSync(process.argv[3]));
  const result = calibrate(JSON.parse(raw), snapshot);
  result.sourceSha256 = createHash("sha256").update(raw).digest("hex");
  const output = process.argv[4] || "/tmp/propeller-neckwork-calibration.json";
  writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
  console.log(
    output,
    { ...result.prime, observedDaily: undefined },
    result.hollar,
    result.coverage,
    result.calibrationScenarios
  );
}
