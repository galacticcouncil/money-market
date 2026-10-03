/**
 * GammaHypervisorOracleAdapter unit tests.
 *
 * The mocks are loaded from a live mainnet snapshot of the aDOT-HOLLAR Hypervisor
 * (tests/unit/gamma-adot-hollar-fixture.json, block recorded inside). The snapshot
 * also carries the vault's OWN getTotalAmounts()/getBasePosition()/getLimitPosition()
 * results at that block, so the adapter's inlined Uniswap math is checked against
 * the real contract's numbers, not against a re-implementation.
 *
 * Run: SKIP_LOAD=true npx hardhat test tests/unit/gamma-hypervisor-oracle.spec.ts
 */
import { expect } from "chai";
import { ethers } from "hardhat";
import { BigNumber } from "ethers";
import fixture from "./gamma-adot-hollar-fixture.json";

const Q96 = BigNumber.from(2).pow(96);
const E8 = BigNumber.from(10).pow(8);
const DEC0 = 10; // aDOT
const DEC1 = 18; // HOLLAR

// Floating-point reference for sqrt(1.0001^tick) * 2^96.
const sqrtRatioFloat = (tick: number) => Math.sqrt(Math.pow(1.0001, tick)) * 2 ** 96;

describe("GammaHypervisorOracleAdapter", () => {
  let pool: any, t0: any, t1: any, hyper: any, feed0: any, adapter: any;
  const bl = fixture.baseLower, bu = fixture.baseUpper, ll = fixture.limitLower, lu = fixture.limitUpper;

  const deployAdapter = async (feed1: string) => {
    const F = await ethers.getContractFactory("GammaHypervisorOracleAdapter");
    return F.deploy(hyper.address, feed0.address, feed1, "GAMMA aDOT-HOLLAR / USD");
  };

  beforeEach(async () => {
    pool = await (await ethers.getContractFactory("MockV3PoolLite")).deploy();
    t0 = await (await ethers.getContractFactory("MockERC20Lite")).deploy(DEC0);
    t1 = await (await ethers.getContractFactory("MockERC20Lite")).deploy(DEC1);
    hyper = await (await ethers.getContractFactory("MockHypervisorLite")).deploy(pool.address, t0.address, t1.address);
    await hyper.setTicks(bl, bu, ll, lu);
    await hyper.setTotalSupply(fixture.totalSupply);
    await pool.setSlot0(fixture.sqrtPriceX96, fixture.tick);
    await pool.setPosition(hyper.address, bl, bu, fixture.basePos.liquidity, fixture.basePos.owed0, fixture.basePos.owed1);
    await pool.setPosition(hyper.address, ll, lu, fixture.limitPos.liquidity, fixture.limitPos.owed0, fixture.limitPos.owed1);
    await t0.setBalance(hyper.address, fixture.idle0);
    await t1.setBalance(hyper.address, fixture.idle1);
    feed0 = await (await ethers.getContractFactory("MockFeed")).deploy(8, fixture.dia.answer);
    adapter = await deployAdapter(ethers.constants.AddressZero);
  });

  it("TickMath port matches sqrt(1.0001^tick)*2^96 for the vault's live ticks", async () => {
    for (const tick of [bl, bu, ll, lu, 0, -bl, 887272, -887272]) {
      const got = Number((await adapter.getSqrtRatioAtTick(tick)).toString());
      const ref = sqrtRatioFloat(tick);
      expect(Math.abs(got / ref - 1)).lt(1e-9, `tick ${tick}`);
    }
    expect(await adapter.getSqrtRatioAtTick(0)).eq(Q96);
  });

  it("reproduces the live vault's getTotalAmounts() exactly when evaluated at pool spot", async () => {
    const [a0, a1] = await adapter.totalAmountsAt(fixture.sqrtPriceX96);
    expect(a0).eq(BigNumber.from(fixture.total0));
    expect(a1).eq(BigNumber.from(fixture.total1));
    // and per position (base amounts = fixture.base[1..2], limit = fixture.limit[1..2])
    const base0 = a0.sub(fixture.idle0).sub(fixture.limit[1]);
    const base1 = a1.sub(fixture.idle1).sub(fixture.limit[2]);
    expect(base0).eq(BigNumber.from(fixture.base[1]));
    expect(base1).eq(BigNumber.from(fixture.base[2]));
  });

  it("fair sqrt price is derived from the feeds, not the pool", async () => {
    const p0 = BigNumber.from(fixture.dia.answer);
    // price(token1 raw per token0 raw) = p0/1 * 10^18 / 10^10
    const ratioX192 = p0.mul(BigNumber.from(10).pow(DEC1)).mul(BigNumber.from(2).pow(192)).div(E8.mul(BigNumber.from(10).pow(DEC0)));
    const fair = await adapter.fairSqrtPriceX96();
    // sqrt check: fair^2 <= ratio < (fair+1)^2
    expect(fair.mul(fair)).lte(ratioX192);
    expect(fair.add(1).mul(fair.add(1))).gt(ratioX192);
    // and it differs from the pool spot (DOT feed 1.2044 vs pool ~1.2185)
    expect(fair).not.eq(BigNumber.from(fixture.sqrtPriceX96));
  });

  it("latestAnswer = fair-value NAV per share in USD (8 dec), HOLLAR fixed at $1", async () => {
    const fair = await adapter.fairSqrtPriceX96();
    const [a0, a1] = await adapter.totalAmountsAt(fair);
    const p0 = BigNumber.from(fixture.dia.answer);
    const usd = a0.mul(p0).div(BigNumber.from(10).pow(DEC0)).add(a1.mul(E8).div(BigNumber.from(10).pow(DEC1)));
    const expected = usd.mul(BigNumber.from(10).pow(18)).div(fixture.totalSupply);
    const answer = await adapter.latestAnswer();
    expect(answer).eq(expected);
    // sanity: a HOLLAR-denominated share minted near 1.0 should be worth ~$0.9-1.0
    const f = Number(answer.toString()) / 1e8;
    expect(f).gt(0.85).and.lt(1.05);
    console.log(`      fair NAV/share = $${f.toFixed(6)}  spot NAV/share = $${(Number((await adapter.spotAnswer()).toString()) / 1e8).toFixed(6)}`);
  });

  it("is invariant to pool spot manipulation; spotAnswer() is not", async () => {
    const base = await adapter.latestAnswer();
    const spotBase = await adapter.spotAnswer();
    for (const mult of [0.5, 0.9, 1.1, 2.0, 10.0]) {
      const s = BigNumber.from(fixture.sqrtPriceX96).mul(Math.round(Math.sqrt(mult) * 1e6)).div(1e6);
      await pool.setSlot0(s, fixture.tick);
      expect(await adapter.latestAnswer()).eq(base);
      expect(await adapter.spotAnswer()).not.eq(spotBase);
    }
  });

  it("tracks the feed (a 10% DOT move lifts the share by the aDOT weight only)", async () => {
    const base = await adapter.latestAnswer();
    const fair = await adapter.fairSqrtPriceX96();
    const [a0, a1] = await adapter.totalAmountsAt(fair);
    const p0 = BigNumber.from(fixture.dia.answer);
    const v0 = a0.mul(p0).div(BigNumber.from(10).pow(DEC0));
    const v1 = a1.mul(E8).div(BigNumber.from(10).pow(DEC1));
    const w0 = Number(v0.toString()) / Number(v0.add(v1).toString());
    await feed0.setAnswer(p0.mul(110).div(100));
    const up = await adapter.latestAnswer();
    const rel = Number(up.toString()) / Number(base.toString()) - 1;
    // concave in price (IL), so strictly below the linear w0*10% but well above 0
    expect(rel).gt(0.5 * w0 * 0.1).and.lt(w0 * 0.1);
  });

  it("counts tokensOwed and idle balances", async () => {
    const base = await adapter.latestAnswer();
    await pool.setPosition(hyper.address, bl, bu, fixture.basePos.liquidity, 0, ethers.utils.parseUnits("1000", DEC1));
    const withOwed = await adapter.latestAnswer();
    const perShare = ethers.utils.parseUnits("1000", DEC1).mul(E8).div(BigNumber.from(10).pow(DEC1)).mul(BigNumber.from(10).pow(18)).div(fixture.totalSupply);
    expect(withOwed.sub(base)).closeTo(perShare, 2);
    await t1.setBalance(hyper.address, BigNumber.from(fixture.idle1).add(ethers.utils.parseUnits("1000", DEC1)));
    expect((await adapter.latestAnswer()).sub(withOwed)).closeTo(perShare, 2);
  });

  it("uses feed1 when given (HOLLAR at $0.98 lowers the share by the HOLLAR weight)", async () => {
    const feed1 = await (await ethers.getContractFactory("MockFeed")).deploy(8, 98_000_000);
    const a2 = await deployAdapter(feed1.address);
    const base = await adapter.latestAnswer();
    const dep = await a2.latestAnswer();
    expect(dep).lt(base);
    expect(Number(dep.toString()) / Number(base.toString())).gt(0.98).and.lt(1.0);
  });

  it("guards: zero supply -> 0; bad feed -> revert; wrong feed decimals -> revert", async () => {
    await hyper.setTotalSupply(0);
    expect(await adapter.latestAnswer()).eq(0);
    await hyper.setTotalSupply(fixture.totalSupply);
    await feed0.setAnswer(0);
    await expect(adapter.latestAnswer()).to.be.revertedWith("feed0 price");
    const bad = await (await ethers.getContractFactory("MockFeed")).deploy(18, 1);
    const F = await ethers.getContractFactory("GammaHypervisorOracleAdapter");
    await expect(F.deploy(hyper.address, bad.address, ethers.constants.AddressZero, "x")).to.be.revertedWith("feed0 decimals");
  });

  it("Chainlink surface: decimals 8, latestRoundData answer == latestAnswer", async () => {
    expect(await adapter.decimals()).eq(8);
    const [, answer] = await adapter.latestRoundData();
    expect(answer).eq(await adapter.latestAnswer());
    expect(await adapter.description()).eq("GAMMA aDOT-HOLLAR / USD");
  });
});
