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
 {id:'trainer-leave',type:'off',date:'2026-09-22',time:'Tüm gün',title:'TrainerLeaveMarker',status:'off'},
 {id:'archive-availability',type:'availability',customerId:state.customer.id,date:state.selectedDate,time:'12:00',title:'ArchivedAvailabilityMarker',status:'open'},
 {id:'archive-legacy-off',type:'off',createdBy:'member:'+state.customer.id,date:state.selectedDate,time:'13:00',title:'ArchivedLegacyOffMarker',status:'off'},
 {id:'trainer-availability',type:'availability',createdBy:'pt',date:state.selectedDate,time:'14:00',title:'TrainerAvailabilityMarker',status:'open'}];calendar();`);
 const contents=()=>d.querySelector('#view').textContent;
 assert.ok(!contents().includes('ArchivedSessionMarker'));assert.ok(!contents().includes('ArchivedLeaveMarker'));
 assert.ok(!contents().includes('ArchivedAvailabilityMarker'));assert.ok(!contents().includes('ArchivedLegacyOffMarker'));assert.ok(contents().includes('TrainerAvailabilityMarker'));
 assert.ok(contents().includes('ActiveSessionMarker'));assert.ok(contents().includes('TrainerLeaveMarker'));
 assert.equal(d.querySelector('#calendarCustomerFilter').value,'all');
 d.querySelector('#calendarShowArchived').click();
 assert.ok(contents().includes('ArchivedSessionMarker'));assert.ok(contents().includes('ArchivedLeaveMarker'));
 assert.ok(contents().includes('ArchivedAvailabilityMarker'));assert.ok(contents().includes('ArchivedLegacyOffMarker'));
 d.querySelector('#calendarCustomerFilter').value=w.testRun('String(state.customer.id)');d.querySelector('#calendarCustomerFilter').dispatchEvent(new w.Event('change'));
 assert.ok(contents().includes('ArchivedSessionMarker'));assert.ok(!contents().includes('ActiveSessionMarker'));
 d.querySelector('#calendarShowArchived').click();
 assert.ok(!contents().includes('ArchivedSessionMarker'));assert.ok(contents().includes('ActiveSessionMarker'));
 assert.ok(!contents().includes('ArchivedAvailabilityMarker'));assert.ok(!contents().includes('ArchivedLegacyOffMarker'));assert.ok(contents().includes('TrainerAvailabilityMarker'));
 assert.equal(w.testRun('state.events.length'),7,'hiding archived customers must preserve history');
 assert.equal(w.testRun("calendarEventForCustomer({type:'session'})"),false,'legacy primary customer events are hidden');
 w.testRun('state.customer.archived=false;calendar()');assert.ok(contents().includes('ArchivedSessionMarker'));
 // Home must ignore archived clients regardless of the calendar archive toggle/filter.
 w.testRun("state.customer.archived=true;state.calendarShowArchived=true;state.calendarCustomerFilter=String(state.customer.id);state.events=state.events.filter(e=>e.type==='session');state.events.forEach(e=>e.date='2099-09-21')");
 assert.equal(w.testRun('nextEvent().id'),'active-session');
 assert.ok(!w.testRun('nextEventHtml()').includes('ArchivedSessionMarker'));
 w.testRun('window.active.archived=true');
 assert.equal(w.testRun('nextEvent()'),undefined);
 assert.ok(w.testRun('nextEventHtml()').includes('Yaklaşan etkinlik yok.'));
 w.testRun('state.customer.archived=false');
 assert.equal(w.testRun('nextEvent().id'),'archive-session');
 // Active task widgets exclude archives; raw history and completed weigh-ins survive.
 w.testRun(`state.customer.archived=true;window.active.archived=false;state.progressData=[];
 state.demoChat={messages:[],tasks:[
 {id:'archived-task',client_id:String(state.customer.id),title:'ArchivedTaskMarker',status:'pending',due_at:'2000-01-01T12:00:00Z'},
 {id:'active-task',client_id:String(window.active.id),title:'ActiveTaskMarker',status:'pending',due_at:'2000-01-01T12:00:00Z'},
 {id:'weigh-history',client_id:String(state.customer.id),title:'Tartıl',status:'done',response_type:'kg',result:'80',completed_at:'2026-09-01T12:00:00Z'}]};openLiveOverdueTasks();`);
 assert.equal(w.testRun('overdueTasks().length'),1);
 assert.ok(!d.querySelector('#modal').textContent.includes('ArchivedTaskMarker'));
 assert.ok(d.querySelector('#modal').textContent.includes('ActiveTaskMarker'));
 assert.equal(w.testRun('currentTaskRows().length'),3);
 assert.equal(w.testRun("progressMeasurements().find(x=>x.taskId==='weigh-history').w"),80);
 assert.ok(!w.testRun('memberTasksHtml()').includes('ArchivedTaskMarker'));
 w.testRun('state.customer.archived=false');assert.equal(w.testRun('overdueTasks().length'),2);
 w.testRun('state.customer.archived=true;state.customer.dbId=String(state.customer.id);window.active.dbId=String(window.active.id);cloudTasks=state.demoChat.tasks;demoMode=false');
 assert.equal(w.testRun('overdueTasks().length'),1,'live and demo task filtering must agree');
 w.testRun(`demoMode=true;authUser=null;state=clone(window.fixture);state.role='pt';state.page='dashboard';state.customer.archived=true;state.archiveViews={};
 window.active=financeCustomers().find(c=>String(c.id)!==String(state.customer.id));window.active.archived=false;state.payment.status='pending';
 state.events=[{id:'archived-request',type:'session',status:'requested',customerId:state.customer.id,title:'ArchivedRequestMarker',date:iso(new Date()),time:'15:00'},
 {id:'active-request',type:'session',status:'requested',customerId:window.active.id,title:'ActiveRequestMarker',date:iso(new Date()),time:'16:00'},
 {id:'archived-notice',type:'memberoff',status:'off',customerId:state.customer.id,title:'ArchivedNoticeMarker',date:iso(new Date()),time:'Tüm gün'}];dashboard();renderLeavePanel();`);
 assert.equal(w.testRun('pendingAppointments().length'),1);
 assert.ok(!w.testRun('pendingPayments().some(c=>c.archived)'));
 assert.ok(!contents().includes('ArchivedRequestMarker'));assert.ok(!contents().includes('ArchivedNoticeMarker'));
 assert.ok(contents().includes('ActiveRequestMarker'));
 w.testRun("state.archiveViews.dashboard=true;dashboard();renderLeavePanel()");
 assert.equal(w.testRun('pendingAppointments().length'),2);
 assert.ok(contents().includes('ArchivedRequestMarker'));assert.ok(contents().includes('ArchivedNoticeMarker'));
 w.testRun("state.page='messages';state.chatCustomerId=state.customer.id");
 assert.notEqual(w.testRun('selectedChatCustomer().id'),w.testRun('state.customer.id'));
 w.testRun('state.archiveViews.messages=true');assert.equal(w.testRun('selectedChatCustomer().id'),w.testRun('state.customer.id'));
 w.testRun("state.page='finance';state.financeCustomerId=state.customer.id;finance()");
 assert.notEqual(w.testRun('financeAccount().customer.id'),w.testRun('state.customer.id'));
 w.testRun("financeCustomers().forEach(c=>c.archived=true);finance()");assert.ok(contents().includes('Gösterilecek müşteri yok.'));
 assert.deepEqual(errors,[]);console.log('PASS: archive filtering for calendar, home, requests, payments, tasks, leave, chat and finance; explicit archive views and history preservation');
}finally{dom.window.close();}
