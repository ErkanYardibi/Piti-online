const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {JSDOM}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const html=fs.readFileSync('index.html','utf8');
async function setup(options={}){
 const dom=new JSDOM(html.slice(html.indexOf('<div class="authBack" id="authBack">'),html.indexOf('<script src="/assets/offline-guard.js">')),{url:'https://mypiti.online/',runScripts:'outside-only'});
 const w=dom.window,d=w.document,calls=[],availability=[...(options.availability||[true])];
 Object.assign(w,{recoveryCallback:{requested:false},recoveryLinkFailed:false,authUser:null,demoMode:false,openForgotPassword(){},
  activateSession:async session=>{calls.push(['activate',session.user.id])},
  managedAccountRequest:async args=>{calls.push(['usernameLogin',args]);return {access_token:'fixture',refresh_token:'fixture'}},
  db:{rpc:async(name,args)=>{if(name==='app_settings')return {data:null};calls.push(['availability',args]);return {data:availability.length?availability.shift():true,error:options.lookupError}},auth:{
   onAuthStateChange(){},getSession:async()=>({data:{session:null}}),
   signUp:async args=>{calls.push(['signup',args]);return {data:{session:{user:{id:'new-user'}}},error:options.signupError}},
   signInWithPassword:async args=>{calls.push(['emailLogin',args]);return {data:{session:{user:{id:'email-user'}}}}},
   setSession:async()=>({data:{session:{user:{id:'username-user'}}}})
  }}
 });
 w.eval(html.slice(html.indexOf('function setAuthBusy('),html.indexOf('let sessionActivation=')));
 w.eval(html.slice(html.indexOf('function normalizeLoginName('),html.indexOf('function renderUsernameSettings(')));
 w.eval(html.slice(html.indexOf('async function initAuth()'),html.indexOf('function packageEnd(')));
 await w.initAuth();d.querySelector('#signUpBtn').click();
 d.querySelector('#authName').value='Test User';d.querySelector('#authUsername').value='ÇAĞRI_1';d.querySelector('#authEmail').value='USER@EXAMPLE.COM';d.querySelector('#authPassword').value='123456';
 return {w,d,calls,close:()=>dom.window.close(),submit:()=>d.querySelector('#authForm').onsubmit({preventDefault(){}})};
}
for(const role of ['pt','member'])test('signup atomically includes normalized username and mandatory email for '+role,async()=>{
 const s=await setup();try{
  s.d.querySelector('#authRole').value=role;await s.submit();
  assert.deepEqual(s.calls.map(c=>c[0]),['availability','signup','activate']);
  const request=s.calls[1][1];assert.equal(request.email,'user@example.com');assert.equal(request.options.data.username,'cagri_1');assert.equal(request.options.data.account_type,role);
  assert.equal(s.d.querySelector('#authUsername').value,'cagri_1');assert.equal(s.d.querySelector('#authUsername').required,true);assert.equal(s.d.querySelector('#authEmail').required,true);
 }finally{s.close()}
});
test('empty, malformed and reserved usernames cannot reach signup',async()=>{
 const s=await setup();try{for(const name of ['', 'ab', 'has space','admin','DEMO','x'.repeat(31)]){s.d.querySelector('#authUsername').value=name;await s.submit();assert.equal(s.calls.length,0)}}finally{s.close()}
});
test('email remains mandatory even when username is valid',async()=>{
 const s=await setup();try{for(const email of ['', 'username-only']){s.d.querySelector('#authEmail').value=email;await s.submit();assert.equal(s.calls.length,0)}}finally{s.close()}
});
test('taken username shows a clear message before creating any account',async()=>{
 const s=await setup({availability:[false]});try{await s.submit();assert.deepEqual(s.calls.map(c=>c[0]),['availability']);assert.match(s.d.querySelector('#authError').textContent,/kullanıcı adı alınmış/);assert.equal(s.d.querySelector('#loginSubmit').disabled,false)}finally{s.close()}
});
test('failed availability check does not silently create a username-less account',async()=>{
 const s=await setup({lookupError:{message:'offline'}});try{await s.submit();assert.deepEqual(s.calls.map(c=>c[0]),['availability']);assert.match(s.d.querySelector('#authError').textContent,/kontrol edilemedi/)}finally{s.close()}
});
test('uniqueness race is reported without activating a partial signup',async()=>{
 const s=await setup({availability:[true,false],signupError:{message:'Database error saving new user'}});try{await s.submit();assert.deepEqual(s.calls.map(c=>c[0]),['availability','signup','availability']);assert.match(s.d.querySelector('#authError').textContent,/kullanıcı adı alınmış/)}finally{s.close()}
});
test('other signup errors remain visible and allow retry',async()=>{
 const s=await setup({signupError:{message:'Email rate limit exceeded'}});try{await s.submit();assert.match(s.d.querySelector('#authError').textContent,/Email rate limit/);assert.equal(s.d.querySelector('#loginSubmit').disabled,false)}finally{s.close()}
});
test('return to login hides registration username and permits both login identifiers',async()=>{
 const s=await setup();try{
  s.d.querySelector('#authUsername').value='x';s.d.querySelector('#signUpBtn').click();
  assert.equal(s.d.querySelector('#registrationUsername').hidden,true);assert.equal(s.d.querySelector('#authUsername').required,false);assert.equal(s.d.querySelector('#authUsername').disabled,true);
  s.d.querySelector('#authEmail').value='ÇAĞRI_1';await s.submit();assert.equal(s.calls[0][0],'usernameLogin');assert.equal(s.calls[0][1].username,'cagri_1');
  assert.equal(s.d.querySelector('#authUsername').disabled,true,'busy reset cannot enable hidden invalid field');
  s.d.querySelector('#authEmail').value='user@example.com';await s.submit();assert.ok(s.calls.some(c=>c[0]==='emailLogin'));
 }finally{s.close()}
});
