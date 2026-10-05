// single-page status ui; plain js, no build step. polls ./api/status
export const UI_HTML = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BIL vault status</title>
<style>
.viz-root {
  color-scheme: light;
  --page: #f9f9f7; --surface-1: #fcfcfb; --border: rgba(11,11,11,0.10);
  --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #898781;
  --grid: #e1e0d9; --meter-fill: #2a78d6; --meter-track: #cde2fb;
  --good: #0ca30c; --warning: #fab219; --serious: #ec835a; --critical: #d03b3b; --info: #2a78d6;
}
@media (prefers-color-scheme: dark) {
  :root:where(:not([data-theme="light"])) .viz-root {
    color-scheme: dark;
    --page: #0d0d0d; --surface-1: #1a1a19; --border: rgba(255,255,255,0.10);
    --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #898781;
    --grid: #2c2c2a; --meter-fill: #3987e5; --meter-track: #104281; --info: #3987e5;
  }
}
:root[data-theme="dark"] .viz-root {
  color-scheme: dark;
  --page: #0d0d0d; --surface-1: #1a1a19; --border: rgba(255,255,255,0.10);
  --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #898781;
  --grid: #2c2c2a; --meter-fill: #3987e5; --meter-track: #104281; --info: #3987e5;
}
* { box-sizing: border-box; }
body { margin: 0; }
.viz-root { min-height: 100vh; background: var(--page); color: var(--text-primary); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; padding: 24px; }
.wrap { max-width: 1180px; margin: 0 auto; }
header { display: flex; flex-wrap: wrap; align-items: center; gap: 12px 16px; margin-bottom: 20px; }
h1 { font-size: 18px; font-weight: 600; margin: 0; }
h2 { font-size: 13px; font-weight: 600; color: var(--text-secondary); margin: 28px 0 10px; }
.meta { color: var(--text-muted); font-size: 12px; }
.spacer { flex: 1; }
a { color: var(--text-secondary); }
button { font: inherit; font-size: 12px; color: var(--text-secondary); background: var(--surface-1); border: 1px solid var(--border); border-radius: 6px; padding: 4px 10px; cursor: pointer; }
.chip { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 600; padding: 3px 10px 3px 8px; border-radius: 999px; border: 1px solid var(--border); background: var(--surface-1); }
.dot { width: 8px; height: 8px; border-radius: 50%; flex: none; }
.card { background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px; padding: 16px; }
.hero { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 8px 24px; }
.hero .value { font-size: 52px; font-weight: 600; line-height: 1; letter-spacing: -0.02em; }
.hero .label { color: var(--text-secondary); font-size: 13px; margin-bottom: 6px; }
.row { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 12px; }
.tile .label { color: var(--text-secondary); font-size: 12px; }
.tile .value { font-size: 22px; font-weight: 600; margin-top: 2px; }
.tile .sub { color: var(--text-muted); font-size: 12px; margin-top: 2px; display: flex; align-items: center; gap: 6px; }
.unit { font-size: 13px; font-weight: 500; color: var(--text-secondary); margin-left: 3px; }
.meter { margin-top: 12px; }
.meter .track { height: 10px; border-radius: 5px; background: var(--meter-track); overflow: hidden; }
.meter .fill { height: 100%; border-radius: 5px; background: var(--meter-fill); }
.meter .legend { display: flex; justify-content: space-between; color: var(--text-muted); font-size: 12px; margin-top: 6px; }
ul.issues { list-style: none; margin: 0; padding: 0; }
ul.issues li { display: flex; gap: 10px; align-items: baseline; padding: 8px 0; border-top: 1px solid var(--grid); }
ul.issues li:first-child { border-top: 0; }
.lvl { font-size: 12px; font-weight: 600; min-width: 64px; display: inline-flex; align-items: center; gap: 6px; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th { text-align: left; font-weight: 500; color: var(--text-muted); font-size: 12px; padding: 6px 10px; border-bottom: 1px solid var(--grid); }
td { padding: 7px 10px; border-bottom: 1px solid var(--grid); }
tr:last-child td { border-bottom: 0; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.empty { color: var(--text-muted); padding: 6px 0; }
.banner { display: none; margin-bottom: 16px; }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
</style>
</head>
<body>
<div class="viz-root">
<div class="wrap">
  <header>
    <h1>BIL vault</h1>
    <span id="overall" class="chip"><span class="dot" style="background:var(--text-muted)"></span>Loading</span>
    <span class="spacer"></span>
    <span class="meta" id="updated"></span>
    <a class="meta" href="api/status">API</a>
    <button id="theme" type="button">Theme</button>
  </header>
  <div class="card banner" id="banner"></div>

  <div class="card hero">
    <div><div class="label">HOLLAR in the vault (total assets)</div><div class="value" id="tvl">–</div></div>
    <div class="label" id="tvl-sub"></div>
  </div>

  <h2>Vault</h2>
  <div class="row" id="vault-row"></div>

  <h2>Decentral</h2>
  <div class="row" id="dec-row"></div>

  <h2>Money market: HOLLAR borrowed against BIL</h2>
  <div class="row" id="mm-row"></div>
  <div class="card meter" id="cap-meter"></div>

  <h2>Keeper</h2>
  <div class="row" id="keeper-row"></div>

  <h2>Open issues</h2>
  <div class="card"><ul class="issues" id="issues"></ul></div>

  <h2>Matured positions</h2>
  <div class="card"><table id="matured"></table></div>

  <h2>Next maturities</h2>
  <div class="card"><table id="upcoming"></table></div>

  <p class="meta" id="footer"></p>
</div>
</div>
<script>
(function () {
  var root = document.documentElement;
  var saved = localStorage.getItem('bil-theme');
  if (saved) root.setAttribute('data-theme', saved);
  document.getElementById('theme').onclick = function () {
    var dark = root.getAttribute('data-theme') === 'dark' ||
      (!root.getAttribute('data-theme') && matchMedia('(prefers-color-scheme: dark)').matches);
    var next = dark ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    localStorage.setItem('bil-theme', next);
  };

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function compact(n) {
    if (n == null || isNaN(n)) return '–';
    var a = Math.abs(n);
    if (a >= 1e6) return (n / 1e6).toFixed(2) + 'M';
    if (a >= 1e4) return (n / 1e3).toFixed(1) + 'K';
    return n.toLocaleString('en-US', { maximumFractionDigits: 2 });
  }
  function full(n) { return n == null ? '–' : n.toLocaleString('en-US', { maximumFractionDigits: 2 }); }
  function pct(x, d) { return (x * 100).toFixed(d == null ? 2 : d) + '%'; }
  function dur(sec) {
    sec = Math.abs(sec);
    if (sec < 3600) return Math.max(1, Math.floor(sec / 60)) + 'm';
    if (sec < 172800) return Math.floor(sec / 3600) + 'h';
    return Math.floor(sec / 86400) + 'd';
  }
  function rel(iso) {
    if (!iso) return '–';
    var s = (Date.parse(iso) - Date.now()) / 1000;
    return s >= 0 ? 'in ' + dur(s) : dur(s) + ' ago';
  }
  function day(iso) { return iso ? iso.slice(0, 16).replace('T', ' ') + ' UTC' : '–'; }
  // status always ships as icon + label, never color alone
  var STATUS = {
    good: ['var(--good)', '✓'], warn: ['var(--warning)', '!'], serious: ['var(--serious)', '!'],
    error: ['var(--critical)', '✕'], info: ['var(--info)', 'i'], muted: ['var(--text-muted)', '·']
  };
  function chip(kind, label) {
    var s = STATUS[kind];
    return '<span class="chip"><span class="dot" style="background:' + s[0] + '"></span>' + s[1] + ' ' + esc(label) + '</span>';
  }
  function dotLabel(kind, label) {
    var s = STATUS[kind];
    return '<span class="dot" style="background:' + s[0] + '"></span>' + esc(label);
  }
  function tile(label, value, unit, sub) {
    return '<div class="card tile"><div class="label">' + esc(label) + '</div><div class="value">' + value +
      (unit ? '<span class="unit">' + esc(unit) + '</span>' : '') + '</div>' + (sub ? '<div class="sub">' + sub + '</div>' : '') + '</div>';
  }

  function render(s) {
    var banner = document.getElementById('banner');
    if (!s.updatedAt) {
      banner.style.display = 'block';
      banner.innerHTML = chip('info', 'Waiting for the first scan') + (s.lastError ? ' <span class="meta">' + esc(s.lastError) + '</span>' : '');
      return;
    }
    banner.style.display = s.lastError ? 'block' : 'none';
    if (s.lastError) banner.innerHTML = chip('error', 'Last scan failed, showing previous data') + ' <span class="meta">' + esc(s.lastError) + '</span>';

    var errs = s.issues.filter(function (i) { return i.level === 'error'; }).length;
    var warns = s.issues.length - errs;
    document.getElementById('overall').outerHTML = '<span id="overall">' +
      (errs ? chip('error', errs + ' error' + (errs > 1 ? 's' : '') + (warns ? ', ' + warns + ' warning' + (warns > 1 ? 's' : '') : ''))
        : warns ? chip('warn', warns + ' warning' + (warns > 1 ? 's' : '')) : chip('good', 'All clear')) + '</span>';
    document.getElementById('updated').textContent = 'scanned ' + rel(s.updatedAt) + ' · block ' + s.block.toLocaleString('en-US');

    var v = s.vault;
    document.getElementById('tvl').innerHTML = compact(v.totalAssets) + '<span class="unit">HOLLAR</span>';
    document.getElementById('tvl-sub').innerHTML = '1 BIL = ' + v.exchangeRate.toFixed(4) + ' HOLLAR · ' + compact(v.totalSupply) + ' BIL supply' +
      (v.paused ? ' · ' + chip('serious', 'Paused') : '');
    document.getElementById('vault-row').innerHTML =
      tile('Idle HOLLAR', compact(v.idleHollar), 'HOLLAR', 'not yet reinvested') +
      tile('Reserved for claims', compact(v.reservedHollar), 'HOLLAR', compact(v.settledUnclaimedBil) + ' BIL settled, unclaimed') +
      tile('Unsettled redemptions', compact(v.unsettledBil), 'BIL', 'waiting for HOLLAR') +
      tile('Open positions', v.openPositions.toLocaleString('en-US'), '', v.positionCount + ' total, head at ' + v.positionHead);

    var d = s.decentral;
    var waitKind = d.waitingCount === 0 ? 'good' : d.overdueCount ? 'warn' : 'info';
    document.getElementById('dec-row').innerHTML =
      tile('Waiting on Decentral approval', compact(d.waitingPrincipal), 'HOLLAR',
        dotLabel(waitKind, d.waitingCount ? d.waitingCount + ' position' + (d.waitingCount > 1 ? 's' : '') + ' (principal)' : 'Nothing waiting')) +
      tile('Yield awaiting approval', compact(d.waitingYield), 'HOLLAR', 'paid when Decentral approves') +
      tile('Oldest wait', d.waitingCount ? dur(d.oldestWaitSeconds) : '–', '',
        d.overdueCount ? dotLabel('warn', d.overdueCount + ' past the ' + dur(d.slaSeconds) + ' SLA') : dotLabel('good', 'within the ' + dur(d.slaSeconds) + ' SLA')) +
      tile('Decentral pool liquidity', compact(d.poolHollar), 'HOLLAR', '<span class="mono">' + esc(d.pool.slice(0, 10)) + '…</span>');

    var m = s.market;
    if (m) {
      document.getElementById('mm-row').innerHTML =
        tile('HOLLAR borrowed', compact(m.debt), 'HOLLAR', 'incl. interest owed') +
        tile('Borrow rate', pct(m.borrowApy), 'APY', pct(m.borrowApr) + ' APR, fixed') +
        tile('Interest owed, not yet repaid', compact(m.accruedUnpaid), 'HOLLAR', 'collected on repay or liquidation') +
        tile('Collected, not yet sent to treasury', compact(m.collectedUndistributed), 'HOLLAR', 'until distributeFeesToTreasury()') +
        tile('Interest per year now', compact(m.yearlyAtCurrent), 'HOLLAR', 'at current borrowing') +
        tile('Interest per year at cap', compact(m.yearlyAtCap), 'HOLLAR', 'if the ' + compact(m.cap) + ' cap is fully used');
      var u = m.cap > 0 ? m.minted / m.cap : 0;
      var fill = u >= 0.95 ? 'var(--critical)' : u >= 0.85 ? 'var(--warning)' : 'var(--meter-fill)';
      document.getElementById('cap-meter').innerHTML =
        '<div class="tile"><div class="label">Facilitator cap used</div><div class="value">' + pct(u, 1) + '</div></div>' +
        '<div class="track" title="' + full(m.minted) + ' of ' + full(m.cap) + ' HOLLAR minted"><div class="fill" style="width:' + Math.min(100, u * 100).toFixed(2) + '%;background:' + fill + '"></div></div>' +
        '<div class="legend"><span>' + compact(m.minted) + ' minted</span><span>' + compact(Math.max(0, m.cap - m.minted)) + ' left of ' + compact(m.cap) + '</span></div>';
    } else {
      document.getElementById('mm-row').innerHTML = '<div class="empty">Money market data unavailable this scan.</div>';
      document.getElementById('cap-meter').innerHTML = '';
    }

    var k = s.keeper;
    document.getElementById('keeper-row').innerHTML = k
      ? tile('Gas balance', k.weth.toFixed(5), 'WETH', k.lowGas ? dotLabel('warn', 'Low, top up') : dotLabel('good', 'OK')) +
        tile('Auto-claim', k.claimRole ? 'On' : 'Off', '', k.claimRole ? dotLabel('good', 'has CLAIM_OPERATOR_ROLE') : dotLabel('muted', 'no CLAIM_OPERATOR_ROLE (optional)')) +
        tile('Address', '<span class="mono">' + esc(k.address.slice(0, 10)) + '…' + esc(k.address.slice(-4)) + '</span>', '', '')
      : '<div class="empty">KEEPER_ADDRESS not set.</div>';

    var il = document.getElementById('issues');
    il.innerHTML = s.issues.length ? s.issues.map(function (i) {
      return '<li><span class="lvl">' + dotLabel(i.level === 'error' ? 'error' : 'warn', i.level === 'error' ? 'Error' : 'Warning') + '</span><span>' +
        esc(i.text) + ' <span class="meta">since ' + rel(i.since) + '</span></span></li>';
    }).join('') : '<li class="empty">' + dotLabel('good', 'No open issues') + '</li>';

    var mt = document.getElementById('matured');
    mt.innerHTML = s.matured.length
      ? '<tr><th class="num">#</th><th class="num">Token</th><th class="num">Principal</th><th>Matured</th><th>State</th><th>Waiting on</th></tr>' +
        s.matured.map(function (p) {
          var wait = p.waitingOn ? esc(p.waitingOn) + (p.waitingSince ? ' <span class="meta">(' + dur((Date.now() - Date.parse(p.waitingSince)) / 1000) + ')</span>' : '') : 'keeper';
          return '<tr><td class="num">' + p.index + '</td><td class="num">' + p.tokenId + '</td><td class="num">' + full(p.principal) + '</td><td>' +
            rel(p.maturity) + '</td><td>' + esc(p.state) + '</td><td>' + wait + '</td></tr>';
        }).join('')
      : '<tr><td class="empty">' + dotLabel('good', 'None. Every matured position is redeemed.') + '</td></tr>';

    var ut = document.getElementById('upcoming');
    ut.innerHTML = s.upcoming.length
      ? '<tr><th class="num">#</th><th class="num">Token</th><th class="num">Principal</th><th>Matures</th><th></th></tr>' +
        s.upcoming.map(function (p) {
          return '<tr><td class="num">' + p.index + '</td><td class="num">' + p.tokenId + '</td><td class="num">' + full(p.principal) + '</td><td>' +
            day(p.maturity) + '</td><td class="meta">' + rel(p.maturity) + '</td></tr>';
        }).join('')
      : '<tr><td class="empty">No open positions.</td></tr>';

    document.getElementById('footer').innerHTML = 'Vault <span class="mono">' + esc(v.address) + '</span>' +
      (m ? ' · market <span class="mono">' + esc(m.pool) + '</span>' : '') + ' · refreshes every 30s';
  }

  function load() {
    fetch('api/status', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(render).catch(function (e) {
      var b = document.getElementById('banner');
      b.style.display = 'block';
      b.innerHTML = chip('error', 'Status API unreachable') + ' <span class="meta">' + esc(e) + '</span>';
    });
  }
  load();
  setInterval(load, 30000);
})();
</script>
</body>
</html>`;
