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

## mainnet deployment

deployed on 9 november 2026 at block `16,824,244`:

- provider: `0xA9d3e3C8516357831E2513049Cb3Fa12eE1224A8`
- transaction: `0x1dc54a18ce87b11deb15b580d47a2c927c06c0ba618cee68d63529ed274eb27b`
- pool: `0x1b02E051683b5cfaC5929C25E84adb26ECf87B38`
- HOLLAR: `0x531a654d1696ED52e7275A8cede955E82620f99a`
- compiler: `0.8.10+commit.fc410830`, optimizer 100,000 runs, EVM Berlin

all seven provider tests passed, including the pinned mainnet regression.
the deployed runtime matches the compiled source after resolving constructor
immutables. Tarn and shellfish independently returned matching reserve data at
the deployment block; direct pool and facilitator reads matched, and three
user-data reads matched the original provider. the four optional metadata
fields return zero for the Juicer discount strategy.

the deployment receipt and compiler input are saved under
`deployments/hydration/UiGhoDataProviderCompat.json` and its referenced
`solcInputs` file. all three production UI configurations share this main-pool
provider; the testnet configuration keeps its existing provider.
