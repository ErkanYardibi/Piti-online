const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require(process.env.PITI_JSDOM_PATH||'jsdom');
(async()=>{
 const dom=new JSDOM('<main></main>',{runScripts:'outside-only'}),w=dom.window;
 w.eval(fs.readFileSync('assets/retained-history.js','utf8'));
 let owner={userId:'member',ready:true,demo:false,role:'member'},calls=0,answer;
 const target=w.document.querySelector('main'),client={rpc:async name=>{assert.equal(name,'member_retained_history');calls++;return answer;}};
 const render=()=>w.PiTiRetainedHistory.render({target,client,context:()=>owner});
 render();assert.equal(calls,0);
 answer={data:[{archived_at:'2026-09-21',snapshot:{payments:[{amount:150,status:'<img src=x onerror=alert(1)>'}]}}]};
 await target.querySelector('button').onclick();assert.equal(calls,1);assert(target.textContent.includes('150'));assert.equal(target.querySelector('img'),null);assert.equal(target.querySelectorAll('input').length,0);
 answer={error:new Error('backend details')};await target.querySelector('button').onclick();assert(target.textContent.includes('yeniden dene'));assert(!target.textContent.includes('backend details'));
 let release;client.rpc=()=>new Promise(r=>release=r);const pending=target.querySelector('button').onclick();owner={...owner,userId:'other'};release({data:[{snapshot:{payments:[{amount:999}]}}]});await pending;assert(!target.textContent.includes('999'));
 target.replaceChildren();owner={...owner,demo:true};render();assert.equal(target.children.length,0);
 owner={...owner,demo:false,role:'pt'};render();assert.equal(target.children.length,0);
 dom.window.close();console.log('PASS: history read-only UI, explicit fetch, safe text, errors, account switch, DEMO/PT exclusion');
})().catch(e=>{console.error(e);process.exit(1)});
