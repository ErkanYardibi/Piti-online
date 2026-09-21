(function(root){
 'use strict';
 const labels={messages:'Mesajlar',sessions:'Seans talepleri ve değişiklikleri',tasks:'PT görevleri',payments:'Ödeme onayları'};
 const keys=Object.keys(labels);
 function render({target,client,context}){
  const owner=context();
  if(!owner.ready||!owner.userId||owner.demo||target.querySelector('[data-push-preferences]'))return null;
  const doc=target.ownerDocument,form=doc.createElement('form');form.dataset.pushPreferences='';
  form.innerHTML='<fieldset disabled><legend>Bildirim türleri</legend>'+keys.map(key=>
   '<label style="display:flex;align-items:center;gap:12px;min-height:44px"><input type="checkbox" name="'+key+'">'+labels[key]+'</label>').join('')+
   '<button type="submit" class="btn primary">Tercihleri Kaydet</button></fieldset><p class="small muted">Seçimlerin bu hesaba bağlı tüm iPhone cihazlarında geçerlidir. Bildirimleri kapatmak uygulama içindeki mesajları ve kayıtları gizlemez. Gönderilmiş bildirimler yine de ulaşabilir.</p><p role="status" aria-live="polite" data-preference-status></p><button type="button" class="btn ghost" data-preference-retry hidden>Yeniden Yükle</button>';
  target.append(form);
  const fieldset=form.querySelector('fieldset'),status=form.querySelector('[data-preference-status]'),retry=form.querySelector('[data-preference-retry]');
  let loading=false,loaded=false;
  const active=()=>{const c=context();return form.isConnected&&c.ready&&!c.demo&&c.userId===owner.userId;};
  function apply(value){
   if(!value||keys.some(key=>typeof value[key]!=='boolean'))throw Error('Invalid preferences');
   keys.forEach(key=>{form.elements.namedItem(key).checked=value[key];});
  }
  async function load(){
   if(loading||!active())return;
   loading=true;loaded=false;fieldset.disabled=true;retry.hidden=true;status.textContent='Bildirim tercihlerin yükleniyor…';
   try{
    const {data,error}=await client.rpc('get_push_preferences');
    if(!active())return;if(error)throw error;apply(data);loaded=true;status.textContent='Tercihlerin yüklendi.';
   }catch{if(active()){status.textContent='Tercihler yüklenemedi. Yeniden dene.';retry.hidden=false;}}
   finally{loading=false;if(active())fieldset.disabled=!loaded;}
  }
  form.onsubmit=async event=>{
   event.preventDefault();if(loading||!loaded||!active())return;
   const values=Object.fromEntries(keys.map(key=>['p_'+key,form.elements.namedItem(key).checked]));
   loading=true;fieldset.disabled=true;status.textContent='Tercihlerin kaydediliyor…';
   try{
    const {data,error}=await client.rpc('set_push_preferences',values);
    if(!active())return;if(error)throw error;apply(data);status.textContent='Bildirim tercihlerin kaydedildi.';
   }catch{if(active())status.textContent='Kaydedilemedi. Seçimlerin ekranda duruyor; tekrar kaydetmeyi deneyebilirsin.';}
   finally{loading=false;if(active())fieldset.disabled=false;}
  };
  retry.onclick=load;load();return form;
 }
 root.PiTiPushPreferences={render};
 if(typeof module!=='undefined')module.exports={render};
})(typeof window!=='undefined'?window:globalThis);
