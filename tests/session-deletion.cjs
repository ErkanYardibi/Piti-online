const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('const db=','let db=').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{}}});
(async()=>{try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json'));
 function setup(){w.testRun("demoMode=false;adminMode=false;authUser={id:'pt-user'};state=clone(window.fixture);state.role='pt';state.page='calendar';state.calendarCustomerFilter='all';state.selectedDate='2099-10-01';state.calCursor='2099-10-01T12:00:00';state.events=[{id:'22222222-2222-4222-8222-222222222222',dbId:'22222222-2222-4222-8222-222222222222',cloudManaged:true,type:'session',customerId:state.customer.id,createdBy:'pt',status:'planned',date:state.selectedDate,time:'10:00',endTime:'11:00',title:'Delete test'}];window.saved=0;save=()=>window.saved++;window.calls=[];cloudSyncChain=Promise.resolve();closeModal();calendar();deletePlannedSession(state.events[0].id)");}
 setup();w.testRun("db={rpc:(name,args)=>{window.calls.push({name,args});return new Promise(resolve=>window.resolveDelete=resolve)}}");
 let pending=d.querySelector('#confirmDeleteSession').onclick();await Promise.resolve();await Promise.resolve();
 assert.equal(w.testRun('state.events.length'),1,'wait for server before removing');
 assert.ok(d.querySelector('#confirmDeleteSession').disabled);
 await d.querySelector('#confirmDeleteSession').onclick();assert.equal(w.calls.length,1,'double click blocked');
 w.resolveDelete({error:Error('network failure')});await pending;
 assert.equal(w.testRun('state.events.length'),1,'failure keeps session');assert.equal(w.saved,0);
 assert.equal(d.querySelector('#confirmDeleteSession').disabled,false);
 w.testRun("db.rpc=async(name,args)=>({data:{deleted:true,id:args.p_session_id}})");
 await d.querySelector('#confirmDeleteSession').onclick();assert.equal(w.testRun('state.events.length'),0);assert.equal(w.saved,1);
 setup();w.testRun("db={rpc:async()=>({data:{deleted:false}})}");await d.querySelector('#confirmDeleteSession').onclick();assert.equal(w.testRun('state.events.length'),1,'malformed confirmation cannot delete');
 setup();Object.defineProperty(w.navigator,'onLine',{value:false,configurable:true});w.testRun("db={rpc:()=>{throw Error('must not call')}}");await d.querySelector('#confirmDeleteSession').onclick();assert.equal(w.testRun('state.events.length'),1);Object.defineProperty(w.navigator,'onLine',{value:true,configurable:true});
 setup();w.testRun("db={rpc:()=>new Promise(resolve=>window.resolveDelete=resolve)}");pending=d.querySelector('#confirmDeleteSession').onclick();await Promise.resolve();await Promise.resolve();
 w.testRun("authUser={id:'different-user'};state=clone(state)");w.resolveDelete({data:{deleted:true,id:'22222222-2222-4222-8222-222222222222'}});await pending;assert.equal(w.testRun('state.events.length'),1,'account switch never changes new account');
 setup();w.testRun("state.role='member';authUser={id:'student'};db={rpc:async(name,args)=>{window.calls.push({name,args});return {data:['22222222-2222-4222-8222-222222222222']}}}");
 assert.equal(await w.testRun('pruneDeletedCloudSessions()'),true);assert.equal(w.testRun('state.events.length'),0,'student removes deletion without logout');
 assert.equal(w.calls[0].name,'get_deleted_session_ids');
 assert.deepEqual(errors,[]);console.log('PASS: server-confirmed deletion, failure/retry, offline, double click, account switch and student cleanup');
}finally{dom.window.close()}})().catch(e=>{console.error(e);process.exitCode=1});
