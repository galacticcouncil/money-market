# HOLLAR UI data provider compatibility

`UiGhoDataProviderCompat` is a drop-in replacement for the Hydration
`UiGhoDataProvider`. It preserves the existing UI ABI while allowing a HOLLAR
discount strategy to omit the four legacy Aave metadata getters.

The replacement only makes these reads optional:

- `GHO_DISCOUNTED_PER_DISCOUNT_TOKEN()`
- `DISCOUNT_RATE()`
- `MIN_DISCOUNT_TOKEN_BALANCE()`
- `MIN_DEBT_TOKEN_BALANCE()`

An absent or malformed optional getter is reported as zero. All pool, HOLLAR,
facilitator, debt-token, discount-balance, and user-position calls retain the
original fail-closed behavior.

## Test

```sh
forge test --match-contract UiGhoDataProviderCompatTest
RPC_HYDRATION=https://rpc.hydradx.cloud \
  forge test --match-contract UiGhoDataProviderCompatForkTest -vv
```

The fork regression is pinned to block `16,683,446`: the existing provider
must revert there, while the replacement must return the reserve data.

## Deploy and verify

The task defaults to the main Hydration Pool and HOLLAR addresses and refuses
to use Hardhat's fallback development key on a live network.

```sh
npm run compile
PRIV_KEY=<deployer-key> npx hardhat deploy-UiGhoDataProviderCompat \
  --network hydration

npx hardhat verify --network hydration <new-provider-address> \
  0x1b02E051683b5cfaC5929C25E84adb26ECf87B38 \
  0x531a654d1696ED52e7275A8cede955E82620f99a
```

The deployment task performs a live `getGhoReserveData()` readback before it
reports success. Independently check the selector used by the frontend:

```sh
cast call <new-provider-address> 0xf5a5b364 \
  --rpc-url https://rpc.hydradx.cloud
```

After deployment, replace `GHO_UI_DATA_PROVIDER` for Hydration mainnet,
GIGAHDX, and BIL in the UI address configuration with the printed address.
