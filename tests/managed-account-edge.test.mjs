import {test} from 'node:test';import assert from 'node:assert/strict';import {createHandler} from '../supabase/functions/manage-client-account/handler.mjs';
const pt='11111111-1111-4111-8111-111111111111',member='22222222-2222-4222-8222-222222222222',client='33333333-3333-4333-8333-333333333333';
function harness({role='pt',required=false,valid=true,existing=false,finishError=false,samePassword=false,noEmail=false,taken=false,loginFail=false}={}){
 const calls=[];const actor=role==='pt'?pt:member;
 const fetchImpl=async(url,options)=>{const path=new URL(url).pathname;const body=options.body?JSON.parse(options.body):null;calls.push({path,method:options.method,body,authorization:options.headers.Authorization});let data={};let status=200;
 if(path==='/rest/v1/profiles')data=taken?[{id:member}]:[];
 else if(path==='/rest/v1/rpc/username_login_lookup')data='internal@accounts.mypiti.invalid';
 else if(path==='/auth/v1/token'){if(loginFail){status=400;data={message:'Invalid login credentials'}}else data={access_token:'access',refresh_token:'refresh'}}
 else if(path==='/auth/v1/user')data={id:actor};
 else if(path==='/rest/v1/rpc/account_context')data={role,must_change_password:required,session_valid:valid};
 else if(path==='/rest/v1/clients')data=options.method==='GET'&&url.includes('user_id=eq.'+member)&&role==='member'?[{id:client}]:[];
 else if(path==='/rest/v1/rpc/managed_account_begin')data={operation_id:'op-1',client_id:client,user_id:body.p_kind==='create'?null:member,email:noEmail?null:'member@example.invalid',full_name:'Member'};
 else if(path==='/auth/v1/admin/users'&&options.method==='POST'){if(existing){status=422;data={message:'A user with this email address has already been registered'}}else data={id:member}}
 else if(path==='/rest/v1/rpc/managed_account_finish'&&finishError){status=400;data={message:'operation expired'}}
 else if(path==='/rest/v1/rpc/consume_entry_link')data={user_id:member,email:'member@example.invalid'};
 else if(path==='/auth/v1/admin/generate_link')data={hashed_token:'hashed-token'};
 else if(path==='/auth/v1/verify')data={user:{id:member},access_token:'member-access',refresh_token:'member-refresh'};
 else if(path==='/rest/v1/rpc/check_new_password')data=!samePassword;
 return new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
 };
 const handler=createHandler({url:'https://unit.invalid',serviceKey:'server-only-secret',fetchImpl});
 const call=(body,auth='actor-token',origin='https://www.mypiti.online')=>handler(new Request('https://unit.invalid/function',{method:'POST',headers:{...(auth?{Authorization:'Bearer '+auth}:{}),Origin:origin},body:JSON.stringify(body)}));
 return {calls,call,handler};
}
test('unauthenticated account management is rejected before any privileged call',async()=>{const h=harness();assert.equal((await h.call({action:'reset',client_id:client,password:'ValidNewPassword!'},'')).status,401);assert.equal(h.calls.length,0)});
test('member cannot create or reset accounts',async()=>{const h=harness({role:'member'});assert.equal((await h.call({action:'reset',client_id:client,password:'ValidNewPassword!'})).status,403);assert.ok(!h.calls.some(x=>x.path.includes('admin/users')))});
test('expired session cannot manage an account',async()=>{const h=harness({valid:false});assert.equal((await h.call({action:'create',client_id:client,password:'ValidNewPassword!'})).status,401)});
test('create confirms email server-side, assigns member role, and returns no server key or password',async()=>{const h=harness();const r=await h.call({action:'create',client_id:client,password:'TemporaryPassword!'});assert.equal(r.status,200);const result=await r.json();const create=h.calls.find(x=>x.path==='/auth/v1/admin/users');assert.equal(create.body.email_confirm,true);assert.equal(create.body.app_metadata.account_role,'member');assert.equal(create.body.app_metadata.must_change_password,true);assert.match(result.entry_url,/#entry=[a-f0-9]{64}$/);assert.ok(!JSON.stringify(result).includes('server-only-secret'));assert.ok(!JSON.stringify(result).includes('TemporaryPassword!'));assert.equal(h.calls.find(x=>x.path.endsWith('managed_account_begin')).body.p_actor,pt)});
test('existing email never triggers password reset or deletion',async()=>{const h=harness({existing:true});assert.equal((await h.call({action:'create',client_id:client,password:'TemporaryPassword!'})).status,400);assert.ok(!h.calls.some(x=>['PUT','DELETE'].includes(x.method)));assert.ok(h.calls.some(x=>x.path.endsWith('managed_account_cancel')))});
test('entry exchange consumes token before minting a session and does not send mail',async()=>{const h=harness();const r=await h.call({action:'redeem',token:'a'.repeat(64)},'');assert.equal(r.status,200);assert.deepEqual(await r.json(),{access_token:'member-access',refresh_token:'member-refresh'});assert.ok(h.calls[0].path.endsWith('consume_entry_link'));assert.ok(h.calls.some(x=>x.path==='/auth/v1/admin/generate_link'));assert.ok(!h.calls.some(x=>x.path.includes('/invite')||x.path.includes('/otp')))});
test('mandatory password completion targets authenticated member, ignoring supplied client or user',async()=>{const h=harness({role:'member',required:true});const r=await h.call({action:'password',client_id:pt,user_id:pt,password:'MyPersonalPassword!'});assert.equal(r.status,200);assert.ok(h.calls.some(x=>x.path==='/auth/v1/admin/users/'+member&&x.method==='PUT'));assert.equal(h.calls.find(x=>x.path.endsWith('managed_account_begin')).body.p_client,client)});
test('same temporary password cannot complete first login',async()=>{const h=harness({role:'member',required:true,samePassword:true});assert.equal((await h.call({action:'password',password:'TemporaryPassword!'})).status,400);assert.ok(!h.calls.some(x=>x.method==='PUT'))});
test('untrusted origins and oversized payloads rejected',async()=>{const h=harness();assert.equal((await h.call({action:'create'},'actor-token','https://evil.invalid')).status,403);assert.equal((await h.call({action:'create',password:'x'.repeat(9000)})).status,413);assert.equal(h.calls.length,0)});

for(const action of ['create','reset','password'])test(action+' accepts six characters and rejects five before mutation',async()=>{
 const options=action==='password'?{role:'member',required:true}:{};
 const short=harness(options);assert.equal((await short.call({action,client_id:client,password:'Ab12!'})).status,400);assert.ok(!short.calls.some(x=>x.path.includes('admin/users')||x.path.endsWith('managed_account_begin')));
 const valid=harness(options);assert.equal((await valid.call({action,client_id:client,password:'Ab12!x'})).status,200);
});


test('username login validates password via Auth and returns only session tokens',async()=>{const h=harness();const r=await h.call({action:'login',username:'MÜŞTERİ1',password:'Secret123'},'');assert.equal(r.status,200);assert.deepEqual(await r.json(),{access_token:'access',refresh_token:'refresh'});assert.equal(h.calls[0].body.p_username,'musteri1');assert.ok(h.calls.some(c=>c.path==='/auth/v1/token'&&c.body.password==='Secret123'));assert.ok(!h.calls.some(c=>c.path.includes('generate_link')))});
test('wrong password returns generic login error and no tokens',async()=>{const h=harness({loginFail:true});const r=await h.call({action:'login',username:'musteri1',password:'wrong'},'');assert.equal(r.status,401);assert.ok(!(await r.json()).access_token)});
test('customer creation requires a recovery email',async()=>{const h=harness({noEmail:true});const r=await h.call({action:'create_client',first_name:'Gonca',last_name:'Test',username:'Müşteri1',password:'Ab12!x'});assert.equal(r.status,400);assert.match((await r.json()).error,/e-posta/i);assert.ok(!h.calls.some(c=>c.path==='/rest/v1/clients'&&c.method==='POST'))});
test('customer creation stores the required recovery email',async()=>{const h=harness();const r=await h.call({action:'create_client',first_name:'Gonca',last_name:'Test',username:'Müşteri1',email:'gonca@example.com',password:'Ab12!x'});assert.equal(r.status,200);const create=h.calls.find(c=>c.path==='/rest/v1/clients'&&c.method==='POST');assert.equal(create.body.email,'gonca@example.com');assert.equal(create.body.weight,null);assert.equal(create.body.pt_id,pt);const user=h.calls.find(c=>c.path==='/auth/v1/admin/users');assert.equal(user.body.email,'member@example.invalid');assert.equal(user.body.app_metadata.username,'musteri1');assert.equal((await r.json()).username,'musteri1')});
test('taken username fails before a client or account is created',async()=>{const h=harness({taken:true});const r=await h.call({action:'create_client',first_name:'A',last_name:'B',username:'taken',password:'Ab12!x'});assert.equal(r.status,409);assert.ok(!h.calls.some(c=>c.path==='/rest/v1/clients'&&c.method==='POST'))});
test('member cannot create client even with valid username',async()=>{const h=harness({role:'member'});assert.equal((await h.call({action:'create_client',first_name:'A',last_name:'B',username:'valid',password:'Ab12!x'})).status,403)});
test('failed account creation cleans only new unlinked client and new user',async()=>{const h=harness({finishError:true});assert.equal((await h.call({action:'create_client',first_name:'A',last_name:'B',username:'valid',email:'a@example.com',password:'Ab12!x'})).status,400);assert.ok(h.calls.some(c=>c.path==='/rest/v1/clients'&&c.method==='DELETE'));assert.ok(h.calls.some(c=>c.path==='/auth/v1/admin/users/'+member&&c.method==='DELETE'))});
