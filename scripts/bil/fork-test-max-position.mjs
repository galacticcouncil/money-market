// Mainnet upgrade rehearsal for the BIL MAX_POSITION split, on a GC chopsticks
// fork of Hydration (ws :8000). Deploys the new QueueLib + linked BILVault impl
// via Root-injected evm.create, upgrades the live proxy as governance
// (dispatchAsAaveManager), checks state survived, then deposits 250k for real
// through the live Decentral pool and checks it lands as three ~83.3k pieces.
//
// Usage (fork running):  node scripts/bil/fork-test-max-position.mjs
import { ApiPromise, WsProvider } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import { compactToU8a, hexToU8a, u8aToHex, u8aConcat } from "@polkadot/util";
import { ethers } from "ethers";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const WS = process.env.WS ?? "ws://127.0.0.1:8000";
const OUT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../bil-vault/out");
const VAULT = "0x6a21891Db0940491603f3ccA0a9f4DBA4c6E810C";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const ALICE_SS58 = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY";
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const WETH = 20;
const CAP = ethers.utils.parseEther("100000");
const DEPOSIT = ethers.utils.parseEther("250000");

const vaultI = new ethers.utils.Interface([
  "function upgradeTo(address)",
  "function setTvlCap(uint256)",
  "function tvlCap() view returns (uint256)",
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function exchangeRate() view returns (uint256)",
  "function idleHollar() view returns (uint256)",
  "function totalInvestedPrincipal() view returns (uint256)",
  "function yieldRateSum() view returns (uint256)",
  "function totalQueuedBil() view returns (uint256)",
  "function totalSettledBil() view returns (uint256)",
  "function totalReservedHollar() view returns (uint256)",
  "function getPositionCount() view returns (uint256)",
  "function getPositionHead() view returns (uint256)",
  "function getPosition(uint256) view returns (uint256,uint256,uint256,uint256,uint256,uint8)",
  "function hasRole(bytes32,address) view returns (bool)",
  "function activeDepositPool() view returns (address)",
  "function balanceOf(address) view returns (uint256)",
  "function syncMaturities(uint256) returns (uint256)",
  "function deposit(uint256,address) returns (uint256)",
  "function pokeQueue()",
]);
const ercI = new ethers.utils.Interface([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
]);
const fmt = (v) => Number(ethers.utils.formatEther(v)).toLocaleString("en-US", { maximumFractionDigits: 4 });
let failures = 0;
const check = (ok, msg) => {
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${msg}`);
  if (!ok) failures++;
};

function artifact(name) {
  return JSON.parse(fs.readFileSync(`${OUT}/${name}.sol/${name}.json`));
}

function linked(art, libs) {
  let code = art.bytecode.object.replace(/^0x/, "");
  for (const [, byName] of Object.entries(art.bytecode.linkReferences ?? {})) {
    for (const [name, refs] of Object.entries(byName)) {
      const addr = libs[name].toLowerCase().replace(/^0x/, "");
      for (const { start, length } of refs) code = code.slice(0, start * 2) + addr + code.slice((start + length) * 2);
    }
  }
  if (code.includes("__$")) throw new Error("unlinked library placeholder left");
  return "0x" + code;
}

async function main() {
  const provider = new WsProvider(WS, 2500, {}, 600000);
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const send = (m, p) => provider.send(m, p);

  // runtime-api eth_call against the latest fork block
  const rpc = async (to, data, from = ALICE_EVM, estimate = false) => {
    const res = await api.call.ethereumRuntimeRPCApi.call(from, to, data, "0", "30000000", null, null, null, estimate, null, null);
    return res.toJSON();
  };
  const view = async (iface, to, fn, args = []) => {
    const r = await rpc(to, iface.encodeFunctionData(fn, args));
    const out = r?.ok?.value ?? r?.Ok?.value;
    return iface.decodeFunctionResult(fn, out);
  };
  const v = async (fn, args = []) => (await view(vaultI, VAULT, fn, args))[0];
  const position = (i) => view(vaultI, VAULT, "getPosition", [i]);
  const storage = async (addr, slot) => (await api.query.evm.accountStorages(addr, slot)).toHex();

  async function enactRoot(innerHex, label) {
    const hash = blake2AsHex(innerHex), len = (innerHex.length - 2) / 2, body = hexToU8a(innerHex);
    await send("dev_setStorage", [[[api.query.preimage.preimageFor.key([hash, len]), u8aToHex(u8aConcat(compactToU8a(body.length), body))]]]);
    const sn = api.query.preimage.requestStatusFor ? "RequestStatusFor" : "StatusFor";
    await send("dev_setStorage", [{ Preimage: { [sn]: [[[hash], { Requested: { maybeTicket: null, count: 1, maybeLen: len } }]] } }]);
    const target = (await api.rpc.chain.getHeader()).number.toNumber() + 1;
    await send("dev_setStorage", [{ Scheduler: { Agenda: [[[target], [{ maybeId: null, priority: 0, call: { Lookup: { hash_: hash, len } }, maybePeriodic: null, origin: { system: "Root" } }]]] } }]);
    await send("dev_newBlock", [{ count: 1 }]);
    const evs = await (await api.at((await api.rpc.chain.getBlockHash(target)).toHex())).query.system.events();
    let created = null, failed = [];
    for (const { event } of evs) {
      const k = `${event.section}.${event.method}`;
      const d = JSON.stringify(event.data.toJSON());
      if (k === "evm.Created") created = event.data.toJSON()[0];
      if (/ExecutedFailed|CreatedFailed|BatchInterrupted|DispatchedAs/.test(event.method) && (/ExecutedFailed|CreatedFailed|BatchInterrupted/.test(event.method) || /"err"/i.test(d))) failed.push(`${k} ${d.slice(0, 200)}`);
      if (k === "scheduler.Dispatched" && /"err"/i.test(d)) failed.push(`${k} ${d.slice(0, 200)}`);
    }
    if (failed.length) console.log(`  [${label}] failures:\n    ${failed.join("\n    ")}`);
    return { created, ok: failed.length === 0 };
  }

  const dispatchAs = (call) => api.tx.utility.dispatchAs({ system: { signed: ALICE_SS58 } }, call);
  const evmCreate = (code) => api.tx.evm.create(ALICE_EVM, code, "0", "15000000", "600000000", null, null, [], []);
  const evmCall = (from, to, data, gas = "15000000") => api.tx.evm.call(from, to, data, "0", gas, "600000000", null, null, [], []);
  const asAlice = (to, data) => dispatchAs(evmCall(ALICE_EVM, to, data));
  const asGov = (to, data) => api.tx.dispatcher.dispatchAsAaveManager(evmCall(GOV, to, data, "3000000"));

  const head0 = (await api.rpc.chain.getHeader()).number.toNumber();
  console.log(`fork head ${head0}`);

  // ── fund Alice: WETH for gas on both account forms, deployer whitelist ──
  const ethPrefixed = u8aToHex(u8aConcat(hexToU8a("0x45544800"), hexToU8a(ALICE_EVM), new Uint8Array(8)));
  const rich = { free: ethers.utils.parseEther("1000").toString(), reserved: 0, frozen: 0 };
  await send("dev_setStorage", [{ Tokens: { Accounts: [[[ALICE_SS58, WETH], rich], [[ethPrefixed, WETH], rich]] } }]);
  await send("dev_setStorage", [[[api.query.evmAccounts.contractDeployer.key(ALICE_EVM), "0x"]]]);

  // ── snapshot ──
  const snap = async () => {
    const head = await v("getPositionHead"), count = await v("getPositionCount");
    const sample = [];
    for (const i of [head.toNumber(), head.toNumber() + 1, count.toNumber() - 2, count.toNumber() - 1]) sample.push((await position(i)).map(String).join(","));
    return {
      impl: await storage(VAULT, IMPL_SLOT),
      totalAssets: await v("totalAssets"), totalSupply: await v("totalSupply"), exchangeRate: await v("exchangeRate"),
      idle: await v("idleHollar"), invested: await v("totalInvestedPrincipal"), rateSum: await v("yieldRateSum"),
      queued: await v("totalQueuedBil"), settled: await v("totalSettledBil"), reserved: await v("totalReservedHollar"),
      head: head.toNumber(), count: count.toNumber(), tvlCap: await v("tvlCap"), sample,
      upgrader: await v("hasRole", [ethers.utils.id("UPGRADER_ROLE"), GOV]),
      admin: await v("hasRole", [ethers.utils.id("ADMIN_ROLE"), GOV]),
    };
  };
  const pre = await snap();
  console.log(`pre: impl ${"0x" + pre.impl.slice(-40)}  positions ${pre.count} (head ${pre.head})  totalAssets ${fmt(pre.totalAssets)}  rate ${fmt(pre.exchangeRate)}  tvlCap ${fmt(pre.tvlCap)}`);

  // ── deploy new QueueLib + linked impl ──
  console.log("=== deploy new QueueLib + BILVault impl (Root evm.create) ===");
  const lib = await enactRoot(api.tx.utility.batchAll([dispatchAs(evmCreate(artifact("QueueLib").bytecode.object))]).method.toHex(), "QueueLib");
  check(lib.ok && lib.created, `QueueLib deployed at ${lib.created}`);
  const implCode = linked(artifact("BILVault"), { QueueLib: lib.created });
  const impl = await enactRoot(api.tx.utility.batchAll([dispatchAs(evmCreate(implCode))]).method.toHex(), "BILVault impl");
  check(impl.ok && impl.created, `BILVault impl deployed at ${impl.created}`);
  const runtime = (await api.query.evm.accountCodes(impl.created)).toHex();
  check((runtime.length - 2) / 2 <= 24576, `impl runtime ${(runtime.length - 2) / 2} bytes ≤ EIP-170`);

  // ── upgrade as governance ──
  console.log("=== upgradeTo as governance (dispatchAsAaveManager) ===");
  const up = await enactRoot(api.tx.utility.batchAll([asGov(VAULT, vaultI.encodeFunctionData("upgradeTo", [impl.created]))]).method.toHex(), "upgradeTo");
  const post = await snap();
  check(up.ok && post.impl.toLowerCase().endsWith(impl.created.toLowerCase().slice(2)), `proxy now points at ${"0x" + post.impl.slice(-40)}`);
  for (const k of ["idle", "invested", "rateSum", "queued", "settled", "reserved", "totalSupply", "tvlCap"]) check(pre[k].eq(post[k]), `${k} unchanged (${fmt(post[k])})`);
  check(pre.head === post.head && pre.count === post.count, `positions unchanged (${post.count}, head ${post.head})`);
  check(JSON.stringify(pre.sample) === JSON.stringify(post.sample), "sampled position records identical");
  check(post.upgrader && post.admin, "governance still holds UPGRADER + ADMIN");
  const drift = post.exchangeRate.sub(pre.exchangeRate).abs();
  check(drift.lte(pre.exchangeRate.div(1_000_000)), `exchange rate ${fmt(post.exchangeRate)} (one block of accrual: Δ ${drift} wei)`);

  // ── raise the cap so a 250k deposit fits (vault is at its cap on mainnet) ──
  const newCap = pre.totalAssets.add(ethers.utils.parseEther("1000000"));
  const capR = await enactRoot(api.tx.utility.batchAll([asGov(VAULT, vaultI.encodeFunctionData("setTvlCap", [newCap]))]).method.toHex(), "setTvlCap");
  check(capR.ok && (await v("tvlCap")).eq(newCap), `tvlCap raised to ${fmt(newCap)}`);

  // ── fund Alice with HOLLAR by finding the ERC20 balance slot from a known holder ──
  const vaultHollar = (await view(ercI, HOLLAR, "balanceOf", [VAULT]))[0];
  let slot = -1;
  for (let s = 0; s < 64 && slot < 0; s++) {
    const key = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [VAULT, s]));
    if (ethers.BigNumber.from(await storage(HOLLAR, key)).eq(vaultHollar) && !vaultHollar.isZero()) slot = s;
  }
  check(slot >= 0, `HOLLAR balance mapping at slot ${slot}`);
  const aliceKey = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [ALICE_EVM, slot]));
  await send("dev_setStorage", [[[api.query.evm.accountStorages.key(HOLLAR, aliceKey), ethers.utils.hexZeroPad(ethers.utils.parseEther("300000").toHexString(), 32)]]]);
  check((await view(ercI, HOLLAR, "balanceOf", [ALICE_EVM]))[0].eq(ethers.utils.parseEther("300000")), "Alice holds 300k HOLLAR");

  // ── approve + sync, then measure and run the 250k deposit ──
  const pool = (await v("activeDepositPool"));
  const poolBefore = (await view(ercI, HOLLAR, "balanceOf", [pool]))[0];
  const prep = await enactRoot(api.tx.utility.batchAll([
    asAlice(HOLLAR, ercI.encodeFunctionData("approve", [VAULT, ethers.constants.MaxUint256])),
    asAlice(VAULT, vaultI.encodeFunctionData("syncMaturities", [50])),
  ]).method.toHex(), "approve+sync");
  check(prep.ok, "approve + syncMaturities");

  const depositData = vaultI.encodeFunctionData("deposit", [DEPOSIT, ALICE_EVM]);

  const countBefore = (await v("getPositionCount")).toNumber();
  const investedBefore = await v("totalInvestedPrincipal");
  const dep = await enactRoot(api.tx.utility.batchAll([asAlice(VAULT, depositData)]).method.toHex(), "deposit 250k");
  const countAfter = (await v("getPositionCount")).toNumber();
  check(dep.ok && countAfter - countBefore === 3, `deposit created ${countAfter - countBefore} positions`);
  let sum = ethers.constants.Zero;
  const maturities = new Set();
  for (let i = countBefore; i < countAfter; i++) {
    const [tokenId, principal, , , maturity, state] = await position(i);
    console.log(`    pos ${i}: token ${tokenId}  ${fmt(principal)} HOLLAR  state ${state}  matures ${new Date(maturity.toNumber() * 1000).toISOString()}`);
    check(principal.lte(CAP) && principal.gt(CAP.div(2)), `pos ${i} within (50k, 100k]`);
    sum = sum.add(principal);
    maturities.add(maturity.toString());
  }
  check(sum.eq(DEPOSIT), `pieces sum to ${fmt(sum)}`);
  check(maturities.size === 1, "pieces share one maturity");
  check((await v("totalInvestedPrincipal")).sub(investedBefore).eq(DEPOSIT), "totalInvestedPrincipal +250k");
  check((await view(ercI, HOLLAR, "balanceOf", [pool]))[0].sub(poolBefore).eq(DEPOSIT), "Decentral pool received 250k");
  check((await v("balanceOf", [ALICE_EVM])).gt(0), `Alice minted ${fmt(await v("balanceOf", [ALICE_EVM]))} BIL`);

  // ── keeper path still works on the new impl ──
  const poke = await enactRoot(api.tx.utility.batchAll([asAlice(VAULT, vaultI.encodeFunctionData("pokeQueue"))]).method.toHex(), "pokeQueue");
  check(poke.ok, "pokeQueue succeeds after upgrade");

  console.log(failures ? `\n${failures} check(s) FAILED` : "\nall checks passed");
  await api.disconnect();
  process.exit(failures ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
