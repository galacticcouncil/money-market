import {
  createPublicClient,
  http, fallback, encodeFunctionData, decodeAbiParameters, parseAbi, toHex, keccak256,
  type Hex,
  type PublicClient,
  type Address,
  type Chain,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { CONFIG, ROUNDING_POLICIES } from './config.js';
import { EXECUTION_ABI, executionQuotes, worthwhileHarvest, operatorTurn, efficientCandidate, type Fill } from './execution-policy.js';
import { roundingAlert } from './rounding-policy.js';
import { deficitLevel, deficitStopped, vaultDeficitBps } from './deficit-policy.js';
import { LatestLog, newestInChunks, type EvidenceLog } from './log-evidence.js';
import { SYNC_EVIDENCE, feedUpdate, syncDue, type FeedSeen } from './sync-policy.js';
import { connectSubstrate, type Substrate } from './substrate.js';
import {
  ENTRY, EXIT, FILLED, RETURNED, WAITING, intentRoute, palletIntentId, quoteRate, submittedIntent,
} from './intent-policy.js';

const hydration: Chain = {
  id: 222222,
  name: 'Hydration',
  nativeCurrency: { name: 'WETH', symbol: 'WETH', decimals: 18 },
  rpcUrls: {
    default: { http: [CONFIG.RPC_URL] },
  },
};

const SUBLOOP_ABI = [
  view('effectiveHealthFactor', 'uint256'), // aave's HF without the dip of an entry in flight
  view('targetHf', 'uint256'),
  view('deleverDebtTarget', 'uint256'),
  view('unwindTargetEquity', 'uint256'),
  view('paused', 'bool'),
  view('emergencyPaused', 'bool'),
  view('negativeCarryBps', 'uint256'),
  { name: 'pendingUnwindOf', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'vault', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'equityOf', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'vault', type: 'address' }], outputs: [{ type: 'uint256' }] },
  nonpayable('pokeBorrow'), // permissionless ramp (lever one tranche)
  nonpayable('pokeRepay'), // permissionless unwind servicing
  nonpayable('deLever'), // permissionless safety de-lever
] as const;

const VAULT_ABI = [
  view('roundingReserve', 'uint256'),
  view('asset', 'address'),
  view('mainDebt', 'address'),
  view('queueHead', 'uint256'),
  view('queueTail', 'uint256'),
  view('queueUnwind', 'uint256'),
  view('paused', 'bool'),
  view('deficitStop', 'bool'),
  view('yieldAccounting', 'address'),
  view('deleverTarget', 'uint256'),
  view('reinvestAssets', 'uint256'),
  {
    name: 'unwindEligibleAt', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'requestId', type: 'uint256' }], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'startUnwinds', type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'maxRequests', type: 'uint256' }], outputs: [],
  },
  nonpayable('pokeSettle'), // settle the redeem queue
  {
    name: 'redemptions', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'requestId', type: 'uint256' }],
    outputs: ['address', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'bool']
      .map((type, i) => ({ name: `f${i}`, type })),
  },
  {
    name: 'claim', type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'requestId', type: 'uint256' }, { name: 'receiver', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  nonpayable('rebalance'), // keep the LTV band
  nonpayable('maintainPeg'), // top up the synthetic floor
] as const;

const LEDGER_ABI = parseAbi([
  'function activePosition() view returns (uint256 debt, uint256 principal, uint256 cash)',
  'function activeFunds() view returns (uint256)',
  'function pendingSourceAccounting() view returns (bool)',
  'function surplusOf(uint256 id) view returns (uint256)',
  'function claimSurplus(uint256 id) returns (uint256)',
]);

const ACCOUNTING_ABI = parseAbi([
  'function sourceValue() view returns (uint256)',
  'function requiredSourceBacking() view returns (uint256)',
]);

// keepers hold DEPOSIT_GUARDIAN_ROLE for it; deposits revert while it is set
const DEFICIT_STOP_ABI = parseAbi(['function setDeficitStop(bool stopped)']);

// declared void: the harvestable shares sync() returns say nothing about whether allocation ran
const SYNC_ABI = parseAbi(['function sync()']);

const ICE_ABI = parseAbi([
  'function intentTtl() view returns (uint32)',
  'function pendingIntent() view returns (uint64 nonce, uint64 deadline, uint8 kind, bool controlled, uint128 amountIn, uint128 minOut, uint128 fairOut, uint128 inBase, uint128 outBase)',
  'function reconcile() returns (uint8)',
  'function removeIntent(uint128 intentId)',
  'function hasRole(bytes32 role, address account) view returns (bool)',
  'function pokeBorrowQuoted(uint256 keeperQuote) returns (uint256)',
  'function pokeRepayQuoted(uint256 keeperQuote) returns (uint256)',
  'function hollar() view returns (address)',
  'function reservedFreed() view returns (uint256)',
  'function hollarAssetId() view returns (uint32)',
  'function primeAssetId() view returns (uint32)',
  'function aPrimeAssetId() view returns (uint32)',
  'function primePoolId() view returns (uint32)',
]);
// declared void: an exit poke that only submits its intent reports zero work, which the dry run disproved
const ICE_SEND_ABI = parseAbi([
  'function pokeBorrowQuoted(uint256 keeperQuote)', 'function pokeRepayQuoted(uint256 keeperQuote)',
  'function pokeBorrow()', 'function pokeRepay()',
]);
const KEEPER_ROLE = keccak256(toHex('KEEPER_ROLE'));
const ORACLE_ABI = parseAbi([
  'function getSourceOfAsset(address asset) view returns (address)',
  'function latestRoundData() view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)',
]);

const HARVESTER_ABI = [
  view('harvestable', 'bool'),
  view('lastHarvestAt', 'uint256'),
  {
    name: 'harvest',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'minOuts', type: 'uint256[]' }],
    outputs: [{type: 'uint256'}],
  },
] as const;

const POOL_ABI = [
  {
    name: 'getUserAccountData',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [
      { name: 'totalCollateralBase', type: 'uint256' },
      { name: 'totalDebtBase', type: 'uint256' },
      { name: 'availableBorrowsBase', type: 'uint256' },
      { name: 'currentLiquidationThreshold', type: 'uint256' },
      { name: 'ltv', type: 'uint256' },
      { name: 'healthFactor', type: 'uint256' },
    ],
  },
] as const;

function view(name: string, out: string) {
  return { name, type: 'function', stateMutability: 'view', inputs: [], outputs: [{ name: '', type: out }] } as const;
}
function nonpayable(name: string) {
  return { name, type: 'function', stateMutability: 'nonpayable', inputs: [], outputs: name === 'deLever' ? [] : [{type: 'uint256'}] } as const;
}

const WAD = 10n ** 18n;
const MAX_NATIVE_TX_GAS = 1n << 24n; // EIP-7825; block gas can be higher.

