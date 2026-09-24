import runtime from './worker.js';
export default {
 async fetch(request, env) {
  const path = new URL(request.url).pathname;
  if (path === '/api/demo-admin') return new Response(JSON.stringify({error:'DEMO yönetimi test ortamında kapalı.'}), {status:403,headers:{'Content-Type':'application/json'}});
  const response = await runtime.fetch(request, env);
  const headers = new Headers(response.headers);
  headers.set('X-PiTi-Environment','staging');
  headers.set('X-PiTi-Source-Commit','6c54bb85f90c6b261b95f458e532e383bd5c8158');
  headers.set('X-Robots-Tag','noindex, nofollow');
  headers.set('Cache-Control','no-store');
  headers.set('Content-Security-Policy', "connect-src 'self' https://ldufxzwgwbaogpmwqhlw.supabase.co wss://ldufxzwgwbaogpmwqhlw.supabase.co; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'self'");
  return new Response(response.body,{status:response.status,statusText:response.statusText,headers});
 }
};
