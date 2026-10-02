# HDX/USD CheckedOracle — Robinhood Chain deploy

One `CheckedOracle` (see `checked-oracle.md`) on Robinhood Chain (chain id 4663),
the HDX/USD price source of the three BandHook pools in `galacticcouncil/liquidity`
(HDX/HOLLAR reads it directly; ETH/HDX reads it through a `RatioSource` with
Chainlink ETH/USD). Fed by the wormhole-direct `OracleReceiver` on Robinhood, which
receives the Hydration emitter's HDX/USD reads (whm repo).

Decision: `galacticcouncil/money-market#59`. Robinhood has no independent HDX
reference, so the oracle deploys **unchecked** (`checkOracle = address(0)`, every
push stored) at the address the hooks read from day one. The owner can switch a
check on later with `setCheckOracle` without touching the hooks or the receiver.
The hook side already degrades safely on a bad print: a price more than
`guardTicks` from the pool cannot cause a recenter, and the worst case is swaps
paying the fee cap until the next good print.

## Parameters (`tasks/misc/deploy-checked-oracle-robinhood.ts`)

| | value | source |
|---|---|---|
| Artifact | `HDX-CheckedOracle` (`deployments/robinhood/`) | pinned |
| Description | `HDX/USD` | pinned |
| Decimals | 8 | contract |
| Check feed | none (unchecked) | pinned |
| `maxDiffBps` | 1000 (inert while unchecked; the band the first real check is expected to use) | pinned |
| Initial price | `HDX_USD_PRICE`, 8 decimals, from the market at deploy time; refused outside [0.001, 1] USD | env |
| Owner | `ROBINHOOD_ORACLE_OWNER` = the hooks' owner multisig on Robinhood | env |
| Pusher | `ROBINHOOD_ORACLE_PUSHER` = Robinhood `OracleReceiver` | env |

The receiver scales the emitter's 18-decimal value to 8 (`PRICE_SCALE_DIVISOR`) and
calls `setPrice(int256)`; the relayer pre-flights with `previewSetPrice`, which
accepts everything while unchecked. No whm code change.

## Prerequisites

- Robinhood `OracleReceiver` deployed and its address known (whm).
- Hook owner multisig on Robinhood known (must accept plain ETH; see the liquidity README).
- Deployer funded with ETH on Robinhood. `PRIV_KEY` in `.env`.
- `SKIP_LOAD=true npx hardhat compile` once.

## Run

```bash
ROBINHOOD_ORACLE_OWNER=0x... ROBINHOOD_ORACLE_PUSHER=0x... HDX_USD_PRICE=1230000 \
  npx hardhat deploy-checked-oracle-robinhood --network robinhood
```

Rehearsal on an anvil fork of Robinhood: `RPC=http://127.0.0.1:8545 ALLOW_ANY_NETWORK=1`
with `--network robinhood` still, so the artifact lands in `deployments/robinhood/`
(delete it before the real run).

The task prints the deployed config and checks: initial price, decimals 8, owner,
pusher, no check feed, `checked() == false`, band 1000, and that
`previewSetPrice(2 × price)` is accepted (unchecked).

## After deploy (not part of this task)

1. whm: `setOracle` migration on the Robinhood receiver, HDX `assetId` → this address.
2. liquidity: `FEED` in `.env.hdx-hollar` and `FEED_B` in `.env.eth-hdx` = this address,
   then `01_SetupPool` per pool (its `EXPECTED_TICK` check catches a wrong feed).
3. Alerting on stale `updatedAt` against the 30-minute push heartbeat. While
   unchecked there are no rejections, so staleness means the pipeline, not the gate.
4. Later, the first real check: a step check against the last accepted value
   (X = 10%) needs its own contract mode; the pool price as a check feed is
   freeze-only but lets anyone push the pool to freeze updates. Separate issue.
