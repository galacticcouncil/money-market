// PLACEHOLDER(track B, plan step 4): the controller's ICE actions and async lanes. Track B
// settles the interfaces (two-phase consume, recordAsync, intent entry, harvest and exit
// callbacks, reconcile); this step then configures, on the new Lark:
//  - configureAction for every new keeper entry point (intent entry, reconcile);
//  - the async lanes: entry (HOLLAR -> aPRIME), unwind, both harvest lanes;
//  - who may call recordAsync (the source and both vaults);
// and marks r.checks.iceWiring. Until then it refuses to run.
import assert from 'node:assert/strict';
import {artifact} from './lark-context.mjs';
assert.ok(artifact('ExecutionController').abi.some(x=>x.name==='recordAsync'),'placeholder: async lanes arrive with track B; point PROPELLER_ARTIFACT_DIR at the merged build');
assert.fail('placeholder: write the ICE action and async lane calls against track B\'s merged interfaces');
