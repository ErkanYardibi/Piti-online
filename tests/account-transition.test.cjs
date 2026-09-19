const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const syncCode=html.slice(html.indexOf('function liveContextGuard()'),html.indexOf('function mapCloudCustomer('));
function setup(){
 let resolve;const pending=new Promise(r=>resolve=r),calls=[];
 const ctx={authUser:{id:'owner-a',email:'a@example.invalid'},demoMode:false,adminMode:false,liveStateOwner:'owner-a',state:{cloudOwner:'owner-a',role:'pt',ptProfile:{name:'Owner A'},customerAccounts:{}},db:{from(table){calls.push(table);return {update(){return {eq:()=>pending}}}}},persistState(){},cloudSyncChain:Promise.resolve()};
 vm.createContext(ctx);vm.runInContext(syncCode,ctx);return {ctx,calls,resolve};
}
for(const transition of ['other-user','demo','new-state','admin'])test('save stops after delayed profile request on '+transition,async()=>{
 const h=setup();const result=h.ctx.syncCloudDataNow();
 if(transition==='other-user')h.ctx.authUser={id:'owner-b'};
 if(transition==='demo')h.ctx.demoMode=true;
 if(transition==='new-state')h.ctx.state={cloudOwner:'owner-a'};
 if(transition==='admin')h.ctx.adminMode=true;
 h.resolve({error:null});await assert.rejects(result,/Hesap değişti/);
 assert.deepEqual(h.calls,['profiles']);
});
test('delayed profile load cannot overwrite DEMO state',async()=>{
 const h=setup();h.ctx.localStorage={getItem:()=>null};h.ctx.db={from:()=>({select:()=>({eq:()=>({maybeSingle:()=>new Promise(r=>h.resolve=r)})})})};
 const code=html.slice(html.indexOf('async function loadCloudData()'),html.indexOf('async function loadDemoData()'));
 vm.runInContext(code,h.ctx);const pending=h.ctx.loadCloudData();
 const demo={marker:'DEMO'};h.ctx.state=demo;h.ctx.demoMode=true;h.ctx.authUser=null;
 h.resolve({data:{role:'pt',full_name:'Old user'}});await assert.rejects(pending,/Hesap değişti/);assert.equal(h.ctx.state,demo);
});
test('delayed DEMO load cannot overwrite a real account',async()=>{
 const h=setup();let release;
 h.ctx.demoMode=true;h.ctx.authUser=null;h.ctx.clearTimeout=()=>{};h.ctx.cloudSyncTimer=null;
 h.ctx.demoDb={from:()=>({select:()=>({eq:()=>({maybeSingle:()=>new Promise(r=>release=r)})})})};
 vm.runInContext(html.slice(html.indexOf('let demoLoadSequence='),html.indexOf('const clientHistoryKeys=')),h.ctx);
 const pending=h.ctx.loadDemoData();const real={marker:'REAL'};h.ctx.state=real;h.ctx.demoMode=false;h.ctx.authUser={id:'real-user'};
 release({data:{data:{customer:{id:'demo-client'}},version:1}});
 await assert.rejects(pending,/Hesap değişti/);assert.equal(h.ctx.state,real);
});
