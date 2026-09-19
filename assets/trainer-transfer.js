let transferNotices=[],transferHistory=[],transferDataOwner=null;
let demoPreviousTrainerState=null,demoNewTrainerState=null;
async function transferRequest(action,args={}){
 if(demoMode)return demoTransferRequest(action,args);
 const guard=liveContextGuard();guard();
 const {data,error}=await db.rpc('trainer_transfer',{p_action:action,p_args:args});guard();if(error)throw error;return data;
}
async function loadTransferData(){
 if(demoMode){transferNotices=state.demoTransferNotices||[];transferHistory=state.demoTransferHistory||[];return;}
 if(!authUser||adminMode)return;
 const guard=liveContextGuard();guard();
 if(transferDataOwner!==authUser.id){transferNotices=[];transferHistory=[];transferDataOwner=authUser.id;}
 const {data,error}=await db.from('transfer_notifications').select('id,body,created_at,read_at').order('created_at',{ascending:false}).limit(30);guard();if(error)throw error;transferNotices=data||[];
 if(state.role==='member'){
  const result=await db.from('trainer_transfers').select('*').order('created_at',{ascending:false});guard();if(result.error)throw result.error;transferHistory=result.data||[];
 }else transferHistory=[];
}
function renderTransferNotices(){
 document.querySelector('#transferNotices')?.remove();
 if(adminMode||(!authUser&&!demoMode))return;
 const notices=demoMode?(state.demoTransferNotices||[]):transferNotices;
 const unread=notices.filter(n=>!n.read_at);if(!unread.length)return;
 const box=document.createElement('div');box.id='transferNotices';box.className='card';
 box.innerHTML='<h2 class="sectionTitle">PT bağlantısı bildirimleri</h2>'+unread.map(n=>`<div class="eventItem"><p>${escapeHtml(n.body)}</p><button class="btn ghost sm" data-transfer-ack="${escapeHtml(n.id)}">Okudum</button></div>`).join('');
 view.prepend(box);
 box.querySelectorAll('[data-transfer-ack]').forEach(b=>b.onclick=async()=>{b.disabled=true;try{await transferRequest('ack',{id:b.dataset.transferAck});await loadTransferData();renderTransferNotices();}catch(e){toast(e.message);b.disabled=false;}});
}
function renderTransferControls(){
 if(adminMode||(!authUser&&!demoMode))return;
 renderTransferNotices();
 if(state.role==='pt'){
  const selected=financeCustomers().find(c=>String(c.id)===String(state.page==='customerProfile'?(state.customerProfileId||state.customer.id):(state.financeCustomerId||state.customer.id)));
  if(selected?.relationshipEndedAt){
   if(state.page==='customerProfile')view.querySelectorAll('#saveCustomerProfile,#customerPhoto').forEach(x=>x.disabled=true);
   if(state.page==='finance')view.querySelectorAll('input,textarea,button:not([data-finance-customer])').forEach(x=>x.disabled=true);
  }
  view.querySelectorAll('[data-archive-customer],[data-delete-customer]').forEach(b=>{const id=b.dataset.archiveCustomer||b.dataset.deleteCustomer;if(financeCustomers().find(c=>String(c.id)===id)?.relationshipEndedAt){b.disabled=true;b.title='Sona ermiş PT ilişkisi salt okunurdur.';}});
 }
 if(state.role==='pt'&&['customers','invites'].includes(state.page)&&!document.querySelector('#inviteTransfer')){
  const b=document.createElement('button');b.id='inviteTransfer';b.className='btn ghost';b.textContent='Başka PT’deki müşteriyi davet et';b.onclick=openTransferInvite;view.prepend(b);
 }
 if(state.role==='member'&&state.page==='trainer'&&!document.querySelector('#transferPanel')){
  const box=document.createElement('div');box.id='transferPanel';box.className='card';
  box.innerHTML='<h2 class="sectionTitle">PT değişikliği</h2><p>Yeni PT’nin verdiği geçiş kodunu kullan. Eski PT’nin onayı gerekmez; geçiş tamamlandığında bilgilendirilir.</p><button class="btn primary" id="openTransfer">PT değiştir</button><button class="btn ghost" id="pastTrainers">Önceki PT geçmişim</button>'+(demoMode?'<p class="small muted">Demo geçiş kodu: DEMO-PT-GECIS</p>':'');
  view.append(box);box.querySelector('#openTransfer').onclick=openTransferForm;box.querySelector('#pastTrainers').onclick=openTransferHistory;
 }
 if(demoMode&&demoPreviousTrainerState&&state.role==='pt'&&!document.querySelector('#demoTransferSwitch')){
  const b=document.createElement('button');b.id='demoTransferSwitch';b.className='btn ghost';b.textContent=state===demoPreviousTrainerState?'Yeni PT görünümüne geç':'Eski PT bildirimini gör';
  b.onclick=()=>{state=state===demoPreviousTrainerState?demoNewTrainerState:demoPreviousTrainerState;state.role='pt';state.page='customers';render();};view.prepend(b);
 }
}
function openTransferInvite(){
 openModal('<h3>PT geçiş daveti</h3><p>Müşterinin mevcut PiTi kullanıcı adını gir. Yeni hesap veya şifre oluşturulmaz.</p><label>Kullanıcı adı</label><input class="input" id="transferUsername" autocomplete="off"><p id="transferError" role="alert"></p><div class="modalFoot"><button class="btn ghost" data-close>Vazgeç</button><button class="btn primary" id="createTransfer">Davet oluştur</button></div>');
 document.querySelector('#createTransfer').onclick=async()=>{const b=document.querySelector('#createTransfer');b.disabled=true;try{
  const result=await transferRequest('create',{username:document.querySelector('#transferUsername').value.trim()});
  openModal(`<h3>Geçiş daveti hazır</h3><p>Bu kodu müşterinle paylaş. Müşteri kendi hesabında PT’im → PT değiştir bölümünden onaylar. Kod 7 gün geçerli ve tek kullanımlıktır.</p><input class="input" id="transferCodeCopy" readonly value="${escapeHtml(result.code)}"><div class="modalFoot"><button class="btn primary" id="copyTransferCode">Kodu kopyala</button><button class="btn ghost" data-close>Kapat</button></div>`);
  document.querySelector('#copyTransferCode').onclick=()=>copyText(result.code);
 }catch(e){document.querySelector('#transferError').textContent=e.message;b.disabled=false;}};
}
function openTransferForm(){
 openModal('<h3>PT değiştir</h3><p>Yeni PT’nin sana özel oluşturduğu geçiş kodunu gir.</p><label>Geçiş kodu</label><input class="input" id="transferCode" autocomplete="off"><p id="transferError" role="alert"></p><div class="modalFoot"><button class="btn ghost" data-close>Vazgeç</button><button class="btn primary" id="previewTransfer">Devam</button></div>');
 document.querySelector('#previewTransfer').onclick=async()=>{
  const b=document.querySelector('#previewTransfer'),error=document.querySelector('#transferError'),code=document.querySelector('#transferCode').value.trim();b.disabled=true;
  try{if(!demoMode){clearTimeout(cloudSyncTimer);await syncCloudData();}const preview=await transferRequest('preview',{code});showTransferConfirmation(code,preview);}catch(e){error.textContent=e.message;b.disabled=false;}
 };
}
function showTransferConfirmation(code,preview){
 openModal(`<h3>PT geçişini onayla</h3><p><b>${escapeHtml(preview.old_pt)}</b> → <b>${escapeHtml(preview.new_pt)}</b></p><p>Eski mesaj, ödeme ve seans geçmişin arşivde kalır. Yeni PT bunları göremez. Paket, kalan seans ve borç devredilmez.</p><p><b>${Number(preview.future_sessions)||0} ileri tarihli planlı seans iptal edilecek.</b></p><p>Eski paket: ${escapeHtml(preview.package?.name||'Kayıt yok')} · Ödeme durumu: ${escapeHtml(preview.payment?.status||'Kayıt yok')}</p><label><input type="checkbox" id="shareTransferMeasurements"> Önceki ölçümlerimi yeni PT ile paylaş</label><p><label><input type="checkbox" id="confirmTransfer"> PT değişikliğini ve belirtilen seans iptallerini onaylıyorum.</label></p><p id="transferError" role="alert"></p><div class="modalFoot"><button class="btn ghost" data-close>Vazgeç</button><button class="btn primary" id="acceptTransfer">Geçişi tamamla</button></div>`);
 document.querySelector('#acceptTransfer').onclick=async()=>{
  const b=document.querySelector('#acceptTransfer'),error=document.querySelector('#transferError');
  if(!document.querySelector('#confirmTransfer').checked){error.textContent='Geçişi onayla.';return;}b.disabled=true;
  try{
   if(!demoMode){clearTimeout(cloudSyncTimer);await cloudSyncChain.catch(()=>{});}
   await transferRequest('accept',{code,old_client_id:preview.old_client_id,fingerprint:preview.fingerprint,confirmed:true,share_measurements:document.querySelector('#shareTransferMeasurements').checked});
   if(!demoMode){liveStateOwner=null;state=emptyLiveState();await loadCloudData();}else render();
   closeModal();toast('PT geçişin tamamlandı. Eski PT bilgilendirildi.');
  }catch(e){error.textContent=e.message;b.disabled=false;}
 };
}
async function openTransferHistory(){
 try{await loadTransferData();}catch(e){toast(e.message);return;}
 const rows=demoMode?(state.demoTransferHistory||[]):transferHistory;
 openModal('<h3>Önceki PT geçmişim</h3><p>Geçiş tarihindeki salt okunur kayıtlar. Yeni PT bu arşivi göremez.</p>'+rows.map((r,i)=>`<button class="btn ghost" data-transfer-history="${i}">${escapeHtml(r.snapshot.trainer)} · ${escapeHtml(new Date(r.created_at).toLocaleDateString('tr-TR'))}</button>`).join('')+(rows.length?'':'<p>Önceki PT kaydı yok.</p>')+'<div class="modalFoot"><button class="btn ghost" data-close>Kapat</button></div>');
 modal.querySelectorAll('[data-transfer-history]').forEach(b=>b.onclick=()=>{
  const s=rows[Number(b.dataset.transferHistory)].snapshot;
  const section=(label,items,format)=>`<h4>${label}</h4>${items?.length?items.map(x=>'<p>'+escapeHtml(format(x))+'</p>').join(''):'<p>Kayıt yok.</p>'}`;
  openModal(`<h3>${escapeHtml(s.trainer)} — geçmiş</h3>`+section('Ölçümler',s.measurements,x=>(x.date||x.d||'')+' · '+x.w+' kg')+section('Seanslar',s.sessions,x=>new Date(x.starts_at).toLocaleString('tr-TR')+' · '+({cancelled:'İptal',completed:'Tamamlandı',planned:'Planlı',no_show:'Katılmadı'}[x.status]||x.status)+' · '+(x.notes||''))+section('Mesajlar',s.messages,x=>(x.created_at?new Date(x.created_at).toLocaleString('tr-TR')+' · ':'')+(x.body||x.text||x.sticker||''))+section('Ödeme geçmişi',s.history?.financeHistory,x=>[x.date||x.createdAt,x.text||x.description||x.title,x.amount].filter(Boolean).join(' · '))+`<h4>Paket / ödeme özeti</h4><p>${escapeHtml(s.history?.package?.name||'Paket kaydı yok')} · ${escapeHtml(String(s.history?.package?.price||''))}</p><p>Son ödeme: ${escapeHtml(String(s.history?.payment?.amount||0))} · ${escapeHtml(({approved:'Onaylandı',pending:'Onay bekliyor',unpaid:'Ödenmedi'})[s.history?.payment?.status]||'Kayıt yok')}</p>`+section('Paket kayıtları',s.packages,x=>[x.name,x.price,x.starts_at,x.ends_at].filter(Boolean).join(' · '))+section('Ödeme kayıtları',s.payments,x=>[x.amount,x.paid_at||x.created_at,x.status].filter(Boolean).join(' · '))+'<div class="modalFoot"><button class="btn ghost" data-close>Kapat</button></div>');
 });
}
function demoTransferRequest(action,args){
 if(action==='ack'){const n=(state.demoTransferNotices||[]).find(n=>n.id===args.id);if(n)n.read_at=new Date().toISOString();return {ok:true};}
 if(action==='create')return {code:'DEMO-PT-GECIS'};
 if(args.code!=='DEMO-PT-GECIS'||demoPreviousTrainerState)throw Error('Demo geçişi için DEMO-PT-GECIS kullan. Yeniden denemek için DEMO’yu yeniden aç.');
 const preview={old_pt:state.memberTrainer.name,new_pt:'Demo Yeni PT',old_client_id:state.customer.id,fingerprint:'demo-preview',future_sessions:state.events.filter(e=>e.type==='session'&&String(e.customerId)===String(state.customer.id)&&e.status==='planned'&&new Date(e.date+'T'+e.time)>new Date()).length,package:state.package,payment:state.payment};
 if(action==='preview')return preview;
 if(action!=='accept'||!args.confirmed)throw Error('Geçişi onayla.');
 const id=state.customer.id,stamp=new Date().toISOString(),measurements=clone(progressMeasurements());
 const snapshot={trainer:preview.old_pt,client:clone(state.customer),history:clone(clientHistoryPayload(state.customer)),measurements,sessions:state.events.filter(e=>e.type==='session'&&String(e.customerId)===String(id)).map(e=>({starts_at:e.date+'T'+e.time,status:e.status==='planned'?'cancelled':e.status,notes:e.note})),messages:clone((state.demoChat?.messages||[]).filter(m=>String(m.client_id)===String(id))),tasks:[]};
 syncTestAccount();demoPreviousTrainerState=clone(state);
 demoPreviousTrainerState.customer.archived=true;demoPreviousTrainerState.customer.relationshipEndedAt=stamp;
 for(const e of demoPreviousTrainerState.events){if(e.type==='session'&&String(e.customerId)===String(id)&&e.status==='planned'&&new Date(e.date+'T'+e.time)>new Date()){e.status='cancelled';e.counts=false;}}
 demoPreviousTrainerState.demoTransferNotices=[{id:'demo-old-notice',body:state.customer.name+' başka bir PT’ye geçti. Eski PT onayı gerekmeden geçiş tamamlandı.',created_at:stamp}];
 const c=clone(state.customer);c.ptId='demo-new-pt';if(!args.share_measurements)c.weight='';
 state=cleanDemoState({customer:c,ptProfile:{name:preview.new_pt,bio:'',specialties:'',locations:[],photo:'',confirmHours:24}});
 state.events=[];state.manualCustomers=[];state.demoCustomers=[];state.customerAccounts={};state.package=null;state.progressData=args.share_measurements?measurements:[];state.role='member';state.page='trainer';state.testPrimaryId=c.id;state.demoFixtureVersion=1;
 state.memberTrainer={name:preview.new_pt,status:'connected'};state.demoChat={messages:[],tasks:[]};state.demoTransferHistory=[{created_at:stamp,snapshot}];state.demoTransferNotices=[];
 demoNewTrainerState=state;return {client_id:c.id};
}
setInterval(async()=>{if(typeof authUser==='undefined'||!authUser||demoMode||adminMode||document.hidden)return;try{await loadTransferData();renderTransferNotices();}catch{}},30000);
