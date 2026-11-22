// Task states in plain words (docs/gui.md section 2).

const STATES = {
  queued: { label: 'Waiting in line', tone: 'idle', group: 'working',
    sentence: 'It starts when another task finishes.' },
  preparing: { label: 'Getting ready', tone: 'working', group: 'working',
    sentence: "Setting up the project's tools. This can take a few minutes the first time." },
  running: { label: 'Working', tone: 'working', group: 'working', sentence: '' },
  interactive: { label: "You're in control", tone: 'working', group: 'working',
    sentence: 'Someone is working with Claude in a terminal.' },
  needs_input: { label: 'Needs your answer', tone: 'needs', group: 'needs', sentence: '' },
  done: { label: 'Finished', tone: 'done', group: 'done', sentence: "Done. Here's what it did." },
  failed: { label: 'Something went wrong', tone: 'bad', group: 'needs',
    sentence: "Claude couldn't finish this task." },
  stopped: { label: 'Stopped', tone: 'idle', group: 'done',
    sentence: 'Stopped before it finished. Its work so far is kept.' },
  lost: { label: 'Interrupted', tone: 'bad', group: 'needs',
    sentence: 'The box restarted while this was working.' },
};

const ARCHIVED = { label: 'Archived', tone: 'idle', group: 'done',
  sentence: 'Its working files were cleaned up after 7 days. You can still read it.' };

export function stateInfo(task) {
  const finished = !['queued', 'preparing', 'running', 'interactive'].includes(task.state);
  if (task.archived && finished) return ARCHIVED;
  return STATES[task.state] ?? { label: task.state, tone: 'idle', group: 'done', sentence: '' };
}

export function isActive(state) {
  return ['queued', 'preparing', 'running', 'interactive'].includes(state);
}

// "12 min ago", "yesterday", or a date.
export function ago(iso) {
  if (!iso) return '';
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return '';
  const s = Math.max(0, (Date.now() - t) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) {
    const h = Math.floor(s / 3600);
    return h === 1 ? '1 hour ago' : `${h} hours ago`;
  }
  if (s < 2 * 86400) return 'yesterday';
  return new Date(t).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

export function duration(fromIso, toIso) {
  const a = Date.parse(fromIso);
  const b = toIso ? Date.parse(toIso) : Date.now();
  if (Number.isNaN(a) || Number.isNaN(b)) return '';
  const m = Math.max(0, Math.round((b - a) / 60000));
  if (m < 1) return 'under a minute';
  if (m < 60) return `${m} min`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}
