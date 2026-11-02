/* CriaHub · notificações (não guarda cache do app). Alarme do aquecimento: tocam com som e vibração e ficam na tela até ela tocar */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data && e.data.text() }; }
  const alarm = d.alarm === '1' || d.alarm === true;
  e.waitUntil(self.registration.showNotification(d.title || 'CriaHub', {
    body: d.body || '', tag: d.tag || 'criahub', renotify: true,
    silent: false, requireInteraction: alarm, vibrate: alarm ? [400, 200, 400, 200, 800, 300, 800] : [200, 100, 200],
    data: { url: d.url || '/#radar' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/#radar';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) { if ('focus' in c) { c.postMessage({ criahub: 'open', url }); return c.focus(); } }
    return self.clients.openWindow(url);
  }));
});