// safety, peg and settlement work run on every operator; optional quoted work rotates by operator slot
export class JuicerLooper {
  private publicClient: PublicClient;
  private account: ReturnType<typeof privateKeyToAccount>;
  private subLoop: Address;
  private vaults: Address[];
  private harvester: Address;
  private pool: Address;
  private cycle = 0;
  private receiptPending = false;
  private receiptSince = 0;
  private pendingHash?: Hex;
  private pendingRaw?: Hex;
  private pendingNonce = 0;
  private broadcastAt = 0;
  private nextNonce = 0;
  private stopping = false;
  private quoteBlocks?: bigint;
  private notes?: Map<string, string>;
  private substrate?: Promise<Substrate>;
  private inFlight?: { nonce: bigint; since: bigint; expired?: bigint };
  private loopId?: Hex;
  private evidence?: Map<string, LatestLog>;
  private feeds?: Map<string, FeedSeen>;
  private synced?: Map<Address, bigint>;

  // drains a submitted transaction but never starts another write
  stop(): void { this.stopping = true; }

  constructor() {
    if (!CONFIG.EXECUTION_CONTROLLER) throw new Error('EXECUTION_CONTROLLER is required for swap execution');
    this.account = privateKeyToAccount(CONFIG.PRIVATE_KEY);
    this.subLoop = CONFIG.SUBLOOP_ADDRESS;
    this.vaults = CONFIG.VAULT_ADDRESSES;
    this.harvester = CONFIG.HARVESTER_ADDRESS;
    this.pool = CONFIG.POOL_ADDRESS;

    this.publicClient = createPublicClient({ chain: hydration, transport: fallback(CONFIG.RPC_URLS.map(url => http(url, {timeout: 15000}))) });
  }

  async runCycle(): Promise<void> {
    if (this.stopping) return;
    this.cycle++;
    console.log(`\n[${new Date().toISOString()}] maintainer cycle #${this.cycle}`);

    const [hf, target, unwind, safetyDebt, paused, emergency, ttl, intent] = (await Promise.all([
      this.read(SUBLOOP_ABI, this.subLoop, 'effectiveHealthFactor'),
      this.read(SUBLOOP_ABI, this.subLoop, 'targetHf'),
      this.read(SUBLOOP_ABI, this.subLoop, 'unwindTargetEquity'),
      this.read(SUBLOOP_ABI, this.subLoop, 'deleverDebtTarget'),
      this.read(SUBLOOP_ABI, this.subLoop, 'paused'),
      this.read(SUBLOOP_ABI, this.subLoop, 'emergencyPaused'),
      this.read(ICE_ABI, this.subLoop, 'intentTtl'),
      this.read(ICE_ABI, this.subLoop, 'pendingIntent'),
    ])) as [bigint, bigint, bigint, bigint, boolean, boolean, number, readonly unknown[]];

    // Safety actions precede optional trading, even on a standby operator.
    if (!paused && hf < target) await this.poke(SUBLOOP_ABI, this.subLoop, 'deLever', 'deLever (HF below floor)');
    const safetyAttempted = !paused && (safetyDebt > 0n || hf < target);
    if (safetyAttempted) await this.poke(SUBLOOP_ABI, this.subLoop, 'pokeRepay', 'pokeRepay (safety debt)');
    for (const vault of this.vaults) await this.poke(VAULT_ABI, vault, 'maintainPeg', `maintainPeg ${short(vault)}`);
    const time = await this.blockTimestamp();
    const turn = operatorTurn(time, CONFIG.OPERATOR_SLOT_SECONDS, CONFIG.OPERATOR_COUNT, CONFIG.OPERATOR_INDEX);
    const leverage = await this.readLeverage();
    console.log(
      `  HF ${fmtHf(hf)} → target ${fmtHf(target)}` +
        (leverage !== null ? `   leverage ${leverage.toFixed(2)}×` : ''),
    );

    // Main rebalances create repayment work even when no user has redeemed.
    const pending: Address[] = [];
    const deployment = new Set<Address>();
    const frozen = new Set<Address>();
    const unsettled = new Set<Address>();
    let funded = true;
    let waiting = false;
    let started = false;
    let now: bigint | undefined;
    for (const vault of this.vaults) {
      const policy = ROUNDING_POLICIES.get(vault.toLowerCase());
      if (policy) {
        // Monitoring failure must not prevent Main debt or synthetic maintenance.
        try {
          const reserve = await this.read(VAULT_ABI, vault, 'roundingReserve') as bigint;
          const asset = await this.read(VAULT_ABI, vault, 'asset') as Address;
          const raw = await this.read([{
            name: 'balanceOf', type: 'function', stateMutability: 'view',
            inputs: [{ name: 'account', type: 'address' }], outputs: [{ type: 'uint256' }],
          }], asset, 'balanceOf', [vault]) as bigint;
          const alert = roundingAlert(reserve, raw, policy.minimum);
          if (alert) console.error(`[ALERT] ${vault}: ${alert}; refill target=${policy.target}`);
        } catch (error) {
          console.error(`[ALERT] ${vault}: rounding monitor failed: ${shortErr(error)}`);
        }
      }
      try {
        const [head, tail, next, delever, vaultPaused, sourcePending, undeployed] = (await Promise.all([
          this.read(VAULT_ABI, vault, 'queueHead'),
          this.read(VAULT_ABI, vault, 'queueTail'),
          this.read(VAULT_ABI, vault, 'queueUnwind'),
          this.read(VAULT_ABI, vault, 'deleverTarget'),
          this.read(VAULT_ABI, vault, 'paused'),
          this.read(SUBLOOP_ABI, this.subLoop, 'pendingUnwindOf', [vault]),
          this.read(VAULT_ABI, vault, 'reinvestAssets'),
        ])) as [bigint, bigint, bigint, bigint, boolean, bigint, bigint];
        // unallocated source proceeds or costs only advance through pokeSettle
        const ledger = await this.read(VAULT_ABI, vault, 'mainDebt') as Address;
        const unallocated = await this.read(LEDGER_ABI, ledger, 'pendingSourceAccounting') as boolean;
        if (unallocated) unsettled.add(vault);
        if (undeployed > 0n) deployment.add(vault);
        if (vaultPaused || emergency) frozen.add(vault);
        waiting ||= tail > next;
        let starting = false;
        if (tail > next && !paused && !frozen.has(vault)) {
          now ??= await this.blockTimestamp();
          const eligibleAt = await this.read(VAULT_ABI, vault, 'unwindEligibleAt', [next]) as bigint;
          if (now >= eligibleAt) {
            // 16 starts measured at >13M gas natively; 8 keeps headroom
            starting = await this.poke(VAULT_ABI, vault, 'startUnwinds', `startUnwinds ${short(vault)}`, [8n]);
            started ||= starting;
          }
        }
        if (delever > 0n || (!frozen.has(vault) && (next > head || starting || sourcePending > 0n || unallocated))) {
          pending.push(vault);
        }
      } catch (error) {
        funded = false;
        waiting = true;
        frozen.add(vault);
        console.error(`[ALERT] ${vault}: queue monitor failed; optional risk disabled: ${shortErr(error)}`);
      }
    }
    // any operator sets a vault's deficit stop; clearing it waits for the duty slot and an unfrozen vault
    const deficit = await this.checkDeficits(frozen, turn);
    // one intent in flight per loop, entries and exits alike: nothing new goes out while it is
    const busy = await this.watchIntent(intent, emergency, turn);
    const servicing = unwind > 0n || safetyDebt > 0n || pending.length > 0 || waiting;
    let harvested = false;
    if (turn && this.harvester && !paused && !emergency && frozen.size === 0) {
      try {
        if (await this.read(HARVESTER_ABI, this.harvester, 'harvestable')) {
          harvested = await this.poke(HARVESTER_ABI, this.harvester, 'harvest', 'harvest (skim+distribute)', [[]]);
        }
      } catch (error) {
        console.error(`[ALERT] harvest preview failed: ${shortErr(error)}`);
      }
    }
    // deposits and earned collateral deploy before more source leverage; rotate so vaults share the entry budget
    let rebalanced = false;
    for (let i = 0; i < this.vaults.length; ++i) {
      const vault = this.vaults[(i + this.cycle - 1) % this.vaults.length];
      // only source safety debt holds back deploying credit, not exits in flight
      const credit = (deployment.has(vault) || harvested) && safetyDebt === 0n;
      if ((credit || (this.cycle % CONFIG.SLOW_EVERY === 0 && !servicing))
          && turn && !paused && !emergency && !frozen.has(vault)) {
        const changed = await this.poke(VAULT_ABI, vault, 'rebalance', `deploy/rebalance ${short(vault)}`);
        rebalanced ||= changed;
      }
    }
    if (!paused) {
      // after a rebalance or harvest, re-read safety and deficit state next cycle before adding leverage
      const ramp = !rebalanced && !harvested && !deficit && turn && hf >= target && funded && !emergency
        && frozen.size === 0 && !servicing;
      const headroom = hf > (target * BigInt(Math.floor((1 + CONFIG.RAMP_HF_BUFFER) * 1e6))) / 1_000_000n;
      if (ttl === 0) {
        if (ramp && headroom) await this.poke(SUBLOOP_ABI, this.subLoop, 'pokeBorrow', 'pokeBorrow (ramp)');
      } else if (ramp && !busy && (headroom || await this.idleHollar() > 0n)) {
        // deposits wait in the loop as cash until an entry carries them
        await this.submitIntent(ENTRY);
      }
      if (!safetyAttempted && !emergency && (unwind > 0n || pending.length > 0 || started)) {
        if (ttl === 0) await this.poke(SUBLOOP_ABI, this.subLoop, 'pokeRepay', 'pokeRepay (unwind/safety debt)');
        else if (turn && !busy) await this.submitIntent(EXIT);
      }
    }
    // Applying already freed funds is safe even while source swaps are paused.
    for (const vault of pending) {
      await this.poke(VAULT_ABI, vault, 'pokeSettle', `pokeSettle ${short(vault)}`);
    }
    // users only send withdraw: settled collateral and exit surplus are pushed to their owners
    for (const vault of this.vaults) await this.deliver(vault);
    // frozen vaults can't sync and unallocated ones wouldn't allocate
    if (turn) await this.syncVaults(new Set([...frozen, ...unsettled]), time);
  }

