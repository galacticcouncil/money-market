// Lark only: test inventory for the market bots, sized from what their logs say
// they lacked, through the seed mechanism (lark-seed.mjs). One referendum per --round.
import assert from 'node:assert/strict';
import {context} from './lark-context.mjs';
import {seedRound} from './lark-seed.mjs';
const round=process.argv.find(a=>a.startsWith('--round='))?.split('=')[1];
assert.ok(round,'usage: --round=<name> [--live]');
// [bot, asset, units to mint, aToken to supply it into (optional)]
const PLANS={
 '20261008-a':[
  ['replay',22,300000,1003],['replay',10,150000,1002],['replay',1000765,0.5,1006],['replay',5,20000],['replay',5,20000,1001],
  ['replay',38,20000],['replay',35,5000],
  ['pools',22,50000],
  ['markets',43,100000],
 ],
 // the loop's ramp plus replayed mainnet PRIME buys outrun PRIME's fuse window
 '20261008-b':[['markets',43,300000]],
};
// lark-only deposit fuse raises (units per window), applied before the mints
const RAISES={'20261008-b':[[43,5000000]]};
// a new lark starts with everything the lark 4 bots reported missing
// a fresh fork's ENA window has used more of its fuse than lark 4's had
PLANS.baseline=[...PLANS['20261008-a'],...PLANS['20261008-b']];RAISES.baseline=[...RAISES['20261008-b'],[38,100000]];
const plan=PLANS[round];
assert.ok(plan,`unknown round ${round}`);
const c=await context();
try{await seedRound(c,{round,plan,raises:RAISES[round]??[]});}finally{await c.api.disconnect();}
