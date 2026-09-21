import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createPushHandler, equalSecret, signAPNs } from '../supabase/functions/send-push/handler.mjs';
const require=createRequire(import.meta.url),{create}=require('../assets/ios-bridge.js');
const secret='x'.repeat(40);
const config={PUSH_DISPATCH_SECRET:secret,SUPABASE_URL:'https://test.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'server-only',
 APNS_KEY:'test',APNS_KEY_ID:'key',APPLE_TEAM_ID:'team',APNS_BUNDLE_ID:'online.mypiti.app.staging'};
const delivery={id:'job1',lease:'lease1',recipient_id:'u1',client_id:'c1',page:'messages',body:'Yeni bir mesajınız var.',
 entity_id:'m1',token:'a'.repeat(64),topic:config.APNS_BUNDLE_ID,environment:'production'};
function req(value=secret){return new Request('https://fn.example',{method:'POST',headers:{'x-piti-push-secret':value}});}
test('dispatcher fails closed when unset, rejects unauthorized and GET',async()=>{
 const fn=createPushHandler({env:()=>undefined,fetcher:()=>{throw Error('must not call')}});
 assert.equal((await fn(req())).status,503);
 const fn2=createPushHandler({env:k=>config[k]});
 assert.equal((await fn2(req('no'))).status,401);
 assert.equal((await fn2(new Request('https://fn.example'))).status,405);
 assert.equal(equalSecret(secret,secret),true);assert.equal(equalSecret(secret,secret+'x'),false);assert.equal(equalSecret(null,undefined),false);
});
test('per-device failures and TestFlight production APNs',async()=>{
 const finishes=[],hosts=[];
 const fn=createPushHandler({env:k=>config[k],signer:async()=> 'signed',fetcher:async(url,options)=>{
  const u=String(url);
  if(u.endsWith('push_claim'))return Response.json([delivery,{...delivery,id:'job2',token:'b'.repeat(64)}]);
  if(u.endsWith('push_finish')){finishes.push(JSON.parse(options.body));return Response.json(null);}
  hosts.push(u);assert.equal(options.headers['apns-topic'],'online.mypiti.app.staging');
  assert.equal(JSON.parse(options.body).recipient_id,'u1');
  return u.endsWith('a'.repeat(64)) ? new Response('',{status:200}) : Response.json({reason:'Unregistered'},{status:410});
 }});
 assert.equal((await fn(req())).status,503);
 assert.ok(hosts.every(h=>h.startsWith('https://api.push.apple.com/')));
 assert.deepEqual(finishes.map(f=>[f.p_ok,f.p_permanent]),[[true,false],[false,true]]);
});
test('wrong topic never hits APNs and no secrets leak',async()=>{
 let sends=0;const finishes=[];
 const fn=createPushHandler({env:k=>config[k],signer:async()=> 'signed',fetcher:async(url,options)=>{
  if(String(url).endsWith('push_claim'))return Response.json([{...delivery,topic:'wrong'}]);
  if(String(url).endsWith('push_finish')){finishes.push(JSON.parse(options.body));return Response.json(null);}
  sends++;throw Error(secret);
 }});
 const response=await fn(req());assert.equal(sends,0);assert.equal(finishes[0].p_permanent,false);assert.ok(!(await response.text()).includes(secret));
});
test('APNs provider JWT is a verifiable ES256 token',async()=>{
 const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
 const der=await crypto.subtle.exportKey('pkcs8',keys.privateKey);
 const key='-----BEGIN PRIVATE KEY-----\n'+Buffer.from(der).toString('base64')+'\n-----END PRIVATE KEY-----';
 const jwt=await signAPNs({...config,APNS_KEY:key},()=>1700000000000),parts=jwt.split('.');
 assert.equal(JSON.parse(Buffer.from(parts[1],'base64url')).iat,1700000000);
 assert.equal(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},keys.publicKey,Buffer.from(parts[2],'base64url'),new TextEncoder().encode(parts[0]+'.'+parts[1])),true);
});
function fixture(){
 let ctx={userId:'one',ready:true,demo:false};const calls=[],commands=[],routes=[],listeners={};
 const w={webkit:{messageHandlers:{pitiNative:{postMessage:x=>commands.push(x)}}},document:{getElementById:()=>null},
  addEventListener:(name,fn)=>listeners[name]=fn};
 const client={rpc:async(name,args)=>{calls.push([name,args]);return {}}};
 const bridge=create({window:w,client,context:()=>ctx,navigate:async r=>routes.push(r)});
 const emit=d=>listeners['piti-native-push-token']({detail:{token:'a'.repeat(64),environment:'production',topic:'online.mypiti.app.staging',app_version:'1',permission:'authorized',...d}});
 const flush=()=>new Promise(r=>setTimeout(r,10));
 return {w,client,bridge,calls,commands,routes,emit,flush,setContext:c=>ctx=c};
}
test('inert browser bridge; demo never registers; explicit permission',async()=>{
 assert.equal(create({window:{},client:{}}),null);
 const f=fixture();f.setContext({userId:'one',ready:true,demo:true});f.bridge.ready();f.emit();await f.flush();
 assert.equal(f.calls.length,0);assert.deepEqual(f.commands,[{action:'ready'}]);
});
test('registration deduplicates; logout disables exact topic/device',async()=>{
 const f=fixture();f.emit();f.emit();await f.flush();assert.equal(f.calls.length,1);assert.equal(f.calls[0][0],'register_push_device');
 await f.bridge.beforeLogout();assert.equal(f.calls[1][0],'disable_push_device');
 assert.equal(f.calls[1][1].p_topic,'online.mypiti.app.staging');
 f.emit();await f.flush();assert.equal(f.calls.length,2);
});
test('routes wait for login, reject another recipient and arbitrary URL',async()=>{
 const f=fixture();f.setContext({ready:false});assert.equal(await f.w.pitiNativeOpenRoute({page:'messages'}),false);
 f.setContext({ready:true,userId:'one',demo:false});
 assert.equal(await f.w.pitiNativeOpenRoute({page:'messages',recipient_id:'two'}),true);assert.equal(f.routes.length,0);
 await f.w.pitiNativeOpenRoute({page:'javascript:alert(1)'});assert.equal(f.routes.length,0);
 await f.w.pitiNativeOpenRoute({page:'calendar',recipient_id:'one',entity_id:'s1'});assert.equal(f.routes.length,1);
});
test('denied permission disables existing registration',async()=>{
 const f=fixture();f.emit();await f.flush();f.emit({permission:'denied'});await f.flush();assert.equal(f.calls.at(-1)[0],'disable_push_device');
});
