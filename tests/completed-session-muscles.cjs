const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{};}});
try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json','utf8'));
 for(const id of [991,'11111111-1111-4111-8111-111111111111']){
  w.sessionId=id;
  w.testRun(`demoMode=true;authUser=null;state=clone(window.fixture);state.role='pt';state.page='calendar';state.customer.archived=false;
   state.selectedDate='2020-01-02';state.calCursor='2020-01-01T12:00:00';state.calendarCustomerFilter='all';
   state.package.usedSessions=3;state.events=[{id:window.sessionId,type:'session',customerId:state.customer.id,status:'completed',counts:true,packageDebit:1,date:state.selectedDate,time:'10:00',endTime:'11:00',title:'Past session',muscleGroups:['Göğüs'],createdBy:'pt'}];calendar();`);
  d.querySelector('[data-edit-result]').click();assert.ok(d.querySelector('#resultMuscleGroups'));
  const select=names=>d.querySelectorAll('#resultMuscleGroups input').forEach(x=>{if(x.checked!==names.includes(x.value))x.parentElement.querySelector('[data-muscle-toggle]').click()});
  select(['Sırt','Bacak']);d.querySelector('#saveResultEdit').click();
  assert.deepEqual(JSON.parse(w.testRun('JSON.stringify(state.events[0].muscleGroups)')),['Sırt','Bacak']);
  assert.equal(w.testRun('state.package.usedSessions'),3,'editing muscles cannot debit package again');
  assert.deepEqual(JSON.parse(w.testRun('JSON.stringify(state.events[0].resultHistory[0].previous.muscleGroups)')),['Göğüs']);
  assert.deepEqual(JSON.parse(w.testRun('JSON.stringify(state.events[0].resultHistory[0].next.muscleGroups)')),['Sırt','Bacak']);
  assert.ok(w.testRun('eventCard(state.events[0])').includes('Bacak'));
  d.querySelector('[data-edit-result]').click();assert.equal(d.querySelectorAll('#resultMuscleGroups input:checked').length,2);
  d.querySelector('#saveResultEdit').click();assert.equal(w.testRun('state.events[0].resultHistory.length'),1);assert.ok(d.querySelector('#modalBack').classList.contains('show'),'no-op must not close as success');
  select([]);d.querySelector('#saveResultEdit').click();assert.equal(w.testRun('state.events[0].muscleGroups.length'),0);assert.equal(w.testRun('state.package.usedSessions'),3);
  w.testRun("state.events[0].status='noshow';state.events[0].noShowReason='No Show';state.events[0].noShowNote='No Show';editSessionResult(window.sessionId)");
  select(['Kol']);d.querySelector('#saveResultEdit').click();assert.equal(w.testRun('state.events[0].muscleGroups[0]'),'Kol');assert.equal(w.testRun('state.package.usedSessions'),3);
  w.testRun("closeModal();state.role='member';editSessionResult(window.sessionId)");assert.ok(!d.querySelector('#modalBack').classList.contains('show'));
 }
 for(const page of ['dashboard','calendar'])for(const action of ['completed','noshow']){
  w.resultPage=page;
  w.testRun(`demoMode=false;authUser={id:'trainer-test'};save=()=>{};state=clone(window.fixture);state.role='pt';state.page=window.resultPage;state.customer.archived=false;state.selectedDate='2020-01-02';state.calCursor='2020-01-01T12:00:00';state.calendarCustomerFilter='all';state.events=[{id:'22222222-2222-4222-8222-222222222222',type:'session',customerId:state.customer.id,status:'planned',date:state.selectedDate,time:'10:00',endTime:'11:00',title:'Live UUID past session',createdBy:'pt'}];render()`);
  if(action==='completed')d.querySelector('[data-complete-session]').click();
  else {d.querySelector('[data-noshow]').click();assert.ok(d.querySelector('#saveNs'));d.querySelector('#saveNs').click();}
  assert.equal(w.testRun('state.events[0].status'),action,page+' live UUID click');
 }
 w.testRun("state.events[0].status='planned';state.events[0].date='2099-01-01';completeSession(state.events[0].id)");assert.equal(w.testRun('state.events[0].status'),'planned');
 assert.deepEqual(errors,[]);console.log('PASS: completed muscle edits and live UUID complete/no-show buttons on home/calendar; future session blocked');
}finally{dom.window.close();}
