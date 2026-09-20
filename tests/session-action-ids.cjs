const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{}}});
try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json'));
 function setup(id){w.testId=id;w.testRun("demoMode=true;authUser=null;state=clone(window.fixture);state.role='pt';state.page='calendar';state.calendarCustomerFilter='all';state.selectedDate='2099-10-01';state.calCursor='2099-10-01T12:00:00';state.events=[{id:window.testId,type:'session',customerId:state.customer.id,createdBy:'pt',status:'planned',date:state.selectedDate,time:'10:00',endTime:'11:00',title:'ID regression'}];closeModal();calendar()");}
 for(const id of ['22222222-2222-4222-8222-222222222222',12345,'12345']){
  setup(id);d.querySelector('[data-delete-session]').click();
  assert.ok(d.querySelector('#confirmDeleteSession'),'delete opens confirmation for '+id);
  assert.equal(w.testRun('state.events.length'),1,'nothing deleted before confirmation');
  w.testRun('closeModal()');assert.equal(w.testRun('state.events.length'),1);
  d.querySelector('[data-delete-session]').click();d.querySelector('#confirmDeleteSession').click();
  assert.equal(w.testRun('state.events.length'),0,'confirmed deletion removes selected record');
  assert.equal(w.testRun('state.messages.at(-1).eventId'),id);
  for(const [action,status] of [['accept','accepted'],['dispute','disputed']]){
   setup(id);w.testRun("state.role='member';state.events[0].status='completed';state.events[0].confirmation={status:'pending',createdAt:'2099-09-30T10:00:00Z',deadline:'2099-10-02T10:00:00Z'};calendar();renderResultApprovals()");
   d.querySelector('[data-result-'+action+']').click();
   assert.equal(w.testRun('state.events[0].confirmation.status'),status);
  }
  setup(id);w.testRun("state.events.push({id:'leave-test',type:'off',status:'off',customerId:null,createdBy:'pt',date:state.selectedDate,time:'Tüm gün',title:'Çalışmıyor'});calendar()");
  d.querySelector('[data-leave-decision]').click();assert.ok(d.querySelector('#saveLeaveDecision'));
  d.querySelector('#saveLeaveDecision').click();assert.equal(w.testRun('state.events[0].status'),'cancelled');
 }
 for(const change of ["state.role='member'","state.events[0].status='completed'","state.events[0].createdBy='member:other'"]){
  setup('protected-id');w.testRun(change+";deletePlannedSession('protected-id')");
  assert.equal(d.querySelector('#confirmDeleteSession'),null,'permission/status guards preserved');
  assert.equal(w.testRun('state.events.length'),1);
 }
 assert.deepEqual(errors,[]);console.log('PASS: UUID/numeric IDs; delete confirmation, result accept/dispute, leave cancellation and permission guards');
}finally{dom.window.close()}
