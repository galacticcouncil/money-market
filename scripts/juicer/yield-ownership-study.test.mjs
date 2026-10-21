import assert from 'node:assert/strict';
import test from 'node:test';
import { Q, OwnershipStudy } from './yield-ownership-study.mjs';

const same = (a, b) => assert.ok(a.eq(b), `${a} != ${b}`);
function seed() {
  const s = new OwnershipStudy();
  s.deposit('old', 1); s.accrue(new Q(1, 10)); s.deposit('new', 1);
  return s;
}

test('new collateral shares buy no old source yield and retain their full collateral claim', () => {
  const s = seed();
  same(s.collateralClaim('new'), 1); same(s.grossCarry('new'), 0);
  same(s.grossCarry('old'), new Q(1, 10));
});
test('partial harvest keeps source NAV and the entrant claim unchanged', () => {
  const s = seed(); const nav = s.sourcePrice();
  s.harvest('old', new Q(1, 20));
  same(s.sourcePrice(), nav); same(s.sourceValue('new'), 1);
  same(s.collateralClaim('new'), 1); same(s.collateralClaim('old'), new Q(21, 20));
  same(s.grossCarry('old'), new Q(1, 20));
});
test('retained yield stays with its owner through entry and a later release', () => {
  const s = seed();
  s.harvest('old', new Q(3, 50), { retain: new Q(1, 25) });
  same(s.grossCarry('old'), new Q(1, 25)); same(s.grossCarry('new'), 0);
  s.harvest('old', new Q(1, 25));
  same(s.collateralClaim('old'), new Q(11, 10)); same(s.collateralClaim('new'), 1);
});
test('actual execution output pays fees, then owned Main interest, then rewards', () => {
  const s = seed(); s.interest('old', new Q(1, 50));
  const r = s.harvest('old', new Q(1, 10), { fee: new Q(1, 20), executionLoss: new Q(1, 100) });
  same(r.lost.add(r.feePaid).add(r.interestPaid).add(r.reward), r.gross);
  same(r.reward, new Q(1481, 20000)); same(s.collateralClaim('new'), 1);
  same(s.owners.get('old').interest, 0);
});
test('insufficient fresh yield leaves interest unpaid without spending collateral', () => {
  const s = seed(); s.interest('old', new Q(1, 5));
  s.harvest('old', new Q(1, 10));
  same(s.collateralClaim('old'), 1); same(s.collateralClaim('new'), 1);
  same(s.owners.get('old').interest, new Q(1, 10));
});
test('an entrant cannot harvest the incumbent reserve or source principal', () => {
  const s = seed();
  assert.throws(() => s.harvest('new', new Q(1, 100)), /principal/);
  assert.throws(() => s.harvest('old', new Q(1, 10), { retain: new Q(1, 25) }), /principal/);
});
test('yield earned after entry follows each cohort source units', () => {
  const s = seed(); s.accrue(new Q(21, 100));
  same(s.grossCarry('old'), new Q(21, 100));
  same(s.grossCarry('new'), new Q(1, 10));
});
test('many partial realizations preserve funded collateral and untouched source ownership', () => {
  const s = seed(); const nav = s.sourcePrice();
  for (let i = 0; i < 100; ++i) {
    s.harvest('old', new Q(1, 1000));
    same(s.sharePrice(), 1); same(s.sourcePrice(), nav);
    same(s.collateralClaim('new'), 1); same(s.sourceValue('new'), 1);
  }
  same(s.collateralClaim('old'), new Q(11, 10)); same(s.grossCarry('old'), 0);
});
