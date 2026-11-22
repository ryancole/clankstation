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
