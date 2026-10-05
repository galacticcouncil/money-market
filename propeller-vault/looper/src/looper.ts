import {
  createPublicClient,
  createWalletClient,
  http, fallback, encodeFunctionData, decodeAbiParameters, parseAbi, toHex,
  type Hex,
  type PublicClient,
  type WalletClient,
  type Address,
  type Chain,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { CONFIG, ROUNDING_POLICIES } from './config.js';
import { EXECUTION_ABI, executionQuotes, worthwhileHarvest, operatorTurn, efficientCandidate, type Fill } from './execution-policy.js';
import { roundingAlert } from './rounding-policy.js';

// ─── Hydration chain definition ──────────────────────────────────────────────

const hydration: Chain = {
  id: 222222,
  name: 'Hydration',
  nativeCurrency: { name: 'WETH', symbol: 'WETH', decimals: 18 },
  rpcUrls: {
    default: { http: [CONFIG.RPC_URL] },
  },
};

// ─── ABIs (only what the maintainer touches) ─────────────────────────────────

const SUBLOOP_ABI = [
  view('healthFactor', 'uint256'),
  view('targetHf', 'uint256'),
  view('deleverDebtTarget', 'uint256'),
  view('unwindTargetEquity', 'uint256'),
  view('paused', 'bool'),
  view('emergencyPaused', 'bool'),
  { name: 'pendingUnwindOf', type: 'function', stateMutability: 'view',
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
  nonpayable('rebalance'), // keep the LTV band
  nonpayable('maintainPeg'), // top up the synthetic floor
] as const;

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

// ─── Maintainer ───────────────────────────────────────────────────────────────
//
// Permissionless keeper: safety repayment and peg maintenance precede optional
// quoted harvest/ramp work. Independent operators rotate optional transactions;
// every operator monitors risk. Zero-work previews skip paid submissions.
// The signer pays gas and needs no maintenance role.

export class PropellerLooper {
  private publicClient: PublicClient;
  private walletClient: WalletClient;
  private account: ReturnType<typeof privateKeyToAccount>;
  private subLoop: Address;
  private vaults: Address[];
  private harvester: Address;
  private pool: Address;
  private cycle = 0;
  private receiptPending = false;
  private receiptSince = 0;
  private pendingHash?: Hex;
  private nextNonce = 0;
  private stopping = false;

  /** Drain an already submitted transaction, but never start another write. */
  stop(): void { this.stopping = true; }

  constructor() {
    if (!CONFIG.EXECUTION_CONTROLLER) throw new Error('EXECUTION_CONTROLLER is required for swap execution');
    this.account = privateKeyToAccount(CONFIG.PRIVATE_KEY);
    this.subLoop = CONFIG.SUBLOOP_ADDRESS;
    this.vaults = CONFIG.VAULT_ADDRESSES;
    this.harvester = CONFIG.HARVESTER_ADDRESS;
    this.pool = CONFIG.POOL_ADDRESS;

    this.publicClient = createPublicClient({ chain: hydration, transport: fallback(CONFIG.RPC_URLS.map(url => http(url, {timeout: 15000}))) });
    this.walletClient = createWalletClient({
      account: this.account,
      chain: hydration,
      transport: fallback(CONFIG.RPC_URLS.map(url => http(url, {timeout: 15000}))),
    });
  }

  async runCycle(): Promise<void> {
    if (this.stopping) return;
    this.cycle++;
    console.log(`\n[${new Date().toISOString()}] maintainer cycle #${this.cycle}`);

    const [hf, target, unwind, safetyDebt, paused, emergency] = (await Promise.all([
      this.read(SUBLOOP_ABI, this.subLoop, 'healthFactor'),
      this.read(SUBLOOP_ABI, this.subLoop, 'targetHf'),
      this.read(SUBLOOP_ABI, this.subLoop, 'unwindTargetEquity'),
      this.read(SUBLOOP_ABI, this.subLoop, 'deleverDebtTarget'),
      this.read(SUBLOOP_ABI, this.subLoop, 'paused'),
      this.read(SUBLOOP_ABI, this.subLoop, 'emergencyPaused'),
    ])) as [bigint, bigint, bigint, bigint, boolean, boolean];

    // Safety actions precede optional trading, even on a standby operator.
    if (!paused && hf < target) await this.poke(SUBLOOP_ABI, this.subLoop, 'deLever', 'deLever (HF below floor)');
    const safetyAttempted = !paused && (safetyDebt > 0n || hf < target);
    if (safetyAttempted) await this.poke(SUBLOOP_ABI, this.subLoop, 'pokeRepay', 'pokeRepay (safety debt)');
    for (const vault of this.vaults) await this.poke(VAULT_ABI, vault, 'maintainPeg', `maintainPeg ${short(vault)}`);
    const turn = operatorTurn(await this.blockTimestamp(), CONFIG.OPERATOR_SLOT_SECONDS, CONFIG.OPERATOR_COUNT, CONFIG.OPERATOR_INDEX);
    const leverage = await this.readLeverage();
    console.log(
      `  HF ${fmtHf(hf)} → target ${fmtHf(target)}` +
        (leverage !== null ? `   leverage ${leverage.toFixed(2)}×` : ''),
    );

    // Main rebalances create repayment work even when no user has redeemed.
    const pending: Address[] = [];
    const deployment = new Set<Address>();
    const frozen = new Set<Address>();
    let funded = true;
    let waiting = false;
    let started = false;
    let now: bigint | undefined;
    for (const vault of this.vaults) {
      try {
        const buffer = await this.read(VAULT_ABI, vault, 'mainDebt') as Address;
        const ready = await this.read([view('ready', 'bool')], buffer, 'ready') as boolean;
        if (!ready) {
          funded = false;
          console.error(`[ALERT] ${vault}: Main debt backing or source allocation incomplete; new ramp disabled`);
        }
      } catch (error) {
        funded = false;
        console.error(`[ALERT] ${vault}: Main debt monitor failed: ${shortErr(error)}`);
      }
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
        if (undeployed > 0n) deployment.add(vault);
        if (vaultPaused || emergency) frozen.add(vault);
        waiting ||= tail > next;
        let starting = false;
        if (tail > next && !paused && !frozen.has(vault)) {
          now ??= await this.blockTimestamp();
          const eligibleAt = await this.read(VAULT_ABI, vault, 'unwindEligibleAt', [next]) as bigint;
          if (now >= eligibleAt) {
            // Native validation: 16 starts need over 13M gas before margins.
            // Eight preserve more headroom for starting new exit cohorts.
            starting = await this.poke(VAULT_ABI, vault, 'startUnwinds', `startUnwinds ${short(vault)}`, [8n]);
            started ||= starting;
          }
        }
        if (delever > 0n || (!frozen.has(vault) && (next > head || starting || sourcePending > 0n))) pending.push(vault);
      } catch (error) {
        funded = false;
        waiting = true;
        frozen.add(vault);
        console.error(`[ALERT] ${vault}: queue monitor failed; optional risk disabled: ${shortErr(error)}`);
      }
    }
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
    if (harvested) {
      // Harvest servicing can change Main readiness. Do not ramp from the
      // pre-harvest snapshot, even within this same scheduler cycle.
      for (const vault of this.vaults) {
        try {
          const ledger = await this.read(VAULT_ABI, vault, 'mainDebt') as Address;
          funded &&= await this.read([view('ready', 'bool')], ledger, 'ready') as boolean;
        } catch (error) {
          funded = false;
          console.error(`[ALERT] ${vault}: post-harvest backing read failed: ${shortErr(error)}`);
        }
      }
    }
    // Pending deposits and freshly earned collateral get first use of entry
    // liquidity, before more source leverage. Rotate vault order for progress
    // when several vaults share a limited entry budget.
    let rebalanced = false;
    for (let i = 0; i < this.vaults.length; ++i) {
      const vault = this.vaults[(i + this.cycle - 1) % this.vaults.length];
      if ((deployment.has(vault) || harvested || this.cycle % CONFIG.SLOW_EVERY === 0)
          && turn && !paused && !emergency && !frozen.has(vault) && !servicing) {
        const changed = await this.poke(VAULT_ABI, vault, 'rebalance', `deploy/rebalance ${short(vault)}`);
        rebalanced ||= changed;
      }
    }
    if (!paused) {
      // A deployment can incur execution costs; a down-rebalance can open an
      // unwind. Re-read all safety/backing state next cycle before adding leverage.
      if (!rebalanced && turn && hf >= target && funded && !emergency && frozen.size === 0 && !servicing && hf > (target * BigInt(Math.floor((1 + CONFIG.RAMP_HF_BUFFER) * 1e6))) / 1_000_000n) {
        await this.poke(SUBLOOP_ABI, this.subLoop, 'pokeBorrow', 'pokeBorrow (ramp)');
      }
      if (!safetyAttempted && !emergency && (unwind > 0n || pending.length > 0 || started)) {
        await this.poke(SUBLOOP_ABI, this.subLoop, 'pokeRepay', 'pokeRepay (unwind/safety debt)');
      }
    }
    // Applying already freed funds is safe even while source swaps are paused.
    for (const vault of pending) {
      await this.poke(VAULT_ABI, vault, 'pokeSettle', `pokeSettle ${short(vault)}`);
    }

    // Optional writes are rotated between independently funded operators.
    if (harvested || this.cycle % CONFIG.SLOW_EVERY === 0) {
      for (const vault of this.vaults) {
        if (!pending.includes(vault)) {
          await this.poke(VAULT_ABI, vault, 'pokeSettle', `service Main interest ${short(vault)}`);
        }
      }
    }
  }

  async monitorSafety(): Promise<void> {
    // Separate read loop: slow simulation/receipts never stop risk monitoring.
    const block = await this.publicClient.getBlock({blockTag: 'latest'});
    if (this.pendingHash) {
      try {
        const receipt = await this.publicClient.getTransactionReceipt({hash: this.pendingHash});
        if (receipt.status === 'reverted') console.error(`[ALERT] pending transaction reverted: ${this.pendingHash}`);
        this.receiptPending = false;
        this.pendingHash = undefined;
      } catch { /* Not found/RPC failure leaves the signer locked until confirmed. */ }
    }
    if (this.receiptPending && Date.now() - this.receiptSince > 120000) {
      console.error('[ALERT] transaction receipt pending for over two minutes; redundant operator must continue maintenance');
    }
    if (BigInt(Math.floor(Date.now() / 1000)) - block.timestamp > BigInt(CONFIG.RPC_STALE_SECONDS)) {
      console.error('[ALERT] RPC head is stale; inspect independent operator/RPC health');
    }
    const [hf, target] = await Promise.all([
      this.read(SUBLOOP_ABI, this.subLoop, 'healthFactor'), this.read(SUBLOOP_ABI, this.subLoop, 'targetHf'),
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
        const [ready, interest] = await Promise.all([
          this.read([view('ready', 'bool')], ledger, 'ready'),
          this.read(parseAbi(['function interestOf(uint256) view returns (uint256)']), ledger, 'interestOf', [0n]),
        ]) as [boolean, bigint];
        if (!ready) console.error(`[ALERT] ${vault}: Main backing/accounting incomplete`);
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
      if (!CONFIG.EXECUTION_CONTROLLER || bound.toLowerCase() !== CONFIG.EXECUTION_CONTROLLER.toLowerCase()) {
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
    // Urgent repayment takes the first acceptable quote; it still obeys the
    // same size and price bounds, but does not spend extra time optimizing.
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
      // Always sample the lane minimum within the bounded RPC budget. A large
      // TVL must not hide a good small quote beyond six successive halvings.
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

  // ─── helpers ─────────────────────────────────────────────────────────

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

  /// simulate → send a permissionless poke; a benign revert (nothing to do /
  /// HealthyEnough / paused) is logged and skipped, never fatal.
  private async poke(
    abi: readonly unknown[],
    address: Address,
    functionName: string,
    label: string,
    args: readonly unknown[] = [],
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
      const guarded = ['harvest', 'pokeBorrow', 'rebalance', 'pokeRepay'].includes(functionName);
      if (guarded) {
        if (!CONFIG.EXECUTION_CONTROLLER) throw new Error('missing execution controller; swap action disabled');
        const quoted = await this.publicClient.getBlock({blockNumber: block.number - 1n});
        const data = encodeFunctionData({abi: abi as any, functionName, args});
        const [result, fills] = await this.quoteAction(address, data, functionName, quoted.number, budget) as readonly [Hex, readonly Fill[]];
        if (!hasWork(result)) return false;
        const serviceLanes = new Set<string>();
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
      const { request } = simulated;
      // Send the gas ceiling explicitly: viem's estimateContractGas omits it
      // from the RPC payload. Reserve room for our 20% submission margin.
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
        const amount = guarded ? decodeAbiParameters([{type: 'uint256'}], simulated.result as Hex)[0] : simulated.result as bigint;
        if (!await this.harvestWorthwhile(amount, gas * gasPrice, block.timestamp)) return false;
      }
      // Some RPCs return used gas even for a reverted estimate. A final
      // simulation at the actual allowance also rechecks the quote and work.
      if (!hasWork((await this.publicClient.simulateContract({...options, gas})).result)) return false;
      // Some gateways cache the pending nonce even after a mined receipt.
      // Keep this dedicated signer's nonce monotonic across maintenance calls.
      const nonce = Math.max(this.nextNonce ?? 0, await this.publicClient.getTransactionCount({
        address: this.account.address, blockTag: 'pending',
      }));
      // SIGTERM may arrive during an RPC await above. Recheck immediately
      // before signing so a rolling replacement cannot start another stream.
      if (this.stopping) return false;
      const hash = await this.walletClient.writeContract({
        ...request,
        gasPrice,
        gas,
        nonce,
      } as any);
      this.nextNonce = nonce + 1;
      console.log(`  ${label} → ${hash}`);
      this.receiptPending = true;
      this.receiptSince = Date.now();
      this.pendingHash = hash;
      // A timeout must not start a second nonce stream. Monitoring continues;
      // another operator has its own signer and can take the next duty slot.
      const wait = this.publicClient.waitForTransactionReceipt({hash, timeout: 0});
      const receipt = await wait;
      this.receiptPending = false;
      this.pendingHash = undefined;
      if (receipt.status !== 'success') console.error(`[ALERT] ${label}: transaction reverted (${hash})`);
      return receipt.status === 'success';
    } catch (err) {
      // simulate reverts on no-op/guarded paths — expected, just skip.
      console.log(`  ${label}: skipped (${shortErr(err)})`);
      return false;
    }
  }
}

// ─── formatting ─────────────────────────────────────────────────────────────

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
  return true; // legacy void safety/start operations retain their on-chain guards
}

function executionReverted(error: unknown): boolean {
  let cause = error as any;
  while (cause) {
    if (cause.name === 'ExecutionRevertedError' || cause.name === 'ContractFunctionRevertedError' || cause.code === 3) return true;
    cause = cause.cause;
  }
  return false;
}
