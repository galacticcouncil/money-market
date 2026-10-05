# Lark Propeller market services

These services are fixtures for **Lark 4**, never production signers or an APY
forecast. They refuse another chain name, chain ID or deployment genesis. Their
public development accounts must never receive real assets.

`mirror` follows the canonical mainnet Money Market sources for ETH, tBTC and
PRIME. It records the original feed, price, source block and source timestamp,
rejects source prices older than 24 hours or a head older than 120 seconds, and
refreshes the testnet ManagedOracles on a one-basis-point change or a five-minute
heartbeat. ManagedOracle itself has no read-time expiry; operators must monitor
this service. The market bot refuses a mirror older than 15 minutes.

`markets` reads the stored native routes in both directions for PRIME/HOLLAR,
ETH/HOLLAR, tBTC/HOLLAR, PRIME/ETH and PRIME/tBTC. Each cycle simulates $1, $100,
$1,000 and $5,000 inputs against one pinned block, including every hop's fees
and price impact. Only quotes at least 2 bps better than the MM oracle can be
submitted. The actual minimum output is the larger of that oracle floor and
the quote less 2 bps. A fresh simulation precedes signing. Quotes expire after
five blocks or 60 seconds. The bot reports unquotable routes as unhealthy.

The funded inventory is finite; price monitoring does not guarantee market
correction when inventory runs out. A profitable trade can be unavailable at
the fair price because pools charge fees. The bot never forces such a trade to
make a keeper appear productive.

Required environment:

| Variable | Meaning |
| --- | --- |
| `BOT_MANIFEST` | JSON containing pinned `genesis` and `oracles` (asset ID, asset address, mirror address, name) |
| `BOT_MODE` | `mirror` or `markets` |
| `BOT_LIVE` | Explicit `true` to sign; otherwise read-only |
| `BOT_ONCE` | `true` for one cycle, with a failing exit code for unhealthy routes |
| `BOT_INTERVAL_MS` | Default 30,000; minimum 5,000 for testnet catch-up |

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
are established by `scripts/propeller/lark-market-setup.mjs`. A testnet reset
requires a fresh reviewed manifest and funding, not disabling the genesis check.
