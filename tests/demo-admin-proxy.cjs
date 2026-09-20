const fs=require('fs'),assert=require('assert/strict');
(async()=>{
 const worker=(await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync('worker.js','utf8')).toString('base64'))).default;
 const original=global.fetch;let calls=0;
 global.fetch=async(url,options)=>{calls++;assert.equal(url,'https://ldufxzwgwbaogpmwqhlw.supabase.co/functions/v1/demo-admin');assert.equal(options.headers.Authorization,'Bearer test-token');assert.equal(options.headers.Origin,'https://mypiti.online');return new Response('{"data":[]}',{status:200})};
 const req=(headers={},body={action:'demo_versions'})=>new Request('https://mypiti.online/api/demo-admin',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(body)});
 assert.equal((await worker.fetch(req(),{})).status,401);
 assert.equal((await worker.fetch(req({authorization:'Bearer test-token',origin:'https://evil.invalid'}),{})).status,403);
 assert.equal((await worker.fetch(req({authorization:'Bearer test-token'},{action:'delete_all'}),{})).status,400);assert.equal(calls,0);
 const r=await worker.fetch(req({authorization:'Bearer test-token',origin:'https://mypiti.online'}),{});assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');assert.equal(calls,1);
 global.fetch=async()=>{throw Error('network')};assert.equal((await worker.fetch(req({authorization:'Bearer test-token'}),{})).status,502);
 global.fetch=original;console.log('PASS: fixed DEMO-only proxy, token forwarding, origin/action guards, no caching and network error');
})().catch(e=>{console.error(e);process.exit(1)});
