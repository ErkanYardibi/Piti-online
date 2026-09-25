const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom');
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const root=path.resolve(__dirname,'..'),html=fs.readFileSync(process.env.PITI_HTML||root+'/index.html','utf8').replace(/<script src=[^>]+><\/script>/g,'').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
const dom=new JSDOM(html,{url:'https://piti-test.invalid',runScripts:'dangerously',pretendToBeVisual:true,virtualConsole:vc,beforeParse(w){w.supabase={createClient:()=>({auth:{onAuthStateChange(){}}})};w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{};w.URL.createObjectURL=()=> 'blob:https://piti-test.invalid/test';w.URL.revokeObjectURL=()=>{}}});
const w=dom.window,d=w.document,run=code=>w.testRun(code),pause=()=>new Promise(r=>setTimeout(r,30));
(async()=>{try{
 w.fixture=JSON.parse(fs.readFileSync(root+'/assets/demo-state.json','utf8'));
 run("demoMode=true;state=clone(window.fixture);state.role='pt';state.page='messages';save=()=>{};syncTestAccount=()=>{};state.demoChat={messages:[],tasks:[]};render()");await pause();
 for(const [id,label] of [['chatStickerToggle','Sticker'],['chatEmojiToggle','Emoji'],['chatPhotoButton','Fotoğraf'],['chatAudioButton','Ses'],['chatVideoButton','Video'],['chatFileButton','Dosya ekle']]){const b=d.getElementById(id);assert.equal(b.textContent,'');assert.equal(b.getAttribute('aria-label'),label);assert.ok(b.querySelector('svg'))}
 assert.equal(d.getElementById('msgInput').tagName,'TEXTAREA');assert.ok(!d.getElementById('chatBox').contains(d.getElementById('msgInput')));
 const box=d.getElementById('chatBox');Object.defineProperties(box,{scrollHeight:{configurable:true,get:()=>6000},clientHeight:{configurable:true,get:()=>500}});
 run("state.demoChat.messages=Array.from({length:120},(_,i)=>({id:'m'+i,client_id:String(state.customer.id),sender_id:'demo-pt',body:'message '+i,created_at:new Date(Date.now()-(120-i)*1000).toISOString()}))");await run('refreshLiveChat()');await pause();assert.equal(box.scrollTop,6000,'initial conversation at latest');
 box.scrollTop=2000;box.dispatchEvent(new w.Event('scroll'));run("state.demoChat.messages.push({id:'new',client_id:String(state.customer.id),sender_id:'demo-pt',body:'new incoming',created_at:new Date().toISOString()})");await run('refreshLiveChat()');await pause();assert.equal(box.scrollTop,2000,'reading position retained on arrival');assert.equal(d.getElementById('chatLatest').hidden,false);
 d.getElementById('chatLatest').click();assert.equal(box.scrollTop,6000);assert.equal(d.getElementById('chatLatest').hidden,true);
 const input=d.getElementById('msgInput');input.value='First line\nSecond line';const shift=new w.KeyboardEvent('keydown',{key:'Enter',shiftKey:true,bubbles:true,cancelable:true});input.dispatchEvent(shift);assert.equal(shift.defaultPrevented,false,'Shift Enter adds newline');
 box.scrollTop=2000;box.dispatchEvent(new w.Event('scroll'));await run('sendLiveMessage()');await pause();assert.equal(box.scrollTop,6000,'own send returns to latest');assert.match(box.textContent,/First line\nSecond line/);assert.equal(input.value,'');
 const f=new w.File(['test attachment'],'Plan.pdf',{type:'application/pdf'});w.file=f;const draft=run('prepareChatFile(window.file)');assert.equal(draft.message_type,'file');assert.equal(draft.mime,'application/pdf');assert.equal(draft.name,'Plan.pdf');
 w.file=new w.File(['x'],'bad.html',{type:'text/html'});assert.throws(()=>run('prepareChatFile(window.file)'),/PDF/);
 w.file={name:'huge.pdf',size:15728641,type:'application/pdf'};assert.throws(()=>run('prepareChatFile(window.file)'),/15 MB/);
 w.file={name:'empty.pdf',size:0};assert.throws(()=>run('prepareChatFile(window.file)'),/boş/);
 w.file=f;run('setChatMediaDraft(prepareChatFile(window.file))');assert.match(d.getElementById('chatMediaDraft').textContent,/Plan.pdf/);await run('sendLiveMessage()');await pause();assert.equal(run('state.demoChat.messages.at(-1).media_name'),'Plan.pdf');assert.equal(d.querySelector('.chatFileCard').getAttribute('download'),'Plan.pdf');
 const hostile=run('chatMediaHtml({message_type:"file",media_url:"blob:test",media_name:"<img src=x onerror=alert(1)>.pdf",media_size:12},"blob:test")');assert.ok(!hostile.includes('<img'));assert.ok(hostile.includes('&lt;img'));
 run("state.role='member';liveMessages()");await pause();assert.equal(d.getElementById('chatStickerToggle'),null);assert.ok(d.getElementById('chatFileButton'));
 run("nav('today')");assert.equal(d.body.classList.contains('chatMode'),false);assert.equal(d.getElementById('view').classList.contains('chatScreen'),false);
 // Cloud pagination: query uses stable descending order and an exclusive tuple cursor.
 w.calls=[];run("db.from=()=>{const q={select(x){window.calls.push(['select',x]);return q},eq(...x){window.calls.push(['eq',...x]);return q},order(...x){window.calls.push(['order',...x]);return q},limit(x){window.calls.push(['limit',x]);return q},or(x){window.calls.push(['or',x]);return q},then(ok){return Promise.resolve({data:[]}).then(ok)}};return q}");
 await run("fetchChatMessages('client-1',{created_at:'2026-09-25T00:00:00Z',id:'message-id'})");assert.equal(w.calls.filter(x=>x[0]==='order').length,2);assert.equal(w.calls.find(x=>x[0]==='limit')[1],100);assert.match(w.calls.find(x=>x[0]==='or')[1],/id.lt.message-id/);
 assert.deepEqual(errors,[]);console.log('PASS: icon accessibility, PT/member controls, latest entry, preserved reading, jump/send-to-latest, multiline, private-file payload/render, size/type/name safety, pagination cursor and navigation cleanup');
 }finally{w.close()}})().catch(e=>{console.error(e);process.exitCode=1});