  // allocation follows prices: sync after a PRIME or collateral oracle update, and every SYNC_EVERY seconds
  private async syncVaults(skip: ReadonlySet<Address>, now: bigint): Promise<void> {
    const synced = (this.synced ??= new Map<Address, bigint>());
    const every = BigInt(CONFIG.SYNC_EVERY);
    let prime: Address | undefined, updates = new Map<string, bigint>();
    const assets = new Map<Address, Address>();
    try {
      prime = await this.read([view('prime', 'address')], this.subLoop, 'prime') as Address;
      for (const vault of this.vaults) assets.set(vault, await this.read(VAULT_ABI, vault, 'asset') as Address);
      updates = await this.priceUpdates([prime, ...assets.values()], now);
    } catch (error) {
      console.log(`  oracle updates unreadable, syncing on SYNC_EVERY only: ${shortErr(error)}`);
    }
    for (const vault of this.vaults) {
      if (skip.has(vault)) continue;
      const times = [prime, assets.get(vault)].map(a => a && updates.get(a.toLowerCase()))
        .filter((t): t is bigint => t !== undefined);
      const updated = times.length ? times.reduce((a, b) => (b > a ? b : a)) : undefined;
      let last = synced.get(vault) ?? 0n;
      if (!syncDue(last, updated, now, every)) continue;
      // another operator, or any allocating checkpoint, may already have synced
      const seen = await this.lastSyncAt(vault).catch(error => {
        console.log(`  sync evidence of ${short(vault)} unreadable: ${shortErr(error)}`);
        return 0n;
      });
      if (seen > last) synced.set(vault, last = seen);
      if (!syncDue(last, updated, now, every)) continue;
      // mined after the head read at `now`, and block timestamps strictly increase
      if (await this.poke(SYNC_ABI, vault, 'sync', `sync ${short(vault)}`)) synced.set(vault, now + 1n);
    }
  }

  // newest update time per asset, from its Aave oracle source's answer and updatedAt
  private async priceUpdates(assets: Address[], now: bigint): Promise<Map<string, bigint>> {
    const provider = await this.read([view('ADDRESSES_PROVIDER', 'address')], this.pool, 'ADDRESSES_PROVIDER') as Address;
    const oracle = await this.read([view('getPriceOracle', 'address')], provider, 'getPriceOracle') as Address;
    const seen = (this.feeds ??= new Map<string, FeedSeen>());
    const updates = new Map<string, bigint>();
    for (const asset of new Set(assets.map(a => a.toLowerCase() as Address))) {
      try {
        const source = (await this.read(ORACLE_ABI, oracle, 'getSourceOfAsset', [asset]) as Address).toLowerCase();
        if (/^0x0{40}$/.test(source)) continue;
        const round = await this.read(ORACLE_ABI, source as Address, 'latestRoundData') as readonly bigint[];
        const feed = feedUpdate(seen.get(source), round[1], round[3], now);
        seen.set(source, feed);
        updates.set(asset, feed.at);
      } catch (error) {
        console.log(`  oracle source of ${short(asset)} unreadable: ${shortErr(error)}`);
      }
    }
    return updates;
  }

  private async lastSyncAt(vault: Address): Promise<bigint> {
    const accounting = await this.read(VAULT_ABI, vault, 'yieldAccounting') as Address;
    const trackers = (this.evidence ??= new Map<string, LatestLog>());
    const key = `sync:${vault.toLowerCase()}`;
    let tracker = trackers.get(key);
    // at least a second per block, so SYNC_EVERY blocks cover SYNC_EVERY seconds
    if (!tracker) trackers.set(key, tracker = new LatestLog(BigInt(CONFIG.SYNC_EVERY)));
    const log = await tracker.find((from, to) => this.newestLog(accounting, SYNC_EVIDENCE, from, to),
      await this.publicClient.getBlockNumber());
    return log ? (await this.publicClient.getBlock({blockNumber: log.block})).timestamp : 0n;
  }

