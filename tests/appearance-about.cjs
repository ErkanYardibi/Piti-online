const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8').replace('const db=','let db=').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));let mediaCallback;
const media={matches:false,addEventListener(type,fn){mediaCallback=fn}};
const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>media;w.scrollTo=()=>{}}});
(async()=>{try{
 const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json'));
 w.testRun("demoMode=true;state=clone(window.fixture);save=()=>{};");
 for(const role of ['pt','member']){
  w.testRun(`state.role='${role}';state.page='about';render()`);
  assert.ok(d.querySelector('[data-nav="appearance"]'));assert.ok(d.querySelector('[data-nav="about"]'));
  assert.equal(d.querySelector('a[href="mailto:eyardibi@gmail.com"]').textContent,'eyardibi@gmail.com');
  assert.match(d.querySelector('#view').textContent,/Designed by Yardibi Production/);
  w.testRun("state.page='appearance';render()");assert.equal(d.querySelector('#appearanceTheme').options.length,3);
 }
 await w.testRun("saveAppearance({theme:'dark',background:'navy'})");assert.equal(d.documentElement.dataset.theme,'dark');assert.equal(d.documentElement.style.getPropertyValue('--bg'),'#101b30');
 w.testRun("state.appearance={theme:'system',background:'cream'};applyAppearance()");assert.equal(d.documentElement.dataset.theme,'light');media.matches=true;mediaCallback();assert.equal(d.documentElement.dataset.theme,'dark');
 w.testRun("state.appearance={};applyAppearance()");assert.equal(d.documentElement.dataset.theme,'dark');
 // Verify preference state passed to the existing cloud synchronization and rollback.
 w.testRun("demoMode=false;authUser={id:'owner'};liveStateOwner='owner';state.cloudOwner='owner';db={};window.originalSync=syncCloudDataNow;syncCloudDataNow=async()=>{window.stored=JSON.parse(JSON.stringify(state))}");
 await w.testRun("saveAppearance({theme:'light',background:'sage'})");assert.equal(w.stored.appearance.background,'sage');
 w.testRun("state=clone(window.stored);applyAppearance()");assert.equal(d.documentElement.dataset.theme,'light');
 w.testRun("syncCloudDataNow=async()=>{throw Error('write failed')}");await assert.rejects(w.testRun("saveAppearance({theme:'dark',background:'navy'})"),/write failed/);assert.equal(w.testRun('state.appearance.theme'),'light');
 w.testRun("state=emptyLiveState();state.role='pt';state.cloudOwner='owner';syncCloudDataNow=window.originalSync;db={from:table=>({update:()=>({eq:async()=>({error:null})}),upsert:async row=>{if(table!=='account_state')throw Error('unexpected table');window.databaseRow=JSON.parse(JSON.stringify(row));return {error:null}}})}");
 await w.testRun("saveAppearance({theme:'dark',background:'gray'})");assert.equal(w.databaseRow.user_id,'owner');assert.equal(w.databaseRow.data.appearance.theme,'dark','actual sync writes account_state preference');
 w.testRun("state=emptyLiveState();applyAppearance()");assert.equal(w.testRun('state.appearance'),undefined,'another account does not inherit preference');
 assert.ok(!w.testRun('clientHistoryKeys.includes("appearance")'),'preference is never copied to a client');
 assert.deepEqual(errors,[]);console.log('PASS: both menus, contact, theme/system changes, account save/reload, failure rollback and account isolation');
}finally{dom.window.close()}})().catch(e=>{console.error(e);process.exitCode=1});
