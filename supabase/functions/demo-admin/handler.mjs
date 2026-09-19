// Runs in the DEMO project. Production credentials here are publishable only.
// The production RPC verifies the caller's real session, admin membership and MFA.
export function createHandler({demoUrl,demoServiceKey,fetchImpl=fetch}){
 const productionUrl='https://objwhegswugyeibcnjfr.supabase.co';
 const productionKey='sb_publishable_iPbwiRE8tlh07UAATv-N8g_feL79rDt';
 const origins=new Set(['https://mypiti.online','https://www.mypiti.online','https://piti-online.erkan-yardibi.workers.dev']);
 if(demoUrl===productionUrl)throw Error('DEMO must use a separate project');
 async function api(url,path,key,token,method='GET',body){
  const r=await fetchImpl(url+path,{method,headers:{apikey:key,Authorization:'Bearer '+token,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(15000)});
  const data=await r.json().catch(()=>null);if(!r.ok)throw Error(data?.message||data?.error||'İşlem tamamlanamadı.');return data;
 }
 return async req=>{
  const origin=req.headers.get('origin');
  const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Headers':'authorization,apikey,content-type','Access-Control-Allow-Methods':'POST,OPTIONS',...(origins.has(origin)?{'Access-Control-Allow-Origin':origin}:{})};
  const reply=(status,data)=>new Response(JSON.stringify(data),{status,headers});
  if(origin&&!origins.has(origin))return reply(403,{error:'İzin verilmeyen adres.'});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply(405,{error:'POST gerekli.'});
  const token=req.headers.get('authorization')?.replace(/^Bearer /i,'');
  if(!token)return reply(401,{error:'Admin girişi gerekli.'});
  try{
   // Fail closed: no DEMO data read/write until production confirms AAL2 admin.
   await api(productionUrl,'/rest/v1/rpc/admin_console',productionKey,token,'POST',{p_action:'overview',p_args:{}});
  }catch{return reply(403,{error:'Geçerli çift doğrulanmış admin oturumu gerekli.'})}
  try{
   const raw=await req.text();if(new TextEncoder().encode(raw).length>2100000)return reply(413,{error:'Demo verisi çok büyük.'});
   const {action,args={}}=JSON.parse(raw);
   let result;
   if(action==='demo'){
    const rows=await api(demoUrl,'/rest/v1/demo_state?id=eq.main&select=data,version',demoServiceKey,demoServiceKey);result=rows[0];
   }else if(action==='demo_versions'){
    const page=Math.max(0,Math.min(Number.isInteger(args.page)?args.page:0,100000));
    result=await api(demoUrl,`/rest/v1/demo_versions?select=id,created_at&order=id.desc&limit=50&offset=${page*50}`,demoServiceKey,demoServiceKey);
   }else if(action==='save_demo'||action==='restore_demo'){
    result=await api(demoUrl,'/rest/v1/rpc/publish_demo',demoServiceKey,demoServiceKey,'POST',{p_action:action,p_args:args});
   }else return reply(400,{error:'Geçersiz demo işlemi.'});
   return reply(200,{data:result});
  }catch(e){return reply(400,{error:e.message})}
 };
}
