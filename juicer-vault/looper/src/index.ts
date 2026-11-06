import { JuicerLooper } from './looper.js';
import { CONFIG } from './config.js';
import { setTimeout as sleep } from 'node:timers/promises';

async function main() {
  console.log('Starting Juicer Looper...');
  console.log(`SubLoop: ${CONFIG.SUBLOOP_ADDRESS}`);
  console.log(`Poll interval: ${CONFIG.POLL_INTERVAL_MS}ms`);

  const looper = new JuicerLooper();
  const shutdown = new AbortController();
  for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => {
    console.log(`${signal}: stopping new work; waiting for any submitted transaction`);
    looper.stop();
    shutdown.abort();
  });

  // sleep after each run, not setInterval: overlapping cycles would race on the signer nonce
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
