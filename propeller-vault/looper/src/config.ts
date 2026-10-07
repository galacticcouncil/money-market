import 'dotenv/config';
import { parseRoundingPolicies } from './rounding-policy.js';

const maxTxGas = process.env.MAX_TX_GAS || '16777216';
if (!/^[1-9][0-9]*$/.test(maxTxGas)) throw new Error('MAX_TX_GAS must be a positive integer');

function integer(name: string, fallback: number, min = 1, max = Number.MAX_SAFE_INTEGER) {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`${name} is out of range`);
  return value;
}
const operatorCount = integer('OPERATOR_COUNT', 1);
const sponsoredGas = process.env.SPONSORED_GAS ?? 'true';
if (!['true', 'false'].includes(sponsoredGas)) throw new Error('SPONSORED_GAS must be true or false');

export const CONFIG = {
  RPC_URL: process.env.RPC_URL || 'https://hdx.tarn.hydration.cloud',
  RPC_URLS: (process.env.RPC_URLS || process.env.RPC_URL || 'https://hdx.tarn.hydration.cloud').split(',').map(s => s.trim()).filter(Boolean),
  GAS_ASSET_ADDRESS: (process.env.GAS_ASSET_ADDRESS || '0x0000000000000000000000000000000000000000') as `0x${string}`,
  // signer only pays gas — pokeBorrow is permissionless, no role required.
  PRIVATE_KEY: process.env.LOOPER_PRIVATE_KEY as `0x${string}`,
  SUBLOOP_ADDRESS: process.env.SUBLOOP_ADDRESS as `0x${string}`,
  // comma-separated; one SubLoop can back several vaults. VAULT_ADDRESS is a legacy alias
  VAULT_ADDRESSES: (process.env.VAULT_ADDRESSES || process.env.VAULT_ADDRESS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean) as `0x${string}`[],
  // Harvester — skim+distribute carry (optional; harvest skipped if unset).
  HARVESTER_ADDRESS: (process.env.HARVESTER_ADDRESS || '') as `0x${string}`,
  EXECUTION_CONTROLLER: (process.env.EXECUTION_CONTROLLER || '') as `0x${string}`,
  // aave main-market pool, for leverage logging (defaults to lark-2 main market).
  POOL_ADDRESS: (process.env.POOL_ADDRESS ||
    '0x1b02E051683b5cfaC5929C25E84adb26ECf87B38') as `0x${string}`,
  POLL_INTERVAL_MS: integer('POLL_INTERVAL_MS', 30000),
  SAFETY_INTERVAL_MS: integer('SAFETY_INTERVAL_MS', 30000),
  RPC_STALE_SECONDS: integer('RPC_STALE_SECONDS', 120),
  QUOTE_TTL_SECONDS: integer('QUOTE_TTL_SECONDS', 60),
  QUOTE_DRIFT_BPS: BigInt(integer('QUOTE_DRIFT_BPS', 2, 0, 100)),
  QUOTE_SIZE_STEPS: integer('QUOTE_SIZE_STEPS', 6, 1, 12),
  // blocks a quote must still have before the controller's window closes;
  // an older one is re-pinned at the chosen sizes just before signing
  QUOTE_INCLUSION_BLOCKS: integer('QUOTE_INCLUSION_BLOCKS', 2, 1, 255),
  // without a receipt by then, re-send the identical signed transaction
  RECEIPT_TIMEOUT_MS: integer('RECEIPT_TIMEOUT_MS', 60000, 1000),
  SLICE_PRICE_TOLERANCE_BPS: BigInt(integer('SLICE_PRICE_TOLERANCE_BPS', 1, 0, 100)),
  SPONSORED_GAS: sponsoredGas === 'true',
  HARVEST_MIN_USD8: BigInt(integer('HARVEST_MIN_USD8', 100000000)),
  HARVEST_MAX_GAS_BPS: BigInt(integer('HARVEST_MAX_GAS_BPS', 10, 1, 10000)),
  HARVEST_MAX_DELAY_SECONDS: BigInt(integer('HARVEST_MAX_DELAY_SECONDS', 86400)),
  MAIN_INTEREST_URGENT_USD8: BigInt(integer('MAIN_INTEREST_URGENT_USD8', 1000000000)),
  OPERATOR_COUNT: operatorCount,
  OPERATOR_INDEX: integer('OPERATOR_INDEX', 0, 0, operatorCount - 1),
  OPERATOR_SLOT_SECONDS: integer('OPERATOR_SLOT_SECONDS', 60),
  // operator budget, also capped by the live block gas limit
  MAX_TX_GAS: BigInt(maxTxGas),
  // stop ramping once HF ≤ target·(1+buffer), avoiding borrow-to-floor no-ops
  RAMP_HF_BUFFER: Number(process.env.RAMP_HF_BUFFER || 0.005),
  // settlement/rebalance cadence in cycles; harvest is checked every cycle
  SLOW_EVERY: Number(process.env.SLOW_EVERY || 10),
  ALERT_WEBHOOK: process.env.ALERT_WEBHOOK,
};

export const ROUNDING_POLICIES = parseRoundingPolicies(
  process.env.PROPELLER_ROUNDING_RESERVES || '[]', CONFIG.VAULT_ADDRESSES,
);
