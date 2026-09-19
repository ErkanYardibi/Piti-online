import test from 'node:test';
import assert from 'node:assert/strict';
import {createHandler} from '../supabase/functions/demo-admin/handler.mjs';
const demoUrl='https://demo.example.invalid';
const request=(token='admin-token',action='save_demo')=>new Request(demoUrl,{method:'POST',headers:{Origin:'https://mypiti.online',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify({action,args:{version:1,data:{events:[]}}})});
test('missing credentials cannot reach either database',async()=>{
 const handler=createHandler({demoUrl,demoServiceKey:'secret',fetchImpl:()=>{throw Error('must not call')}});
 assert.equal((await handler(request(''))).status,401);
});
test('failed production admin/MFA check prevents demo writes',async()=>{
 const calls=[];const handler=createHandler({demoUrl,demoServiceKey:'secret',fetchImpl:async(url,options)=>{calls.push({url,options});return Response.json({message:'denied'},{status:403})}});
 assert.equal((await handler(request())).status,403);assert.equal(calls.length,1);
 assert.equal(JSON.parse(calls[0].options.body).p_action,'overview');
 assert.notEqual(calls[0].options.headers.apikey,'secret');
});
test('authorized publish writes only to demo and uses separate credentials',async()=>{
 const calls=[];const handler=createHandler({demoUrl,demoServiceKey:'secret',fetchImpl:async(url,options)=>{calls.push({url,options});return Response.json({ok:true})}});
 assert.equal((await handler(request())).status,200);assert.equal(calls.length,2);
 assert.equal(calls[0].options.headers.Authorization,'Bearer admin-token');
 assert.equal(calls[1].url,demoUrl+'/rest/v1/rpc/publish_demo');
 assert.equal(calls[1].options.headers.Authorization,'Bearer secret');
 assert.equal(JSON.parse(calls[1].options.body).p_action,'save_demo');
});
test('production URL cannot be configured as demo backend',()=>{
 assert.throws(()=>createHandler({demoUrl:'https://objwhegswugyeibcnjfr.supabase.co',demoServiceKey:'secret'}),/separate project/);
});
