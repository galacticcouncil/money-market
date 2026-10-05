import 'dotenv/config';
import { parseEther } from 'viem';

const num = (v: string | undefined, d: number) => (v === undefined || v === '' ? d : Number(v));

export const CONFIG = {
  RPC_URL: process.env.RPC_URL || 'https://rpc.hydradx.cloud',
  VAULT_ADDRESS: process.env.VAULT_ADDRESS as `0x${string}`,
  // optional: enables role + gas diagnostics in alerts
  KEEPER_ADDRESS: (process.env.KEEPER_ADDRESS || undefined) as `0x${string}` | undefined,
  // BIL money market pool (HOLLAR borrow side); mainnet default
  BIL_POOL: (process.env.BIL_POOL || '0x69310FdA58c819aD82df7d2Cb61841C853337a53') as `0x${string}`,
  POLL_INTERVAL_MS: num(process.env.POLL_INTERVAL_MS, 60_000),
  CLAIM_GRACE_SECONDS: num(process.env.CLAIM_GRACE_MINUTES, 10) * 60,
  MATURED_GRACE_SECONDS: num(process.env.MATURED_GRACE_MINUTES, 60) * 60,
  STUCK_THRESHOLD_SECONDS: num(process.env.STUCK_THRESHOLD_HOURS, 96) * 3600,
  // decentral approvals are out of our hands: one digest per DIGEST_HOURS, waits past the sla marked overdue
  DIGEST_SECONDS: num(process.env.DIGEST_HOURS, 24) * 3600,
  APPROVAL_SLA_SECONDS: num(process.env.APPROVAL_SLA_HOURS, 48) * 3600,
  REALERT_SECONDS: num(process.env.REALERT_HOURS, 6) * 3600,
  RPC_FAILURES_BEFORE_ALERT: num(process.env.RPC_FAILURES_BEFORE_ALERT, 5),
  // evm gas on hydration is paid in WETH (asset 20); eth_getBalance reports it. ~0.0001/day at current keeper volume
  MIN_KEEPER_WETH: parseEther(process.env.MIN_KEEPER_WETH || '0.001'),
  // status ui + api; 0 disables
  PORT: num(process.env.PORT, 8080),
  ALERT_WEBHOOK: process.env.ALERT_WEBHOOK,
};
