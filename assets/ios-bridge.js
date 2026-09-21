(function(root){
 'use strict';
 function create({window:w,client,context,navigate}){
  const native=w.webkit?.messageHandlers?.pitiNative;
  if(!native||!client)return null;
  let device=null,registeredKey='',serial=Promise.resolve(),leaving=false,statusText='Bildirim izni henüz verilmedi.';
  const params=d=>({p_token:d.token,p_environment:d.environment,p_topic:d.topic});
  const post=action=>native.postMessage({action});
  function updateStatus(text){statusText=text;const el=w.document.getElementById('nativePushStatus');if(el)el.textContent=text;}
  async function sync(){
   const ctx=context(),snapshot=device;
   if(leaving||!ctx.ready||!ctx.userId||ctx.demo||!snapshot)return;
   if(!/^[a-f0-9]{64,512}$/.test(snapshot.token||'')||snapshot.token.length%2)return;
   if(!['sandbox','production'].includes(snapshot.environment)||!['online.mypiti.app','online.mypiti.app.staging'].includes(snapshot.topic))return;
   if(snapshot.permission!=='authorized'){
    const {error}=await client.rpc('disable_push_device',params(snapshot));
    if(error)throw error;registeredKey='';return;
   }
   const key=JSON.stringify([ctx.userId,snapshot.token,snapshot.environment,snapshot.topic]);
   if(key===registeredKey){updateStatus('Bildirim kaydı tamamlandı. Teslim, iPhone bildirim ayarlarına bağlıdır.');return;}
   const {error}=await client.rpc('register_push_device',{...params(snapshot),p_app_version:String(snapshot.app_version||'').slice(0,32)});
   if(error)throw error;
   if(context().userId===ctx.userId&&!context().demo&&!leaving){registeredKey=key;updateStatus('Bildirim kaydı tamamlandı. Teslim, iPhone bildirim ayarlarına bağlıdır.');}
  }
  function enqueueSync(){serial=serial.catch(()=>{}).then(sync).catch(()=>updateStatus('Bildirim kaydı tamamlanamadı. Tekrar dene veya profilini yeniden aç.'));return serial;}
  w.addEventListener('piti-native-push-token',event=>{
   if(!event.detail||typeof event.detail!=='object')return;
   device={...event.detail};
   const labels={authorized:'İzin verildi. Cihaz kaydediliyor…',denied:'Bildirimler kapalı. iPhone ayarlarından açabilirsin.',registrationFailed:'Apple bildirim servisine kayıt yapılamadı.',notDetermined:'Bildirim izni henüz verilmedi.'};
   updateStatus(labels[device.permission]||labels.notDetermined);enqueueSync();
  });
  w.pitiNativeOpenRoute=async route=>{
   if(!route||typeof route!=='object'||!['calendar','messages','finance','profile','today','dashboard'].includes(route.page))return true;
   const ctx=context();
   if(!ctx.ready||!ctx.userId||ctx.demo||leaving)return false; // native retains until login ready
   if(route.recipient_id&&route.recipient_id!==ctx.userId)return true; // discard other user's push
   try{await navigate(route);return true;}catch{return false;}
  };
  return {
   ready(){leaving=false;registeredKey='';post('ready');enqueueSync();},
   async beforeLogout(){
    leaving=true;await serial.catch(()=>{});
    if(device?.token&&context().userId){
     const {error}=await client.rpc('disable_push_device',params(device));
     if(error){leaving=false;throw new Error('Bildirim kaydı kapatılamadı. Bağlantını kontrol edip tekrar çıkış yap.');}
    }
    registeredKey='';
   },
   renderSettings(target){
    if(context().demo||!context().ready||target.querySelector('#nativePushPanel'))return;
    const section=w.document.createElement('section');section.id='nativePushPanel';section.className='card';section.style.marginTop='18px';
    section.innerHTML='<h2 class="sectionTitle">iPhone Bildirimleri</h2><p>Seans, mesaj, görev ve ödeme bildirimlerini al. İzin vermeden de PiTi’yi kullanabilirsin.</p><div class="rightActions"><button class="btn primary" data-push-enable>Bildirimleri Aç</button><button class="btn ghost" data-push-settings>iPhone Ayarları</button><button class="btn ghost" data-push-retry>Tekrar Dene</button></div><p id="nativePushStatus" class="small muted" role="status" aria-live="polite"></p>';
    target.append(section);updateStatus(statusText);
    section.querySelector('[data-push-enable]').onclick=()=>post('requestPushPermission');
    section.querySelector('[data-push-settings]').onclick=()=>post('notificationSettings');
    section.querySelector('[data-push-retry]').onclick=()=>{registeredKey='';enqueueSync();};
   }
  };
 }
 root.PiTiIOSBridge={create};
 if(typeof module!=='undefined')module.exports={create};
})(typeof window!=='undefined'?window:globalThis);
