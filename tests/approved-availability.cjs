const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{};}});

(async()=>{try{
 const w=dom.window;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json','utf8'));
 w.testRun("demoMode=true;authUser=null;state=clone(window.fixture);state.role='member';state.page='calendar';state.selectedDate='2099-10-01';state.calCursor='2099-10-01T12:00:00';");
 w.testRun("window.slot={id:'pt-slot-a',sourceSlotId:'a',type:'availability',date:'2099-10-01',time:'14:00',endTime:'17:00',title:'Müsait',status:'open',visibility:'all',sharedTrainerAvailability:true};window.session={id:'session-a',type:'session',date:'2099-10-01',time:'15:00',endTime:'16:00',title:'PT Seansı',status:'planned',customerId:state.customer.id};");
 const fragments=JSON.parse(JSON.stringify(w.testRun('trimTrainerAvailability([window.slot],[window.session])')));
 assert.deepEqual(fragments.map(e=>[e.time,e.endTime]),[['14:00','15:00'],['16:00','17:00']]);
 assert.ok(fragments.every(e=>e.sourceSlotId==='a'));

 const consumed=JSON.parse(JSON.stringify(w.testRun("trimTrainerAvailability([window.slot],[{...window.session,time:'14:00',endTime:'17:00'}])")));
 assert.equal(consumed.length,0,'approved session removes the complete matching availability');

 w.testRun('state.events=[window.slot,window.session];calendar()');
 assert.equal(w.document.querySelector('[data-request-slot="pt-slot-a"]'),null,'overlapping availability is hidden immediately');
 const before=w.testRun('state.events.length');await w.testRun("requestSlot('pt-slot-a')");
 assert.equal(w.testRun('state.events.length'),before,'hidden occupied slot cannot be requested');

 const pending=JSON.parse(JSON.stringify(w.testRun("trimTrainerAvailability([window.slot],[{...window.session,status:'requested'}])")));
 assert.deepEqual(pending.map(e=>[e.time,e.endTime]),[['14:00','15:00'],['16:00','17:00']]);
 // PT calendar, month badges and lower list must use the same derived view.
 w.testRun("state.role='pt';state.calendarCustomerFilter='all';window.slot={...window.slot,id:'pt-own-a',customerId:null,createdBy:'pt',sharedTrainerAvailability:false};state.events=[window.slot,window.session];window.originalEvents=JSON.stringify(state.events);calendar()");
 assert.equal(w.testRun('JSON.stringify(state.events)'),w.originalEvents,'render must not mutate persisted slots');
 assert.equal(w.document.querySelectorAll('[data-edit-event="pt-own-a"]').length,2,'free fragments still edit the original availability');
 assert.equal(w.document.querySelectorAll('[data-list-edit-calendar="pt-own-a"]').length,2,'lower list shows both free fragments');
 assert.ok(!w.document.querySelector('#leavePanel').textContent.includes('14:00–17:00'));
 assert.ok(w.document.querySelector('#leavePanel').textContent.includes('16:00–17:00'));
 w.document.querySelector('[data-edit-event="pt-own-a"]').click();
 assert.ok(w.document.querySelector('#modal').textContent.includes('14:00')||w.document.querySelector('#modal input[value="14:00"]'),'fragment edit resolves original record');
 w.testRun("closeModal();window.session.time='14:00';window.session.endTime='17:00';calendar()");
 assert.equal(w.document.querySelector('[data-edit-event="pt-own-a"]'),null);
 assert.equal(w.document.querySelector('[data-list-edit-calendar="pt-own-a"]'),null);
 assert.ok(!w.document.querySelector('[data-date="2099-10-01"]').textContent.includes('Müsait'),'month badge hides fully occupied availability');
 w.testRun("state.calendarCustomerFilter='pt_self';calendar()");
 assert.equal(w.document.querySelector('[data-edit-event="pt-own-a"]'),null,'hidden customer bookings still block PT availability');
 w.testRun("window.session.status='cancelled';calendar()");
 assert.equal(w.document.querySelectorAll('[data-edit-event="pt-own-a"]').length,1,'cancellation restores availability without recreation');
 assert.ok(w.document.querySelector('#leavePanel').textContent.includes('14:00–17:00'));
 const overnight=JSON.parse(JSON.stringify(w.testRun("trimTrainerAvailability([{...window.slot,time:'23:00',endTime:'02:00'}],[{...window.session,status:'planned',time:'23:00',endTime:'00:30'}])")));
 assert.equal(overnight[0].date,'2099-10-02');
 assert.equal(overnight[0].time,'00:30');
 assert.deepEqual(errors,[]);
 console.log('PASS: approved/pending sessions hide occupied availability and preserve only free fragments');
}finally{dom.window.close()}})().catch(e=>{console.error(e);process.exitCode=1});