  // settles a fill or refund that landed without its callback, reports a quiet solver or a slow
  // expiry, and calls the intent home under an emergency pause. true while one is still in flight
  private async watchIntent(intent: readonly unknown[], emergency: boolean, turn: boolean): Promise<boolean> {
    const [nonce, deadline, kind, , amountIn] = intent as [bigint, bigint, number, boolean, bigint];
    if (!kind) {
      this.inFlight = undefined;
      for (const key of ['ice:stall', 'ice:expiry', 'ice:watch', 'ice:remove']) this.note(key);
      return false;
    }
    const name = `${kind === ENTRY ? 'entry' : 'exit'} intent #${nonce}`;
    try {
      const outcome = Number(await this.read(ICE_ABI, this.subLoop, 'reconcile'));
      if (outcome === FILLED || outcome === RETURNED) {
        if (!turn && !emergency) return true;
        return !await this.poke(ICE_ABI, this.subLoop, 'reconcile', `reconcile ${name}`, [], true);
      }
      if (outcome !== WAITING) return false;
      const head = await this.publicClient.getBlock({blockTag: 'latest'});
      if (this.inFlight?.nonce !== nonce) this.inFlight = {nonce, since: head.number};
      const track = this.inFlight;
      if (head.number - track.since >= BigInt(CONFIG.ICE_STALL_BLOCKS)) {
        this.note('ice:stall', `[ALERT] ${name} unfilled for ${CONFIG.ICE_STALL_BLOCKS} blocks: solver quiet or its limit out of reach`);
      }
      if (head.timestamp * 1000n > deadline) {
        track.expired ??= head.number;
        if (head.number - track.expired >= BigInt(CONFIG.ICE_CLEANUP_BLOCKS)) await this.cleanupExpired(name, amountIn, turn);
      }
      if (emergency) await this.removeInFlight(name, amountIn);
      this.note('ice:watch');
    } catch (error) {
      this.note('ice:watch', `[ALERT] ${name}: intent watch failed: ${shortErr(error)}`);
    }
    return true;
  }

  // expiry refunds come from the pallet's offchain worker; an optional dev signer stands in when it lags
  private async cleanupExpired(name: string, amountIn: bigint, turn: boolean): Promise<void> {
    const sub = await this.chain();
    if (!sub.cleanup) {
      return this.note('ice:expiry',
        `[ALERT] ${name} expired ${CONFIG.ICE_CLEANUP_BLOCKS} blocks ago and its input is still away; no cleanup signer`);
    }
    if (!turn) return;
    const id = palletIntentId(await sub.intents(await this.loopAccount(sub)), amountIn);
    if (id === undefined) return this.note('ice:expiry', `[ALERT] ${name} expired but its pallet intent id is ambiguous`);
    console.log(`  cleanup_intent ${id} for ${name} → ${await sub.cleanup(id)}`);
  }

  // under an emergency pause anyone may call the intent home by its pallet id; it settles as a refund
  private async removeInFlight(name: string, amountIn: bigint): Promise<void> {
    const sub = await this.chain();
    const id = palletIntentId(await sub.intents(await this.loopAccount(sub)), amountIn);
    if (id === undefined) return this.note('ice:remove', `[ALERT] ${name}: no pallet intent id to remove under the emergency pause`);
    if (await this.poke(ICE_ABI, this.subLoop, 'removeIntent', `removeIntent ${name}`, [id], true)) this.note('ice:remove');
  }

  // a dry run of the loop's own call gives the intent's real size, and a router dry run of that size the quote
  private async submitIntent(kind: number): Promise<boolean> {
    const name = kind === ENTRY ? 'entry' : 'exit';
    try {
      const quoted = await this.read(ICE_ABI, this.subLoop, 'hasRole', [KEEPER_ROLE, this.account.address]) as boolean;
      this.note('ice:role', quoted ? undefined : '[ALERT] keeper lacks KEEPER_ROLE: intents carry only the oracle floor');
      const fn = kind === ENTRY ? (quoted ? 'pokeBorrowQuoted' : 'pokeBorrow') : (quoted ? 'pokeRepayQuoted' : 'pokeRepay');
      const args = quoted ? [0n] : [];
      const label = `${fn} (${name} intent)`;
      const sub = await this.chain();
      const [block, price] = await Promise.all([this.publicClient.getBlock({blockTag: 'latest'}), this.publicClient.getGasPrice()]);
      const gas = [block.gasLimit, MAX_NATIVE_TX_GAS, CONFIG.MAX_TX_GAS].reduce((a, b) => (a < b ? a : b));
      const logs = await sub.dryRunEvm(this.account.address, this.subLoop,
        encodeFunctionData({abi: ICE_SEND_ABI, functionName: fn, args} as any), gas, price * 2n);
      this.note('ice:probe');
      if (!logs) {
        console.log(`  ${label}: dry run fails, skipped`);
        return false;
      }
      const submitted = submittedIntent(logs, this.subLoop);
      // no intent to send, but an exit poke may still repay and free what a fill brought back
      if (!submitted) return kind === EXIT && await this.poke(quoted ? ICE_ABI : SUBLOOP_ABI, this.subLoop, fn, label, args, true);
      let rate = 0n;
      if (quoted) {
        try {
          rate = await this.routerQuote(sub, submitted.kind, submitted.amountIn);
          this.note('ice:quote');
        } catch (error) {
          this.note('ice:quote', `[ALERT] router dry run for the ${name} quote failed: ${shortErr(error)}`);
          // an entry can wait for a quote; an exit goes out on the oracle floor
          if (kind === ENTRY) return false;
        }
        console.log(`  ${label}: ${submitted.amountIn} in, quote ${rate} per 1e18`);
      }
      return await this.poke(ICE_SEND_ABI, this.subLoop, fn, label, quoted ? [rate] : [], true);
    } catch (error) {
      this.note('ice:probe', `[ALERT] ${name} intent probe failed, nothing submitted: ${shortErr(error)}`);
      this.substrate = undefined;
      return false;
    }
  }

  private async routerQuote(sub: Substrate, kind: number, amountIn: bigint): Promise<bigint> {
    const [hollar, prime, aPrime, pool] = await Promise.all(['hollarAssetId', 'primeAssetId', 'aPrimeAssetId', 'primePoolId']
      .map(fn => this.read(ICE_ABI, this.subLoop, fn))) as number[];
    const loop = await this.loopAccount(sub);
    // an entry borrows inside its own call, so until then any HOLLAR holder can stand in for the loop
    const origin = kind === EXIT || await sub.free(hollar, loop) >= amountIn ? loop : CONFIG.ICE_QUOTE_HOLDER;
    return quoteRate(amountIn, await sub.dryRunSell(origin, intentRoute(kind, {hollar, prime, aPrime, pool}), amountIn));
  }

