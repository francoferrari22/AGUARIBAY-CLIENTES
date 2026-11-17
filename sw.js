const C='aguaribay-v9',F=['./','index.html','config.js','manifest.json','icon.svg','icon-192.png','icon-512.png','icon-maskable.png','icon-180.png','fondo.jpg','bienvenida.wav','sello.wav'];
self.addEventListener('install',e=>{self.skipWaiting();e.waitUntil(caches.open(C).then(c=>c.addAll(F)).catch(()=>{}))});
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{if(e.request.method!=='GET'||e.request.url.includes('supabase.co'))return;e.respondWith(fetch(e.request,{cache:'no-cache'}).catch(()=>caches.match(e.request)))});
