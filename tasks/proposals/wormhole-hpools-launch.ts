// @ts-nocheck
//
// Wormhole H-pools launch (Nov 2026, Root track) — steps 2–4 of moving the HOLLAR venues
// to the Wormhole NTT stables (USDC 21 / USDT 23). Step 1 (ref 440) listed both in the MM.
//
// One enactment batch, in this order:
//   1. treasury unwinds 3-Pool-MRL (105): a3-Pool-MRL (1105) -> shares, remove all liquidity.
//      The treasury owns every share, and removing all of them destroys the pool.
//   2. the 3-Pool-MRL MM reserve is frozen
//   3. registry names: 2-Pool-HUSDC/HUSDT (110/111) and Hydrated USDC/Tether (1110/1111)
//      become "(Polkadot)"; symbols stay
//   4. register shares 114 / 115 "(Wormhole)", stableswap.createPool HOLLAR + aUSDC.wh (1021)
//      / aUSDT.wh (1023), amplification 222, fee 0.02 % (= 110/111)
//   5. treasury supplies 100k USDC.wh + 100k USDT.wh to the MM and seeds each pool with
//      100k aToken + 100k HOLLAR
//   6. init-reserve 2-POOL-HUSDC.WH / 2-POOL-HUSDT.WH (= H-pools: LTV 70 / LT 80 / 3.5 %,
//      not borrowable, cap 4M, Stablecoins eMode, 10-min stablesw share oracle)
//   7. register Hydrated USDC/Tether (Wormhole) 1114 / 1115 at the predicted aToken
//      addresses + fee currency; treasury supplies its shares
//   8. routes: every stored route through pool 105 re-pointed through the new pools;
//      liquidation routes for the new shares; fee-pricing routes for the new HUSDx
//   9. ice.updateRouting(AaveWrap(share, HUSDx), Included)
//  10. hsm.addCollateralAsset aUSDC.wh -> pool 114, aUSDT.wh -> pool 115 (= 1003/1002 params,
//      max holding 2M = the MM supply cap of the Wormhole stables)
//  11. treasury sends PRIME to the rewards distributor: 2 x 275.616 PRIME/day from the
//      INCENTIVES_START epoch to the program end
//
// aToken addresses are predicted from the PoolConfigurator nonce (+3 per reserve; USDC pool
// at nonce, USDT pool at nonce + 3; ATOKEN_NONCE overrides).
//
// dispatchAsAaveManager and dispatchAsTreasury swallow inner failures, so the dry-run must
// confirm the events and the treasury balances, not just BatchCompleted.
//
import {
  getApi,
  location,
  generateProposalV2,
  aaveManagerCall,
  dispatchAsTreasury,
} from "../../helpers/hydration-proposal.js";
import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { addTransaction, getBatch, clearBatch } from "../../helpers/transaction-batch";
import { FORK, getPool, getPoolAddressesProvider, getPoolConfiguratorProxy, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

const HDX = 0;
const USDC_WH = 21;
const USDT_WH = 23;
const PRIME = 43;
const HOLLAR = 222;
const aUSDC_WH = 1021;
const aUSDT_WH = 1023;
const MRL_POOL = 105; // 3-Pool-MRL: USDC.wh / USDT.wh / HOLLAR
const aMRL_POOL = 1105;
const MRL_POOL_ADDRESS = "0x0000000000000000000000000000000100000069"; // asset 105 precompile (not in this market config)
const TREASURY = "13UVJyLnbVp9RBZYFwFGyDvVd1y27Tt8tkntv6Q7JVPhFsTB";

const POOLS = [
  // reserve key, share id, HUSDx id, stable, aToken, old share, old HUSDx
  { key: "2-POOL-HUSDC.WH", share: 114, husd: 1114, stable: USDC_WH, aToken: aUSDC_WH, old: 110, oldHusd: 1110,
    shareName: "2-Pool-HUSDC (Wormhole)", shareSymbol: "2-Pool-HUSDC", husdName: "Hydrated USDC (Wormhole)", husdSymbol: "HUSDC",
    oldShareName: "2-Pool-HUSDC (Polkadot)", oldHusdName: "Hydrated USDC (Polkadot)" },
  { key: "2-POOL-HUSDT.WH", share: 115, husd: 1115, stable: USDT_WH, aToken: aUSDT_WH, old: 111, oldHusd: 1111,
    shareName: "2-Pool-HUSDT (Wormhole)", shareSymbol: "2-Pool-HUSDT", husdName: "Hydrated Tether (Wormhole)", husdSymbol: "HUSDT",
    oldShareName: "2-Pool-HUSDT (Polkadot)", oldHusdName: "Hydrated Tether (Polkadot)" },
];

const AMPLIFICATION = 222; // = 110 / 111
const POOL_FEE = 200; // Permill, 0.02 % = 110 / 111
const SHARE_ED = "1000"; // = 110 / 111
const HUSD_ED = "33000000000000000"; // = 1110 / 1111
const HUSD_FEE_PRICE = "11190000000000000000000"; // = 1110 / 1111 (fallback only)
const SEED_STABLE = 100_000n * 10n ** 6n;
const SEED_HOLLAR = 100_000n * 10n ** 18n;

// HSM: = aUSDC (1003) / aUSDT (1002) live values, except the holding limit
const HSM = {
  purchaseFee: 0,
  maxBuyPriceCoefficient: "998000000000000000",
  buyBackFee: 100, // Permill, 0.01 %
  buybackRate: 100_000, // Perbill, 0.01 %
  maxInHolding: (2_000_000n * 10n ** 6n).toString(),
};

// PRIME incentives: the live HUSDC/HUSDT budget, per pool, from the first epoch to the program end
const URD = "0x5Ca17568846eD083Fd0eb307382C69232Bd787F0";
const PRIME_PER_DAY_RAW = 275_616_000n; // 275.616 PRIME, 6 dec
const PROGRAM_END = Date.parse("2027-01-15T16:00:00Z") / 1000;
const INCENTIVES_START = Date.parse(`${process.env.INCENTIVES_START ?? "2026-12-01"}T16:00:00Z`) / 1000;

const EVM_DEFAULT_GAS = 1_000_000;
const TREASURY_MM_EXTRA_GAS = Number(process.env.TREASURY_MM_EXTRA_GAS ?? 1_000_000);

const aave = (a, b) => ({ pool: "Aave", assetIn: a, assetOut: b });
const ss = (pool, a, b) => ({ pool: { Stableswap: pool }, assetIn: a, assetOut: b });
const omni = (a, b) => ({ pool: "Omnipool", assetIn: a, assetOut: b });
const reverse = (route) => [...route].reverse().map((h) => ({ pool: h.pool, assetIn: h.assetOut, assetOut: h.assetIn }));
const isSs = (h, pool) => typeof h.pool === "object" && h.pool.Stableswap === pool;
const show = (route) =>
  route.map((h) => `${typeof h.pool === "object" ? "ss" + h.pool.Stableswap : h.pool.toLowerCase()}(${h.assetIn}>${h.assetOut})`).join(" ");

const poolOf = (stable) => POOLS.find((p) => p.stable === stable);
// stable -> HOLLAR through its own new pool
const toHollar = (stable) => {
  const p = poolOf(stable);
  return [aave(stable, p.aToken), ss(p.share, p.aToken, HOLLAR)];
};

// One hop through pool 105 -> the same swap through the new pools
const replaceHop = (h) => {
  const { assetIn: a, assetOut: b } = h;
  if (a === HOLLAR) return reverse(toHollar(b));
  if (b === HOLLAR) return toHollar(a);
  return [...toHollar(a), ...reverse(toHollar(b))]; // USDC.wh <-> USDT.wh
};

// drop a wrap immediately followed by its unwrap (or the other way round)
const simplify = (route) => {
  const out = [];
  for (const h of route) {
    const prev = out[out.length - 1];
    if (prev && prev.pool === "Aave" && h.pool === "Aave" && prev.assetIn === h.assetOut && prev.assetOut === h.assetIn) out.pop();
    else out.push(h);
  }
  return out;
};

task(`wormhole-hpools-launch`, `3-Pool-MRL unwind + Wormhole H-pools + MM listing + HSM + PRIME incentives`).setAction(
  async function (_, hre) {
    const { utils } = hre.ethers;
    const network = FORK ? FORK : hre.network.name;
    const admin = POOL_ADMIN[network];
    const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
    const api = await getApi();
    const tx = api.tx;
    const poolAddressesProvider = await getPoolAddressesProvider();
    const poolConfigurator = await getPoolConfiguratorProxy();
    const pool = await getPool();

    const deployer = await poolAddressesProvider.getPoolConfigurator();
    const liveNonce = await hre.ethers.provider.getTransactionCount(deployer);
    const nonce = process.env.ATOKEN_NONCE ? Number(process.env.ATOKEN_NONCE) : liveNonce;
    POOLS.forEach((p, i) => (p.husdAddress = utils.getContractAddress({ from: deployer, nonce: nonce + 3 * i })));
    console.log(
      `PoolConfigurator ${deployer} nonce ${liveNonce}${nonce !== liveNonce ? ` (building for ${nonce})` : ""} -> ` +
        POOLS.map((p) => `${p.husdName} ${p.husdAddress}`).join(", ")
    );

    const aaveTxs = async () => {
      const out = [];
      for (const el of getBatch()) {
        el.from = admin;
        el.gasLimit = el.gasLimit ?? EVM_DEFAULT_GAS;
        out.push(await aaveManagerCall(el));
      }
      clearBatch();
      return out;
    };
    const asTreasury = async (call) => await dispatchAsTreasury(call);
    // MM supply / withdraw as the treasury: the default EVM gas budget of a dispatched call
    // is too small for the health-factor pass over the treasury's collaterals (EvmOutOfGas)
    const asTreasuryMm = async (call) => await dispatchAsTreasury(tx.dispatcher.dispatchWithExtraGas(call, TREASURY_MM_EXTRA_GAS));
    const rename = (id, name) => tx.assetRegistry.update(id, name, null, null, null, null, null, null, null);

    // ---- 1. treasury unwinds 3-Pool-MRL
    const mrlATokens = BigInt((await api.call.currenciesApi.account(aMRL_POOL, TREASURY)).free.toString());
    const mrlLoose = BigInt((await api.query.tokens.accounts(TREASURY, MRL_POOL)).free.toString());
    const mrlIssuance = BigInt((await api.query.tokens.totalIssuance(MRL_POOL)).toString());
    const mrlShares = mrlATokens + mrlLoose;
    console.log(`3-Pool-MRL shares: treasury ${mrlATokens} supplied + ${mrlLoose} loose = ${mrlShares}, issuance ${mrlIssuance}`);
    if (mrlShares !== mrlIssuance) throw new Error("the treasury no longer owns every 3-Pool-MRL share: rework the unwind");
    const mrlAssets = (await api.query.stableswap.pools(MRL_POOL)).unwrap().assets.map((a) => a.toNumber());
    const unwind = [
      await asTreasuryMm(tx.router.sellAll(aMRL_POOL, MRL_POOL, 0, [aave(aMRL_POOL, MRL_POOL)])),
      await asTreasury(
        tx.stableswap.removeLiquidity(
          MRL_POOL,
          mrlShares.toString(),
          mrlAssets.map((assetId) => ({ assetId, amount: 0 }))
        )
      ),
    ];

    // ---- 2. 3-Pool-MRL reserve frozen
    addTransaction(await poolConfigurator.populateTransaction.setReserveFreeze(MRL_POOL_ADDRESS, true));
    const switchOff = await aaveTxs();

    // ---- 3. + 4. names, share tokens, pools
    const pools = [];
    for (const p of POOLS) pools.push(rename(p.old, p.oldShareName), rename(p.oldHusd, p.oldHusdName));
    for (const p of POOLS) {
      pools.push(
        tx.assetRegistry.register(
          ...Object.values({
            id: p.share,
            name: p.shareName,
            assetType: "StableSwap",
            existentialDeposit: SHARE_ED,
            symbol: p.shareSymbol,
            decimals: 18,
            location: null,
            xcmRateLimit: null,
            isSufficient: true,
          })
        ),
        tx.stableswap.createPool(p.share, [HOLLAR, p.aToken], AMPLIFICATION, POOL_FEE)
      );
    }

    // ---- 5. treasury seeds: stable -> aToken (1:1 wrap), then aToken + HOLLAR into the pool
    const seeds = [];
    for (const p of POOLS) {
      seeds.push(
        await asTreasuryMm(tx.router.sell(p.stable, p.aToken, SEED_STABLE.toString(), 0, [aave(p.stable, p.aToken)])),
        await asTreasuryMm(
          tx.stableswap.addAssetsLiquidity(
            p.share,
            [
              { assetId: HOLLAR, amount: SEED_HOLLAR.toString() },
              { assetId: p.aToken, amount: SEED_STABLE.toString() },
            ],
            0
          )
        )
      );
    }

    // ---- 6. reserves
    for (const p of POOLS) await hre.run("init-reserve", { symbol: p.key, batch: true });
    for (const p of POOLS) {
      addTransaction(
        await poolConfigurator.populateTransaction.setAssetEModeCategory(
          await getReserveAddress(config, p.key),
          config.EModes["StableEMode"].id
        )
      );
    }
    const reserves = await aaveTxs();

    // ---- 7. HUSDx registry entries, fee currency, treasury supplies its shares
    const husd = [];
    for (const p of POOLS) {
      husd.push(
        tx.assetRegistry.register(
          ...Object.values({
            id: p.husd,
            name: p.husdName,
            assetType: "Erc20",
            existentialDeposit: HUSD_ED,
            symbol: p.husdSymbol,
            decimals: 18,
            location: location(p.husdAddress),
            xcmRateLimit: null,
            isSufficient: true,
          })
        ),
        tx.multiTransactionPayment.addCurrency(p.husd, HUSD_FEE_PRICE)
      );
    }
    for (const p of POOLS) {
      husd.push(await asTreasuryMm(tx.router.sellAll(p.share, p.husd, 0, [aave(p.share, p.husd)])));
    }

    // ---- 8. routes
    const stored = (await api.query.router.routes.entries()).map(([k, v]) => ({
      pair: [k.args[0].assetIn.toNumber(), k.args[0].assetOut.toNumber()],
      route: v.unwrap().map((h) => ({
        pool: h.pool.isStableswap ? { Stableswap: h.pool.asStableswap.toNumber() } : h.pool.type,
        assetIn: h.assetIn.toNumber(),
        assetOut: h.assetOut.toNumber(),
      })),
    }));
    // asset-precompile reserves only (HOLLAR and the other contract reserves have their own entries)
    const reserveIds = (await pool.getReservesList())
      .filter((a) => a.toLowerCase().startsWith("0x00000000000000000000000000000001"))
      .map((a) => Number(BigInt(a) & 0xffffffffn));
    const DEAD = [MRL_POOL, aMRL_POOL];
    const routes = new Map();
    // Stored routes whose Omnipool hop names an asset the Omnipool no longer holds (GLMR, WBTC)
    // cannot trade today; they are neither re-pointed nor mirrored.
    const omnipoolAssets = (await api.query.omnipool.assets.keys()).map((k) => k.args[0].toNumber());
    const inOmnipool = (a) => a === HOLLAR || omnipoolAssets.includes(a);
    const dead = [];
    const put = (a, b, route) => {
      const [k, r] = a < b ? [`${a},${b}`, route] : [`${b},${a}`, reverse(route)];
      if (routes.has(k)) throw new Error(`route ${k} built twice`);
      if (route.some((h) => h.pool === "Omnipool" && !(inOmnipool(h.assetIn) && inOmnipool(h.assetOut)))) return dead.push(k);
      routes.set(k, simplify(r));
    };

    // 8a. every stored route through pool 105, except the ones of the dead share itself
    const skipped = [];
    for (const { pair, route } of stored) {
      if (!route.some((h) => isSs(h, MRL_POOL))) continue;
      if (pair.some((a) => DEAD.includes(a)) || route.some((h) => DEAD.includes(h.assetIn) || DEAD.includes(h.assetOut))) {
        skipped.push(pair.join(","));
        continue;
      }
      put(pair[0], pair[1], route.flatMap((h) => (isSs(h, MRL_POOL) ? replaceHop(h) : [h])));
    }
    console.log(`re-pointed ${routes.size} routes off pool 105; left as they are (3-Pool-MRL share): ${skipped.join(" ")}`);

    // 8b. liquidation routes for the new shares: share -> HOLLAR, then the tail the Wormhole
    // stables' routes already use from HOLLAR to each reserve
    const tails = new Map([[HOLLAR, []]]);
    for (const { pair, route } of stored) {
      const other = pair[0] === USDC_WH ? pair[1] : pair[1] === USDC_WH ? pair[0] : null;
      if (other === null || !reserveIds.includes(other) || DEAD.includes(other) || other === USDT_WH) continue;
      const fromStable = pair[0] === USDC_WH ? route : reverse(route);
      if (!isSs(fromStable[0], MRL_POOL) || fromStable[0].assetOut !== HOLLAR) continue;
      tails.set(other, fromStable.slice(1));
    }
    for (const p of POOLS) {
      const out = [ss(p.share, p.share, HOLLAR)];
      for (const [reserve, tail] of tails) put(p.share, reserve, [...out, ...tail]);
      // its own stable, the other Wormhole stable
      put(p.stable, p.share, [aave(p.stable, p.aToken), ss(p.share, p.aToken, p.share)]);
      const other = POOLS.find((o) => o !== p);
      put(other.stable, p.share, [...toHollar(other.stable), ss(p.share, HOLLAR, p.share)]);
    }
    put(POOLS[0].share, POOLS[1].share, [ss(POOLS[0].share, POOLS[0].share, HOLLAR), ss(POOLS[1].share, HOLLAR, POOLS[1].share)]);
    // anything else the old share has a stored route to through HOLLAR (WBTC, and the WETH / GLMR pricing routes)
    for (const p of POOLS) {
      for (const { pair, route } of stored) {
        const other = pair[0] === p.old ? pair[1] : pair[1] === p.old ? pair[0] : null;
        if (other === null || routes.has(other < p.share ? `${other},${p.share}` : `${p.share},${other}`)) continue;
        const hop = route.find((h) => isSs(h, p.old));
        if (!hop || ![hop.assetIn, hop.assetOut].includes(HOLLAR) || route.some((h) => isSs(h, MRL_POOL))) continue;
        const swap = (a) => (a === p.old ? p.share : a);
        put(
          swap(pair[0]),
          swap(pair[1]),
          route.map((h) => ({ pool: isSs(h, p.old) ? { Stableswap: p.share } : h.pool, assetIn: swap(h.assetIn), assetOut: swap(h.assetOut) }))
        );
      }
    }
    const listed = reserveIds.concat(POOLS.map((p) => p.share));
    for (const p of POOLS) {
      const missing = listed.filter((r) => r !== p.share && !routes.has(r < p.share ? `${r},${p.share}` : `${p.share},${r}`));
      console.log(`${p.shareName}: no liquidation route to reserves ${missing.join(", ") || "-"}`);
    }

    // 8c. fee-currency pricing of the new HUSDx: the old HUSDx routes with the new share
    for (const p of POOLS) {
      for (const { pair, route } of stored) {
        if (!pair.includes(p.oldHusd)) continue;
        const swap = (a) => (a === p.old ? p.share : a === p.oldHusd ? p.husd : a);
        put(
          swap(pair[0]),
          swap(pair[1]),
          route.map((h) => ({ pool: isSs(h, p.old) ? { Stableswap: p.share } : h.pool, assetIn: swap(h.assetIn), assetOut: swap(h.assetOut) }))
        );
      }
    }
    console.log(`not built, the Omnipool leg is gone: ${dead.join(" ") || "-"}`);
    const routeTxs = [];
    for (const [k, route] of routes) {
      const [assetIn, assetOut] = k.split(",").map(Number);
      console.log(`  ${k.padEnd(16)} ${show(route)}`);
      for (let i = 0; i < route.length; i++) {
        const prev = i === 0 ? assetIn : route[i - 1].assetOut;
        if (route[i].assetIn !== prev) throw new Error(`route ${k} is not continuous`);
        if (isSs(route[i], MRL_POOL)) throw new Error(`route ${k} still uses pool 105`);
      }
      if (route[route.length - 1].assetOut !== assetOut) throw new Error(`route ${k} ends in the wrong asset`);
      routeTxs.push(tx.router.forceInsertRoute({ assetIn, assetOut }, route));
    }

    // ---- 9. ICE
    const ice = POOLS.map((p) => tx.ice.updateRouting({ AaveWrap: [p.share, p.husd] }, "Included"));

    // ---- 10. HSM
    const hsm = POOLS.map((p) =>
      tx.hsm.addCollateralAsset(p.aToken, p.share, HSM.purchaseFee, HSM.maxBuyPriceCoefficient, HSM.buyBackFee, HSM.buybackRate, HSM.maxInHolding)
    );

    // ---- 11. PRIME to the rewards distributor
    const days = BigInt((PROGRAM_END - INCENTIVES_START) / 86400);
    if (days <= 0n || (PROGRAM_END - INCENTIVES_START) % 86400 !== 0) throw new Error("INCENTIVES_START must be whole days before the program end");
    const primeAmount = PRIME_PER_DAY_RAW * BigInt(POOLS.length) * days;
    const urdAccount = utils.hexlify(utils.concat([utils.toUtf8Bytes("ETH\0"), URD, new Uint8Array(8)]));
    const treasuryPrime = BigInt((await api.query.tokens.accounts(TREASURY, PRIME)).free.toString());
    console.log(
      `PRIME: ${days} days x ${POOLS.length} x 275.616 = ${Number(primeAmount) / 1e6} PRIME to ${URD} (${urdAccount}); treasury holds ${Number(treasuryPrime) / 1e6}`
    );
    if (primeAmount > treasuryPrime) throw new Error("the treasury cannot cover the PRIME transfer");
    const incentives = [await asTreasury(tx.currencies.transfer(urdAccount, PRIME, primeAmount.toString()))];

    const all = [...unwind, ...switchOff, ...pools, ...seeds, ...reserves, ...husd, ...routeTxs, ...ice, ...hsm, ...incentives];
    const preimage = await generateProposalV2(all, false);
    const decoder = new ProposalDecoder(hre);
    await decoder.init();
    console.log("submit preimage:");
    console.log(preimage.toHex());
    if (!process.env.NO_TREE) decoder.printTree(decoder.transformCall(preimage.toHuman()));
    console.log("items:", all.length, "routes:", routeTxs.length);
    console.log("hash:", preimage.hash.toHex());
    console.log("length:", preimage.encodedLength);
  }
);
