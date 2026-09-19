// Offline is read-only. Keep this before application and backend scripts.
(()=>{
 const message='Bağlantı yok. Değişiklik yapmak için yeniden bağlanın.';
 const browsing='[data-nav],[data-close],[data-home-date],[data-home-action],.day[data-date],#prevM,#nextM,#todayM,#avatar,#calendarCustomerFilter,#calendarShowArchived,[data-archive-view],#chatCustomerSelect,[data-finance-customer],[data-customer-package],[data-customer-profile],#custFinance,#showOmittedTasks,[data-task-chat],[data-open-task-chat],[data-transfer-history],#pastTrainers';
 const locked=new Set();
 const offline=()=>navigator.onLine===false;
 function warn(){const banner=document.getElementById('offlineNotice');if(banner){banner.hidden=false;banner.textContent=message}}
 window.pitiRequireOnline=()=>{if(!offline())return true;warn();return false};
 function refresh(){
  let banner=document.getElementById('offlineNotice');
  if(!banner&&document.body){banner=document.createElement('div');banner.id='offlineNotice';banner.setAttribute('role','status');banner.style.cssText='background:#fff3d7;color:#764509;padding:12px 16px;text-align:center;font:600 14px system-ui';const top=document.querySelector('.topbar');if(top)top.after(banner);else document.body.prepend(banner)}
  if(banner){banner.hidden=!offline();if(offline())banner.textContent=message}
  if(!offline()){for(const el of locked){el.disabled=false}locked.clear();return}
  document.querySelectorAll('input,select,textarea').forEach(el=>{if(!el.matches(browsing)&&!el.disabled){el.disabled=true;locked.add(el)}});
  for(const el of locked)if(!el.isConnected)locked.delete(el);
 }
 function block(event){
  if(!offline())return;
  const target=event.target instanceof Element?event.target:null;if(!target)return;
  if(event.type==='keydown'&&!['Enter',' ','ArrowUp','ArrowDown'].includes(event.key))return;
  if(event.type!=='submit'&&target.closest(browsing))return;
  if(event.type==='click'&&!target.closest('button,a,input,select,textarea,label,[role="button"],[onclick]'))return;
  event.preventDefault();event.stopImmediatePropagation();warn();
 }
 for(const type of ['click','submit','beforeinput','change','input','keydown'])window.addEventListener(type,block,true);
 // Catch asynchronous writes that reach the network after connectivity changes.
 const originalFetch=window.fetch?.bind(window);
 if(originalFetch)window.fetch=(input,init)=>{
  const method=String(init?.method||(typeof Request!=='undefined'&&input instanceof Request?input.method:'GET')).toUpperCase();
  if(offline()&&!['GET','HEAD','OPTIONS'].includes(method))return Promise.reject(new Error(message));
  return originalFetch(input,init);
 };
 window.addEventListener('offline',refresh);window.addEventListener('online',refresh);
 const start=()=>{refresh();new MutationObserver(records=>{if(records.some(r=>[...r.addedNodes].some(n=>n.nodeType===1)))refresh()}).observe(document.body,{childList:true,subtree:true})};
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);else start();
})();
