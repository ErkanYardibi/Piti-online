// Native fetch only: no browser-admin SDK and no third-party runtime dependencies.
export function createHandler({url,serviceKey,fetchImpl=fetch,cryptoImpl=crypto}) {
 const allowedOrigins=new Set(['https://mypiti.online','https://www.mypiti.online','https://mypiti-online.netlify.app']);
 const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
 async function api(path,method='GET',body,token=serviceKey){
  const response=await fetchImpl(url+path,{method,headers:{apikey:serviceKey,Authorization:'Bearer '+token,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(15000)});
  const data=await response.json().catch(()=>null);
  if(!response.ok){const e=new Error(data?.msg||data?.message||data?.error_description||'Hesap işlemi tamamlanamadı.');e.status=response.status;throw e}
  return data;
 }
 const rpc=(name,args,token)=>api('/rest/v1/rpc/'+name,'POST',args,token);
 async function hash(value){const bytes=await cryptoImpl.subtle.digest('SHA-256',new TextEncoder().encode(value));return Array.from(new Uint8Array(bytes),b=>b.toString(16).padStart(2,'0')).join('')}
 function newToken(){return Array.from(cryptoImpl.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('')}
 return async function handler(req){
  const origin=req.headers.get('Origin');
  const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS',...(allowedOrigins.has(origin)?{'Access-Control-Allow-Origin':origin}:{})};
  const reply=(status,data)=>new Response(JSON.stringify(data),{status,headers});
  if(origin&&!allowedOrigins.has(origin))return reply(403,{error:'Bu adresten işlem yapılamaz.'});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply(405,{error:'POST gerekli.'});
  let operation=null,newUser=null,bound=false;
  try{
   const raw=await req.text();if(raw.length>8192)return reply(413,{error:'İstek çok büyük.'});
   const body=JSON.parse(raw);
   if(body.action==='redeem'){
    if(typeof body.token!=='string'||!/^[a-f0-9]{64}$/.test(body.token))return reply(400,{error:'Geçersiz giriş bağlantısı.'});
    // Consume once, atomically, before issuing any session. No email is sent.
    const entry=await rpc('consume_entry_link',{p_hash:await hash(body.token)});
    const generated=await api('/auth/v1/admin/generate_link','POST',{type:'magiclink',email:entry.email});
    if(!generated.hashed_token)throw Error('Giriş bağlantısı hazırlanamadı. Geçici şifrenle giriş yap.');
    const session=await api('/auth/v1/verify','POST',{type:'magiclink',token_hash:generated.hashed_token});
    if(session.user?.id!==entry.user_id)throw Error('Hesap eşleşmesi doğrulanamadı.');
    return reply(200,{access_token:session.access_token,refresh_token:session.refresh_token});
   }
   const token=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');
   if(!token||token===serviceKey)return reply(401,{error:'Önce hesabına giriş yap.'});
   const user=await api('/auth/v1/user','GET',undefined,token);
   const access=await rpc('account_context',{},token);
   if(!access.session_valid)return reply(401,{error:'Oturumun sona erdi. Yeniden giriş yap.'});
   if(!['create','reset','password'].includes(body.action))return reply(400,{error:'Geçersiz işlem.'});
   const password=body.password;
   if(typeof password!=='string'||password.length<12||new TextEncoder().encode(password).length>64)return reply(400,{error:'Şifre en az 12 karakter, en fazla 64 bayt olmalı.'});
   let clientId=body.client_id;
   if(body.action==='password'){
    if(access.role!=='member'||!access.must_change_password)return reply(403,{error:'Bu hesap için zorunlu şifre değişimi bulunmuyor.'});
    const clients=await api('/rest/v1/clients?user_id=eq.'+encodeURIComponent(user.id)+'&select=id');
    if(clients.length!==1)return reply(409,{error:'Müşteri hesabı eşleştirilemedi.'});
    clientId=clients[0].id;
    if(!await rpc('check_new_password',{p_user:user.id,p_password:password}))return reply(400,{error:'Yeni şifren geçici şifrenden farklı olmalı.'});
   }else if(access.role!=='pt'||access.must_change_password)return reply(403,{error:'Bu işlem yalnızca PT hesabına açık.'});
   if(typeof clientId!=='string'||!uuidPattern.test(clientId))return reply(400,{error:'Geçerli müşteri kaydı gerekli.'});
   operation=await rpc('managed_account_begin',{p_actor:user.id,p_client:clientId,p_kind:body.action});
   let targetUser=operation.user_id;
   if(body.action==='create'){
    const created=await api('/auth/v1/admin/users','POST',{email:operation.email.trim().toLowerCase(),password,email_confirm:true,user_metadata:{full_name:operation.full_name},app_metadata:{account_role:'member',must_change_password:true}});
    newUser=created.id||created.user?.id;if(!newUser)throw Error('Hesap oluşturulamadı.');targetUser=newUser;
   }else{
    await api('/auth/v1/admin/users/'+encodeURIComponent(targetUser),'PUT',{password});
   }
   const entryToken=body.action==='password'?null:newToken();
   await rpc('managed_account_finish',{p_operation:operation.operation_id,p_user:targetUser,p_token_hash:entryToken?await hash(entryToken):null});
   bound=true;
   return reply(200,body.action==='password'?{success:true,relogin:true}:{success:true,user_id:targetUser,email:operation.email,entry_url:'https://www.mypiti.online/#entry='+entryToken,expires_hours:24});
  }catch(error){
   if(newUser&&!bound){
    // Compensate only a newly created, still-unlinked identity, never an existing account.
    try{const links=await api('/rest/v1/clients?user_id=eq.'+encodeURIComponent(newUser)+'&select=id');if(!links.length)await api('/auth/v1/admin/users/'+encodeURIComponent(newUser),'DELETE')}catch{/* Admin audit contains the operation for recovery. */}
   }
   if(operation)try{await rpc('managed_account_cancel',{p_operation:operation.operation_id})}catch{}
   let message=error instanceof SyntaxError?'Geçersiz istek.':error.message||'İşlem tamamlanamadı.';
   if(/already.*registered|already.*exists/i.test(message))message='Bu e-posta zaten bir hesaba ait. Var olan hesabı davetle bağla; şifresi değiştirilmedi.';
   return reply(error.status===401?401:400,{error:message});
  }
 };
}
