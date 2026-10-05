import { PropellerLooper } from './looper.js';
import { CONFIG } from './config.js';
import { setTimeout as sleep } from 'node:timers/promises';

async function main() {
  console.log('Starting Propeller Looper...');
  console.log(`SubLoop: ${CONFIG.SUBLOOP_ADDRESS}`);
  console.log(`Poll interval: ${CONFIG.POLL_INTERVAL_MS}ms`);

  const looper = new PropellerLooper();
  const shutdown = new AbortController();
  for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => {
    console.log(`${signal}: stopping new work; waiting for any submitted transaction`);
    looper.stop();
    shutdown.abort();
  });

  // Self-scheduling loop, NOT setInterval: a cycle can outlast POLL_INTERVAL_MS
  // (a slow cycle submits pokeBorrow + maintainPeg/rebalance per vault + harvest,
  // each awaiting a receipt at ~12s/block). setInterval fires regardless, so
  // cycles overlap and the overlapping txs race on the signer's nonce — the very
  // thing `replicas: 1` exists to prevent, reintroduced inside one process.
  // Sleeping AFTER each cycle keeps exactly one in flight.
  const repeat = async (task: () => Promise<void>, interval: number, label: string) => {
    while (!shutdown.signal.aborted) {
      try { await task(); }
      catch (err) { console.error(`[ALERT] ${label} failed:`, err); }
      if (!shutdown.signal.aborted) {
        try { await sleep(interval, undefined, {signal: shutdown.signal}); }
        catch (err) { if (!shutdown.signal.aborted) throw err; }
      }
    }
  };
  await Promise.all([
    repeat(() => looper.runCycle(), CONFIG.POLL_INTERVAL_MS, 'maintenance'),
    repeat(() => looper.monitorSafety(), CONFIG.SAFETY_INTERVAL_MS, 'independent safety monitor'),
  ]);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
