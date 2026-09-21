const {chromium}=require(process.env.PITI_PLAYWRIGHT_PATH||'playwright');
const binary=require(process.env.PITI_CHROMIUM_PACKAGE||'@sparticuz/chromium');const fs=require('fs'),http=require('http'),assert=require('assert/strict');
const root=require('path').resolve(__dirname,'..');const fixture=JSON.parse(fs.readFileSync(root+'/assets/demo-state.json'));
const html=fs.readFileSync(process.env.PITI_HTML||root+'/index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
(async()=>{const server=http.createServer((req,res)=>{try{res.end(req.url==='/'?html:fs.readFileSync(root+req.url))}catch{res.writeHead(404);res.end()}}).listen(8769);const browser=await chromium.launch({executablePath:process.env.PITI_CHROMIUM_EXECUTABLE,args:binary.args,headless:true});try{const page=await browser.newPage();await page.goto('http://localhost:8769');await page.evaluate(f=>{window.fixture=f;window.testRun("demoMode=true;state=clone(window.fixture);state.role='pt';state.page='dashboard';state.events=[{id:123,type:'session',date:iso(new Date()),time:'14:00',endTime:'15:00',title:'PT Seansı',status:'completed',customerId:state.customer.id}];document.querySelector('#authBack').hidden=true;render()")},fixture);

for(const role of ['pt','member'])for(const width of [390,1468]){
 await page.setViewportSize({width,height:1000});
 await page.evaluate(role=>window.testRun("state.role='"+role+"';state.page='messages';render()"),role);
 await page.locator('#msgInput').focus();
 assert.equal(await page.locator('#sidebar').evaluate(el=>getComputedStyle(el).visibility),'visible');
 await page.locator('#sidebar [data-nav="calendar"]').click();
 assert.equal(await page.evaluate(()=>window.testRun('state.page')),'calendar');
 assert.equal(await page.evaluate(()=>document.body.classList.contains('messageTyping')),false);
 await page.evaluate(()=>window.testRun("nav('messages')"));
 await page.locator('#msgInput').focus();
 await page.locator('#chatBack').click();
 assert.equal(await page.evaluate(()=>window.testRun('state.page')),role==='pt'?'dashboard':'today');
 assert.equal(await page.evaluate(()=>document.body.classList.contains('messageTyping')),false);
}
console.log('PASS: PT/member mobile/desktop menu navigation with input focus and return-home button');
}finally{await browser.close();server.close()}})().catch(e=>{console.error(e);process.exit(1)});
