import { BILWatchdog } from './watchdog.js';
import { CONFIG } from './config.js';
import { serve } from './server.js';

async function main() {
  if (!CONFIG.VAULT_ADDRESS) throw new Error('VAULT_ADDRESS required');
  console.log('Starting BIL Watchdog...');
  console.log(`Vault: ${CONFIG.VAULT_ADDRESS}`);
  console.log(`Keeper: ${CONFIG.KEEPER_ADDRESS ?? '(not set)'}`);
  console.log(`Poll interval: ${CONFIG.POLL_INTERVAL_MS}ms, claim grace: ${CONFIG.CLAIM_GRACE_SECONDS}s`);
  if (!CONFIG.KEEPER_ADDRESS) console.warn('KEEPER_ADDRESS not set — auto-claim and keeper-gas checks disabled');
  if (!CONFIG.ALERT_WEBHOOK) console.warn('ALERT_WEBHOOK not set — alerts go to stdout only');

  const watchdog = new BILWatchdog();
  if (CONFIG.PORT) serve(watchdog, CONFIG.PORT, CONFIG.POLL_INTERVAL_MS);

  // serialize cycles so a slow RPC never overlaps two scans
  const loop = async () => {
    await watchdog.runCycle();
    setTimeout(loop, CONFIG.POLL_INTERVAL_MS);
  };
  await loop();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
