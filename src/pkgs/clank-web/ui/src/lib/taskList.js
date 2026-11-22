// The task list's groups (docs/gui.md 3.1), shared by Home on a phone and
// the side list on a PC (3.8).
import { stateInfo, ago } from './states.js';
import { onReconnect } from './connection.svelte.js';

const WEEK = 7 * 86400 * 1000;

export function groupTasks(tasks) {
  const g = { needs: [], working: [], done: [], older: [] };
  for (const t of tasks ?? []) {
    const info = stateInfo(t);
    if (info.group === 'done') {
      const when = Date.parse(t.finished || t.created);
      (Date.now() - when > WEEK ? g.older : g.done).push(t);
    } else {
      g[info.group].push(t);
    }
  }
  // Working first, then the line in order (the oldest waits longest).
  g.working.sort((a, b) =>
    (a.state === 'queued') - (b.state === 'queued') ||
    (a.state === 'queued' ? a.id.localeCompare(b.id) : b.id.localeCompare(a.id)));
  return g;
}

export function when(t) {
  const info = stateInfo(t);
  if (info.group === 'working') return `started ${ago(t.created)}`;
  return ago(t.finished || t.created);
}

// The list refreshes every few seconds while it's on screen.
export function pollTasks(listTasks, onTasks, onError) {
  let stopped = false;
  async function refresh() {
    try {
      const t = await listTasks();
      if (!stopped) onTasks(t);
    } catch {
      if (!stopped) onError();
    }
  }
  refresh();
  const timer = setInterval(refresh, 3000);
  const off = onReconnect(refresh); // don't wait for the next tick
  return () => {
    stopped = true;
    off();
    clearInterval(timer);
  };
}
