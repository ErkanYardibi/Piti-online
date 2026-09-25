(function(root){
 'use strict';
 function render({target,client,context}){
  const owner=context();if(!owner.ready||owner.demo||owner.role!=='member')return;
  const doc=target.ownerDocument,box=doc.createElement('section'),button=doc.createElement('button'),content=doc.createElement('div');
  box.className='card';button.className='btn ghost';button.textContent='Eski PT seans ve ödeme arşivim';content.setAttribute('aria-live','polite');box.append(button,content);target.append(box);
  const active=()=>{const c=context();return box.isConnected&&c.ready&&!c.demo&&c.role==='member'&&c.userId===owner.userId;};
  const add=(tag,text)=>{const el=doc.createElement(tag);el.textContent=text;content.append(el);};
  button.onclick=async()=>{
   if(!active())return;button.disabled=true;content.replaceChildren();add('p','Geçmiş yükleniyor…');
   try{
    const {data,error}=await client.rpc('member_retained_history');if(!active()){content.replaceChildren();return;}if(error)throw error;
    content.replaceChildren();add('p','Salt okunur tarihsel bilgi. Yeni PT bu arşivi göremez; paket, borç ve seans hakları yeni PT’ye aktarılmaz.');
    if(!data?.length)add('p','Arşivlenmiş kayıt yok.');
    for(const row of data||[]){
     add('h3','Eski PT · '+new Date(row.archived_at).toLocaleDateString('tr-TR'));
     const s=row.snapshot||{};
     for(const [label,items] of [['Seanslar',s.sessions],['Paketler',s.packages],['Ödemeler',s.payments],['Seans ücretleri',s.charges],['Tahsilatlar',s.receipts],['Ödeme geçmişi',s.financeHistory],['Önceki paketler',s.previousPackages],['Önceki ödeme durumları',s.previousPayments],['Paket özeti',[s.package]],['Ödeme özeti',[s.payment]]]){
      add('h4',label);
      const values=(items||[]).filter(x=>x&&Object.keys(x).length);
      if(!values.length)add('p','Kayıt yok.');
      for(const item of values)add('p',Object.entries(item).filter(([key])=>!['id','chargeId'].includes(key)).map(([key,value])=>(labels[key]||key)+': '+(typeof value==='boolean'?(value?'Evet':'Hayır'):statuses[value]||String(value??'—'))).join(' · '));
     }
    }
   }catch{if(active()){content.replaceChildren();add('p','Geçmiş yüklenemedi. Lütfen yeniden dene.');}}
   finally{if(active())button.disabled=false;}
  };
 }
 const labels={starts_at:'Başlangıç',ends_at:'Bitiş',status:'Durum',workout_title:'Antrenman',counts_against_package:'Paketten düşüldü',name:'Paket',price:'Tutar',total_sessions:'Seans sayısı',totalSessions:'Seans sayısı',start_date:'Başlangıç',startDate:'Başlangıç',expiry_date:'Bitiş',expiryDate:'Bitiş',amount:'Tutar',method:'Yöntem',paid_at:'Ödeme tarihi',paidAt:'Ödeme tarihi',created_at:'Kayıt tarihi',createdAt:'Kayıt tarihi',date:'Tarih',type:'Tür'};
 Object.assign(labels,{start:'Başlangıç',end:'Bitiş',expireDate:'Bitiş',usedSessions:'Kullanılan seans',billingType:'Ödeme türü',receivedAmount:'Alınan tutar',submittedAt:'Bildirim tarihi',recordedAt:'Kayıt tarihi',voided:'Ücret iptal edildi'});
 const statuses={completed:'Tamamlandı',cancelled:'İptal',planned:'Planlı',requested:'Talep edildi',no_show:'Katılmadı',approved:'Onaylandı',pending:'Onay bekliyor',unpaid:'Ödenmedi',rejected:'Reddedildi',active:'Aktif',closed:'Kapalı',per_session:'Ders başı'};
 root.PiTiRetainedHistory={render};
})(window);
