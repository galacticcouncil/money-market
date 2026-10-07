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
  'function positionPool(uint256) view returns (address)',
  'function asset() view returns (address)',
  'function activeDepositPool() view returns (address)',
  'function totalAssets() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function exchangeRate() view returns (uint256)',
  'function idleHollar() view returns (uint256)',
  'function totalQueuedBil() view returns (uint256)',
  'function totalSettledBil() view returns (uint256)',
  'function totalReservedHollar() view returns (uint256)',
]);

const DECENTRAL_ABI = parseAbi([
  'function getYieldWithdrawalRequest(uint256) view returns (uint256 amount, uint256 requestTimestamp, bool exists, bool approved)',
  'function getPrincipalWithdrawalRequest(uint256) view returns (uint256 amount, uint256 requestTimestamp, uint256 availableTimestamp, bool exists, bool approved)',
]);

const MARKET_ABI = parseAbi([
  'function getReserveData(address) view returns ((uint256,uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128))',
  'function getFacilitatorBucket(address) view returns (uint256, uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function getGhoTreasury() view returns (address)',
]);

const CLAIM_OPERATOR_ROLE = keccak256(toHex('CLAIM_OPERATOR_ROLE'));
const STATE_NAMES = ['Active', 'YieldWithdrawalRequested', 'YieldClaimed', 'PrincipalWithdrawalRequested', 'Redeemed'];
const YIELD_REQUESTED = 1;
const PRINCIPAL_REQUESTED = 3;
const REDEEMED = 4;
const BATCH = 20;
const RAY = 1e27;
const UPCOMING = 10;

type Level = 'warn' | 'error';
type Issue = { level: Level; text: string };
type Tracked = Issue & { firstSeen: number; lastAlert: number };
type Decentral = { waiting: string | null; requestedAt: number | null; amount: bigint };

export type Status = ReturnType<BILWatchdog['buildStatus']>;

export class BILWatchdog {
  private client: PublicClient;
  private vault: Address = CONFIG.VAULT_ADDRESS;
  // requestId → chain ts when first seen settled (in-memory; a restart restarts the grace clock)
  private settledSince = new Map<bigint, number>();
  // positionIndex → chain ts when decentral first allowed the next step (keeper should act within grace)
  private readySince = new Map<bigint, number>();
  private open = new Map<string, Tracked>();
  private rpcFailures = 0;
  private rpcAlerted = false;
  private lastDigest = 0;
  private snapshot: Awaited<ReturnType<BILWatchdog['scan']>>['snapshot'] | null = null;
  private lastError: string | null = null;

  constructor() {
    this.client = createPublicClient({ chain: hydration, transport: http(CONFIG.RPC_URL, { timeout: 20_000 }) });
  }

