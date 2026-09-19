const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom'),fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{}}});
try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json'));
 w.testRun("demoMode=true;state=clone(window.fixture);state.role='pt';openModal(musclePickerHtml([]))");
 const toggle=name=>Array.from(d.querySelectorAll('[data-muscle-toggle]')).find(b=>b.getAttribute('aria-label')===name).click();
 toggle('Sırt');toggle('Göğüs');assert.equal(w.testRun('readMusclePicker().join()'),'Sırt,Göğüs');
 toggle('Sırt');toggle('Sırt');assert.equal(w.testRun('readMusclePicker().join()'),'Göğüs,Sırt');
 w.testRun("openModal(musclePickerHtml(['Sırt','Bacak']))");assert.equal(w.testRun('readMusclePicker().join()'),'Sırt,Bacak');
 w.testRun("closeModal();state.events=[{id:'hero-session',customerId:state.customer.id,type:'session',status:'planned',date:'2099-01-01',time:'10:00',endTime:'11:00',title:'Sırt + Bacak',muscleGroups:['Sırt','Bacak']}];state.customer.gender='Kadın';state.page='dashboard';render()");
 assert.ok(d.querySelector('.hero-female'));assert.ok(d.querySelector('.heroPhoto').style.cssText.includes('50%'));
 d.querySelector('.heroOpen').click();assert.equal(w.testRun('state.page'),'calendar');assert.equal(w.testRun('state.selectedDate'),'2099-01-01');
 w.testRun("state.customer.gender='Erkek';state.role='member';state.page='today';state.ptProfile.name='Test PT';state.ptProfile.photo='https://example.invalid/avatar.jpg';render()");
 assert.ok(d.querySelector('.hero-male'));assert.equal(d.querySelector('.heroTrainer img').getAttribute('src'),'https://example.invalid/avatar.jpg');
 d.querySelector('.heroTrainer').click();assert.equal(w.testRun('state.page'),'trainer');
 w.testRun("state.customer.gender='';state.page='today';render()");assert.ok(d.querySelector('.hero-gym'));
 assert.deepEqual(errors,[]);console.log('PASS: selection order/remove/reselect/reopen, gender backgrounds, trainer avatar, calendar and trainer navigation');
}finally{dom.window.close()}
