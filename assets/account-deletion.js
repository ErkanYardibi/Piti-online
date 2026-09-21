(function(root){
 'use strict';
 const states={requested:'Silme talebin alındı. Hesabın henüz silinmedi.',processing:'Hesap silme işlemi sürüyor.',needs_attention:'İşlem henüz tamamlanamadı; teknik kontrol gerekiyor.',completed:'Hesabının silinmesi tamamlandı.'};
 function render({target,client,context,url,key,fetcher=root.fetch}){
  const owner=context();
  if(owner.demo||!owner.ready||!owner.userId||target.querySelector('#accountDeletionPanel'))return null;
  const doc=target.ownerDocument,section=doc.createElement('section');section.id='accountDeletionPanel';section.className='card';section.style.marginTop='18px';
  section.innerHTML='<h2 class="sectionTitle">Hesabımı Sil</h2><p>Silme kapsamını ve hesabına etkilerini incele.</p><button type="button" class="btn ghost" data-delete-preview>Silme Bilgilerini Gör</button><div data-delete-details hidden><p data-delete-summary></p><p data-delete-notice></p><form hidden><div class="field"><label>Mevcut şifren<input class="input" name="password" type="password" autocomplete="current-password" required maxlength="64"></label></div><div class="field"><label>Onay için HESABIMI SIL yaz<input class="input" name="confirmation" autocomplete="off" required></label></div><button type="submit" class="btn danger">Silme Talebini Gönder</button><button type="button" class="btn ghost" data-delete-cancel>Vazgeç</button></form><button type="button" class="btn ghost" data-delete-status hidden>Durumu Kontrol Et</button></div><p role="status" aria-live="polite" data-delete-message></p>';
  target.append(section);
  const details=section.querySelector('[data-delete-details]'),form=section.querySelector('form'),message=section.querySelector('[data-delete-message]'),statusButton=section.querySelector('[data-delete-status]');
  let busy=false,preview=null,tracking=null;
  const active=()=>{const c=context();return section.isConnected&&c.ready&&!c.demo&&c.userId===owner.userId;};
  function setBusy(value){busy=value;section.querySelectorAll('button,input').forEach(el=>el.disabled=value);}
  async function request(body){
   const {data,error}=await client.auth.getSession();
   if(error||!active()||data?.session?.user?.id!==owner.userId)throw Error('Oturum değişti. Yeniden giriş yap.');
   const response=await fetcher(url+'/functions/v1/delete-account',{method:'POST',headers:{'Content-Type':'application/json',apikey:key,Authorization:'Bearer '+data.session.access_token},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
   const result=await response.json();
   if(!response.ok)throw Error(result?.error||'İşlem tamamlanamadı.');return result;
  }
  function showStatus(result){
   if(!states[result?.state])throw Error('Talep durumu doğrulanamadı.');
   form.hidden=true;message.textContent=states[result.state];
   if(result.deadline_at&&result.state!=='completed')message.textContent+=' Hedef tamamlanma: '+new Date(result.deadline_at).toLocaleString('tr-TR')+'.';
   statusButton.hidden=result.state==='completed';
  }
  async function load(){
   if(busy||!active())return;setBusy(true);message.textContent='Silme bilgileri yükleniyor…';
   form.hidden=true;form.reset();
   try{
    const result=await request({action:'preview'});if(!active())return;preview=result;details.hidden=false;
    const s=result.summary;
    if(!s||!['pt','member'].includes(s.role))throw Error('Silme özeti doğrulanamadı.');
    section.querySelector('[data-delete-summary]').textContent=(s.role==='pt'?'PT hesabı':'Müşteri hesabı')+' · İlişkili müşteri kaydı: '+Number(s.client_records||0)+' · PT geçiş kaydı: '+Number(s.past_transfers||0);
    section.querySelector('[data-delete-notice]').textContent=result.notice||'Silme kapsamı henüz yayımlanmadı.';
    statusButton.hidden=true;
    if(result.request){showStatus(result.request);return;}
    form.hidden=!result.available;
    message.textContent=result.available?'Özeti okuyup mevcut şifrenle onayla. Tamamlanma hedefi: '+Number(result.max_hours)+' saat.':'Hesap silme henüz kullanıma açık değil. Hiçbir veri silinmedi.';
   }catch(error){if(active())message.textContent=error.message;}
   finally{setBusy(false);}
  }
  section.querySelector('[data-delete-preview]').onclick=load;
  section.querySelector('[data-delete-cancel]').onclick=()=>{form.reset();details.hidden=true;message.textContent='İşlemden vazgeçildi. Silme talebi gönderilmedi.';};
  form.onsubmit=async event=>{
   event.preventDefault();if(busy||!active()||!preview?.available)return;
   if(form.elements.confirmation.value!=='HESABIMI SIL'){message.textContent='Onay için HESABIMI SIL yaz.';return;}
   const password=form.elements.password.value;form.elements.password.value='';
   if(!password){message.textContent='Mevcut şifreni gir.';return;}
   tracking=tracking||{request_id:root.crypto.randomUUID(),receipt:Array.from(root.crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('')};
   setBusy(true);message.textContent='Şifren doğrulanıyor ve talebin gönderiliyor…';
   try{
    const result=await request({action:'request',password,confirmation:'HESABIMI SIL',fingerprint:preview.fingerprint,...tracking});
    if(active())showStatus(result);
   }catch(error){if(active()){message.textContent=error.message;statusButton.hidden=false;}}
   finally{setBusy(false);}
  };
  statusButton.onclick=load;
  return section;
 }
 root.PiTiAccountDeletion={render};
 if(typeof module!=='undefined')module.exports={render};
})(typeof window!=='undefined'?window:globalThis);
