# Lark deployment and hosted operators — 5 October 2026

The fresh PR #62 contracts are deployed on **Lark 4**, with two keeper signers,
a mainnet-MM oracle mirror and a testnet arbitrage service in the
`propeller-oct2026` [Swarm stack](https://swarmpit.lark.hydration.cloud).
The [UI preview](https://deploy-preview-3978--edge-hydra-app.netlify.app/strategies/propeller)
uses these contracts. **This is a testnet rehearsal with outstanding execution
gates, not a mainnet release or evidence of a promised APY.**

The [public evidence](evidence/lark-2026-10-05/) records deployment hashes,
governance enactments, runtime code hashes, policies, transaction receipts,
quotes, service tasks and checksums. Raw signed journals and hosting credentials
are excluded. Earlier reports retain their dated scope.

| Item | Deployed value |
| --- | --- |
| Genesis | `0xba82f5b6d812fd3e2a6c610969e395d3be1e558145a9f07148b8d1f269ab4fb2` |
| Runtime / EVM chain ID | 443 / 222222 |
| Contracts source | `9828ffd6257293fe40ef99da41e4a1b8d058e3c7` |
| ETH vault | `0x40cca3da6cead6dada9e9ffc4c06e9039791876a` |
| tBTC vault | `0x5b153c8e24ca62436ef836a1f179dd8ade2d5acd` |
| Source | `0x7016805f0f1ab369a1e308038db22eefe3d4b49f` |
| Controller | `0x7e7a0e795e14a11e62b20efaec48407003bfdc8f` |
| Keeper code / image | `e3ec9cd` / `sha256:972ee604daba2ac70079c0fc989b7d1314798bbb37fecaa375e749e41e6908c8` |
| Market/oracle code / image | `f361bf8` / `sha256:70c13bb2991431be8bcdd4615398d6fbbb48cccd7db8297ec39cf70f8ddb280a` |
| UI code | `95a20173daec6a6e7f4d3a4345f86bc67e27d445`, [PR #3978](https://github.com/galacticcouncil/hydration-ui/pull/3978) |

The implementation, immutable compound helper, source proxy, both vault proxies,
Main ledgers and yield ledgers were deployed together. Existing older vaults were
not upgraded. The implementation sizes and London production bytecode are those
validated in the [4 October report](deferred-deployment-validation-2026-10-04.md).
All deployed runtime code matches the selected artifacts outside immutable
substitutions. The reused HydraAugustus adapter is code-hashed and dust-protected.
The first synthetic-listing referendum (411) was not executed because its
asset name exceeded the runtime's length bound; the corrected payload (412)
executed successfully. Both outcomes remain in the deployment record.

## Verified behavior

- **184/184 live readiness checks passed.** Governance owns administration;
  the Technical Committee is guardian. Temporary bootstrap administration was
  revoked. Fee is 5%, borrowing discount 0%, Lark withdrawal cooldown 60 seconds.
- Both native-browser deposits initially left HOLLAR debt at zero. Eight browser
  transactions finalized, including exact-balance ETH and tBTC withdrawal
  claims before leverage. Signing used an explicit public test-wallet fixture.
  The [UI report](https://github.com/galacticcouncil/hydration-ui/blob/feat/propeller/docs/propeller-lark-ui-2026-10-05.md)
  records all hashes, cancellation cases, 75 tests and green CI/previews.
- Hosted keeper ETH deployment: block **415835**, gas **2,312,512**,
  `0x3a8153af35c0876d917b088aaaa45c75bb14e03b1df4e1c011250da8f458cbc6`.
  Hosted tBTC deployment: block **415852**, gas **2,318,184**,
  `0x360fd23d62c45ec69796c1370f0044818c0322e5f4f82dc917818b7be138b50e`.
- Both independent keeper signers executed source leverage slices. Examples:
  primary block **415864**, **1,766,848 gas**;
  secondary block **415894**, **1,769,780 gas**. Receipts are in the snapshot.
  Every allowance stays below the native **16,777,216 gas** ceiling.
- **51 keeper tests**, TypeScript build and **5 bot policy tests** passed.
  Shutdown now prevents a new write after SIGTERM, including a signal received
  during nonce lookup, while draining a transaction already submitted.
- All ten directions across PRIME/HOLLAR, ETH/HOLLAR, tBTC/HOLLAR, PRIME/ETH and
  PRIME/tBTC return real-route quotes. Arb transactions corrected the initially
  stale markets; executable prices remain separated by fees and price impact.

## Approved policy and remaining execution gates

The user approved **6 bps total cost on Lark PRIME↔HOLLAR only**. Referendum
**428**, enacted at block **415823**, sets both controller source lanes to 6 bps
and legacy source slippage to 600 ppm. The ETH/tBTC harvest and servicing lanes
remain **0 bps**, as do their legacy compound floors. Quotes last at most 60
seconds / five blocks. Entry and source ramp are bounded to **50 HOLLAR** each;
source unwind to **50 aPRIME**. Shared group spacing is 60 seconds. The full
minimum, maximum, refill and expiry values are in `deployment.json`.

**A productive harvest has not been mined.** A pinned read-only simulation at
block **415942** first failed during the compound delegatecall. Simulated price
floor relaxation exposed `TradeSize`; additionally reducing only the simulated
Main servicing minimums allowed the complete four-leg harvest preview. No live
policy was relaxed. The diagnostic used a deliberately broad 50% ceiling to
isolate causes; that is neither a proposal nor a release setting.

Small test positions owe less interest than the configured service input minima
(ETH `1e12` wei; tBTC `1e10` wei). Independently, sampled collateral-to-HOLLAR
routes cost roughly **3.8–3.9%** against the MM oracle during catch-up. Stored
Omnipool asset fees for GIGAETH and tBTC were about 3% at block 415952; dynamic
fees, route hops and imbalance must be calibrated before proposing tight caps.
Repeated arbitrage cannot eliminate a fee spread. Pool usability for quoting
does **not** establish that each Propeller lane can trade within its cap.

Small leveraged exits from the deployer fixture were requested as request ID 1
in both vaults. The hosted keeper started them; source repayment initially
waited for an acceptable PRIME quote. These are separate from the completed
debt-free browser exits. The latest snapshot/logs record progress; this report
does not certify a completed leveraged withdrawal or harvest cycle.

Next execution work is to calibrate the test market fee/price state, choose
explicit ETH/tBTC price bounds and service minimums, then mine and verify a
harvest, collateral reinvestment and complete leveraged exits. Mainnet policy
requires its own measured liquidity, oracle freshness and safety-repayment
review. No 7% yield or APY projection follows from funded test-market activity.

## Operator handover

`keeper0` and `keeper1` poll maintenance and safety every 30 seconds, rotating
optional writes in 60-second slots with separate funded signers. They use
`node4.lark` first and `4.lark` as fallback. The gateway's cached EVM `latest`
block/nonce responses caused failed previews and nonce reuse; native-head
pinning, the direct node and monotonic signer nonces address the observed cases.
There is one replica per signer. Both operators currently share **one physical
Swarm host**: process/key redundancy is verified, independent-host failover is
still a release task. Safety logs must be monitored; no external alert receiver
was provisioned.

The mirror reads canonical mainnet feeds with a 24-hour upstream-age bound,
refreshing test feeds every five minutes or at 1 bp drift. The arb refuses
mirrors older than 15 minutes. ManagedOracle has no read-time expiry, and keeper
contracts do not themselves reject an old managed feed: a production freshness
policy remains required. PRIME pool peg catch-up completed and referendum 429
restored the original **40 ppb/block** pacing.

The arb evaluates four sizes per route at one native block and only executes
at least **2 bps better than the MM oracle**, with at most 2 bps quote drift.
Guarded inclusion failures occurred during convergence; they are logged, never
counted as successful fills. It retains $100 per input for quoting. HOLLAR
inventory was exhausted down to that reserve after catch-up; it was refilled
with public test HOLLAR. Watch `inventory-refill-needed` explicitly: healthy
route quoting alone does not prove enough inventory for price correction.
All fixtures use public development keys and must never hold real assets.

The obsolete Lark-4 ratio-only arb `propeller-rebalancer_rebalancer` was stopped
after replacement services were running, so it does not fight the MM reference.
Other Lark stacks remain untouched. Restarting it is not a safe replacement for
the oracle-aware bot without reviewing its old assumptions.

Images are pinned by digest and published under the `galacticcouncil` Docker
Hub organization with those same digests. `scripts/propeller/lark-stack.mjs --keepers`
generates the compose file using `KEEPER_IMAGE` and `BOT_IMAGE`; without
`--keepers` it drains keeper replicas while leaving pricing services enabled.
Use stop-first updates. Confirm old tasks have exited before starting another
process with the same signer. The pre-fix keeper ignored SIGTERM, so this rollout
explicitly scaled it to zero and waited for all old tasks to disappear.
Keep the deployment journal and review known pending hashes before retrying.
Do not run phase scripts concurrently against one journal.

The `lark-*.mjs` scripts record this specific pinned-genesis rehearsal. Initial
wiring, reserve listing, fixture balance repair and one-time cap approval are
not a generic migration or replay recipe. After a chain reset, prepare a new
reviewed deployment and manifest. Do not disable the identity checks. Read-only
checks are `lark-readiness.mjs` and `lark-observe.mjs`; the latter requires
`PROPELLER_ARTIFACT_DIR` pointing to the verified London build.

## PR/release status

PR #62 remains unmerged pending review. Keeper/bot CI passes. Foundry still
fails at workflow startup: the effective organization Actions allowlist omits
`foundry-rs/foundry-toolchain@908c540300062bd5a7e473851cdb4282204cee09`.
The token lacks `admin:org`; repository settings cannot override that policy.
The existing 367-test local Solidity pass is recorded separately and is not a
substitute for the missing hosted check. No mainnet write was performed.
