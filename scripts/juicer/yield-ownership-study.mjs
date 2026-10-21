// Exact-rational accounting study, not contract execution or a liquidity model.
// Collateral and HOLLAR have unit price; source NAV includes accrued source yield.
import { pathToFileURL } from 'node:url';

const gcd = (a, b) => b === 0n ? (a < 0n ? -a : a) : gcd(b, a % b);
export class Q {
  constructor(n, d = 1n) {
    n = BigInt(n); d = BigInt(d);
    if (d === 0n) throw new Error('zero denominator');
    if (d < 0n) { n = -n; d = -d; }
    const g = gcd(n, d); this.n = n / g; this.d = d / g;
  }
  add(b) { b = q(b); return new Q(this.n * b.d + b.n * this.d, this.d * b.d); }
  sub(b) { return this.add(q(b).mul(-1)); }
  mul(b) { b = q(b); return new Q(this.n * b.n, this.d * b.d); }
  div(b) { b = q(b); return new Q(this.n * b.d, this.d * b.n); }
  lt(b) { return this.sub(b).n < 0n; }
  eq(b) { return this.sub(b).n === 0n; }
  toString() { return this.d === 1n ? `${this.n}` : `${this.n}/${this.d}`; }
  toJSON() { return this.toString(); }
}
const q = value => value instanceof Q ? value : new Q(value);
const min = (a, b) => a.lt(b) ? a : b;

export class OwnershipStudy {
  collateral = q(0);
  shares = q(0);
  sourceEquity = q(0);
  sourceUnits = q(0);
  owners = new Map();
  sharePrice() { return this.shares.eq(0) ? q(1) : this.collateral.div(this.shares); }
  sourcePrice() { return this.sourceUnits.eq(0) ? q(1) : this.sourceEquity.div(this.sourceUnits); }
  deposit(owner, collateral, seed = collateral) {
    if (this.owners.has(owner)) throw new Error('study uses a separate cohort for each entry');
    collateral = q(collateral); seed = q(seed);
    if (!q(0).lt(collateral) || !q(0).lt(seed)) throw new Error('nonpositive deposit');
    const shares = collateral.div(this.sharePrice());
    const units = seed.div(this.sourcePrice());
    this.collateral = this.collateral.add(collateral); this.shares = this.shares.add(shares);
    this.sourceEquity = this.sourceEquity.add(seed); this.sourceUnits = this.sourceUnits.add(units);
    this.owners.set(owner, { shares, units, principal: seed, interest: q(0) });
  }
  collateralClaim(owner) { return this.owners.get(owner).shares.mul(this.sharePrice()); }
  sourceValue(owner) { return this.owners.get(owner).units.mul(this.sourcePrice()); }
  grossCarry(owner) { return this.sourceValue(owner).sub(this.owners.get(owner).principal); }
  accrue(amount) { this.sourceEquity = this.sourceEquity.add(amount); }
  interest(owner, amount) { const p = this.owners.get(owner); p.interest = p.interest.add(amount); }
  harvest(owner, gross, { fee = q(0), executionLoss = q(0), retain = q(0) } = {}) {
    gross = q(gross); fee = q(fee); executionLoss = q(executionLoss); retain = q(retain);
    if (gross.lt(0) || retain.lt(0) || fee.lt(0) || q(1).lt(fee) ||
        executionLoss.lt(0) || q(1).lt(executionLoss) || this.grossCarry(owner).sub(retain).lt(gross)) {
      throw new Error('cannot spend another cohort or principal');
    }
    const p = this.owners.get(owner);
    // Removing value must burn only the owning cohort's source units. Otherwise
    // every other depositor suffers the same NAV drop without receiving cash.
    const burn = gross.div(this.sourcePrice());
    p.units = p.units.sub(burn); this.sourceUnits = this.sourceUnits.sub(burn);
    this.sourceEquity = this.sourceEquity.sub(gross);
    const lost = gross.mul(executionLoss);
    const received = gross.sub(lost);
    const feePaid = received.mul(fee);
    const interestPaid = min(p.interest, received.sub(feePaid));
    p.interest = p.interest.sub(interestPaid);
    const reward = received.sub(feePaid).sub(interestPaid);
    // These shares can be allocated through a funded reward escrow; the model
    // materializes the beneficiary immediately and does not model gas/indexes.
    const minted = reward.div(this.sharePrice());
    p.shares = p.shares.add(minted); this.shares = this.shares.add(minted);
    this.collateral = this.collateral.add(reward);
    return { gross, lost, feePaid, interestPaid, reward };
  }
}

function example() {
  const study = new OwnershipStudy();
  study.deposit('incumbent', 1);
  study.accrue(new Q(1, 10));
  study.interest('incumbent', new Q(1, 50));
  study.deposit('entrant', 1);
  const result = study.harvest('incumbent', new Q(3, 50), { fee: new Q(1, 20), retain: new Q(1, 25) });
  return {
    assumptions: 'Exact arithmetic; unit collateral/HOLLAR price; no route impact, leverage or gas simulation.',
    rejectedNavPricingEntrantBeforeHarvest: new Q(20, 21),
    collateralClaims: { incumbent: study.collateralClaim('incumbent'), entrant: study.collateralClaim('entrant') },
    retainedCarry: { incumbent: study.grossCarry('incumbent'), entrant: study.grossCarry('entrant') },
    harvest: result,
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) console.log(JSON.stringify(example(), null, 2));
