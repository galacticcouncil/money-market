// Read-only: recompute the Gamma share fair value from live chain state in JS and
// compare with the vault's own spot NAV (and, if deployed, with the adapter).
//   node scripts/gamma-oracle-live-check.mjs [adapterAddress]
import { ethers } from "ethers";
const RPC = process.env.RPC || "https://rpc.hydradx.cloud";
const HYPER = process.env.HYPERVISOR || "0xa206D0959813f17c17C87147271C49065438648A";
const FEED0 = process.env.FEED0 || "0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702"; // DIA DOT/USD
const P1 = 1e8; // HOLLAR fixed $1
const p = new ethers.providers.JsonRpcProvider(RPC);
const hyper = new ethers.Contract(HYPER, [
  "function pool() view returns (address)", "function token0() view returns (address)", "function token1() view returns (address)",
  "function baseLower() view returns (int24)", "function baseUpper() view returns (int24)", "function limitLower() view returns (int24)", "function limitUpper() view returns (int24)",
  "function totalSupply() view returns (uint256)", "function getTotalAmounts() view returns (uint256,uint256)"], p);
const poolAbi = ["function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)", "function positions(bytes32) view returns (uint128,uint256,uint256,uint128,uint128)"];
const erc = ["function balanceOf(address) view returns (uint256)", "function decimals() view returns (uint8)"];
const [poolAddr, t0a, t1a, bl, bu, ll, lu, supply, [tot0, tot1]] = await Promise.all([hyper.pool(), hyper.token0(), hyper.token1(), hyper.baseLower(), hyper.baseUpper(), hyper.limitLower(), hyper.limitUpper(), hyper.totalSupply(), hyper.getTotalAmounts()]);
const pool = new ethers.Contract(poolAddr, poolAbi, p), t0 = new ethers.Contract(t0a, erc, p), t1 = new ethers.Contract(t1a, erc, p);
const feed = new ethers.Contract(FEED0, ["function latestAnswer() view returns (int256)"], p);
const [slot, d0, d1, idle0, idle1, p0] = await Promise.all([pool.slot0(), t0.decimals(), t1.decimals(), t0.balanceOf(HYPER), t1.balanceOf(HYPER), feed.latestAnswer()]);
const key = (lo, up) => ethers.utils.solidityKeccak256(["address", "int24", "int24"], [HYPER, lo, up]);
const [base, limit] = await Promise.all([pool.positions(key(bl, bu)), pool.positions(key(ll, lu))]);
const B = (x) => BigInt(x.toString());
const Q96 = 1n << 96n;
const sqrtAtTick = (t) => BigInt(Math.round(Math.sqrt(1.0001 ** t) * 1e15)) * Q96 / BigInt(1e15); // float ref (~1e-12), fine for a check
const isqrt = (n) => { if (n < 2n) return n; let x = BigInt(Math.floor(Math.sqrt(Number(n)))); for (let i = 0; i < 64; i++) { const y = (x + n / x) >> 1n; if (y >= x && x * x <= n && (x + 1n) * (x + 1n) > n) break; x = y; } while (x * x > n) x--; while ((x + 1n) * (x + 1n) <= n) x++; return x; };
const amounts = (sP, sA, sB, L) => { if (sA > sB) [sA, sB] = [sB, sA]; const a0 = (a, b) => (L << 96n) * (b - a) / b / a, a1 = (a, b) => L * (b - a) / Q96; if (sP <= sA) return [a0(sA, sB), 0n]; if (sP < sB) return [a0(sP, sB), a1(sA, sP)]; return [0n, a1(sA, sB)]; };
const total = (sP) => { const [b0, b1] = amounts(sP, sqrtAtTick(bl), sqrtAtTick(bu), B(base[0])); const [l0, l1] = amounts(sP, sqrtAtTick(ll), sqrtAtTick(lu), B(limit[0])); return [B(idle0) + b0 + l0 + B(base[3]) + B(limit[3]), B(idle1) + b1 + l1 + B(base[4]) + B(limit[4])]; };
const usdPerShare = ([a0, a1]) => Number((a0 * B(p0) / 10n ** BigInt(d0) + a1 * BigInt(P1) / 10n ** BigInt(d1)) * 10n ** 18n / B(supply)) / 1e8;
const fairSqrt = isqrt(B(p0) * 10n ** BigInt(d1) * (1n << 192n) / (BigInt(P1) * 10n ** BigInt(d0)));
const spotSqrt = B(slot[0]);
const spotPrice = Number(spotSqrt * spotSqrt * 10n ** 18n / (1n << 192n)) / 1e18 * 10 ** (d0 - d1);
console.log(`block ${await p.getBlockNumber()}  DIA DOT/USD ${Number(p0) / 1e8}  pool aDOT/HOLLAR ${spotPrice.toFixed(6)}  ticks base[${bl},${bu}] limit[${ll},${lu}]`);
console.log(`vault getTotalAmounts  : ${Number(tot0) / 10 ** d0} aDOT + ${Number(tot1) / 10 ** d1} HOLLAR  (spot NAV/share $${usdPerShare([B(tot0), B(tot1)]).toFixed(6)} at DIA prices)`);
const js = total(spotSqrt); console.log(`JS amounts @ pool spot : ${Number(js[0]) / 10 ** d0} aDOT + ${Number(js[1]) / 10 ** d1} HOLLAR  (should match the line above)`);
const fair = total(fairSqrt); console.log(`JS amounts @ DIA price : ${Number(fair[0]) / 10 ** d0} aDOT + ${Number(fair[1]) / 10 ** d1} HOLLAR  -> FAIR NAV/share $${usdPerShare(fair).toFixed(6)}`);
if (process.argv[2]) { const a = new ethers.Contract(process.argv[2], ["function latestAnswer() view returns (int256)", "function spotAnswer() view returns (int256)"], p); const [la, sa] = await Promise.all([a.latestAnswer(), a.spotAnswer()]); console.log(`adapter ${process.argv[2]}: latestAnswer $${Number(la) / 1e8}  spotAnswer $${Number(sa) / 1e8}`); }
