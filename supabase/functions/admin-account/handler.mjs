export function createHandler({url,serviceKey,fetchImpl=fetch}){
 const origins=new Set(['https://mypiti.online','https://www.mypiti.online','https://piti-online.erkan-yardibi.workers.dev','https://mypiti-online.netlify.app']);
 async function api(path,method,body,token=serviceKey){
  const r=await fetchImpl(url+path,{method,headers:{apikey:serviceKey,Authorization:'Bearer '+token,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(15000)});
  const data=await r.json().catch(()=>null);if(!r.ok)throw Error(data?.message||data?.msg||'İşlem tamamlanamadı.');return data;
 }
 return async req=>{
  const origin=req.headers.get('Origin');const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS',...(origins.has(origin)?{'Access-Control-Allow-Origin':origin}:{})};
  const reply=(status,data)=>new Response(JSON.stringify(data),{status,headers});
  if(origin&&!origins.has(origin))return reply(403,{error:'İzin verilmeyen adres.'});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply(405,{error:'POST gerekli.'});
  try{
   const token=req.headers.get('Authorization')?.replace(/^Bearer /i,'');if(!token)return reply(401,{error:'Giriş gerekli.'});
   const user=await api('/auth/v1/user','GET',null,token);
   const context=await api('/rest/v1/rpc/account_context','POST',{},token);
   if(!context?.session_valid)return reply(401,{error:'Oturum sona erdi.'});
   const raw=await req.text();if(raw.length>2048)return reply(413,{error:'İstek çok büyük.'});
   const body=JSON.parse(raw);
   if(typeof body.password!=='string'||body.password.length<6||new TextEncoder().encode(body.password).length>64)return reply(400,{error:'Şifre 6–64 karakter aralığında olmalı.'});
   let target;
   if(body.action==='own_password'){
    if(!context.must_change_password)return reply(403,{error:'Şifre değişim isteği bulunamadı.'});
    target=user.id;
   }else if(body.action==='reset_password'){
    if(!/^[0-9a-f-]{36}$/i.test(body.user_id||''))return reply(400,{error:'Kullanıcı seç.'});
    // This RPC verifies current session, server-owned admin membership and AAL2.
    await api('/rest/v1/rpc/admin_console','POST',{p_action:'password_prepare',p_args:{user_id:body.user_id}},token);
    target=body.user_id;
   }else return reply(400,{error:'Geçersiz işlem.'});
   await api('/auth/v1/admin/users/'+target,'PUT',{password:body.password});
   if(body.action==='own_password')await api('/rest/v1/rpc/finish_password_change','POST',{p_user:target});
   return reply(200,{ok:true});
  }catch(e){return reply(400,{error:e.message})}
 };
}