  async runCycle(): Promise<void> {
    let issues: Map<string, Issue>;
    let now: number;
    let snapshot: NonNullable<typeof this.snapshot>;
    try {
      ({ issues, now, snapshot } = await this.scan());
    } catch (err) {
      this.rpcFailures++;
      this.lastError = String(err).slice(0, 300);
      console.error(`Scan failed (${this.rpcFailures} in a row):`, err);
      if (this.rpcFailures >= CONFIG.RPC_FAILURES_BEFORE_ALERT && !this.rpcAlerted) {
        this.rpcAlerted = true;
        await this.post('error', 'BIL Watchdog — blind', `Scan failed ${this.rpcFailures}× in a row, so the vault is unwatched.\n\`${this.lastError}\``);
      }
      return;
    }
    if (this.rpcAlerted) {
      await this.post('ok', 'BIL Watchdog — recovered', `Scanning again after ${this.rpcFailures} failed cycles.`);
    }
    this.rpcFailures = 0;
    this.rpcAlerted = false;
    this.lastError = null;
    this.snapshot = snapshot;

    const fire: Issue[] = [];
    for (const [key, issue] of issues) {
      const prev = this.open.get(key);
      if (!prev || now - prev.lastAlert >= CONFIG.REALERT_SECONDS) {
        fire.push(issue);
        this.open.set(key, { ...issue, firstSeen: prev?.firstSeen ?? now, lastAlert: now });
      } else {
        this.open.set(key, { ...issue, firstSeen: prev.firstSeen, lastAlert: prev.lastAlert });
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

    // decentral approvals: one summary per digest window, never per position, and only
    // when a wait is actually slow; fresh waits are normal processing and stay quiet
    const d = snapshot.decentral;
    if (d.slowCount > 0 && now - this.lastDigest >= CONFIG.DIGEST_SECONDS) {
      this.lastDigest = now;
      const overdue = d.overdueCount ? `, ${d.overdueCount} past the ${dur(CONFIG.APPROVAL_SLA_SECONDS)} sla` : '';
      await this.post(
        d.overdueCount ? 'warn' : 'info',
        'BIL — slow Decentral approvals',
        `${fmt(d.slowPrincipal)} HOLLAR principal (+ ${fmt(d.slowYield)} yield) across ${d.slowCount} position(s) waiting over ${dur(CONFIG.DIGEST_MIN_WAIT_SECONDS)} for Decentral approval; oldest ${dur(d.oldestWait)}${overdue}.\n` +
          `Decentral pool holds ${fmt(d.poolHollar)} HOLLAR. Nothing to do on our side.`,
      );
    }
  }

  status() {
    return this.buildStatus();
  }

  private buildStatus() {
    const s = this.snapshot;
    const n = (v: bigint) => Number(formatEther(v));
    return {
      ok: s !== null && this.lastError === null,
      lastError: this.lastError,
      updatedAt: s ? new Date(s.now * 1000).toISOString() : null,
      block: s ? Number(s.block) : null,
      vault: s && {
        address: this.vault,
        paused: s.vault.paused,
        totalAssets: n(s.vault.totalAssets),
        totalSupply: n(s.vault.totalSupply),
        exchangeRate: n(s.vault.exchangeRate),
        idleHollar: n(s.vault.idle),
        reservedHollar: n(s.vault.reserved),
        unsettledBil: n(s.vault.queued - s.vault.settled),
        settledUnclaimedBil: n(s.vault.settled),
        positionCount: Number(s.vault.posCount),
        positionHead: Number(s.vault.posHead),
        openPositions: Number(s.vault.posCount - s.vault.posHead),
      },
      keeper: s?.keeper && { address: s.keeper.address, weth: n(s.keeper.weth), claimRole: s.keeper.claimRole, lowGas: s.keeper.weth < CONFIG.MIN_KEEPER_WETH },
      decentral: s && {
        pool: s.decentral.pool,
        poolHollar: n(s.decentral.poolHollar),
        waitingCount: s.decentral.waitingCount,
        waitingPrincipal: n(s.decentral.waitingPrincipal),
        waitingYield: n(s.decentral.waitingYield),
        oldestWaitSeconds: s.decentral.oldestWait,
        overdueCount: s.decentral.overdueCount,
        slaSeconds: CONFIG.APPROVAL_SLA_SECONDS,
        slowCount: s.decentral.slowCount,
        digestMinWaitSeconds: CONFIG.DIGEST_MIN_WAIT_SECONDS,
        lastDigestAt: this.lastDigest ? new Date(this.lastDigest * 1000).toISOString() : null,
      },
      market: s?.market && {
        pool: CONFIG.BIL_POOL,
        debt: n(s.market.debt),
        minted: n(s.market.minted),
        cap: n(s.market.cap),
        accruedUnpaid: n(s.market.debt > s.market.minted ? s.market.debt - s.market.minted : 0n),
        collectedUndistributed: n(s.market.collected),
        treasury: s.market.treasury,
        borrowApr: s.market.apr,
        borrowApy: Math.exp(s.market.apr) - 1,
        yearlyAtCurrent: n(s.market.debt) * (Math.exp(s.market.apr) - 1),
        yearlyAtCap: n(s.market.cap) * (Math.exp(s.market.apr) - 1),
      },
      matured: (s?.matured ?? []).map((p) => ({
        index: Number(p.index),
        tokenId: Number(p.tokenId),
        principal: n(p.principal),
        maturity: new Date(p.maturity * 1000).toISOString(),
        state: STATE_NAMES[p.state] ?? String(p.state),
        waitingOn: p.waiting,
        waitingSince: p.requestedAt ? new Date(p.requestedAt * 1000).toISOString() : null,
      })),
      upcoming: (s?.upcoming ?? []).map((p) => ({
        index: Number(p.index),
        tokenId: Number(p.tokenId),
        principal: n(p.principal),
        maturity: new Date(p.maturity * 1000).toISOString(),
      })),
      maturities: s ? maturityBuckets(s.now, s.matured, s.upcomingAll) : null,
      issues: [...this.open.entries()].map(([key, t]) => ({ key, level: t.level, text: t.text, since: new Date(t.firstSeen * 1000).toISOString() })),
    };
  }

  private async scan() {
    const issues = new Map<string, Issue>();
    const block = await this.client.getBlock();
    const now = Number(block.timestamp);
    const blockNumber = block.number;
    const read = <T>(functionName: string, args: readonly unknown[] = []) =>
      this.client.readContract({ address: this.vault, abi: VAULT_ABI, functionName: functionName as any, args: args as any, blockNumber }) as Promise<T>;

    const [head, tail, posHead, posCount, paused, totalAssets, totalSupply, exchangeRate, idle, queued, settledBil, reserved, hollar, activePool] =
      await Promise.all([
        read<bigint>('getQueueHead'),
        read<bigint>('getRedemptionQueueLength'),
        read<bigint>('getPositionHead'),
        read<bigint>('getPositionCount'),
        read<boolean>('paused'),
        read<bigint>('totalAssets'),
        read<bigint>('totalSupply'),
        read<bigint>('exchangeRate'),
        read<bigint>('idleHollar'),
        read<bigint>('totalQueuedBil'),
        read<bigint>('totalSettledBil'),
        read<bigint>('totalReservedHollar'),
        read<Address>('asset'),
        read<Address>('activeDepositPool'),
      ]);
    const erc = <T>(address: Address, functionName: string, args: readonly unknown[] = []) =>
      this.client.readContract({ address, abi: MARKET_ABI, functionName: functionName as any, args: args as any, blockNumber }) as Promise<T>;
    const poolHollar = await erc<bigint>(hollar, 'balanceOf', [activePool]);

    let keeperNote = '';
    let claimRole = false;
    let keeper: { address: Address; weth: bigint; claimRole: boolean } | null = null;
    if (CONFIG.KEEPER_ADDRESS) {
      const [hasRole, bal] = await Promise.all([
        read<boolean>('hasRole', [CLAIM_OPERATOR_ROLE, CONFIG.KEEPER_ADDRESS]),
        this.client.getBalance({ address: CONFIG.KEEPER_ADDRESS, blockNumber }),
      ]);
      claimRole = hasRole;
      keeper = { address: CONFIG.KEEPER_ADDRESS, weth: bal, claimRole: hasRole };
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
          text: `Unclaimed auto-claim: request ${id}, ${user}, ${fmt(bilSettled)} BIL → ${fmt(hollarOwed)} HOLLAR, settled ≥${dur(age)} ago${keeperNote}`,
        });
      }
    }
    for (const id of this.settledSince.keys()) if (!live.has(id)) this.settledSince.delete(id);

