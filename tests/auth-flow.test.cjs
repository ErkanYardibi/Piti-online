const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const code=html.slice(html.indexOf('function setAuthBusy'),html.indexOf('function packageEnd(pkg)'));
function setup({missingClient=false,loadError=false,sessionError=false,loginError=false}={}){
 const nodes=new Map(),timers=[];let callback,locked=false,loads=0;
 const node=id=>{if(!nodes.has(id))nodes.set(id,{hidden:false,disabled:false,value:id==='#authPassword'?'password123':id==='#authRole'?'pt':'test@example.invalid',textContent:''});return nodes.get(id)};
 const ctx={authUser:null,cloudSyncTimer:null,demoMode:false,setTimeout:fn=>timers.push(fn),clearTimeout(){},location:{reload(){}},localStorage:{setItem(){}},toast(){},
 document:{querySelector(id){if(['#cloudBadge','#logoutBtn'].includes(id))return nodes.get(id)||null;if(id==='.userbox')return {prepend(el){nodes.set('#'+el.id,el)},append(el){nodes.set('#'+el.id,el)}};return node(id)},querySelectorAll(){return [node('#signUpBtn'),node('#authEmail')]},createElement(){return {}}},
 async loadCloudData(){loads++;assert.equal(locked,false,'database calls must not run under the auth lock');if(loadError)throw Error('database unavailable')},
 db:missingClient?null:{auth:{onAuthStateChange(fn){callback=fn},async getSession(){if(sessionError)throw Error('network offline');return {data:{session:null}}},async signInWithPassword(){if(loginError)throw Error('login offline');const session={user:{id:'u1'}};locked=true;const result=callback('SIGNED_IN',session);assert.equal(result,undefined,'auth callback must be synchronous');locked=false;return {data:{session}}},async signOut(){return {}}}}
 };
 vm.createContext(ctx);vm.runInContext(code,ctx);
 return {ctx,node,timers,get loads(){return loads},fire(){locked=true;const result=callback('SIGNED_IN',{user:{id:'u1'}});locked=false;return result}};
}
test('all inline application JavaScript parses',()=>{for(const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))new vm.Script(match[1])});
test('sign-in releases auth lock before loading data and loads only once',async()=>{const h=setup();await h.ctx.initAuth();await h.node('#authForm').onsubmit({preventDefault(){}});for(const fn of h.timers)await fn();assert.equal(h.loads,1);assert.equal(h.node('#authBack').hidden,true)});
test('auth event schedules data load outside callback',async()=>{const h=setup();await h.ctx.initAuth();assert.equal(h.fire(),undefined);assert.equal(h.loads,0);h.timers[0]();await h.ctx.sessionActivation;await new Promise(setImmediate);assert.equal(h.loads,1)});
test('database load failure keeps login visible and enables retry',async()=>{const h=setup({loadError:true});await h.ctx.initAuth();await h.ctx.activateSession({user:{id:'u1'}});assert.equal(h.node('#authBack').hidden,false);assert.match(h.node('#authError').textContent,/database unavailable/);assert.equal(h.ctx.authUser,null);assert.equal(h.node('#signUpBtn').disabled,false)});
test('network failure does not leave login disabled',async()=>{const h=setup({loginError:true});await h.ctx.initAuth();await h.node('#authForm').onsubmit({preventDefault(){}});assert.equal(h.node('#signUpBtn').disabled,false);assert.match(h.node('#authError').textContent,/login offline/)});
test('session lookup failure still leaves login handlers available',async()=>{const h=setup({sessionError:true});await h.ctx.initAuth();assert.equal(typeof h.node('#authForm').onsubmit,'function');assert.match(h.node('#authError').textContent,/network offline/)});
test('demo works even when Supabase script cannot load',async()=>{const h=setup({missingClient:true});await h.ctx.initAuth();h.node('#demoBtn').onclick();assert.equal(h.ctx.demoMode,true);assert.equal(h.node('#authBack').hidden,true)});
