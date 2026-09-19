const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{};}});
try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json','utf8'));
 const reset=()=>w.testRun(`demoMode=true;authUser=null;state=clone(window.fixture);state.role='pt';state.page='calendar';state.selectedDate='2099-09-02';state.calCursor='2099-09-01T12:00:00';
 state.events=[1,2,3,4,5].map(n=>({id:'slot-'+n,type:'availability',createdBy:'pt',groupId:'series',date:'2099-09-0'+n,time:'10:00',endTime:'11:00',title:'Müsait',status:'open'}));
 state.events.push({id:'other-slot',type:'availability',createdBy:'pt',date:state.selectedDate,time:'14:00',endTime:'15:00',title:'Other',status:'open'},
 {id:'session',type:'session',customerId:state.customer.id,createdBy:'pt',date:state.selectedDate,time:'16:00',title:'Session',status:'planned'},
 {id:'member-leave',type:'memberoff',customerId:state.customer.id,createdBy:'member:'+state.customer.id,date:state.selectedDate,time:'Tüm gün',title:'Leave',status:'off'});calendar();`);
 reset();
 w.testRun("financeCustomers().forEach(c=>c.archived=true);state.calendarShowArchived=false;state.calendarCustomerFilter='pt_self';calendar()");
 assert.ok(d.querySelector('[data-delete-calendar="slot-2"]'),'own calendar includes open availability');
 assert.ok(d.querySelector('[data-delete-calendar="other-slot"]'),'own calendar includes standalone availability');
 w.testRun("deleteCalendarEntry('slot-2')");d.querySelector('#deleteCalendarScope').value='group';d.querySelector('#confirmDeleteCalendar').click();
 w.testRun("deleteCalendarEntry('other-slot')");d.querySelector('#confirmDeleteCalendar').click();
 w.testRun("state.calendarCustomerFilter='all';calendar()");
 assert.equal(d.querySelectorAll('[data-delete-calendar]').length,0,'switching to all cannot reveal other PT availability after deletion');
 assert.equal(w.testRun("state.events.filter(e=>e.type==='availability').length"),0);
 assert.equal(w.testRun('state.events.length'),2,'archived customer records remain intact');
 reset();assert.ok(d.querySelector('[data-delete-calendar="slot-2"]'));
 d.querySelector('[data-delete-calendar="slot-2"]').click();assert.equal(w.testRun('state.events.length'),8,'opening confirmation cannot delete');
 assert.equal(d.querySelector('#deleteCalendarScope').value,'single');
 d.querySelector('#confirmDeleteCalendar').click();assert.equal(w.testRun('state.events.length'),7);assert.equal(w.testRun("state.events.some(e=>e.id==='slot-2')"),false);
 reset();w.testRun("deleteCalendarEntry('slot-2')");
 const scope=d.querySelector('#deleteCalendarScope');scope.value='range';scope.dispatchEvent(new w.Event('change'));
 d.querySelector('#deleteCalendarStart').value='2099-09-02';d.querySelector('#deleteCalendarEnd').value='2099-09-04';d.querySelector('#deleteCalendarEnd').dispatchEvent(new w.Event('change'));
 assert.equal(d.querySelector('#deleteCalendarSummary').textContent,'3 kayıt silinecek.');d.querySelector('#confirmDeleteCalendar').click();
 assert.equal(w.testRun('state.events.length'),5);assert.ok(w.testRun("state.events.some(e=>e.id==='other-slot')"));assert.ok(w.testRun("state.events.some(e=>e.id==='session')"));
 reset();w.testRun("deleteCalendarEntry('slot-2')");d.querySelector('#deleteCalendarScope').value='group';d.querySelector('#confirmDeleteCalendar').click();assert.equal(w.testRun('state.events.length'),3);
 reset();w.testRun("openEventEdit('slot-2')");assert.equal(d.querySelector('#editStart').value,'2099-09-01');assert.equal(d.querySelector('#editEnd').value,'2099-09-05');
 d.querySelector('#editEnd').value='2099-09-07';d.querySelector('#editTime').value='09:00';d.querySelector('#editEndTime').value='10:00';d.querySelector('#saveEventEdit').click();
 assert.equal(w.testRun("state.events.filter(e=>e.groupId).length"),7);assert.ok(w.testRun("state.events.filter(e=>e.groupId).every(e=>e.time==='09:00')"));
 reset();w.testRun("openEventEdit('slot-2')");d.querySelector('#editScope').value='single';d.querySelector('#editScope').dispatchEvent(new w.Event('change'));d.querySelector('#editTime').value='08:00';d.querySelector('#saveEventEdit').click();
 assert.equal(w.testRun("state.events.find(e=>e.id==='slot-2').time"),'08:00');assert.equal(w.testRun("state.events.find(e=>e.id==='slot-1').time"),'10:00');
 reset();w.testRun("closeModal();state.role='member';deleteCalendarEntry('slot-2')");assert.ok(!d.querySelector('#confirmDeleteCalendar'));assert.equal(w.testRun('state.events.length'),8);
 assert.deepEqual(errors,[]);console.log('PASS: availability delete confirmation, single/group/subrange, string IDs, protected unrelated events, date-range editing and role checks');
}finally{dom.window.close();}
