const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom'),fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('const db=','let db=').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{}}});
(async()=>{try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json'));
 w.testRun("demoMode=true;authUser=null;state=clone(window.fixture);state.role='pt';state.page='finance';state.financeCustomerId=state.customer.id;state.package=null;state.payment={status:'unpaid',amount:0};state.sessionBilling={charges:[],receipts:[]};state.events=[];save=()=>{};openPackage()");
 d.querySelector('#packageBillingType').value='per_session';d.querySelector('#packageBillingType').dispatchEvent(new w.Event('change'));
 d.querySelector('#psUnitPrice').value='500';d.querySelector('#psAutoCharge').checked=true;await d.querySelector('#savePerSession').onclick();
 assert.equal(w.testRun('state.package.billingType'),'per_session');assert.equal(w.testRun('state.package.autoCharge'),true);
 w.testRun("state.package.start='2000-01-01';window.e={id:'bill-session',type:'session',createdBy:'pt',status:'planned',customerId:state.customer.id,date:'2020-01-02',time:'10:00',endTime:'11:00',title:'Bill test',counts:false,packageDebit:0};state.events=[window.e];recordSessionResult(window.e,'completed',true)");
 assert.equal(w.testRun('state.sessionBilling.charges.length'),1);assert.equal(w.testRun('state.sessionBilling.charges[0].amount'),500);
 w.testRun("recordSessionResult(window.e,'completed',true,'','',['Sırt'])");assert.equal(w.testRun('state.sessionBilling.charges.length'),1,'edits cannot double charge');
 w.testRun("state.package.price=700;finance();openPTReceipt(state,state.sessionBilling.charges[0].id)");d.querySelector('#ptPaidAmount').value='200';await d.querySelector('#savePTReceipt').onclick();
 assert.equal(w.testRun('chargeDue(state,state.sessionBilling.charges[0])'),300,'partial receipt retains debt');
 w.testRun("recordSessionResult(window.e,'noshow',false)");assert.equal(w.testRun('chargeDue(state,state.sessionBilling.charges[0])'),0);assert.equal(w.testRun('state.sessionBilling.receipts.length'),1,'void preserves receipts');
 w.testRun("recordSessionResult(window.e,'noshow',true)");assert.equal(w.testRun('chargeDue(state,state.sessionBilling.charges[0])'),300,'restores original fee, not new rate');
 w.testRun('stopPerSessionPackage()');await d.querySelector('#confirmStopBilling').onclick();assert.equal(w.testRun('state.package.status'),'closed');
 w.testRun("window.second={...window.e,id:'second',status:'planned'};state.events.push(window.second);recordSessionResult(window.second,'completed',true)");assert.equal(w.testRun('state.sessionBilling.charges.length'),1,'stopped model cannot create debt');
 w.testRun("state.package.status='active';state.package.autoCharge=false;window.third={...window.e,id:'third',status:'planned'};state.events.push(window.third);recordSessionResult(window.third,'completed',true)");assert.equal(w.testRun('state.sessionBilling.charges.length'),1,'unchecked option cannot create debt');
 w.testRun("state.package.autoCharge=true;updateSessionCharge(state,{...window.e,id:'demo',type:'demo'},'completed',true,'planned')");assert.equal(w.testRun('state.sessionBilling.charges.length'),1,'free demo never charged');
 w.testRun("state.role='member';finance()");assert.equal(d.querySelector('#stopPerSession'),null);assert.equal(d.querySelector('#manualPTPayment'),null);
 w.testRun('openSessionReceipt(state,state.sessionBilling.charges[0].id)');await d.querySelector('#sendSessionReceipt').onclick();assert.equal(w.testRun('state.payment.status'),'pending');assert.equal(w.testRun('chargeDue(state,state.sessionBilling.charges[0])'),300);
 w.testRun("state.role='pt';finance();approvePayment()");await d.querySelector('#savePTReceipt').onclick();assert.equal(w.testRun('chargeDue(state,state.sessionBilling.charges[0])'),0);
 w.testRun("state.package={name:'Fixed',price:1000,start:'2020-01-01',totalSessions:12,usedSessions:0,end:'2099-01-01'};state.payment={status:'unpaid',amount:1000};finance()");assert.ok(d.querySelector('#manualPTPayment'));
 d.querySelector('#manualPTPayment').click();d.querySelector('#ptPaidAmount').value='400';await d.querySelector('#savePTReceipt').onclick();assert.equal(w.testRun('fixedPaymentDue(state)'),600);assert.equal(w.testRun('state.payment.status'),'unpaid');
 w.testRun('openPTReceipt(state)');await d.querySelector('#savePTReceipt').onclick();assert.equal(w.testRun('fixedPaymentDue(state)'),0);assert.equal(w.testRun('state.payment.status'),'approved');
 // Reload/roundtrip of protected history includes the financial ledger.
 w.testRun("state.customer.dbId='client-db';window.payload=clientHistoryPayload(state.customer);state.sessionBilling=null;state.package=null;demoMode=false;authUser={id:'pt'};db={from:()=>({select:async()=>({data:[{client_id:'client-db',data:window.payload,version:4}]})})}");await w.testRun('loadClientHistories()');assert.equal(w.testRun('state.sessionBilling.receipts.length'),4);
 // Atomic-result failure restores both status and ledger, then retry commits.
 w.testRun("state.package={billingType:'per_session',status:'active',price:500,start:'2000-01-01',autoCharge:true};window.atomic={id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',dbId:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',type:'session',status:'planned',customerId:state.customer.id,date:'2020-01-01',time:'10:00',endTime:'11:00',title:'Atomic'};state.events=[window.atomic];window.initialCharges=state.sessionBilling.charges.length;db.rpc=async()=>({error:Error('conflict')})");
 assert.equal(await w.testRun("recordSessionResult(window.atomic,'completed',true)"),false);assert.equal(w.testRun('window.atomic.status'),'planned');assert.equal(w.testRun('state.sessionBilling.charges.length'),w.initialCharges);
 w.testRun("db.rpc=async(name,args)=>{window.rpcName=name;return {data:5}};");assert.equal(await w.testRun("recordSessionResult(window.atomic,'completed',true)"),true);assert.equal(w.rpcName,'save_billable_session_result');assert.equal(w.testRun('state.sessionBilling.charges.length'),w.initialCharges+1);
 assert.deepEqual(errors,[]);console.log('PASS: creation, completion, duplicate prevention, No Show reversal, stop, auto off, free demo, member reporting, PT full/partial receipts, reload and atomic failure/retry');
}finally{dom.window.close()}})().catch(e=>{console.error(e);process.exitCode=1});
