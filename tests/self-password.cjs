const {JSDOM}=require(process.env.PITI_JSDOM_PATH||'jsdom'),fs=require('fs'),assert=require('assert/strict');
(async()=>{
 const html=fs.readFileSync('index.html','utf8');const start=html.indexOf('function renderSelfPasswordSettings('),end=html.indexOf('function showPasswordGate()',start);
 const dom=new JSDOM('<main id="view"></main>',{runScripts:'outside-only'}),w=dom.window,d=w.document;
 w.eval("let adminMode=false,state={page:'profile'},demoMode=false,authUser={id:'owner'},view=document.getElementById('view'),db={auth:{updateUser:async data=>{window.calls.push(data);return {data:{user:{id:'owner'}}}}}};window.run=code=>eval(code);"+html.slice(start,end));
 w.calls=[];
 for(const role of ['pt','member','admin']){
  w.run("view.innerHTML='';renderSelfPasswordSettings(view)");
  const form=d.querySelector('form');d.querySelector('#selfNewPassword').value='abcdef';d.querySelector('#selfRepeatPassword').value='wrong';await form.onsubmit({preventDefault(){}});assert.equal(d.querySelector('#selfPasswordStatus').textContent,'Şifreler aynı olmalı.');
  d.querySelector('#selfRepeatPassword').value='abcdef';await form.onsubmit({preventDefault(){}});assert.ok(d.querySelector('#selfPasswordStatus').textContent.includes('Şifren değiştirildi'));assert.equal(d.querySelector('#selfNewPassword').value,'');
 }
 assert.equal(w.calls.length,3);assert.deepEqual(Object.keys(w.calls[0]),['password']);
 w.run("view.innerHTML='';demoMode=true;renderSelfPasswordSettings(view)");assert.equal(d.querySelector('form'),null);assert.equal(w.calls.length,3);
 w.run("demoMode=false;view.innerHTML='';renderSelfPasswordSettings(view);db.auth.updateUser=async()=>({error:{message:'Test sunucu hatası'}})");d.querySelector('#selfNewPassword').value='abcdef';d.querySelector('#selfRepeatPassword').value='abcdef';await d.querySelector('form').onsubmit({preventDefault(){}});assert.equal(d.querySelector('#selfPasswordStatus').textContent,'Test sunucu hatası');assert.equal(d.querySelector('button').disabled,false);
 dom.window.close();console.log('PASS: own password validation, success clearing, server error, no target-user field and DEMO protection');
})().catch(e=>{console.error(e);process.exit(1)});
