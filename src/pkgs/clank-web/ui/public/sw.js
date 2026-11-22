// Clankstation's service worker: it makes the app installable and shows the
// box's push notifications (S6). It caches nothing: the app always shows what
// the box says right now.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

// The box sends {title, body, url, tag} (push.go).
self.addEventListener('push', (event) => {
  let n = { title: 'Clankstation', body: '', url: '/', tag: '' };
  try {
    n = { ...n, ...event.data.json() };
  } catch {
    /* show the default */
  }
  event.waitUntil(
    self.registration.showNotification(n.title, {
      body: n.body,
      tag: n.tag || undefined,
      renotify: Boolean(n.tag),
      icon: '/icon-192.png',
      badge: '/icon-192.png',
      data: { url: n.url || '/' },
    }),
  );
});

// Tapping a notification opens (or focuses) the app on that task.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || '/', self.location.origin).href;
  event.waitUntil(
    (async () => {
      const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const c of all) {
        if (new URL(c.url).origin === self.location.origin) {
          await c.focus();
          if ('navigate' in c) await c.navigate(url);
          return;
        }
      }
      await self.clients.openWindow(url);
    })(),
  );
});
