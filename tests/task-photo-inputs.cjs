const {JSDOM,VirtualConsole}=require(process.env.PITI_JSDOM_PATH||'jsdom'),fs=require('fs'),assert=require('assert/strict');
(async()=>{
 const html=fs.readFileSync('index.html','utf8').replace('<script src="/vendor/supabase.min.js"></script>','').replace('render();maybeOpenJoinLink();initAuth();','window.testRun=code=>eval(code);render();');
 const errors=[],vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
 const dom=new JSDOM(html,{url:'https://mypiti.online',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){w.matchMedia=()=>({matches:false,addEventListener(){}});w.scrollTo=()=>{};}});
 try{
  const w=dom.window,d=w.document;w.fixture=JSON.parse(fs.readFileSync('assets/demo-state.json','utf8'));
  w.testRun(`demoMode=true;authUser=null;state=clone(window.fixture);state.role='member';state.page='messages';window.uploads=[];window.processed=[];
   prepareTaskPhoto=async file=>{window.processed.push(file.name);return 'data:image/jpeg;base64,YWJj'};
   chatData=()=>({complete:async(t,payload)=>{window.uploads.push(payload);return {data:[{id:t.id}]}}});refreshLiveChat=async()=>{};loadLiveTasks=async()=>{};
   chatTaskRows=[{id:'photo-task',title:'Öğünü Paylaş',response_type:'photo',status:'pending'}]`);
  for(const source of ['taskCameraPhoto','taskResultPhoto']){
   w.testRun("openCompleteTask('photo-task')");
   assert.equal(d.querySelector('#taskCameraPhoto').getAttribute('capture'),'environment');
   assert.equal(d.querySelector('#taskResultPhoto').getAttribute('capture'),null);
   const input=d.getElementById(source);Object.defineProperty(input,'files',{value:[new w.File(['original'],source+'.jpg',{type:'image/jpeg'})]});
   await input.onchange({target:input});
   assert.equal(w.processed.at(-1),source+'.jpg');assert.equal(w.uploads.at(-1).result_photo,'data:image/jpeg;base64,YWJj');assert.equal(w.uploads.at(-1).status,'done');
  }
  assert.equal(w.uploads.length,2);assert.deepEqual(errors,[]);console.log('PASS: camera capture and gallery share compression and automatic submission');
 }finally{dom.window.close()}
})().catch(e=>{console.error(e);process.exit(1)});