  // HOLLAR deposited into the loop and owed to no exit; only an entry deploys it
  private async idleHollar(): Promise<bigint> {
    try {
      const [hollar, reserved] = await Promise.all([
        this.read(ICE_ABI, this.subLoop, 'hollar'), this.read(ICE_ABI, this.subLoop, 'reservedFreed'),
      ]) as [Address, bigint];
      const cash = await this.read(parseAbi(['function balanceOf(address) view returns (uint256)']), hollar,
        'balanceOf', [this.subLoop]) as bigint;
      return cash > reserved ? cash - reserved : 0n;
    } catch {
      return 0n;
    }
  }

  private chain(): Promise<Substrate> {
    return this.substrate ??= connectSubstrate(CONFIG.SUBSTRATE_RPC_URL, CONFIG.ICE_CLEANUP_SURI).catch(error => {
      this.substrate = undefined;
      throw error;
    });
  }

  private async loopAccount(sub: Substrate): Promise<Hex> {
    return this.loopId ??= await sub.accountOf(this.subLoop);
  }

  // the vault's deficitStop flag is the hysteresis state both operators share. true while any
  // vault is stopped or unreadable: the ramp then waits
  private async checkDeficits(frozen: ReadonlySet<Address>, turn: boolean): Promise<boolean> {
    const stop = BigInt(CONFIG.DEFICIT_STOP_BPS), resume = BigInt(CONFIG.DEFICIT_RESUME_BPS);
    let source: bigint | undefined;
    try {
      source = await this.read(SUBLOOP_ABI, this.subLoop, 'negativeCarryBps') as bigint;
    } catch (error) {
      console.error(`[ALERT] source deficit read failed; ramp held: ${shortErr(error)}`);
    }
    let blocked = source === undefined;
    for (const vault of this.vaults) {
      let stopped: boolean, vaultBps: bigint | undefined;
      try {
        const [ledger, accounting] = await Promise.all([
          this.read(VAULT_ABI, vault, 'mainDebt'), this.read(VAULT_ABI, vault, 'yieldAccounting'),
        ]) as [Address, Address];
        const [flag, position, funds, unallocated, equity, sourceValue, required] = await Promise.all([
          this.read(VAULT_ABI, vault, 'deficitStop'),
          this.read(LEDGER_ABI, ledger, 'activePosition'),
          this.read(LEDGER_ABI, ledger, 'activeFunds'),
          this.read(LEDGER_ABI, ledger, 'pendingSourceAccounting'),
          this.read(SUBLOOP_ABI, this.subLoop, 'equityOf', [vault]),
          this.read(ACCOUNTING_ABI, accounting, 'sourceValue'),
          this.read(ACCOUNTING_ABI, accounting, 'requiredSourceBacking'),
        ]) as [boolean, readonly bigint[], bigint, boolean, bigint, bigint, bigint];
        stopped = flag;
        // unallocated source cash leaves activeFunds stale until pokeSettle
        if (!unallocated) vaultBps = vaultDeficitBps(position[0], equity, sourceValue, funds, required);
      } catch (error) {
        blocked = true;
        console.error(`[ALERT] ${vault}: deficit read failed; ramp held: ${shortErr(error)}`);
        continue;
      }
      const level = deficitLevel([source, vaultBps], stop);
      const want = level === undefined ? stopped : deficitStopped(level, stopped, stop, resume);
      blocked ||= level === undefined || want;
      const view = `source ${source ?? '?'} bps, vault ${vaultBps ?? '?'} bps`;
      console.log(`  deficit ${short(vault)}: ${view}${want ? ', stopped' : ''}`);
      if (want === stopped || (!want && (!turn || frozen.has(vault)))) continue;
      const done = await this.poke(DEFICIT_STOP_ABI, vault, 'setDeficitStop', `setDeficitStop(${want}) ${short(vault)}`, [want])
        || await this.read(VAULT_ABI, vault, 'deficitStop').catch(() => stopped) === want;
      if (!done) {
        this.note(`deficit:${vault}`, `[ALERT] deficit ${want ? 'stop' : 'resume'} ${vault}: setDeficitStop(${want}) not confirmed; retrying every cycle`);
        continue;
      }
      this.note(`deficit:${vault}`);
      console.error(want ? `[ALERT] deficit stop ${vault}: ${view}, above ${stop}; ramp stopped, deficitStop set`
        : `[ALERT] deficit resume ${vault}: ${view}, below ${resume}; ramp allowed, deficitStop cleared`);
    }
    return blocked;
  }

  // a lasting condition alerts when it changes, not on every cycle it persists
  private note(key: string, alert?: string): void {
    const notes = (this.notes ??= new Map<string, string>());
    if (!alert) return void notes.delete(key);
    if (notes.get(key) !== alert) console.error(alert);
    notes.set(key, alert);
  }

  private newestLog(address: Address | Address[], topics: Hex[], from: bigint, to: bigint) {
    return newestInChunks(async (lo, hi) => {
      const logs = await this.publicClient.request({method: 'eth_getLogs', params: [{
        address, topics: [topics], fromBlock: toHex(lo), toBlock: toHex(hi),
      }]}) as any[];
      return logs.filter(l => !l.removed).map((l): EvidenceLog => ({block: BigInt(l.blockNumber),
        index: Number(l.logIndex), topics: l.topics, data: l.data, tx: l.transactionHash}));
    }, from, to);
  }

  private claimCursor?: Map<Address, bigint>;

  private async deliver(vault: Address): Promise<void> {
    try {
      const [head, ledger] = await Promise.all([
        this.read(VAULT_ABI, vault, 'queueHead'), this.read(VAULT_ABI, vault, 'mainDebt'),
      ]) as [bigint, Address];
      const cursors = (this.claimCursor ??= new Map());
      let id = cursors.get(vault) ?? (head > CONFIG.CLAIM_LOOKBACK ? head - CONFIG.CLAIM_LOOKBACK : 0n);
      let next: bigint | undefined;
      // ids below the head are fully settled, so one claim pays out the whole request
      for (let n = 0; id < head && n < 16; ++n, ++id) {
        const r = await this.read(VAULT_ABI, vault, 'redemptions', [id]) as readonly unknown[];
        const owner = r[0] as Address, settled = r[6] as bigint, active = r[8] as boolean;
        if (active && settled > 0n) await this.poke(VAULT_ABI, vault, 'claim', `claim ${short(vault)} #${id}`, [id, owner]);
        const surplus = await this.read(LEDGER_ABI, ledger, 'surplusOf', [id]) as bigint;
        const owed = surplus >= CONFIG.CLAIM_MIN_SURPLUS
          && !(await this.poke(LEDGER_ABI, ledger, 'claimSurplus', `claimSurplus ${short(vault)} #${id}`, [id]));
        // stop at the first request still owed something, so a failed delivery is retried
        const still = (await this.read(VAULT_ABI, vault, 'redemptions', [id]) as readonly unknown[])[8] as boolean;
        if (next === undefined && (still || owed)) next = id;
      }
      cursors.set(vault, next ?? id);
    } catch (error) {
      console.error(`[ALERT] ${vault}: delivery scan failed: ${shortErr(error)}`);
    }
  }

