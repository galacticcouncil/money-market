# Lark Propeller market services

These services are fixtures for **Lark 4**, never production signers or an APY
forecast. They refuse another chain name, chain ID or deployment genesis. Their
public development accounts must never receive real assets.

`mirror` follows the canonical mainnet Money Market sources for ETH, tBTC and
PRIME. It records the original feed, price, source block and source timestamp,
rejects source prices older than 24 hours or a head older than 120 seconds, and
refreshes the testnet ManagedOracles on a one-basis-point change or a five-minute
heartbeat. It also copies every other MM oracle from mainnet: DIA feeds through
`setMultipleValues` and pusher feeds through `setPrice`, both re-pointed to the
mirror signer by governance. ManagedOracle itself has no read-time expiry;
operators must monitor this service. The market bot refuses a mirror older
than 15 minutes.

`markets` reads the stored native routes in both directions for PRIME/HOLLAR,
ETH/HOLLAR, tBTC/HOLLAR, PRIME/ETH and PRIME/tBTC. Each cycle simulates $1, $100,
$1,000 and $5,000 inputs against one pinned block, including every hop's fees
and price impact. Only PRIME/HOLLAR is traded: `pools` keeps ETH, tBTC and
the other Omnipool assets at mainnet's pool prices, which sit off the MM oracle
there too, and an oracle arb on those legs would fight it. Only quotes at least
2 bps better than the MM oracle can be submitted. The actual minimum output is
the larger of that oracle floor and the quote less 2 bps. A fresh simulation
precedes signing. Quotes expire after five blocks or 60 seconds. The bot
reports unquotable routes as unhealthy.

`pools` keeps every Omnipool asset's price, measured against HOLLAR, within
`POOL_BAND_BPS` of mainnet's live Omnipool price. It trades only a deviation
that persists for two ticks, because a finalized mainnet trade that `replay`
has not yet applied reads as a one-tick deviation. Each tick it makes one
Omnipool trade, the one that removes the most deviation, capped at 3% of the
reserve. An asset whose inventory cannot remove `POOL_MIN_GAIN_BPS` logs
`inventory-refill-needed` instead of blocking the others. aTokens it sells
(aDOT, GSOL, GETH) are wrapped from a held underlying stash (DOT, jitoSOL,
wstETH) whenever the balance drops below 1% of the Omnipool reserve, so
refills never trade on the Omnipool being corrected.

`replay` re-executes finalized mainnet extrinsic trades on Lark with the same
pair and input amount, scaled by `REPLAY_SCALE`. A routed trade is rebuilt from
its per-hop `broadcast.Swapped3` events. Trades whose hops cannot be rebuilt,
such as UniswapV3 hops, fall back to the stored route. Block-hook trades, such
as fee conversion and DCA, are skipped because the fork runs those natively.
Trades are batched with `utility.forceBatch`, so one failing item does not
block the rest. H2O is never minted for replay.

The market bot retains $100 of each input asset for live route quoting. The funded
inventory is finite; price monitoring does not guarantee market
correction when inventory runs out. A profitable trade can be unavailable at
the fair price because pools charge fees. The bot never forces such a trade to
make a keeper appear productive.

Monitor `inventory-refill-needed` as well as Docker health. Health confirms that
the bot can quote all routes; a funded quote reserve does not mean there is
enough spendable inventory to correct every profitable deviation. Refill only
the isolated public test account, and keep those subsidies out of APY results.

Required environment:

| Variable | Meaning |
| --- | --- |
| `BOT_MANIFEST` | JSON containing pinned `genesis` and `oracles` (asset ID, asset address, mirror address, name) |
| `BOT_MODE` | `mirror`, `markets`, `pools` or `replay` |
| `BOT_LIVE` | Explicit `true` to sign; otherwise read-only |
| `BOT_ONCE` | `true` for one cycle, with a failing exit code for unhealthy routes |
| `BOT_INTERVAL_MS` | Default 30,000; minimum 5,000 for testnet catch-up |
| `POOL_BAND_BPS` | `pools`: tolerated deviation from mainnet, default 40 |
| `POOL_MIN_GAIN_BPS` | `pools`: smallest correction worth a trade, default 5 |
| `REPLAY_SCALE` | `replay`: input size multiplier, default 1 |
| `REPLAY_BATCH` | `replay`: maximum trades per batch, default 25 |
| `REPLAY_MAX_BLOCKS` | `replay`: mainnet blocks per cycle, default 20 |
| `REPLAY_FROM` | `replay`: first mainnet block; default is the finalized head at start |

Use one replica per mode and a stop-first rollout. Allow four minutes for a
graceful stop so an in-flight receipt can resolve. Docker health checks require
a successful cycle within three minutes. Logs contain quote decisions and mined
transaction hashes; verify those receipts as well as container health.

```sh
npm ci
npm test
BOT_MANIFEST=/path/to/lark.json BOT_MODE=markets BOT_ONCE=true npm start
```

The mirror uses index 19 of the public Hardhat mnemonic; the market bot uses
`//Alice//propeller-20261005-arb`. Its Substrate/EVM binding and test inventory
are established by `scripts/propeller/lark-market-setup.mjs`. `pools` and
`replay` sign as `//Alice//propeller-20261007-pools` and `-replay`. Their feed
rights, duster exemptions and inventory come from
`scripts/propeller/lark-mainnet-sync-setup.mjs`,
`lark-mainnet-sync-inventory.mjs` and `lark-wrap-inventory.mjs`. Test mints
must stay within each asset's deposit-fuse headroom: an oversized mint is
parked as reserved balance and locks the asset (see `lark-release-deposits.mjs`).
A testnet reset requires a fresh reviewed manifest and funding, not disabling
the genesis check.
