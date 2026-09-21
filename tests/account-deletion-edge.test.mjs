import test from 'node:test';import assert from 'node:assert/strict';
import {createHandler} from '../supabase/functions/delete-account/handler.mjs';
const user='00000000-0000-4000-8000-000000000001',sid='00000000-0000-4000-8000-000000000011',id='00000000-0000-4000-8000-000000000099';
const token='header.'+Buffer.from(JSON.stringify({session_id:sid})).toString('base64url')+'.signature';
const body={action:'request',password:'secret-password',confirmation:'HESABIMI SIL',fingerprint:'fp',request_id:id,receipt:'a'.repeat(64)};
const req=(data,auth=token,origin='https://staging.example')=>new Request('https://fn.example',{method:'POST',headers:{Origin:origin,Authorization:'Bearer '+auth},body:JSON.stringify(data)});
function setup(overrides={}){
 const calls=[];
 const fn=createHandler({url:'https://db.example',serviceKey:'server-secret',origins:['https://staging.example'],fetcher:async(url,options)=>{
  const path=new URL(url).pathname+new URL(url).search;calls.push({path,options});
  if(overrides[path])return overrides[path](options);
  if(path==='/auth/v1/user')return Response.json({id:user,email:'verified@accounts.mypiti.invalid'});
  if(path==='/rest/v1/rpc/account_deletion_preview')return Response.json({available:true,fingerprint:'fp',summary:{role:'member'}});
  if(path==='/auth/v1/token?grant_type=password')return Response.json({user:{id:user},access_token:'temporary-session'});
  if(path==='/auth/v1/logout?scope=local')return new Response(null,{status:204});
  if(path==='/rest/v1/rpc/account_deletion_request')return Response.json({id,state:'requested'});
  if(path==='/rest/v1/rpc/account_deletion_receipt')return Response.json(null);
  throw Error('Unexpected API');
 }});return {fn,calls};
}
test('reauthentication is bound to verified user; temporary session revoked before queue',async()=>{
 const f=setup(),response=await f.fn(req(body));assert.equal(response.status,202);assert.equal((await response.json()).state,'requested');
 const login=f.calls.find(x=>x.path.includes('grant_type'));assert.deepEqual(JSON.parse(login.options.body),{email:'verified@accounts.mypiti.invalid',password:body.password});
 assert.deepEqual(f.calls.slice(-2).map(x=>x.path),['/auth/v1/logout?scope=local','/rest/v1/rpc/account_deletion_request']);
 const payload=JSON.parse(f.calls.at(-1).options.body);assert.equal(payload.p_user,user);assert.equal(payload.p_session,sid);assert.notEqual(payload.p_receipt_hash,body.receipt);assert.ok(!f.calls.at(-1).options.body.includes(body.password));
 assert.ok(f.calls.every(x=>!['DELETE','PUT','PATCH'].includes(x.options.method)),'initiation must not delete/disable accounts');
});
test('unknown target fields, wrong origin and missing auth are rejected',async()=>{
 const f=setup();assert.equal((await f.fn(req({...body,user_id:user}))).status,400);assert.equal((await f.fn(req(body,token,'https://evil.example'))).status,403);assert.equal((await f.fn(req({action:'preview'},''))).status,401);assert.equal(f.calls.length,0);
});
test('disabled service and stale summary never check passwords or accept jobs',async()=>{
 const f=setup({'/rest/v1/rpc/account_deletion_preview':()=>Response.json({available:false})});assert.equal((await f.fn(req(body))).status,503);assert.equal(f.calls.length,2);
 const g=setup();assert.equal((await g.fn(req({...body,fingerprint:'stale'}))).status,409);assert.equal(g.calls.length,2);
});
test('wrong password or mismatched reauth user cannot queue',async()=>{
 const f=setup({'/auth/v1/token?grant_type=password':()=>Response.json({error:'invalid'},{status:400})});assert.equal((await f.fn(req(body))).status,401);assert.ok(!f.calls.some(x=>x.path.endsWith('account_deletion_request')));
 const g=setup({'/auth/v1/token?grant_type=password':()=>Response.json({user:{id:sid},access_token:'temp'})});assert.equal((await g.fn(req(body))).status,401);assert.equal(g.calls.at(-1).path,'/auth/v1/logout?scope=local');
});
test('temporary-session revoke failure is fail-closed and sanitized',async()=>{
 const f=setup({'/auth/v1/logout?scope=local':()=>{throw Error('server-secret')}});const r=await f.fn(req(body));assert.equal(r.status,503);assert.ok(!(await r.text()).includes('server-secret'));assert.ok(!f.calls.some(x=>x.path.endsWith('account_deletion_request')));
});
test('receipt requires high-entropy secret; no user data is returned for mismatch',async()=>{
 const f=setup();assert.equal((await f.fn(req({action:'status',request_id:id,receipt:'short'},''))).status,400);
 assert.equal((await f.fn(req({action:'status',request_id:id,receipt:'b'.repeat(64)},''))).status,404);assert.equal(f.calls.length,1);
});
