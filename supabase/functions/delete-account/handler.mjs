const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const receipt=/^[a-f0-9]{64}$/;
export function createHandler({url,serviceKey,origins=[],fetcher=fetch}){
 const allowed=new Set(origins);
 async function api(path,method,body,token=serviceKey){
  const response=await fetcher(url+path,{method,headers:{apikey:serviceKey,Authorization:'Bearer '+token,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(15000)});
  const data=await response.json().catch(()=>null);
  if(!response.ok)throw Error('Service operation failed');return data;
 }
 const rpc=(name,args,token)=>api('/rest/v1/rpc/'+name,'POST',args,token);
 const hash=async value=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),b=>b.toString(16).padStart(2,'0')).join('');
 return async req=>{
  const origin=req.headers.get('Origin');
  const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS',...(allowed.has(origin)?{'Access-Control-Allow-Origin':origin}:{})};
  const reply=(status,data)=>new Response(JSON.stringify(data),{status,headers});
  if(origin&&!allowed.has(origin))return reply(403,{error:'Bu adresten işlem yapılamaz.'});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply(405,{error:'POST gerekli.'});
  if(!url||!serviceKey)return reply(503,{error:'Hesap silme servisi henüz hazır değil.'});
  let body;
  try{const raw=await req.text();if(raw.length>4096)return reply(413,{error:'İstek çok büyük.'});body=JSON.parse(raw);}catch{return reply(400,{error:'Geçersiz istek.'});}
  if(!body||Array.isArray(body)||typeof body!=='object')return reply(400,{error:'Geçersiz istek.'});
  const keys={preview:['action'],request:['action','password','confirmation','fingerprint','request_id','receipt'],status:['action','request_id','receipt']};
  if(!keys[body.action]||Object.keys(body).some(k=>!keys[body.action].includes(k)))return reply(400,{error:'Geçersiz işlem veya alan.'});
  if(body.action!=='preview'&&(!uuid.test(body.request_id||'')||!receipt.test(body.receipt||'')))return reply(400,{error:'Geçersiz talep bilgisi.'});
  try{
   if(body.action==='status'){
    const result=await rpc('account_deletion_receipt',{p_id:body.request_id,p_receipt_hash:await hash(body.receipt)});
    return result?reply(200,result):reply(404,{error:'Talep bulunamadı.'});
   }
   const token=(req.headers.get('Authorization')||'').match(/^Bearer\s+(\S+)$/i)?.[1]||'';
   if(!token||token===serviceKey)return reply(401,{error:'Önce hesabına giriş yap.'});
   let user,preview;
   try{user=await api('/auth/v1/user','GET',undefined,token);preview=await rpc('account_deletion_preview',{},token);}catch{return reply(401,{error:'Oturumunu doğrulayamadık. Yeniden giriş yap.'});}
   if(!uuid.test(user?.id||''))return reply(401,{error:'Hesap doğrulanamadı.'});
   if(body.action==='preview')return reply(200,preview);
   if(!preview.available)return reply(503,{error:'Hesap silme henüz kullanıma açık değil. Hesabında değişiklik yapılmadı.'});
   if(preview.fingerprint!==body.fingerprint)return reply(409,{error:'Bilgiler değişti. Silme özetini yeniden aç.'});
   if(body.confirmation!=='HESABIMI SIL'||typeof body.password!=='string'||body.password.length<1||new TextEncoder().encode(body.password).length>64)return reply(400,{error:'Şifreni ve silme onayını gir.'});
   let verified;
   try{verified=await api('/auth/v1/token?grant_type=password','POST',{email:user.email,password:body.password});}
   catch{return reply(401,{error:'Şifre doğrulanamadı.'});}
   // Never expose or persist the temporary reauthentication session. Revoke it
   // before accepting a job. Failure leaves the account and queue untouched.
   if(verified?.access_token)await api('/auth/v1/logout?scope=local','POST',undefined,verified.access_token);
   if(verified?.user?.id!==user.id||!verified.access_token)return reply(401,{error:'Hesap doğrulanamadı.'});
   const claims=JSON.parse(atob(token.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));
   if(!uuid.test(claims.session_id||''))return reply(401,{error:'Geçerli oturum gerekli.'});
   const result=await rpc('account_deletion_request',{p_user:user.id,p_session:claims.session_id,p_id:body.request_id,p_receipt_hash:await hash(body.receipt),p_fingerprint:body.fingerprint});
   return reply(202,result);
  }catch{return reply(503,{error:'İşlem tamamlanamadı. Talep durumunu kontrol edip yeniden dene.'});}
 };
}
