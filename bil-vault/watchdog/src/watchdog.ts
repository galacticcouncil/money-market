import {
  createPublicClient,
  http,
  parseAbi,
  keccak256,
  toHex,
  formatEther,
  type Address,
  type Chain,
  type PublicClient,
} from 'viem';
import { CONFIG } from './config.js';

const hydration: Chain = {
  id: 222222,
  name: 'Hydration',
  nativeCurrency: { name: 'HDX', symbol: 'HDX', decimals: 18 },
  rpcUrls: { default: { http: [CONFIG.RPC_URL] } },
};

const VAULT_ABI = parseAbi([
  'function getQueueHead() view returns (uint256)',
  'function getRedemptionQueueLength() view returns (uint256)',
  'function getRedemptionRequest(uint256) view returns (address user, uint256 bilAmount, uint256 bilSettled, uint256 hollarOwed, bool active)',
  'function autoClaimEnabled(address) view returns (bool)',
  'function getPositionHead() view returns (uint256)',
  'function getPositionCount() view returns (uint256)',
  'function getPosition(uint256) view returns (uint256 tokenId, uint256 principal, uint256 apyWad, uint256 depositTime, uint256 maturityTime, uint8 state)',
  'function paused() view returns (bool)',
  'function hasRole(bytes32, address) view returns (bool)',
]);

const CLAIM_OPERATOR_ROLE = keccak256(toHex('CLAIM_OPERATOR_ROLE'));
const STATE_NAMES = ['Active', 'YieldWithdrawalRequested', 'YieldClaimed', 'PrincipalWithdrawalRequested', 'Redeemed'];
const REDEEMED = 4;
const BATCH = 20;

type Level = 'warn' | 'error';
type Issue = { level: Level; text: string };
type Tracked = Issue & { lastAlert: number };

export class BILWatchdog {
  private client: PublicClient;
  private vault: Address = CONFIG.VAULT_ADDRESS;
  // requestId → chain ts when first seen settled (in-memory; a restart restarts the grace clock)
  private settledSince = new Map<bigint, number>();
  private open = new Map<string, Tracked>();
  private rpcFailures = 0;
  private rpcAlerted = false;

  constructor() {
    this.client = createPublicClient({ chain: hydration, transport: http(CONFIG.RPC_URL, { timeout: 20_000 }) });
  }

  async runCycle(): Promise<void> {
    let issues: Map<string, Issue>;
    let now: number;
    try {
      ({ issues, now } = await this.scan());
    } catch (err) {
      this.rpcFailures++;
      console.error(`Scan failed (${this.rpcFailures} in a row):`, err);
      if (this.rpcFailures >= CONFIG.RPC_FAILURES_BEFORE_ALERT && !this.rpcAlerted) {
        this.rpcAlerted = true;
        await this.post('error', 'BIL Watchdog — blind', `Scan failed ${this.rpcFailures}× in a row, so the vault is unwatched.\n\`${String(err).slice(0, 300)}\``);
      }
      return;
    }
    if (this.rpcAlerted) {
      await this.post('ok', 'BIL Watchdog — recovered', `Scanning again after ${this.rpcFailures} failed cycles.`);
    }
    this.rpcFailures = 0;
    this.rpcAlerted = false;

    const fire: Issue[] = [];
    for (const [key, issue] of issues) {
      const prev = this.open.get(key);
      if (!prev || now - prev.lastAlert >= CONFIG.REALERT_SECONDS) {
        fire.push(issue);
        this.open.set(key, { ...issue, lastAlert: now });
      } else {
        this.open.set(key, { ...issue, lastAlert: prev.lastAlert });
      }
    }
    const resolved: string[] = [];
    for (const [key, prev] of this.open) {
      if (!issues.has(key)) {
        resolved.push(prev.text);
        this.open.delete(key);
      }
    }

    console.log(`[${new Date(now * 1000).toISOString()}] open issues: ${issues.size}, alerting: ${fire.length}, resolved: ${resolved.length}`);
    if (fire.length) {
      const level: Level = fire.some((i) => i.level === 'error') ? 'error' : 'warn';
      await this.post(level, `BIL Watchdog — ${fire.length} issue(s)`, fire.map((i) => `• ${i.text}`).join('\n'));
    }
    if (resolved.length) {
      await this.post('ok', `BIL Watchdog — ${resolved.length} resolved`, resolved.map((t) => `• ~~${t}~~`).join('\n'));
    }
  }

