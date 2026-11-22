// Whether the app can reach the box (docs/gui.md 3.10). Every request and
// the live event stream report here; while the box can't be reached, a
// banner says "Reconnecting…" and the box is tried again every few seconds.
// When it answers, the banner says "Connected" for a moment and pages
// refresh at once instead of waiting for their next poll.
//
// A phone that comes back to the app (it was in the background or asleep)
// checks right away, and shows the banner if that takes more than a moment.
// While the app is on screen, it also checks every 10 s.

export const connection = $state({ status: 'ok' }); // ok, reconnecting, back

const listeners = new Set();
let probeTimer = null;
let backTimer = null;

// onReconnect(fn) calls fn whenever the box answers again after a loss or
// after the app comes back to the foreground. It returns an unsubscribe.
export function onReconnect(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function notify() {
  for (const fn of listeners) {
    try {
      fn();
    } catch {
      /* a page's refresh failing isn't ours to handle */
    }
  }
}

// lost: a request couldn't reach the box.
export function lost() {
  if (connection.status === 'reconnecting') return;
  clearTimeout(backTimer);
  connection.status = 'reconnecting';
  probe(1000);
}

// reached: the box answered.
export function reached() {
  if (connection.status !== 'reconnecting') return;
  clearTimeout(probeTimer);
  connection.status = 'back';
  backTimer = setTimeout(() => {
    if (connection.status === 'back') connection.status = 'ok';
  }, 2000);
  notify();
}

async function ping(timeout) {
  try {
    const r = await fetch('/api/me', {
      cache: 'no-store',
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(timeout),
    });
    return r.status < 502 || r.status > 504; // 502-504: a dev proxy without the box
  } catch {
    return false;
  }
}

function probe(delay) {
  clearTimeout(probeTimer);
  probeTimer = setTimeout(async () => {
    if (connection.status !== 'reconnecting') return;
    if (await ping(8000)) reached();
    else probe(Math.min(delay * 1.5, 6000));
  }, delay);
}

// check: back in the foreground, or the network came back. Quietly if the
// box answers quickly; otherwise the banner shows until it does.
async function check() {
  const slow = setTimeout(lost, 800);
  const ok = await ping(6000);
  clearTimeout(slow);
  if (!ok) {
    lost();
  } else if (connection.status === 'reconnecting') {
    reached();
  } else {
    notify(); // a stream left open in the background may have gone quiet
  }
}

if (typeof window !== 'undefined') {
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') check();
  });
  window.addEventListener('offline', lost);
  window.addEventListener('online', check);
  // A live stream can go quiet without an error when the network drops
  // (or behind a proxy), and a page like a finished task makes no other
  // requests: check on the box every 10 s while the app is on screen.
  setInterval(async () => {
    if (document.visibilityState !== 'visible' || connection.status === 'reconnecting') return;
    if (!(await ping(5000))) lost();
  }, 10000);
}
