// A rehearsal must select its build explicitly; a stale default out/ is unsafe.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

export const artifactDir = process.env.PROPELLER_ARTIFACT_DIR;
assert.ok(artifactDir, 'Set PROPELLER_ARTIFACT_DIR to the verified London production build');
export const artifactManifest = {};
// EIP-7825, enforced by native transaction validation on Hydration runtime 447.
// The block allowance is larger and eth_estimateGas alone does not enforce it.
export const maxTransactionGas = 1n << 24n;
export function artifact(name) {
  const file = name === 'HydraAugustus'
    ? process.env.PROPELLER_ADAPTER_ARTIFACT
    : resolve(artifactDir, `${name}.sol`, `${name}.json`);
  assert.ok(file, 'Set PROPELLER_ADAPTER_ARTIFACT to the pinned production adapter');
  const bytes = readFileSync(file);
  const value = JSON.parse(bytes);
  const metadata = typeof value.metadata === 'string' ? JSON.parse(value.metadata) : value.metadata;
  assert.equal(metadata.settings.evmVersion, 'london', `${name}: expected native London build`);
  artifactManifest[name] = { file, sha256: createHash('sha256').update(bytes).digest('hex') };
  return value;
}