  async monitorSafety(): Promise<void> {
    // Separate read loop: slow simulation/receipts never stop risk monitoring.
    const block = await this.publicClient.getBlock({blockTag: 'latest'});
    if (this.pendingHash) await this.recoverPending();
    if (this.receiptPending && Date.now() - this.receiptSince > 120000) {
      console.error('[ALERT] transaction receipt pending for over two minutes; redundant operator must continue maintenance');
    }
    if (BigInt(Math.floor(Date.now() / 1000)) - block.timestamp > BigInt(CONFIG.RPC_STALE_SECONDS)) {
      console.error('[ALERT] RPC head is stale; inspect independent operator/RPC health');
    }
    const [hf, target] = await Promise.all([
      this.read(SUBLOOP_ABI, this.subLoop, 'effectiveHealthFactor'), this.read(SUBLOOP_ABI, this.subLoop, 'targetHf'),
    ]) as [bigint, bigint];
    if (hf < target) console.error(`[ALERT] source HF ${fmtHf(hf)} below target ${fmtHf(target)}`);
    for (const vault of this.vaults) {
      try {
        const [supplied, lt, debtToken, ledger] = await Promise.all([
          this.read([view('syntheticSupplied', 'uint256')], vault, 'syntheticSupplied'),
          this.read([view('synthLtBps', 'uint256')], vault, 'synthLtBps'),
          this.read([view('hollarDebtToken', 'address')], vault, 'hollarDebtToken'),
          this.read(VAULT_ABI, vault, 'mainDebt'),
        ]) as [bigint, bigint, Address, Address];
        const debt = await this.read(parseAbi(['function balanceOf(address) view returns (uint256)']), debtToken, 'balanceOf', [vault]) as bigint;
        if (supplied * lt < debt * 10025n) console.error(`[ALERT] ${vault}: synthetic buffer needs replenishing`);
        const interest = await this.read(parseAbi(['function interestOf(uint256) view returns (uint256)']), ledger, 'interestOf', [0n]) as bigint;
        if (interest / 10n ** 10n >= CONFIG.MAIN_INTEREST_URGENT_USD8) console.error(`[ALERT] ${vault}: Main interest needs urgent harvest/service`);
      } catch (error) { console.error(`[ALERT] ${vault}: safety monitor failed: ${shortErr(error)}`); }
    }
  }

  private async harvestWorthwhile(primeAmount: bigint, gasWei: bigint, now: bigint): Promise<boolean> {
    const prime = await this.read([view('prime', 'address')], this.subLoop, 'prime') as Address;
    const provider = await this.read([view('ADDRESSES_PROVIDER', 'address')], this.pool, 'ADDRESSES_PROVIDER') as Address;
    const oracle = await this.read([view('getPriceOracle', 'address')], provider, 'getPriceOracle') as Address;
    const priceAbi = parseAbi(['function getAssetPrice(address) view returns (uint256)']);
    const [primePrice, ethPrice, decimals, last] = await Promise.all([
      this.read(priceAbi, oracle, 'getAssetPrice', [prime]),
      CONFIG.SPONSORED_GAS ? Promise.resolve(0n) : this.read(priceAbi, oracle, 'getAssetPrice', [CONFIG.GAS_ASSET_ADDRESS]),
      this.read([view('decimals', 'uint8')], prime, 'decimals'),
      this.read(HARVESTER_ABI, this.harvester, 'lastHarvestAt'),
    ]) as [bigint, bigint, number, bigint];
    if (!primePrice || (!CONFIG.SPONSORED_GAS && !ethPrice)) throw new Error('missing economic price');
    let interest = 0n;
    for (const vault of this.vaults) {
      const ledger = await this.read(VAULT_ABI, vault, 'mainDebt') as Address;
      interest += await this.read(parseAbi(['function interestOf(uint256) view returns (uint256)']), ledger, 'interestOf', [0n]) as bigint;
    }
    const urgent = interest / 10n ** 10n >= CONFIG.MAIN_INTEREST_URGENT_USD8;
    const value = primeAmount * primePrice / 10n ** BigInt(decimals);
    const cost = gasWei * ethPrice / WAD;
    const execute = worthwhileHarvest(value, cost, CONFIG.HARVEST_MIN_USD8, CONFIG.HARVEST_MAX_GAS_BPS,
      urgent, now - last, CONFIG.HARVEST_MAX_DELAY_SECONDS);
    console.log(`  harvest economics: valueUSD8=${value} gasUSD8=${cost} urgent=${urgent} execute=${execute}`);
    return execute;
  }

  private async blockTimestamp(): Promise<bigint> {
    return (await this.publicClient.getBlock({ blockTag: 'latest' })).timestamp;
  }

