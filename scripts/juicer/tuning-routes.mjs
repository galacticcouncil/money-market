// Snapshot-only source-route constraints for the five-round tuning campaign.
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { loadMath, capacity, poolQuote, maximumInput } from './pressure-model.mjs';
import { lossBps } from './route-calibration.mjs';

export function tuningRoutes(snapshot, math) {
  const original = snapshot.pools[143], price = BigInt(snapshot.markets.PRIME.price);
  const wad = 10n ** 18n;
  const quotes = [1, 10, 100, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000].map(usd => {
    const hollar = BigInt(usd) * wad, prime = BigInt(usd) * 10n ** 14n / price;
    try { return { usd,
      entryLossBps: lossBps(hollar, poolQuote(math.stable, original, 222, 43, hollar), price),
      exitLossBps: lossBps(prime, poolQuote(math.stable, original, 43, 222, prime), price, true),
    }; } catch (e) { return { usd, rejected: e.message }; }
  });
  const oneShot = [5, 10, 15, 25, 50, 100].map(bps => ({ bps,
    entryHollar: Number(maximumInput(q => poolQuote(math.stable, original, 222, 43, q),
      (out, input) => out * price * 10n ** 12n * 10000n >= input * 100000000n * BigInt(10000 - bps), 10n ** 24n)) / 1e18,
  }));
  const sequential = [];
  for (const bps of [10, 15, 25, 50, 100]) for (const chunk of [250, 1000, 5000]) {
    const pool = structuredClone(original);
    let cumulative = 0, lastLoss = 0, truncated = true;
    for (let i = 0; i < 4000; i++) {
      const input = BigInt(chunk) * wad;
      let output;
      try { output = poolQuote(math.stable, pool, 222, 43, input); }
      catch { truncated = false; break; }
      const loss = lossBps(input, output, price);
      if (loss + 2 > bps) { truncated = false; break; }
      const h = pool.reserves.find(x => x.id === 222), p = pool.reserves.find(x => x.id === 43);
      h.balance = (BigInt(h.balance) + input).toString();
      p.balance = (BigInt(p.balance) - output).toString();
      cumulative += chunk; lastLoss = loss;
    }
    sequential.push({ sourceBps: bps, chunk, quoteMarginBps: 2,
      noRefillCumulativeHollar: cumulative, lastLossBps: lastLoss, truncated });
  }
  return { block: snapshot.block, hash: snapshot.hash, dependencies: math.dependencies,
    capacity: capacity(snapshot), quotes, oneShot, sequential,
    scope: 'Fixed oracle, peg and amplification; sequential reserve updates without external refill. Pool math omits native circuit breakers and concurrent trades. This is a necessary quote constraint, not guaranteed executable throughput. Shared limits must aggregate all vaults.',
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [input, output] = process.argv.slice(2);
  const raw = readFileSync(input);
  const result = tuningRoutes(JSON.parse(raw), loadMath(process.env.HYDRATION_MATH_ROOT));
  result.inputSha256 = createHash('sha256').update(raw).digest('hex');
  writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
}
