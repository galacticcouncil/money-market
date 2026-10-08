import { createServer } from 'node:http';
import type { BILWatchdog } from './watchdog.js';
import { UI_HTML } from './ui.js';

// read-only status: last scan as json + a static page that polls it
export function serve(watchdog: BILWatchdog, port: number, pollMs: number): void {
  createServer((req, res) => {
    const path = (req.url ?? '/').split('?')[0].replace(/\/+$/, '') || '/';
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405).end();
      return;
    }
    if (path === '/api/status') {
      const body = JSON.stringify(watchdog.status());
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store', 'access-control-allow-origin': '*' });
      res.end(body);
      return;
    }
    if (path === '/healthz') {
      const s = watchdog.status();
      // stale after three missed polls
      const fresh = s.updatedAt !== null && Date.now() - Date.parse(s.updatedAt) < Math.max(3 * pollMs, 180_000);
      res.writeHead(fresh ? 200 : 503, { 'content-type': 'text/plain' }).end(fresh ? 'ok' : 'stale');
      return;
    }
    if (path === '/') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-cache' }).end(UI_HTML);
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' }).end('not found');
  }).listen(port, () => console.log(`Status UI on :${port} (api: /api/status)`));
}
