// One reviewed deployment per Lark genesis. After a reset, pin the new genesis
// and journal date here; never disable the identity checks that read these.
export const GENESIS = '0x0a1fba23f7897cb5cbb3289db93ab605774565149b0c87033b4f2af817c9f96c';
export const DEPLOYMENT = '20261007';
export const COMMIT = 'db0799c2c13cfea880b089d737c02cfb2e116be6';
export const CORE_FILE = `/tmp/propeller-lark-${DEPLOYMENT}.json`;
// price mirrors and the discount adapter journal separately (PROPELLER_LARK_RESULT=PRICES_FILE)
export const FILE = process.env.PROPELLER_LARK_RESULT || CORE_FILE;
export const PRICES_FILE = process.env.PROPELLER_LARK_PRICES || `/tmp/propeller-lark-prices-${DEPLOYMENT}.json`;
export const MANIFEST_CONFIG = `propeller-lark4-${DEPLOYMENT}-manifest-v2`;
