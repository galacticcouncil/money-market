import 'dotenv/config';
import { parseEther } from 'viem';

const num = (v: string | undefined, d: number) => (v === undefined || v === '' ? d : Number(v));

export const CONFIG = {
  RPC_URL: process.env.RPC_URL || 'https://rpc.hydradx.cloud',
  VAULT_ADDRESS: process.env.VAULT_ADDRESS as `0x${string}`,
  // optional: enables role + gas diagnostics in alerts
  KEEPER_ADDRESS: (process.env.KEEPER_ADDRESS || undefined) as `0x${string}` | undefined,
  POLL_INTERVAL_MS: num(process.env.POLL_INTERVAL_MS, 60_000),
  CLAIM_GRACE_SECONDS: num(process.env.CLAIM_GRACE_MINUTES, 10) * 60,
  MATURED_GRACE_SECONDS: num(process.env.MATURED_GRACE_MINUTES, 60) * 60,
  APPROVAL_SLA_SECONDS: num(process.env.APPROVAL_SLA_HOURS, 24) * 3600,
  STUCK_THRESHOLD_SECONDS: num(process.env.STUCK_THRESHOLD_HOURS, 96) * 3600,
  REALERT_SECONDS: num(process.env.REALERT_HOURS, 6) * 3600,
  RPC_FAILURES_BEFORE_ALERT: num(process.env.RPC_FAILURES_BEFORE_ALERT, 5),
  // evm gas on hydration is paid in WETH (asset 20); eth_getBalance reports it
  MIN_KEEPER_WETH: parseEther(process.env.MIN_KEEPER_WETH || '0.02'),
  ALERT_WEBHOOK: process.env.ALERT_WEBHOOK,
};
