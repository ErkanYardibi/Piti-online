const test=require('node:test'),assert=require('node:assert/strict');
const {JSDOM}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const {render}=require('../assets/push-preferences.js');
const defaults={messages:true,sessions:true,tasks:true,payments:true};
const flush=()=>new Promise(r=>setTimeout(r,5));
function setup(rpc){
 const dom=new JSDOM('<main></main>'),target=dom.window.document.querySelector('main');
 let ctx={ready:true,userId:'one',demo:false};const calls=[];
 const client={rpc:async(...args)=>{calls.push(args);return rpc?rpc(...args):{data:defaults};}};
 return {target,calls,dom,setContext:c=>ctx=c,render:()=>render({target,client,context:()=>ctx})};
}
test('preferences load before edit; save sends booleans without a target user',async()=>{
 const f=setup((name,args)=>({data:name==='get_push_preferences'?{...defaults,tasks:false}:{messages:args.p_messages,sessions:args.p_sessions,tasks:args.p_tasks,payments:args.p_payments}}));
 const form=f.render();assert.equal(form.querySelector('fieldset').disabled,true);await flush();
 assert.equal(form.elements.tasks.checked,false);form.elements.messages.checked=false;
 await form.onsubmit({preventDefault(){}});
 assert.deepEqual(f.calls[1],['set_push_preferences',{p_messages:false,p_sessions:true,p_tasks:false,p_payments:true}]);
 assert.match(form.textContent,/tercihlerin kaydedildi/);f.dom.window.close();
});
test('failed load stays disabled, retry works, failed save preserves choices',async()=>{
 let fail=true;const f=setup((name)=>fail?{error:{message:'unavailable'}}:{data:defaults});
 const form=f.render();await flush();assert.equal(form.querySelector('fieldset').disabled,true);
 fail=false;await form.querySelector('[data-preference-retry]').onclick();
 form.elements.payments.checked=false;fail=true;await form.onsubmit({preventDefault(){}});
 assert.equal(form.elements.payments.checked,false);assert.equal(form.querySelector('fieldset').disabled,false);assert.match(form.textContent,/Kaydedilemedi/);f.dom.window.close();
});
test('late result cannot populate another account and stale form cannot save',async()=>{
 let finish;const f=setup(()=>new Promise(r=>finish=r)),form=f.render();
 f.setContext({ready:true,userId:'two',demo:false});finish({data:defaults});await flush();
 assert.equal(form.querySelector('fieldset').disabled,true);await form.onsubmit({preventDefault(){}});assert.equal(f.calls.length,1);f.dom.window.close();
});
test('demo and logged-out users do not load preferences',()=>{
 const f=setup();f.setContext({ready:true,userId:'one',demo:true});assert.equal(f.render(),null);
 f.setContext({ready:false});assert.equal(f.render(),null);assert.equal(f.calls.length,0);f.dom.window.close();
});
