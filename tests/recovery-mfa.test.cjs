const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const gateCode=html.slice(html.indexOf('async function showRecoveryPasswordGate()'),html.indexOf('async function openForgotPassword()'));
const listenerCode=html.slice(html.indexOf('db.auth.onAuthStateChange((event,session)=>{'),html.indexOf('\n });',html.indexOf('db.auth.onAuthStateChange((event,session)=>{'))+5);
async function setup(options={}){
 const nodes={},calls=[],storage=new Map([['pitiRecoveryPending','1']]);
 let callback,level=options.level||'aal1',lookupError=options.lookupError;
 const factors=options.factors||[{id:'totp-existing',factor_type:'totp',status:'verified'}];
 const ctx={
  document:{querySelector:s=>nodes[s]||null},
  openModal(markup){for(const [,id] of markup.matchAll(/id="([^"]+)"/g))nodes['#'+id]={value:'',textContent:'',hidden:id==='recoveryMfaField',disabled:id==='saveRecoveryPassword',focus(){this.focused=true}}},
  sessionStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},
  location:{pathname:'/',replace:url=>calls.push(['replace',url]),reload:()=>calls.push(['reload'])},
  authUser:null,demoMode:false,cloudSyncTimer:null,clearTimeout(){},setTimeout:fn=>fn(),
  activateSession:()=>calls.push(['activate']),
  db:{auth:{
   onAuthStateChange:fn=>{callback=fn},
   mfa:{
    getAuthenticatorAssuranceLevel:async()=>({data:{currentLevel:level,nextLevel:factors.some(f=>f.status==='verified')?'aal2':level},error:lookupError}),
    listFactors:async()=>({data:{totp:factors.filter(f=>f.factor_type==='totp'),all:factors},error:options.factorError}),
    challengeAndVerify:async args=>{calls.push(['verify',args]);if(options.verifyError)return {error:options.verifyError};level='aal2';callback('MFA_CHALLENGE_VERIFIED',{});return {error:null}}
   },
   updateUser:async args=>{calls.push(['update',args]);callback('USER_UPDATED',{});return {error:options.updateError}},
   signOut:async()=>{calls.push(['signOut']);callback('SIGNED_OUT');return {error:null}}
  }}
 };
 vm.createContext(ctx);vm.runInContext(gateCode,ctx);vm.runInContext(listenerCode,ctx);
 await ctx.showRecoveryPasswordGate();
 nodes['#recoveryPassword'].value=nodes['#recoveryPasswordAgain'].value='test-password';
 return {nodes,calls,storage,submit:()=>nodes['#saveRecoveryPassword'].onclick(),retryLookup:()=>{lookupError=null}};
}
test('MFA recovery displays code field and blocks missing or malformed codes',async()=>{
 const s=await setup();assert.equal(s.nodes['#recoveryMfaField'].hidden,false);
 for(const code of ['', 'abc123', '12345']){s.nodes['#recoveryMfaCode'].value=code;await s.submit();assert.equal(s.calls.length,0)}
 assert.match(s.nodes['#recoveryError'].textContent,/6 haneli/);
});
test('invalid MFA code cannot update password',async()=>{
 const s=await setup({verifyError:{message:'invalid code'}});s.nodes['#recoveryMfaCode'].value='123456';await s.submit();
 assert.deepEqual(s.calls.map(c=>c[0]),['verify']);assert.match(s.nodes['#recoveryError'].textContent,/Kod doğrulanamadı/);
 assert.equal(s.nodes['#recoveryMfaCode'].value,'');assert.equal(s.nodes['#saveRecoveryPassword'].disabled,false);
});
test('valid MFA is verified before password update and redirects without reloading recovery URL',async()=>{
 const s=await setup();s.nodes['#recoveryMfaCode'].value='123456';await s.submit();
 assert.deepEqual(s.calls.map(c=>c[0]),['verify','update','signOut','replace']);
 assert.equal(s.calls[0][1].factorId,'totp-existing');assert.equal(s.calls[0][1].code,'123456');
 assert.equal(s.calls[3][1],'/?reset=done');assert.equal(s.storage.get('pitiResetDone'),'1');assert.equal(s.storage.has('pitiRecoveryPending'),false);
});
for(const options of [{factors:[]},{level:'aal2'},{factors:[{id:'draft',factor_type:'totp',status:'unverified'}]}])test('no challenge for '+JSON.stringify(options),async()=>{
 const s=await setup(options);assert.equal(s.nodes['#recoveryMfaField'].hidden,true);await s.submit();
 assert.deepEqual(s.calls.map(c=>c[0]),['update','signOut','replace']);
});
test('assurance lookup failure blocks update and can be retried',async()=>{
 const s=await setup({lookupError:{message:'offline'},factors:[]});await s.submit();assert.equal(s.calls.length,0);
 s.retryLookup();await s.submit();assert.equal(s.calls[0][0],'update');
});
test('factor lookup failure blocks password update',async()=>{
 const s=await setup({factorError:{message:'offline'}});await s.submit();assert.equal(s.calls.length,0);
});
test('unsupported verified factor blocks update',async()=>{
 const s=await setup({factors:[{id:'phone',factor_type:'phone',status:'verified'}]});await s.submit();assert.equal(s.calls.length,0);
 assert.match(s.nodes['#recoveryError'].textContent,/desteklenmiyor/);
});
test('password validation prevents any verification attempt',async()=>{
 const s=await setup();s.nodes['#recoveryPasswordAgain'].value='different';await s.submit();assert.equal(s.calls.length,0);
 assert.match(s.nodes['#recoveryError'].textContent,/eşleşmiyor/);
});
test('failed password update preserves recovery session after successful MFA',async()=>{
 const s=await setup({updateError:{message:'Use a different password'}});s.nodes['#recoveryMfaCode'].value='123456';await s.submit();
 assert.deepEqual(s.calls.map(c=>c[0]),['verify','update']);assert.equal(s.storage.get('pitiRecoveryPending'),'1');assert.equal(s.storage.has('pitiResetDone'),false);
 await s.submit();assert.deepEqual(s.calls.map(c=>c[0]),['verify','update','update']);
});
