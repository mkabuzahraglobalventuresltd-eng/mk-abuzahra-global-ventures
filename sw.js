const CACHE='mk-sales-v1';
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['./','./index.html','./styles.css','./app.js','./config.js','./manifest.json','./assets/logo.png']))));
self.addEventListener('fetch',e=>{e.respondWith(caches.match(e.request).then(x=>x||fetch(e.request).catch(()=>x)))});
