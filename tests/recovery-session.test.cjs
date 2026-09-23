const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const helpers=html.slice(html.indexOf('function recoveryLinkDetected()'),html.indexOf('async function showRecoveryPasswordGate()'));
const init=html.slice(html.indexOf('async function initAuth()'),html.indexOf('function packageEnd('));
async function setup(options={}){
 let url=new URL(options.url||'https://mypiti.online/'),callback;
 const calls=[],tasks=[],storage=new Map(Object.entries(options.storage||{})),nodes={};
 const node=selector=>nodes[selector]||(nodes[selector]={value:'',hidden:false,textContent:'',prepend(){}});
 const ctx={URL,URLSearchParams,
  location:{get href(){return url.href},get hash(){return url.hash},get search(){return url.search},get pathname(){return url.pathname},replace:value=>calls.push(['navigate',value]),reload:()=>calls.push(['reload'])},
  history:{state:null,replaceState(state,title,value){url=new URL(value,url)}},
  sessionStorage:{getItem:key=>storage.get(key)||null,setItem:(key,value)=>storage.set(key,value),removeItem:key=>storage.delete(key)},
  document:{querySelector:node,createElement:()=>({})},
  authUser:null,demoMode:false,cloudSyncTimer:null,
  clearTimeout(){},setTimeout:fn=>{tasks.push(fn)},
  authMessage:message=>{node('#authError').textContent=message},setAuthBusy(){},
  closeModal:()=>calls.push(['closeModal']),showRecoveryPasswordGate:()=>calls.push(['gate']),openForgotPassword(){},
  activateSession:async session=>{ctx.authUser=session.user;calls.push(['activate',session.user.id])},
  signInWithIdentifier:async()=>({data:{session:{user:{id:'manual-login'}}}}),
  db:{rpc:async()=>({data:null}),auth:{onAuthStateChange:fn=>{callback=fn},getSession:async()=>{
   for(const event of options.initEvents||[])callback(event,options.session||null);
   return {data:{session:options.session||null},error:options.error||null};
  }}}
 };
 vm.createContext(ctx);vm.runInContext(helpers,ctx);
 ctx.recoveryCallback=ctx.readRecoveryCallback();ctx.recoveryLinkFailed=ctx.recoveryCallback.failed;
 if(options.sdkClearsUrl)url=new URL('/',url);
 vm.runInContext(init,ctx);await ctx.initAuth();
 async function flush(){while(tasks.length)await tasks.shift()()}
 await flush();
 return {ctx,calls,storage,nodes,get url(){return url},async emit(event,session=null){callback(event,session);await flush()}};
}
function noNavigation(s){assert.ok(!s.calls.some(c=>['navigate','reload'].includes(c[0])))}
function linkError(s){assert.match(s.nodes['#authError'].textContent,/yeni bir şifre sıfırlama bağlantısı iste/);assert.equal(s.storage.has('pitiRecoveryPending'),false);assert.equal(s.nodes['#authBack'].hidden,false)}
test('expired email callback with repeated SIGNED_OUT events never navigates',async()=>{
 const s=await setup({url:'https://mypiti.online/?passwordReset=1#access_token=old&refresh_token=old&type=recovery',error:{message:'invalid token'},initEvents:['SIGNED_OUT']});
 for(let i=0;i<3;i++)await s.emit('SIGNED_OUT');
 linkError(s);noNavigation(s);assert.equal(s.url.href,'https://mypiti.online/');assert.ok(!s.calls.some(c=>c[0]==='gate'));
});
test('used-link URL error is retained even when SDK clears URL and returns a previous session',async()=>{
 const s=await setup({url:'https://mypiti.online/?passwordReset=1#error=access_denied&error_code=otp_expired&error_description=Expired',sdkClearsUrl:true,session:{user:{id:'previous-account'}},initEvents:['INITIAL_SESSION']});
 linkError(s);noNavigation(s);assert.ok(!s.calls.some(c=>['gate','activate'].includes(c[0])));
 await s.emit('TOKEN_REFRESHED',{user:{id:'previous-account'}});assert.ok(!s.calls.some(c=>c[0]==='activate'));
});
test('error redirect without recovery query also shows a stable message',async()=>{
 const s=await setup({url:'https://mypiti.online/#error=access_denied&error_code=otp_expired'});
 linkError(s);noNavigation(s);assert.equal(s.url.hash,'');
});
for(const options of [{url:'https://mypiti.online/?passwordReset=1'},{storage:{pitiRecoveryPending:'1'}}])test('missing recovery session does not leave a blank or looping screen '+JSON.stringify(options),async()=>{
 const s=await setup(options);linkError(s);noNavigation(s);assert.ok(!s.calls.some(c=>c[0]==='gate'));
});
test('valid recovery preserves pending session and cleans URL without navigation',async()=>{
 const s=await setup({url:'https://mypiti.online/?passwordReset=1&keep=yes#type=recovery&access_token=fake&refresh_token=fake',session:{user:{id:'recovery-user'}},initEvents:['INITIAL_SESSION']});
 noNavigation(s);assert.deepEqual(s.calls,[['gate']]);assert.equal(s.storage.get('pitiRecoveryPending'),'1');assert.equal(s.url.href,'https://mypiti.online/?keep=yes');
 await s.emit('TOKEN_REFRESHED',{user:{id:'recovery-user'}});assert.ok(!s.calls.some(c=>c[0]==='activate'));
});
test('recovery session loss closes the password dialog without navigation',async()=>{
 const s=await setup({storage:{pitiRecoveryPending:'1'},session:{user:{id:'recovery-user'}}});
 await s.emit('SIGNED_OUT');linkError(s);noNavigation(s);assert.equal(s.calls.at(-1)[0],'closeModal');
});
test('SIGNED_OUT during normal initialization does not reload',async()=>{
 const s=await setup({initEvents:['SIGNED_OUT']});await s.emit('SIGNED_OUT');noNavigation(s);assert.equal(s.ctx.authUser,null);
});
test('normal active-user logout navigates once to a clean login URL',async()=>{
 const s=await setup({session:{user:{id:'normal-user'}}});
 assert.deepEqual(s.calls,[['activate','normal-user']]);
 await s.emit('SIGNED_OUT');await s.emit('SIGNED_OUT');
 assert.deepEqual(s.calls,[['activate','normal-user'],['navigate','/']]);
});
test('manual login remains available after an invalid recovery link',async()=>{
 const s=await setup({url:'https://mypiti.online/?passwordReset=1#error_code=otp_expired'});
 s.nodes['#authEmail']={value:'user'};s.nodes['#authPassword']={value:'password'};
 await s.nodes['#authForm'].onsubmit({preventDefault(){}});
 assert.equal(s.ctx.authUser.id,'manual-login');noNavigation(s);
});
test('fresh recovery event superseded by sign-out cannot reopen stale password dialog',async()=>{
 const s=await setup();await s.emit('PASSWORD_RECOVERY',{user:{id:'recovery-user'}});await s.emit('SIGNED_OUT');
 linkError(s);noNavigation(s);const gates=s.calls.filter(c=>c[0]==='gate').length;
 await s.emit('PASSWORD_RECOVERY',{user:{id:'stale'}});assert.equal(s.calls.filter(c=>c[0]==='gate').length,gates);
});