  private async quoteAction(target: Address, data: Hex, operation: string, blockNumber: bigint, gas: bigint) {
    const options = {account: this.account, address: CONFIG.EXECUTION_CONTROLLER,
      abi: EXECUTION_ABI, blockNumber, gas} as const;
    const boundTargets = new Set([this.subLoop, target, ...(operation === 'harvest' ? this.vaults : [])]);
    for (const address of boundTargets) {
      const bound = await this.publicClient.readContract({address,
        abi: [view('executionController', 'address')], functionName: 'executionController', blockNumber}) as Address;
      if (bound.toLowerCase() !== CONFIG.EXECUTION_CONTROLLER.toLowerCase()) {
        throw new Error(`execution controller mismatch at ${address}`);
      }
    }
    type Candidate = {result: Hex; fills: readonly Fill[]};
    const candidates: Candidate[] = [];
    let initial: unknown;
    try {
      const [result, fills] = (await this.publicClient.simulateContract({
        ...options, functionName: 'preview', args: [target, data],
      })).result;
      if (!fills.length) return [result, fills] as const;
      candidates.push({result, fills});
    } catch (error) {
      if (!executionReverted(error)) throw error;
      initial = error;
    }
    const getter = async (address: Address, name: string) => this.publicClient.readContract({
      address, abi: [view(name, 'address')], functionName: name, blockNumber,
    }) as Promise<Address>;
    const urgent = operation === 'pokeRepay' && (await this.publicClient.readContract({
      address: this.subLoop, abi: [view('deleverDebtTarget', 'uint256')],
      functionName: 'deleverDebtTarget', blockNumber,
    }) as bigint) > 0n;
    // urgent repayment takes the first acceptable quote instead of optimizing size
    if (urgent && candidates.length) return [candidates[0].result, candidates[0].fills] as const;
    const routes: Address[][] = [];
    if (operation === 'harvest') {
      const prime = await getter(this.subLoop, 'prime');
      for (const vault of this.vaults) routes.push([vault, prime, await getter(vault, 'collateral')]);
    } else {
      const hollar = await getter(this.subLoop, 'hollar'), aPrime = await getter(this.subLoop, 'primeAToken');
      routes.push(operation === 'pokeRepay' ? [this.subLoop, aPrime, hollar] : [this.subLoop, hollar, aPrime]);
    }
    let caps = await Promise.all(routes.map(async route => {
      const args = route as [Address, Address, Address];
      const [lane, available] = await Promise.all([
        this.publicClient.readContract({...options, functionName: 'lane', args}),
        this.publicClient.readContract({...options, functionName: urgent ? 'availableSafety' : 'available', args}),
      ]);
      const [, minimum] = await this.publicClient.readContract({...options, functionName: 'limits', args: [lane]});
      const first = candidates[0]?.fills.find(f => f.lane.toLowerCase() === lane.toLowerCase());
      const amountIn = first && first.amountIn < available ? first.amountIn : available;
      return {lane, amountIn, minimum, minOut: 0n};
    }));
    caps = caps.filter(c => c.amountIn > 0n);
    const primary = new Set(caps.map(c => c.lane.toLowerCase()));
    for (let attempt = 0; attempt < CONFIG.QUOTE_SIZE_STEPS && caps.length; ++attempt) {
      // the last step always samples the lane minimum so halvings can't skip a good small quote
      const smaller = caps.map(c => ({...c, amountIn: attempt + 1 === CONFIG.QUOTE_SIZE_STEPS
        ? c.minimum : c.amountIn / 2n > c.minimum ? c.amountIn / 2n : c.minimum}));
      if (smaller.every((c, i) => c.amountIn === caps[i].amountIn)) break;
      caps = smaller;
      try {
        const [result, fills] = (await this.publicClient.simulateContract({...options,
          functionName: 'previewBounded', args: [target, data, caps],
        })).result;
        if (fills.length) candidates.push({result, fills});
        else if (!candidates.length && hasWork(result)) return [result, fills] as const;
        if (urgent && candidates.length) break;
      } catch (error) { if (!executionReverted(error)) throw error; }
    }
    if (!candidates.length) throw initial ?? new Error('no executable slice');
    const chosen = efficientCandidate(candidates, primary, CONFIG.SLICE_PRICE_TOLERANCE_BPS);
    console.log(`  compared ${candidates.length} executable sizes at block ${blockNumber}`);
    return [chosen.result, chosen.fills] as const;
  }

  private async readLeverage(): Promise<number | null> {
    try {
      const data = (await this.read(POOL_ABI, this.pool, 'getUserAccountData', [
        this.subLoop,
      ])) as readonly bigint[];
      const equity = data[0] - data[1];
      if (equity <= 0n) return null;
      return Number(data[0]) / Number(equity);
    } catch {
      return null;
    }
  }

  private async read(
    abi: readonly unknown[],
    address: Address,
    functionName: string,
    args?: readonly unknown[],
  ): Promise<unknown> {
    return this.publicClient.readContract({
      address,
      abi: abi as any,
      functionName: functionName as any,
      args: args as any,
    });
  }

  // benign reverts (nothing to do, healthy enough, paused) are logged and skipped, never fatal
  private async poke(
    abi: readonly unknown[],
    address: Address,
    functionName: string,
    label: string,
    args: readonly unknown[] = [],
    direct = false,
  ): Promise<boolean> {
    if (this.stopping || this.receiptPending) return false;
    try {
      const [block, quotedPrice] = await Promise.all([
        this.publicClient.getBlock({ blockTag: 'latest' }),
        this.publicClient.getGasPrice(),
      ]);
      const limit = block.gasLimit < MAX_NATIVE_TX_GAS ? block.gasLimit : MAX_NATIVE_TX_GAS;
      const budget = limit < CONFIG.MAX_TX_GAS ? limit : CONFIG.MAX_TX_GAS;
      const gasPrice = (quotedPrice * 120n + 99n) / 100n;
      let options: any = {
        account: this.account,
        address,
        abi: abi as any,
        functionName: functionName as any,
        args: args as any,
        gas: budget,
        gasPrice,
      };
      // intents go to the loop directly: through execute nothing deploys without an entry-lane quote
      const guarded = !direct && ['harvest', 'pokeBorrow', 'rebalance', 'pokeRepay'].includes(functionName);
      let quotedNumber = 0n;
      let fills: readonly Fill[] = [];
      const serviceLanes = new Set<string>();
      const data = encodeFunctionData({abi: abi as any, functionName, args});
      if (guarded) {
        const quoted = await this.publicClient.getBlock({blockNumber: block.number - BigInt(CONFIG.QUOTE_DEPTH_BLOCKS)});
        let result: Hex;
        [result, fills] = await this.quoteAction(address, data, functionName, quoted.number, budget) as readonly [Hex, readonly Fill[]];
        if (!hasWork(result)) return false;
        quotedNumber = quoted.number;
        if (functionName === 'harvest') {
          const get = async (target: Address, name: string) => await this.publicClient.readContract({
            address: target, abi: [view(name, 'address')], functionName: name, blockNumber: quoted.number,
          }) as Address;
          const hollar = await get(this.subLoop, 'hollar');
          for (const vault of this.vaults) {
            const lane = await this.publicClient.readContract({address: CONFIG.EXECUTION_CONTROLLER,
              abi: EXECUTION_ABI, functionName: 'lane', blockNumber: quoted.number,
              args: [await get(vault, 'mainDebt'), await get(vault, 'collateral'), hollar]});
            serviceLanes.add(lane.toLowerCase());
          }
        }
        options = {...options, address: CONFIG.EXECUTION_CONTROLLER, abi: EXECUTION_ABI, functionName: 'execute',
          args: [address, data, quoted.number, quoted.hash, quoted.timestamp + BigInt(CONFIG.QUOTE_TTL_SECONDS),
            executionQuotes(fills, CONFIG.QUOTE_DRIFT_BPS, serviceLanes)]};
      }
      const simulated = await this.publicClient.simulateContract(options);
      if (!hasWork(simulated.result)) {
        console.log(`  ${label}: no useful work`);
        return false;
      }
      // raw eth_estimateGas since viem drops the gas cap; the cap leaves room for the 20% margin
      const estimate = BigInt(await this.publicClient.request({method: 'eth_estimateGas', params: [{
        from: this.account.address, to: options.address,
        data: encodeFunctionData({abi: options.abi, functionName: options.functionName, args: options.args}),
        gas: toHex(budget * 100n / 120n), gasPrice: toHex(gasPrice),
      }, 'latest']}));
      const gas = (estimate * 120n + 99n) / 100n;
      if (gas > budget) {
        console.error(`[ALERT] ${label}: gas estimate ${estimate} plus 20% margin exceeds budget ${budget}`);
        return false;
      }
      if (functionName === 'harvest') {
        const amount = decodeAbiParameters([{type: 'uint256'}], simulated.result as Hex)[0];
        if (!await this.harvestWorthwhile(amount, gas * gasPrice, block.timestamp)) return false;
      }
      if (guarded) {
        // previews and estimates can outlast the controller's block window;
        // re-pin the chosen sizes so the quote still has room to land
        const head = await this.publicClient.getBlockNumber();
        if (head + BigInt(CONFIG.QUOTE_INCLUSION_BLOCKS) - quotedNumber > await this.maxQuoteBlocks()) {
          const fresh = await this.publicClient.getBlock({blockNumber: head - BigInt(CONFIG.QUOTE_DEPTH_BLOCKS)});
          const caps = fills.filter(f => !serviceLanes.has(f.lane.toLowerCase()))
            .map(f => ({lane: f.lane, amountIn: f.amountIn, minOut: 0n}));
          const [result, refilled] = (await this.publicClient.simulateContract({account: this.account,
            address: CONFIG.EXECUTION_CONTROLLER, abi: EXECUTION_ABI, blockNumber: fresh.number, gas: budget,
            ...(caps.length ? {functionName: 'previewBounded', args: [address, data, caps]}
              : {functionName: 'preview', args: [address, data]}),
          } as any)).result as readonly [Hex, readonly Fill[]];
          if (!hasWork(result)) return false;
          options = {...options, args: [address, data, fresh.number, fresh.hash,
            fresh.timestamp + BigInt(CONFIG.QUOTE_TTL_SECONDS), executionQuotes(refilled, CONFIG.QUOTE_DRIFT_BPS, serviceLanes)]};
        }
      }
      // some RPCs estimate reverting calls; re-simulate at the final allowance
      if (!hasWork((await this.publicClient.simulateContract({...options, gas})).result)) return false;
      // some gateways serve a stale pending nonce; keep ours monotonic
      const nonce = Math.max(this.nextNonce ?? 0, await this.publicClient.getTransactionCount({
        address: this.account.address, blockTag: 'pending',
      }));
      // a stop may land during the awaits above; recheck right before signing
      if (this.stopping) return false;
      const serialized = await this.account.signTransaction({
        chainId: hydration.id, type: 'legacy', nonce, gas, gasPrice, value: 0n, to: options.address,
        data: encodeFunctionData({abi: options.abi, functionName: options.functionName, args: options.args}),
      });
      const hash = keccak256(serialized);
      // lock the nonce before broadcasting: a send that errors after reaching
      // a node must not let the next poke reuse it for another payload
      this.nextNonce = nonce + 1;
      this.receiptPending = true;
      this.receiptSince = this.broadcastAt = Date.now();
      this.pendingHash = hash;
      this.pendingRaw = serialized;
      this.pendingNonce = nonce;
      console.log(`  ${label} → ${hash}`);
      await this.broadcast(serialized, label);
      try {
        // bounded wait: maintenance moves on with the signer still locked, and
        // the safety loop re-sends the same bytes or releases the spent nonce
        const receipt = await this.publicClient.waitForTransactionReceipt({hash, timeout: CONFIG.RECEIPT_TIMEOUT_MS});
        this.release(hash);
        if (receipt.status !== 'success') console.error(`[ALERT] ${label}: transaction reverted (${hash})`);
        return receipt.status === 'success';
      } catch (error) {
        console.error(`[ALERT] ${label}: no receipt for ${hash} yet; signer stays locked (${shortErr(error)})`);
        return false;
      }
    } catch (err) {
      // simulate reverts on no-op/guarded paths — expected, just skip.
      console.log(`  ${label}: skipped (${shortErr(err)})`);
      return false;
    }
  }

