const test=require('node:test'),assert=require('node:assert/strict');
const {JSDOM}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const {render}=require('../assets/account-deletion.js');
const initial={available:true,summary:{role:'pt',client_records:2,past_transfers:1},fingerprint:'fp',notice:'Test kapsamı',max_hours:24};
function setup(responder){
 const dom=new JSDOM('<main></main>'),target=dom.window.document.querySelector('main'),calls=[];let ctx={userId:'one',ready:true,demo:false};
 const client={auth:{getSession:async()=>({data:{session:{user:{id:'one'},access_token:'bound-token'}}})}};
 const args={target,client,context:()=>ctx,url:'https://db.example',key:'public',fetcher:async(url,options)=>{const b=JSON.parse(options.body);calls.push({b,options});return responder?responder(b):Response.json(b.action==='preview'?initial:{id:b.request_id,state:'requested'});}};
 return {dom,calls,args,setContext:c=>ctx=c,render:()=>render(args)};
}
test('no automatic request; explicit summary and confirmation required; password cleared',async()=>{
 const f=setup(),panel=f.render();assert.equal(f.calls.length,0);await panel.querySelector('[data-delete-preview]').onclick();
 const form=panel.querySelector('form');form.elements.password.value='password';form.elements.confirmation.value='wrong';await form.onsubmit({preventDefault(){}});assert.equal(f.calls.length,1);
 form.elements.confirmation.value='HESABIMI SIL';await form.onsubmit({preventDefault(){}});
 assert.equal(f.calls.length,2);assert.equal(form.elements.password.value,'');assert.equal(f.calls[1].options.headers.Authorization,'Bearer bound-token');assert.ok(!('user_id' in f.calls[1].b));assert.match(panel.textContent,/henüz silinmedi/);f.dom.window.close();
});
test('unavailable service keeps destructive confirmation hidden; notice is text',async()=>{
 const f=setup(()=>Response.json({...initial,available:false,notice:'<img src=x onerror=alert(1)>'})),panel=f.render();await panel.querySelector('[data-delete-preview]').onclick();assert.equal(panel.querySelector('form').hidden,true);assert.equal(panel.querySelector('img'),null);assert.match(panel.textContent,/Hiçbir veri silinmedi/);f.dom.window.close();
});
test('demo and stale account contexts cannot send requests',async()=>{
 const f=setup();f.setContext({userId:'one',ready:true,demo:true});assert.equal(f.render(),null);f.setContext({userId:'one',ready:true,demo:false});const panel=f.render();f.setContext({userId:'two',ready:true,demo:false});await panel.querySelector('[data-delete-preview]').onclick();assert.equal(f.calls.length,0);f.dom.window.close();
});
test('cancel clears password and does not submit; failed request never reports completion',async()=>{
 const f=setup(b=>b.action==='preview'?Response.json(initial):Response.json({error:'İşlem tamamlanamadı.'},{status:503})),panel=f.render();await panel.querySelector('[data-delete-preview]').onclick();const form=panel.querySelector('form');
 form.elements.password.value='password';panel.querySelector('[data-delete-cancel]').onclick();assert.equal(form.elements.password.value,'');assert.equal(f.calls.length,1);
 await panel.querySelector('[data-delete-preview]').onclick();form.elements.password.value='password';form.elements.confirmation.value='HESABIMI SIL';await form.onsubmit({preventDefault(){}});assert.match(panel.querySelector('[data-delete-message]').textContent,/tamamlanamadı/);f.dom.window.close();
});