    // matured positions: who is holding them up, the keeper or Decentral?
    const positions = await this.batch(posHead, posCount, (i) => read<[bigint, bigint, bigint, bigint, bigint, number]>('getPosition', [i]));
    const ready = new Set<bigint>();
    const matured: { index: bigint; tokenId: bigint; principal: bigint; maturity: number; state: number; waiting: string | null; requestedAt: number | null }[] = [];
    const upcoming: { index: bigint; tokenId: bigint; principal: bigint; maturity: number }[] = [];
    const dec = { waitingCount: 0, waitingPrincipal: 0n, waitingYield: 0n, oldestWait: 0, overdueCount: 0, slowCount: 0, slowPrincipal: 0n, slowYield: 0n };
    for (const [i, [tokenId, principal, , , maturity, state]] of positions) {
      if (state === REDEEMED) continue;
      const over = now - Number(maturity);
      if (over < 0) {
        upcoming.push({ index: i, tokenId, principal, maturity: Number(maturity) });
        continue;
      }
      const desc = `position ${i} (token ${tokenId}, ${fmt(principal)} HOLLAR) in ${STATE_NAMES[state] ?? state}, ${dur(over)} past maturity`;

      let d: Decentral = { waiting: null, requestedAt: null, amount: 0n };
      if (state === 0) {
        if (!paused && over >= CONFIG.MATURED_GRACE_SECONDS) {
          issues.set(`pos:${i}`, { level: 'warn', text: `Matured but not advanced: ${desc}${keeperNote}` });
        }
      } else {
        d = await this.decentralStatus(i, tokenId, state, now, blockNumber, hollar);
        if (d.waiting && d.requestedAt !== null) {
          // approval wait: decentral's job, rolled into the digest
          const age = now - d.requestedAt;
          dec.waitingCount++;
          dec.waitingPrincipal += principal;
          if (state === YIELD_REQUESTED) dec.waitingYield += d.amount;
          dec.oldestWait = Math.max(dec.oldestWait, age);
          if (age >= CONFIG.APPROVAL_SLA_SECONDS) dec.overdueCount++;
          if (age >= CONFIG.DIGEST_MIN_WAIT_SECONDS) {
            dec.slowCount++;
            dec.slowPrincipal += principal;
            if (state === YIELD_REQUESTED) dec.slowYield += d.amount;
          }
        }
        if (!d.waiting) {
          ready.add(i);
          const since = this.readySince.get(i) ?? now;
          this.readySince.set(i, since);
          if (!paused && now - since >= CONFIG.CLAIM_GRACE_SECONDS) {
            issues.set(`ready:${i}`, {
              level: 'error',
              text: `Keeper not advancing: ${desc}, Decentral allows the next step since ≥${dur(now - since)}${keeperNote}`,
            });
          }
        }
      }
      matured.push({ index: i, tokenId, principal, maturity: Number(maturity), state, waiting: d.waiting, requestedAt: d.requestedAt });
      if (over >= CONFIG.STUCK_THRESHOLD_SECONDS && d.requestedAt === null) {
        issues.set(`pos:${i}`, { level: 'error', text: `Stuck ${desc}${d.waiting ? ` (${d.waiting})` : ''}` });
      }
    }
    for (const i of this.readySince.keys()) if (!ready.has(i)) this.readySince.delete(i);
    upcoming.sort((a, b) => a.maturity - b.maturity);