  private async maxQuoteBlocks(): Promise<bigint> {
    if (this.quoteBlocks === undefined) {
      this.quoteBlocks = BigInt(await this.publicClient.readContract({address: CONFIG.EXECUTION_CONTROLLER,
        abi: EXECUTION_ABI, functionName: 'maxQuoteBlocks'}));
      if (BigInt(CONFIG.QUOTE_DEPTH_BLOCKS + CONFIG.QUOTE_INCLUSION_BLOCKS) > this.quoteBlocks) {
        console.error(`[ALERT] QUOTE_DEPTH_BLOCKS ${CONFIG.QUOTE_DEPTH_BLOCKS} + QUOTE_INCLUSION_BLOCKS ` +
          `${CONFIG.QUOTE_INCLUSION_BLOCKS} exceed the controller's ${this.quoteBlocks}-block quote window`);
      }
    }
    return this.quoteBlocks;
  }

  private async broadcast(serialized: Hex, label: string): Promise<void> {
    try {
      await this.publicClient.sendRawTransaction({serializedTransaction: serialized});
    } catch (error) {
      // the node may already hold it; the receipt wait decides
      console.log(`  ${label}: broadcast returned ${shortErr(error)}`);
    }
  }

  // a dropped transaction is re-sent as the same signed bytes; the lock clears once its nonce is spent
  private async recoverPending(): Promise<void> {
    const hash = this.pendingHash!;
    const receipt = await this.publicClient.getTransactionReceipt({hash}).catch(() => undefined);
    if (receipt) {
      if (receipt.status === 'reverted') console.error(`[ALERT] pending transaction reverted: ${hash}`);
      return this.release(hash);
    }
    // not found or rpc failure leaves the signer locked until the nonce is spent
    const mined = await this.publicClient.getTransactionCount({address: this.account.address, blockTag: 'latest'})
      .catch(() => undefined);
    if (mined !== undefined && mined > this.pendingNonce) {
      console.error(`[ALERT] nonce ${this.pendingNonce} mined without a visible receipt for ${hash}`);
      return this.release(hash);
    }
    if (this.pendingRaw && Date.now() - this.broadcastAt >= CONFIG.RECEIPT_TIMEOUT_MS) {
      this.broadcastAt = Date.now();
      await this.broadcast(this.pendingRaw, `re-send ${hash}`);
    }
  }

  private release(hash: Hex): void {
    if (this.pendingHash !== undefined && this.pendingHash !== hash) return;
    this.receiptPending = false;
    this.pendingHash = undefined;
    this.pendingRaw = undefined;
  }
}

function fmtHf(hf: bigint): string {
  if (hf > 1000n * WAD) return '∞';
  return (Number(hf) / 1e18).toFixed(3);
}

function short(addr: Address): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function shortErr(err: unknown): string {
  const m = (err as Error)?.message ?? String(err);
  const reason = m.match(/reason:\s*([^\n]+)/)?.[1] ?? m.split('\n')[0];
  return reason.slice(0, 80);
}

function hasWork(result: unknown): boolean {
  if (typeof result === 'bigint') return result > 0n;
  if (typeof result === 'string' && result !== '0x') return decodeAbiParameters([{type: 'uint256'}], result as Hex)[0] > 0n;
  return true; // void calls (deLever, startUnwinds) rely on their on-chain guards
}

function executionReverted(error: unknown): boolean {
  let cause = error as any;
  while (cause) {
    if (cause.name === 'ExecutionRevertedError' || cause.name === 'ContractFunctionRevertedError' || cause.code === 3) return true;
    cause = cause.cause;
  }
  return false;
}
