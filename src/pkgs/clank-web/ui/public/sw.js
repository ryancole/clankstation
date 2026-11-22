// Clankstation's service worker. It makes the app installable and, from S6,
// receives push notifications. It caches nothing: the app always shows what
// the box says right now.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
