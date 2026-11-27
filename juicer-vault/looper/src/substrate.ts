import type { Address, Hex } from 'viem';

export type EvmLog = { address: Address; topics: Hex[]; data: Hex };
export type Hop = { pool: 'Aave' | { Stableswap: number }; assetIn: number; assetOut: number };

// what the keeper needs from the node's substrate side; tests substitute a fake
export interface Substrate {
  accountOf(address: Address): Promise<Hex>;
  free(asset: number, account: Hex): Promise<bigint>;
  // logs of a dry-run EVM call, or undefined when the call fails
  dryRunEvm(from: Address, to: Address, data: Hex, gas: bigint, maxFeePerGas: bigint): Promise<EvmLog[] | undefined>;
  dryRunSell(origin: Hex, route: readonly Hop[], amountIn: bigint): Promise<bigint>;
  intents(owner: Hex): Promise<{ id: bigint; amountIn: bigint }[]>;
  // present only with a dev signer
  cleanup?: (id: bigint) => Promise<string>;
}

export async function connectSubstrate(url: string, suri?: string): Promise<Substrate> {
  const { ApiPromise, HttpProvider, WsProvider, Keyring } = await import('@polkadot/api');
  const provider = /^wss?:/.test(url) ? new WsProvider(url) : new HttpProvider(url);
  // hydration-specific runtime apis are not in the generic augmentation
  const api = await ApiPromise.create({ provider, noInitWarn: true }) as any;
  let signer: unknown;
  if (suri) {
    const { cryptoWaitReady } = await import('@polkadot/util-crypto');
    await cryptoWaitReady();
    signer = new Keyring({ type: 'sr25519' }).addFromUri(suri);
  }
  const accountOf = async (address: Address): Promise<Hex> => (await api.call.evmAccountsApi.accountId(address)).toHex();
  // the call's events; a dispatch error (fees, origin, a failed sell) throws with its module name
  const dryRun = async (origin: Hex, call: unknown) => {
    const result = await api.call.dryRunApi.dryRunCall({ system: { Signed: origin } }, call, 4);
    if (!result.isOk) throw new Error(`dry run refused: ${result.asErr.toString()}`);
    const execution = result.asOk.executionResult;
    if (execution.isErr) {
      const error = execution.asErr.error ?? execution.asErr;
      const meta = error.isModule ? api.registry.findMetaError(error.asModule) : undefined;
      throw new Error(`dry run failed: ${meta ? `${meta.section}.${meta.name}` : error.toString()}`);
    }
    return result.asOk.emittedEvents as any[];
  };
  return {
    accountOf,
    free: async (asset, account) => BigInt((await api.call.currenciesApi.account(asset, account)).free.toString()),
    dryRunEvm: async (from, to, data, gas, maxFeePerGas) => {
      const args: unknown[] = [from, to, data, 0, gas, maxFeePerGas, null, null, []];
      if (api.tx.evm.call.meta.args.length > args.length) args.push([]); // authorization list
      const events = await dryRun(await accountOf(from), api.tx.evm.call(...args));
      // a reverted EVM call still dispatches fine; only `Executed` means it ran through
      if (!events.some(e => e.section === 'evm' && e.method === 'Executed')) return undefined;
      return events.filter(e => e.section === 'evm' && e.method === 'Log').map(e => {
        const log = e.data[0].toJSON();
        return { address: log.address, topics: log.topics, data: log.data };
      });
    },
    dryRunSell: async (origin, route, amountIn) => {
      const sell = api.tx.router.sell(route[0].assetIn, route[route.length - 1].assetOut, amountIn, 0, route);
      const fill = (await dryRun(origin, sell)).find(e => e.section === 'router' && e.method === 'Executed');
      if (!fill) throw new Error('router dry run did not fill');
      return BigInt(fill.data[3].toString());
    },
    intents: async owner => Promise.all((await api.query.intent.accountIntents.keys(owner)).map(async (key: any) => {
      const id = BigInt(key.args[1].toString());
      const intent = (await api.query.intent.intents(id)).toJSON();
      return { id, amountIn: BigInt(intent?.data?.swap?.amountIn ?? 0) };
    })),
    cleanup: signer
      ? async id => (await api.tx.intent.cleanupIntent(id).signAndSend(signer)).toHex()
      : undefined,
  };
}
