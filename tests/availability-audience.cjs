const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom'),fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{}}});
try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json'));
 w.testRun("demoMode=true;authUser=null;state=clone(window.fixture);state.role='pt';state.events=[];state.page='calendar';state.selectedDate='2099-09-02';state.calCursor='2099-09-01T12:00:00';financeCustomers()[1].archived=true;window.first=String(financeCustomers()[0].id);window.second=String(financeCustomers()[2].id);openAvailability()");
 const checks=[...d.querySelectorAll('[data-audience-client]')];assert.equal(checks.length,w.testRun("financeCustomers().filter(c=>!c.archived&&!c.relationshipEndedAt).length"));
 d.querySelector('#saveAvail').click();assert.equal(w.testRun('state.events.length'),0,'selected-empty must not save');
 checks[0].checked=true;checks[0].dispatchEvent(new w.Event('change'));assert.equal(d.querySelector('#audienceCount').textContent,'1 müşteri seçildi');
 d.querySelector('#audienceSearch').value='no such client';d.querySelector('#audienceSearch').dispatchEvent(new w.Event('input'));assert.ok([...d.querySelectorAll('[data-audience-row]')].every(r=>r.style.display==='none'));
 d.querySelector('#aEndDate').value='2099-09-04';d.querySelector('#saveAvail').click();
 assert.equal(w.testRun('state.events.length'),3);assert.equal(w.testRun("state.events.every(e=>e.type==='availability'&&e.visibility==='selected'&&e.visibleCustomerIds.length===1)"),true);
 w.testRun("window.slotId=state.events[0].id;openEventEdit(window.slotId)");assert.equal(d.querySelectorAll('[data-audience-client]:checked').length,1);
 d.querySelector('#audienceSelectAll').click();assert.equal(d.querySelectorAll('[data-audience-client]:checked').length,checks.length);
 d.querySelector('#audienceClear').click();d.querySelector('#saveEventEdit').click();assert.ok(d.querySelector('#saveEventEdit'),'empty edit remains open');
 d.querySelector('[data-audience-client]').checked=true;d.querySelector('#saveEventEdit').click();
 w.testRun("state.role='member'");assert.equal(w.testRun('testEventVisible(state.events[0])'),true);
 assert.equal(w.testRun("memberCanSeeAvailability({visibility:'selected',visibleCustomerIds:[window.second]})"),false);
 assert.equal(w.testRun("memberCanSeeAvailability({visibility:'Seçili müşteriler görebilir'})"),false);
 assert.equal(w.testRun("memberCanSeeAvailability({visibility:'none'})"),false);
 assert.equal(w.testRun("memberCanSeeAvailability({visibility:'all'})"),true);
 w.testRun("state.customer.archived=true");assert.equal(w.testRun("memberCanSeeAvailability({visibility:'all'})"),false);
 w.testRun("state.customer.archived=false;state.role='pt';openEventEdit(state.events[0].id)");
 d.querySelector('#aVis').value='none';d.querySelector('#aVis').dispatchEvent(new w.Event('change'));assert.equal(d.querySelector('#availabilityAudience').hidden,true);d.querySelector('#saveEventEdit').click();
 assert.equal(w.testRun("state.events.every(e=>e.visibility==='none'&&e.visibleCustomerIds.length===0)"),true);
 w.testRun("state.role='member'");assert.equal(w.testRun("memberRequestBox(state.events[0].date)"),'');
 assert.deepEqual(errors,[]);console.log('PASS: audience selection, search, count, archived exclusion, range save/edit, empty validation, member visibility, legacy fail-closed');
}finally{dom.window.close()}
