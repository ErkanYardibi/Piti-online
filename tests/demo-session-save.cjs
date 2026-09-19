const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{};}});
try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json','utf8'));
 w.testRun("demoMode=true;authUser=null;state=clone(window.fixture);state.role='pt';state.page='calendar';window.id=state.events.find(e=>e.type==='session'&&e.status==='planned'&&String(e.customerId)===String(state.customer.id)).id;openEventEdit(window.id)");
 d.querySelector('#editTitle').value='Güncellenen seans';d.querySelector('#editNote').value='Yeni seans notu <test>';
 d.querySelectorAll('#editMuscleGroups input').forEach(x=>{if(x.checked!==['Bacak','Sırt'].includes(x.value))x.parentElement.querySelector('[data-muscle-toggle] .muscleImage').click();});
 assert.equal(d.querySelector('[data-muscle-summary]').textContent,'Seçilen: Sırt, Bacak');
 assert.equal(d.querySelectorAll('#editMuscleGroups [aria-pressed="true"]').length,2);
 d.querySelector('#saveEventEdit').click();
 const saved=JSON.parse(w.testRun('JSON.stringify(state.events.find(e=>e.id===window.id))'));
 assert.equal(saved.title,'Güncellenen seans');assert.equal(saved.note,'Yeni seans notu <test>');assert.deepEqual(saved.muscleGroups,['Sırt','Bacak']);
 assert.ok(d.querySelector('#view').textContent.includes(saved.title));
 assert.ok(d.querySelector('#view').textContent.includes(saved.note),'saved session note must appear on calendar card');
 w.testRun('openEventEdit(window.id)');assert.equal(d.querySelector('#editNote').value,saved.note);assert.equal(d.querySelectorAll('#editMuscleGroups input:checked').length,2);
 d.querySelectorAll('#editMuscleGroups input:checked').forEach(x=>x.parentElement.querySelector('[data-muscle-toggle]').click());
 assert.equal(d.querySelector('[data-muscle-summary]').textContent,'Seçilen: Yok');d.querySelector('#saveEventEdit').click();
 w.testRun('openEventEdit(window.id)');assert.equal(d.querySelectorAll('#editMuscleGroups input:checked').length,0);
 w.testRun("closeModal();switchTestUser(state.customer.id,'member','calendar')");
 assert.equal(w.testRun('state.events.find(e=>e.id===window.id).note'),saved.note);
 assert.deepEqual(errors,[]);console.log('PASS: DEMO session edit updates stored title, muscles and note; calendar and reopened form agree; member sees same edit');
}finally{dom.window.close();}
