// Read-only parity check. Pass the hydration-ui checkout and Forge artifact dir.
// Usage: node scripts/juicer/check-ui-abi.cjs /path/to/hydration-ui juicer-vault/out
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

if (process.argv.length !== 4) throw new Error('Expected UI checkout and Forge artifact directory');
const uiRoot = path.resolve(process.argv[2]);
const out = path.resolve(process.argv[3]);
const fromUi = Module.createRequire(path.join(uiRoot, 'package.json'));
const ts = fromUi('typescript');
const file = path.join(uiRoot, 'apps/main/src/modules/strategies/propeller/config/abi.ts');
const mod = new Module(file, module);
mod.paths = Module._nodeModulePaths(path.dirname(file));
mod._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText, file);

const pairs = {
  VAULT_ABI: 'CollateralVault', MAIN_DEBT_ABI: 'JuicerMainDebt',
  YIELD_ACCOUNTING_ABI: 'JuicerYieldAccounting', SUBLOOP_ABI: 'SubLoop',
  FEE_CONTROLLER_ABI: 'JuicerFeeController',
};
const type = x => x.type.startsWith('tuple')
  ? `(${(x.components || []).map(type).join(',')})${x.type.slice(5)}` : x.type;
const signature = f => `${f.name}(${(f.inputs || []).map(type).join(',')})`;
let total = 0;
for (const [exported, contract] of Object.entries(pairs)) {
  const abi = JSON.parse(fs.readFileSync(path.join(out, `${contract}.sol/${contract}.json`))).abi;
  let checked = 0;
  for (const item of mod.exports[exported].filter(x => x.type === 'function')) {
    const expected = abi.find(x => x.type === 'function' && signature(x) === signature(item));
    if (!expected || JSON.stringify(expected.outputs.map(type)) !== JSON.stringify(item.outputs.map(type))
      || expected.stateMutability !== item.stateMutability) {
      throw new Error(`${contract}: incompatible ${signature(item)}`);
    }
    ++checked;
    ++total;
  }
  console.log(`${contract}: ${checked} UI functions match compiled ABI`);
}
console.log(`Passed: ${total} signatures, return types and mutability; no chain reads.`);
