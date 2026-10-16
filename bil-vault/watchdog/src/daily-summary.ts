import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

const DAY = 86_400;
type State = { version: 1; lastAttempt: number; hadPositions: boolean };

/** One summary attempt per 24 hours, including across restarts and ambiguous HTTP failures. */
export class DailySummary {
  private state: State;

  constructor(private path: string, now: number, private interval = DAY) {
    if (!Number.isFinite(interval) || interval <= 0) throw new Error('Invalid daily summary interval');
    this.interval = Math.max(DAY, interval);
    try {
      const saved = JSON.parse(readFileSync(path, 'utf8'));
      if (saved.version !== 1 || !Number.isFinite(saved.lastAttempt) || saved.lastAttempt < 0 || typeof saved.hadPositions !== 'boolean') {
        throw new Error('Invalid daily summary state; refusing to reset the notification clock');
      }
      this.state = saved;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
      // A first deployment starts a new window instead of dumping the existing backlog.
      this.state = { version: 1, lastAttempt: now, hadPositions: false };
      this.save();
    }
  }

  get lastAttempt() { return this.state.lastAttempt; }

  reserve(now: number, hasProblems: boolean): boolean {
    if (!hasProblems) return false;
    if (now - this.state.lastAttempt < this.interval) return false;
    const previous = this.state;
    // Keep the v1 field for compatibility with state written by older deployments.
    this.state = { version: 1, lastAttempt: now, hadPositions: true };
    try {
      // Persist BEFORE sending: a crash after Discord accepts a message cannot duplicate it.
      this.save();
    } catch (err) {
      this.state = previous;
      throw err;
    }
    return true;
  }

  private save() {
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(`${this.path}.tmp`, JSON.stringify(this.state), { mode: 0o600 });
    renameSync(`${this.path}.tmp`, this.path);
  }
}

export const isPositionIssue = (key: string) => /^(pos|ready|claim):\d+$/.test(key);