    // money market: hollar borrowed against BIL; a failure here must not blind the vault checks
    let market: { debt: bigint; minted: bigint; cap: bigint; collected: bigint; treasury: Address; apr: number } | null = null;
    try {
      const rd = (await erc<readonly unknown[]>(CONFIG.BIL_POOL, 'getReserveData', [hollar])) as readonly [
        bigint, bigint, bigint, bigint, bigint, bigint, number, number, Address, Address, Address, Address, bigint, bigint, bigint,
      ];
      const [aToken, debtToken, apr] = [rd[8], rd[10], Number(rd[4]) / RAY];
      const [[cap, minted], debt, collected, treasury] = await Promise.all([
        erc<readonly [bigint, bigint]>(hollar, 'getFacilitatorBucket', [aToken]),
        erc<bigint>(debtToken, 'totalSupply'),
        erc<bigint>(hollar, 'balanceOf', [aToken]),
        erc<Address>(aToken, 'getGhoTreasury'),
      ]);
      market = { debt, minted, cap, collected, treasury, apr };
    } catch (err) {
      console.error('  market read failed:', String(err).slice(0, 200));
    }

    const snapshot = {
      now,
      block: blockNumber,
      vault: { paused, totalAssets, totalSupply, exchangeRate, idle, queued, settled: settledBil, reserved, posHead, posCount },
      keeper,
      decentral: { pool: activePool, poolHollar, ...dec },
      market,
      matured,
      upcoming: upcoming.slice(0, UPCOMING),
      upcomingAll: upcoming,
    };
    return { issues, now, snapshot };
  }

  /// What the next Decentral step is waiting on (null = it can proceed), since when, and the request amount.
  private async decentralStatus(index: bigint, tokenId: bigint, state: number, now: number, blockNumber: bigint, hollar: Address): Promise<Decentral> {
    const pool = (await this.client.readContract({ address: this.vault, abi: VAULT_ABI, functionName: 'positionPool', args: [index], blockNumber })) as Address;
    if (state === YIELD_REQUESTED) {
      const [amount, requestedAt, exists, approved] = await this.client.readContract({ address: pool, abi: DECENTRAL_ABI, functionName: 'getYieldWithdrawalRequest', args: [tokenId], blockNumber });
      if (exists && !approved) return { waiting: 'yield withdrawal not approved', requestedAt: Number(requestedAt), amount };
      if (exists) {
        const short = await this.poolShort(pool, hollar, amount, blockNumber);
        if (short) return { waiting: short, requestedAt: Number(requestedAt), amount };
      }
    } else if (state === PRINCIPAL_REQUESTED) {
      const [amount, requestedAt, availableAt, exists, approved] = await this.client.readContract({ address: pool, abi: DECENTRAL_ABI, functionName: 'getPrincipalWithdrawalRequest', args: [tokenId], blockNumber });
      if (exists && !approved) return { waiting: 'principal withdrawal not approved', requestedAt: Number(requestedAt), amount };
      if (exists && now < Number(availableAt)) return { waiting: `principal delay until ${new Date(Number(availableAt) * 1000).toISOString()}`, requestedAt: null, amount };
      if (exists) {
        const short = await this.poolShort(pool, hollar, amount, blockNumber);
        if (short) return { waiting: short, requestedAt: Number(requestedAt), amount };
      }
    }
    // YIELD_CLAIMED: requestPrincipalWithdrawal needs nothing from Decentral
    return { waiting: null, requestedAt: null, amount: 0n };
  }

  /// Decentral pays from its own HOLLAR; an approved payout it can't fund is Decentral's
  /// wait, not the keeper's, and rolls into the digest like an unapproved one.
  private async poolShort(pool: Address, hollar: Address, amount: bigint, blockNumber: bigint): Promise<string | null> {
    const balance = (await this.client.readContract({ address: hollar, abi: MARKET_ABI, functionName: 'balanceOf', args: [pool], blockNumber })) as bigint;
    return balance < amount ? `pool liquidity ${fmt(balance)} < ${fmt(amount)} HOLLAR` : null;
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

  private async post(level: Level | 'ok' | 'info', title: string, description: string): Promise<void> {
    console.log(`${title}\n${description}`);
    if (!CONFIG.ALERT_WEBHOOK) return;
    const color = { error: 0xe74c3c, warn: 0xf1c40f, ok: 0x2ecc71, info: 0x3498db }[level];
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

const DAY = 86400;
const isoDay = (ts: number) => new Date(ts * 1000).toISOString().slice(0, 10);

/** Principal maturing per UTC day: matured-but-unredeemed ("pending") and still-open ("upcoming"). */
function maturityBuckets(
  now: number,
  matured: { principal: bigint; maturity: number }[],
  upcoming: { principal: bigint; maturity: number }[],
) {
  const all = [...matured.map((p) => ({ ...p, pending: true })), ...upcoming.map((p) => ({ ...p, pending: false }))];
  const today = Math.floor(now / DAY) * DAY;
  const first = Math.min(today, ...all.map((p) => Math.floor(p.maturity / DAY) * DAY));
  const last = Math.max(today, ...all.map((p) => Math.floor(p.maturity / DAY) * DAY));
  const days = new Map<number, { day: string; pendingHollar: number; pendingCount: number; upcomingHollar: number; upcomingCount: number }>();
  for (let d = first; d <= last; d += DAY) days.set(d, { day: isoDay(d), pendingHollar: 0, pendingCount: 0, upcomingHollar: 0, upcomingCount: 0 });
  for (const p of all) {
    const b = days.get(Math.floor(p.maturity / DAY) * DAY)!;
    const v = Number(formatEther(p.principal));
    if (p.pending) {
      b.pendingHollar += v;
      b.pendingCount++;
    } else {
      b.upcomingHollar += v;
      b.upcomingCount++;
    }
  }
  return { now: new Date(now * 1000).toISOString(), today: isoDay(today), days: [...days.values()] };
}

const fmt = (v: bigint) => Number(formatEther(v)).toLocaleString('en-US', { maximumFractionDigits: 2 });

const dur = (sec: number) => (sec < 3600 ? `${Math.floor(sec / 60)}m` : sec < 172800 ? `${Math.floor(sec / 3600)}h` : `${Math.floor(sec / 86400)}d`);