  private async scan(): Promise<{ issues: Map<string, Issue>; now: number }> {
    const issues = new Map<string, Issue>();
    const block = await this.client.getBlock();
    const now = Number(block.timestamp);
    const blockNumber = block.number;
    const read = <T>(functionName: string, args: readonly unknown[] = []) =>
      this.client.readContract({ address: this.vault, abi: VAULT_ABI, functionName: functionName as any, args: args as any, blockNumber }) as Promise<T>;

    const [head, tail, posHead, posCount, paused] = await Promise.all([
      read<bigint>('getQueueHead'),
      read<bigint>('getRedemptionQueueLength'),
      read<bigint>('getPositionHead'),
      read<bigint>('getPositionCount'),
      read<boolean>('paused'),
    ]);

    let keeperNote = '';
    let claimRole = false;
    if (CONFIG.KEEPER_ADDRESS) {
      const [hasRole, bal] = await Promise.all([
        read<boolean>('hasRole', [CLAIM_OPERATOR_ROLE, CONFIG.KEEPER_ADDRESS]),
        this.client.getBalance({ address: CONFIG.KEEPER_ADDRESS, blockNumber }),
      ]);
      claimRole = hasRole;
      keeperNote = ` (keeper gas: ${Number(formatEther(bal)).toFixed(4)} WETH)`;
      if (bal < CONFIG.MIN_KEEPER_WETH) {
        issues.set('keeper:gas', { level: 'warn', text: `Keeper ${CONFIG.KEEPER_ADDRESS} low on gas: ${formatEther(bal)} WETH` });
      }
    }
    if (paused) {
      issues.set('vault:paused', { level: 'warn', text: 'Vault is paused, so claims and pokes revert. Not a keeper fault.' });
    }

    // settled + opted-in redemptions that the keeper should have auto-claimed.
    // auto-claim is optional (CLAIM_OPERATOR_ROLE); without the role these are the users' to claim
    const reqs = await this.batch(head, tail, (id) => read<[Address, bigint, bigint, bigint, boolean]>('getRedemptionRequest', [id]));
    const settled = reqs.filter(([, r]) => r[4] && r[2] > 0n);
    const users = [...new Set(settled.map(([, r]) => r[0]))];
    const optIn = new Map<Address, boolean>();
    for (let i = 0; i < users.length; i += BATCH) {
      const chunk = users.slice(i, i + BATCH);
      const flags = await Promise.all(chunk.map((u) => read<boolean>('autoClaimEnabled', [u])));
      chunk.forEach((u, j) => optIn.set(u, flags[j]));
    }

    const live = new Set<bigint>();
    const waiting = settled.filter(([, r]) => optIn.get(r[0]));
    if (CONFIG.KEEPER_ADDRESS && !claimRole && waiting.length) {
      issues.set('claim:disabled', {
        level: 'warn',
        text: `Auto-claim is off (keeper lacks CLAIM_OPERATOR_ROLE), but ${waiting.length} opted-in settled request(s) are waiting for users to claim manually`,
      });
    }
    for (const [id, [user, , bilSettled, hollarOwed]] of claimRole && !paused ? waiting : []) {
      live.add(id);
      const since = this.settledSince.get(id) ?? now;
      this.settledSince.set(id, since);
      const age = now - since;
      if (age >= CONFIG.CLAIM_GRACE_SECONDS) {
        issues.set(`claim:${id}`, {
          level: 'error',
          text: `Unclaimed auto-claim: request ${id}, ${user}, ${fmt(bilSettled)} BIL → ${fmt(hollarOwed)} HOLLAR, settled ≥${Math.floor(age / 60)}m ago${keeperNote}`,
        });
      }
    }
    for (const id of this.settledSince.keys()) if (!live.has(id)) this.settledSince.delete(id);

    // matured positions the keeper should be advancing
    const positions = await this.batch(posHead, posCount, (i) => read<[bigint, bigint, bigint, bigint, bigint, number]>('getPosition', [i]));
    for (const [i, [tokenId, principal, , , maturity, state]] of positions) {
      if (state === REDEEMED) continue;
      const over = now - Number(maturity);
      if (over < 0) continue;
      const desc = `position ${i} (token ${tokenId}, ${fmt(principal)} HOLLAR) in ${STATE_NAMES[state] ?? state}, ${Math.floor(over / 3600)}h past maturity`;
      if (over >= CONFIG.STUCK_THRESHOLD_SECONDS) {
        issues.set(`pos:${i}`, { level: 'error', text: `Stuck ${desc}` });
      } else if (state === 0 && !paused && over >= CONFIG.MATURED_GRACE_SECONDS) {
        issues.set(`pos:${i}`, { level: 'warn', text: `Matured but not advanced: ${desc}${keeperNote}` });
      }
    }

    return { issues, now };
  }

  private async batch<T>(from: bigint, to: bigint, fn: (i: bigint) => Promise<T>): Promise<[bigint, T][]> {
    const out: [bigint, T][] = [];
    for (let i = from; i < to; i += BigInt(BATCH)) {
      const ids: bigint[] = [];
      for (let j = i; j < to && j < i + BigInt(BATCH); j++) ids.push(j);
      const res = await Promise.all(ids.map(fn));
      ids.forEach((id, k) => out.push([id, res[k]]));
    }
    return out;
  }

  private async post(level: Level | 'ok', title: string, description: string): Promise<void> {
    console.log(`${title}\n${description}`);
    if (!CONFIG.ALERT_WEBHOOK) return;
    const color = level === 'error' ? 0xe74c3c : level === 'warn' ? 0xf1c40f : 0x2ecc71;
    const body = description.length > 4000 ? description.slice(0, 3990) + '\n…' : description;
    try {
      const res = await fetch(CONFIG.ALERT_WEBHOOK, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: 'BIL Watchdog',
          embeds: [{ title, description: body, color, footer: { text: `Vault ${this.vault}` }, timestamp: new Date().toISOString() }],
        }),
      });
      if (!res.ok) console.error(`  webhook ${res.status}: ${await res.text()}`);
    } catch (err) {
      console.error('  Failed to send alert:', err);
    }
  }
}

const fmt = (v: bigint) => Number(formatEther(v)).toLocaleString('en-US', { maximumFractionDigits: 2 });
