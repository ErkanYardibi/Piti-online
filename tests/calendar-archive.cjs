const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{};}});
try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json','utf8'));
 w.testRun(`demoMode=true;authUser=null;state=clone(window.fixture);state.role='pt';state.page='calendar';
 window.active=financeCustomers().find(c=>String(c.id)!==String(state.customer.id));state.customer.archived=true;
 state.selectedDate='2026-09-21';state.calCursor='2026-09-01T12:00:00';state.calendarShowArchived=false;state.calendarCustomerFilter=String(state.customer.id);
 state.events=[{id:'archive-session',type:'session',customerId:state.customer.id,date:state.selectedDate,time:'10:00',title:'ArchivedSessionMarker',status:'planned'},
 {id:'active-session',type:'session',customerId:window.active.id,date:state.selectedDate,time:'11:00',title:'ActiveSessionMarker',status:'planned'},
 {id:'archive-leave',type:'memberoff',customerId:state.customer.id,date:state.selectedDate,time:'Tüm gün',title:'ArchivedLeaveMarker',status:'off'},
 {id:'trainer-leave',type:'off',date:'2026-09-22',time:'Tüm gün',title:'TrainerLeaveMarker',status:'off'}];calendar();`);
 const contents=()=>d.querySelector('#view').textContent;
 assert.ok(!contents().includes('ArchivedSessionMarker'));assert.ok(!contents().includes('ArchivedLeaveMarker'));
 assert.ok(contents().includes('ActiveSessionMarker'));assert.ok(contents().includes('TrainerLeaveMarker'));
 assert.equal(d.querySelector('#calendarCustomerFilter').value,'all');
 d.querySelector('#calendarShowArchived').click();
 assert.ok(contents().includes('ArchivedSessionMarker'));assert.ok(contents().includes('ArchivedLeaveMarker'));
 d.querySelector('#calendarCustomerFilter').value=w.testRun('String(state.customer.id)');d.querySelector('#calendarCustomerFilter').dispatchEvent(new w.Event('change'));
 assert.ok(contents().includes('ArchivedSessionMarker'));assert.ok(!contents().includes('ActiveSessionMarker'));
 d.querySelector('#calendarShowArchived').click();
 assert.ok(!contents().includes('ArchivedSessionMarker'));assert.ok(contents().includes('ActiveSessionMarker'));
 assert.equal(w.testRun('state.events.length'),4,'hiding archived customers must preserve history');
 assert.equal(w.testRun("calendarEventForCustomer({type:'session'})"),false,'legacy primary customer events are hidden');
 w.testRun('state.customer.archived=false;calendar()');assert.ok(contents().includes('ArchivedSessionMarker'));
 assert.deepEqual(errors,[]);console.log('PASS: archived sessions and leave hidden, explicit archive view works, stale filter resets, history retained, reactivation restores visibility');
}finally{dom.window.close();}
