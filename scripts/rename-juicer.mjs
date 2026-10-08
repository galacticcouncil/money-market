#!/usr/bin/env node
// propeller → juicer rename (plan step 8); mapping and exclusions in the vault's docs/rename-juicer.md
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const USAGE = `usage: node scripts/rename-juicer.mjs [--dry-run | --check] [--verbose] [--allow-dirty]
  (none)         git mv + text replacement on tracked files, result staged
  --dry-run      print the summary, change nothing
  --check        exit 1 if a non-excluded "propeller" or old share symbol remains
  --verbose      list every edited file
  --allow-dirty  apply on a tree with tracked changes`;

const git = (args, opts = {}) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 1 << 28, ...opts });

const V = '(?:propeller|juicer)-vault';
const FROZEN = [
  [/^scripts\/rename-juicer\.mjs$/, 'this script'],
  [new RegExp(`^${V}/docs/rename-juicer\\.md$`), 'rename mapping doc'],
  [new RegExp(`^${V}/docs/evidence/`), 'raw evidence'],
  [/(?:^|\/)[^/]*(?:19|20)\d\d-?[01]\d-?[0-3]\d[^/]*\.(?:md|txt|json|jsonl|log|csv|tsv|svg|html)$/, 'dated report or snapshot'],
  [new RegExp(`^${V}/(?:audit|deployments|x-ray)/`), 'audit, deployment journal or x-ray snapshot'],
  [new RegExp(`^${V}/AUDIT\\.md$`), 'historical audit ledger'],
  [new RegExp(`^${V}/formal/BRIDGE_SPIKE\\.md$`), 'dated spike report'],
  [new RegExp(`^${V}/docs/(?:coupled-liquidity-checkpoint|hollar-peg-liquidity|interest-policy-comparison|main-debt-verification|market-stress-90d|next-version-plan|operating-buffer|operating-buffer-verification|pr60-completion|prime-pricing-replenishment|principal-safety-history|release-candidate|route-execution-calibration)\\.md$`), 'historical report'],
  [/^PROPELLER-MAINNET-HANDOVER\.md$/, 'historical lark-4 handover'],
];
export const frozenReason = p => FROZEN.find(([re]) => re.test(p))?.[1];
// only evidence keeps directory names; every other directory is renamed
const frozenDir = p => new RegExp(`^${V}/docs/evidence/`).test(`${p}/`);
// real env files are never opened; committed templates are
const isSecretEnv = p => /^\.env/.test(path.posix.basename(p)) && !/\.(?:example|sample|template)$/.test(p);

