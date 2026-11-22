// The box's API (protocol v1, see api.go).

async function getJSON(path) {
  const r = await fetch(path, { headers: { Accept: 'application/json' } });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`${path}: ${r.status}`);
  return r.json();
}

export const listTasks = () => getJSON('/api/tasks');
export const getTask = (id) => getJSON(`/api/tasks/${encodeURIComponent(id)}`);
export const getChanges = (id) => getJSON(`/api/tasks/${encodeURIComponent(id)}/changes`);

// Live task events. EventSource reconnects by itself and sends the last
// event id, so the box resumes after the last line we saw. It gives up for
// good on some failures (an error page while the box restarts), so a closed
// stream is reopened here, after the last id we saw.
export function taskEvents(id, onEvent) {
  let es = null;
  let lastId = 0;
  let timer = null;
  let stopped = false;

  function open() {
    const after = lastId ? `?after=${lastId}` : '';
    es = new EventSource(`/api/tasks/${encodeURIComponent(id)}/events${after}`);
    es.onmessage = (m) => {
      if (m.lastEventId) lastId = Number(m.lastEventId) || lastId;
      try {
        const e = JSON.parse(m.data);
        if (e.v === 1) onEvent(e);
      } catch {
        /* ignore a malformed event */
      }
    };
    es.onerror = () => {
      if (es.readyState === EventSource.CLOSED && !stopped) {
        clearTimeout(timer);
        timer = setTimeout(open, 3000);
      }
    };
  }

  open();
  return () => {
    stopped = true;
    clearTimeout(timer);
    es?.close();
  };
}

// Actions. A failure throws an Error whose message is the box's own
// plain-language explanation.
async function postJSON(path, body) {
  let r;
  try {
    r = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(body ?? {}),
    });
  } catch {
    throw new Error("Can't reach the box right now. Check your connection and try again.");
  }
  const text = await r.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    /* not JSON */
  }
  if (!r.ok) throw new Error(data?.error ?? 'Something went wrong on the box.');
  return data;
}

export const listProjects = () => getJSON('/api/projects');
export const addProject = (name, url) => postJSON('/api/projects', { name, url });
export const newTask = (project, prompt) => postJSON('/api/tasks', { project, prompt });
export const reply = (id, prompt) => postJSON(`/api/tasks/${encodeURIComponent(id)}/reply`, { prompt });
export const stopTask = (id) => postJSON(`/api/tasks/${encodeURIComponent(id)}/stop`);

export async function getClaude() {
  const r = await fetch('/api/claude', { headers: { Accept: 'application/json' } });
  const data = await r.json().catch(() => null);
  if (!r.ok) throw new Error(data?.error ?? "Couldn't check Claude on the box.");
  return data;
}

export const getMe = () => getJSON('/api/me');

// Notifications (S6).
export const getPushKey = () => getJSON('/api/push/key');
export const pushSubscribe = (sub) => postJSON('/api/push/subscribe', sub);
export const pushUnsubscribe = (endpoint) => postJSON('/api/push/unsubscribe', { endpoint });
export const pushTest = (endpoint) => postJSON('/api/push/test', { endpoint });