const PROTECT = [
  ['url', /\b(?:https?|wss?):\/\/[^\s<>"'`)\]]+/g],
  ['path into another checkout', /(?:\/home\/[^/\s]+|~|\$HOME)\/git\/[^\s<>"'`)\],;]+/g],
  ['git branch', /\b(?:feat|fix|review|integrate|chore|docs|refactor|hotfix|release)\/propeller[\w./-]*|\bys-propeller-fixes\b|(?<=\bbranch(?:es)?:? |\bbased on )`propeller`/g],
  ['garden note', /\bnote-propeller[\w-]*/g],
  ['hydration-ui path', /\b(?:apps\/main\/)?src\/modules\/strategies\/propeller\b[\w./-]*|\bi18n\/(?:locales\/[\w-]+\/propeller\.json|content\/propeller-vault\b[\w./-]*)|\b(?:apps\/main\/)?tests\/propeller-abi\.mjs\b|\/strategies\/propeller\b/g],
  ['sr25519 derivation path', /\/\/[A-Za-z]+\/\/propeller[\w-]*/g],
  ['ignored secret file name', /\.propeller-bot\.secret\b/g],
  ['digest-pinned image', /(?<![\w./-])[\w./-]*propeller[\w./-]*@sha256:[0-9a-f]{64}/g],
  ['lark 4 swarm stack', /\bpropeller-oct2026[\w-]*/g],
  ['dated artifact name', /(?<![\w${}-])propeller[\w.${}-]*?(?:19|20)\d\d-?[01]\d-?[0-3]\d[\w.${}-]*/g],
  ['removed contract', /\bPropellerOperatingBuffer\b/g],
];

const RULES = [
  ['PROPELLER→JUICER', /PROPELLER/g, 'JUICER'],
  ['Propeller→Juicer', /Propeller/g, 'Juicer'],
  ['propeller→juicer', /propeller/g, 'juicer'],
  ['pETH→jETH', /(?<![A-Za-z0-9_])(w?)pETH(?![a-z])/g, '$1jETH'],
  ['ptBTC→jtBTC', /(?<![A-Za-z0-9_])(w?)ptBTC(?![a-z])/g, '$1jtBTC'],
  ['pBTC→jBTC', /(?<![A-Za-z0-9_])pBTC(?![a-z])/g, 'jBTC'],
  ['psHOL…→jsHOL…', /(?<![A-Za-z0-9_])psHOL(?![a-z])/g, 'jsHOL'],
  ['{a,vd,sd}PS…→{a,vd,sd}JS…', /(?<![A-Za-z0-9_])(a|vd|sd)PS(?=YNTH(?![A-Za-z])|-)/g, '$1JS'],
  ['`p${…}` symbol template→`j${…}`', /(?<=`)p(?=\$\{)/g, 'j'],
  ['pVault/pShares→jVault/jShares', /(?<![A-Za-z0-9_])p(Vault|Shares)(?![A-Za-z0-9_])/g, 'j$1'],
];
const CANDIDATE = /propeller|pETH|ptBTC|pBTC|psHOL|PSYNTH|PS-|`p\$\{|pVault|pShares/i;
const LEFTOVER_NAME = /propeller/i;
const LEFTOVER_SYMBOL = /(?<![A-Za-z0-9_])(?:w?pETH(?![a-z])|w?ptBTC(?![a-z])|pBTC(?![a-z])|psHOL(?![a-z])|(?:a|vd|sd)PS(?:YNTH|-)|p(?:Vault|Shares)(?![A-Za-z0-9_]))|`p\$\{/;

const renameSegment = s => s.replace(/PROPELLER/g, 'JUICER').replace(/Propeller/g, 'Juicer').replace(/propeller/g, 'juicer');

// gitlinks and symlinks are not ours to edit
function tracked() {
  const out = git(['ls-files', '-s', '-z']).split('\0').filter(Boolean);
  return out.map(l => { const t = l.indexOf('\t'); return { mode: l.slice(0, 6), path: l.slice(t + 1) }; })
    .filter(e => e.mode !== '160000' && e.mode !== '120000')
    .map(e => e.path).sort();
}

function frozenBasenameSpans(files) {
  const names = [...new Set(files.filter(f => frozenReason(f) && /propeller/i.test(path.posix.basename(f)))
    .map(f => path.posix.basename(f)))].sort();
  if (!names.length) return [];
  return [['frozen file name', new RegExp(names.map(n => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g')]];
}

function mask(text, protect, tally) {
  const spans = [];
  for (const [kind, re] of protect) {
    re.lastIndex = 0;
    for (const m of text.matchAll(re)) {
      if (!CANDIDATE.test(m[0])) continue;
      spans.push([m.index, m.index + m[0].length, kind]);
    }
  }
  spans.sort((a, b) => a[0] - b[0] || b[1] - a[1]);
  const merged = [];
  for (const s of spans) {
    const last = merged[merged.length - 1];
    if (last && s[0] < last[1]) last[1] = Math.max(last[1], s[1]);
    else merged.push([...s]);
  }
  const saved = [];
  let out = '', at = 0;
  for (const [a, b, kind] of merged) {
    out += text.slice(at, a) + `\uE000${saved.length}\uE001`;
    saved.push(text.slice(a, b));
    if (tally) tally[kind] = (tally[kind] || 0) + 1;
    at = b;
  }
  out += text.slice(at);
  return { out, unmask: s => s.replace(/\uE000(\d+)\uE001/g, (_, i) => saved[Number(i)]) };
}

function readText(file) {
  const buf = readFileSync(file);
  if (buf.subarray(0, 8192).includes(0)) return null;
  const text = buf.toString('utf8');
  return Buffer.from(text, 'utf8').equals(buf) ? text : null;
}

export function replaceAll(text, protect = PROTECT, counts = {}, tally = {}) {
  const { out, unmask } = mask(text, protect, tally);
  let s = out;
  for (const [name, re, to] of RULES) {
    s = s.replace(re, (...m) => {
      counts[name] = (counts[name] || 0) + 1;
      return to.replace(/\$(\d)/g, (_, i) => m[Number(i)] ?? '');
    });
  }
  return unmask(s);
}

function planDirMoves(files) {
  const dirs = new Set();
  for (const f of files) {
    const parts = f.split('/');
    for (let i = 1; i < parts.length; i++) {
      const d = parts.slice(0, i).join('/');
      if (/propeller/i.test(parts[i - 1]) && !frozenDir(d)) dirs.add(d);
    }
  }
  const moves = [];
  const done = [];
  const current = p => { for (const [from, to] of done) if (p === from || p.startsWith(`${from}/`)) p = to + p.slice(from.length); return p; };
  for (const d of [...dirs].sort((a, b) => a.split('/').length - b.split('/').length || a.localeCompare(b))) {
    const from = current(d);
    const to = path.posix.join(path.posix.dirname(from), renameSegment(path.posix.basename(from)));
    if (from !== to) { moves.push([from, to]); done.push([from, to]); }
  }
  return { moves, current };
}

function planFileMoves(files) {
  return files.filter(f => !frozenReason(f) && /propeller/i.test(path.posix.basename(f)))
    .map(f => [f, path.posix.join(path.posix.dirname(f), renameSegment(path.posix.basename(f)))])
    .filter(([a, b]) => a !== b);
}

const area = f => {
  const p = f.split('/');
  if (/^(?:propeller|juicer)-vault$/.test(p[0]) && p.length > 2) return `${p[0]}/${p[1]}`;
  if (p[0] === 'scripts' && p.length > 2) return `${p[0]}/${p[1]}`;
  return p.length > 1 ? p[0] : '(root)';
};
const bump = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };
const sortedEntries = o => Object.entries(o).sort((a, b) => a[0].localeCompare(b[0]));

function check() {
  const files = tracked();
  const protect = [...PROTECT, ...frozenBasenameSpans(files)];
  const problems = [];
  const keptByReason = {};
  for (const f of files) {
    const reason = frozenReason(f);
    const segs = f.split('/');
    segs.forEach((s, i) => {
      if (!/propeller/i.test(s)) return;
      const isBase = i === segs.length - 1;
      if (isBase ? reason : frozenDir(segs.slice(0, i + 1).join('/'))) return;
      problems.push(`${f}: path still says "${s}"`);
    });
    if (isSecretEnv(f)) continue;
    if (reason) {
      if (CANDIDATE.test(readFileSync(f, 'latin1'))) bump(keptByReason, reason);
      continue;
    }
    const text = readText(f);
    if (text === null) {
      if (/propeller/i.test(readFileSync(f, 'latin1'))) problems.push(`${f}: binary or non-utf8 file mentions propeller`);
      continue;
    }
    if (!CANDIDATE.test(text)) continue;
    const { out } = mask(text, protect);
    out.split('\n').forEach((line, i) => {
      if (LEFTOVER_NAME.test(line) || LEFTOVER_SYMBOL.test(line)) {
        problems.push(`${f}:${i + 1}: ${line.replace(/\uE000\d+\uE001/g, '…').trim().slice(0, 160)}`);
      }
    });
  }
  console.log(`rename-juicer --check: ${files.length} tracked files`);
  for (const [r, n] of sortedEntries(keptByReason)) console.log(`  excluded, still mentions the old names: ${n} (${r})`);
  if (problems.length) {
    console.log(`FAIL: ${problems.length} leftover(s)`);
    for (const p of problems) console.log(`  ${p}`);
    process.exit(1);
  }
  console.log('OK: no propeller outside the documented exclusions');
}

function run(dry, { allowDirty, verbose }) {
  if (!dry && !allowDirty) {
    const dirty = git(['status', '--porcelain', '--untracked-files=no', '--ignore-submodules=all']).trim();
    if (dirty) {
      console.error('tracked changes present; commit or stash them first (or pass --allow-dirty)');
      process.exit(2);
    }
  }
  let files = tracked();
  const { moves: dirMoves, current } = planDirMoves(files);
  for (const [from, to] of dirMoves) {
    if (!dry && existsSync(to)) { console.error(`refusing to move ${from}: ${to} already exists`); process.exit(2); }
  }
  if (!dry) for (const [from, to] of dirMoves) git(['mv', from, to]);
  files = dry ? files.map(current).sort() : tracked();
  const fileMoves = planFileMoves(files);
  for (const [from, to] of fileMoves) {
    if (!dry && existsSync(to)) { console.error(`refusing to move ${from}: ${to} already exists`); process.exit(2); }
    if (!dry) git(['mv', from, to]);
  }
  const moved = new Map(fileMoves);
  files = files.map(f => moved.get(f) ?? f).sort();
  // in a dry run the bytes still sit at the old path
  const undo = new Map(fileMoves.map(([a, b]) => [b, a]));
  const source = f => {
    if (!dry) return f;
    let p = undo.get(f) ?? f;
    for (const [from, to] of [...dirMoves].reverse()) if (p === to || p.startsWith(`${to}/`)) p = from + p.slice(to.length);
    return p;
  };

  const protect = [...PROTECT, ...frozenBasenameSpans(files)];
  const counts = {}, tally = {}, keptByReason = {}, editedByArea = {}, skipped = [];
  const edited = [];
  for (const f of files) {
    const reason = frozenReason(f);
    const src = source(f);
    if (isSecretEnv(f)) { skipped.push(`${f} (env file, never opened)`); continue; }
    if (reason) {
      if (CANDIDATE.test(readFileSync(src, 'latin1'))) bump(keptByReason, reason);
      continue;
    }
    const text = readText(src);
    if (text === null) {
      if (/propeller/i.test(readFileSync(src, 'latin1'))) skipped.push(`${f} (binary or non-utf8)`);
      continue;
    }
    if (!CANDIDATE.test(text)) continue;
    const fileCounts = {};
    const next = replaceAll(text, protect, fileCounts, tally);
    if (next === text) continue;
    for (const [k, n] of Object.entries(fileCounts)) bump(counts, k, n);
    bump(editedByArea, area(f));
    edited.push([f, Object.values(fileCounts).reduce((a, b) => a + b, 0)]);
    if (!dry) writeFileSync(f, next);
  }
  if (!dry && edited.length) {
    for (let i = 0; i < edited.length; i += 200) git(['add', '--', ...edited.slice(i, i + 200).map(([f]) => f)]);
  }

  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  console.log(`rename-juicer ${dry ? '--dry-run' : 'apply'}: ${files.length} tracked files`);
  console.log(`directories moved: ${dirMoves.length}`);
  for (const [a, b] of dirMoves) console.log(`  ${a} -> ${b}`);
  console.log(`files renamed: ${fileMoves.length}`);
  for (const [a, b] of fileMoves) console.log(`  ${a} -> ${path.posix.basename(b)}`);
  console.log(`files edited: ${edited.length}, replacements: ${total}`);
  for (const [k, n] of sortedEntries(editedByArea)) console.log(`  ${k}: ${n} files`);
  console.log('replacements by rule:');
  for (const [name] of RULES) console.log(`  ${name}: ${counts[name] || 0}`);
  console.log('kept verbatim inside edited files (protected spans):');
  for (const [k, n] of sortedEntries(tally)) console.log(`  ${k}: ${n}`);
  console.log('excluded files that still mention the old names:');
  for (const [k, n] of sortedEntries(keptByReason)) console.log(`  ${k}: ${n}`);
  for (const s of skipped) console.log(`skipped: ${s}`);
  if (verbose) for (const [f, n] of edited) console.log(`  edited ${f} (${n})`);
  if (!dry) {
    console.log(`\nstaged:${git(['diff', '--cached', '--shortstat', '-M']).trimEnd()}`);
    console.log('next: node scripts/rename-juicer.mjs --check && git diff --cached --stat -M');
    console.log('stale build output keeps old names until rebuilt: forge clean in juicer-vault, npm run build in juicer-vault/looper');
  }
}

export { FROZEN, PROTECT, RULES, frozenBasenameSpans, planDirMoves, planFileMoves };

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const argv = new Set(process.argv.slice(2));
  if (argv.has('--help') || argv.has('-h')) { console.log(USAGE); process.exit(0); }
  for (const a of argv) {
    if (!['--check', '--dry-run', '--verbose', '--allow-dirty'].includes(a)) {
      console.error(`unknown argument ${a}\n${USAGE}`);
      process.exit(2);
    }
  }
  process.chdir(git(['rev-parse', '--show-toplevel']).trim());
  if (argv.has('--check')) check();
  else run(argv.has('--dry-run'), { allowDirty: argv.has('--allow-dirty'), verbose: argv.has('--verbose') });
}
