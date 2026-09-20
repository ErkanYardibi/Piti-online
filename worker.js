export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Fixed DEMO destination; authorization remains in the DEMO function.
    if (url.pathname === '/api/demo-admin') {
      const json = (status, error) => new Response(JSON.stringify({error}), {status, headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
      if (request.method !== 'POST') return json(405, 'POST gerekli.');
      const origin = request.headers.get('origin');
      if (origin && origin !== url.origin) return json(403, 'İzin verilmeyen adres.');
      const authorization = request.headers.get('authorization');
      if (!authorization?.startsWith('Bearer ')) return json(401, 'Admin girişi gerekli.');
      if (Number(request.headers.get('content-length') || 0) > 2100000) return json(413, 'Demo verisi çok büyük.');
      try {
        const body = await request.text();
        if (new TextEncoder().encode(body).length > 2100000) return json(413, 'Demo verisi çok büyük.');
        const parsed = JSON.parse(body);
        if (!['demo','demo_versions','save_demo','restore_demo'].includes(parsed.action)) return json(400, 'Geçersiz demo işlemi.');
        const upstream = await fetch('https://ldufxzwgwbaogpmwqhlw.supabase.co/functions/v1/demo-admin', {
          method:'POST', headers:{'Authorization':authorization,'Content-Type':'application/json','Origin':url.origin}, body, signal:AbortSignal.timeout(35000), redirect:'error'
        });
        const text = await upstream.text();
        try { JSON.parse(text); } catch { return json(502, 'DEMO servisi şu anda yanıt veremiyor. Tekrar deneyin.'); }
        return new Response(text,{status:upstream.status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
      } catch { return json(502, 'DEMO servisine ulaşılamadı. Bağlantınızı kontrol edip tekrar deneyin.'); }
    }
    const response = await env.ASSETS.fetch(request);

    if (request.method !== 'GET' || (url.pathname !== '/' && url.pathname !== '/index.html')) {
      return response;
    }
    if (!response.ok || !(response.headers.get('content-type') || '').includes('text/html')) {
      return response;
    }

    let html = await response.text();
    let patches = 0;
    const patch = (from, to) => {
      if (html.includes(from)) {
        html = html.replace(from, to);
        patches++;
      }
    };

    // Calendar UX: when a customer opens "Müsait Değilim", both dates start
    // from the currently selected calendar day.
    patch('id="leaveStart" value="${iso(addDays(today,5))}"', 'id="leaveStart" value="${state.selectedDate||iso(today)}"');
    patch('id="leaveEnd" value="${iso(addDays(today,10))}"', 'id="leaveEnd" value="${state.selectedDate||iso(today)}"');

    // Cloud-first persistence. A save starts the database write immediately;
    // there is no browser-only 650 ms debounce window anymore. persistState()
    // intentionally remains empty, so business data is never persisted locally.
    patch(
      'function save(){if(navigator.onLine===false)return Promise.resolve(false);syncTestAccount();persistState();queueCloudSync()}\nfunction queueCloudSync(){if(!authUser||demoMode||!db)return;clearTimeout(cloudSyncTimer);cloudSyncTimer=setTimeout(()=>syncCloudData().catch(e=>toast(\'Buluta kaydedilemedi: \'+e.message)),650)}',
      'function save(){if(navigator.onLine===false)return Promise.resolve(false);syncTestAccount();persistState();return queueCloudSync()}\nfunction queueCloudSync(){if(!authUser||demoMode||!db)return Promise.resolve(true);clearTimeout(cloudSyncTimer);return syncCloudData().then(()=>true).catch(e=>{toast(\'Buluta kaydedilemedi: \'+e.message);return false})}'
    );

    // Registration hand-off is transient session data, not business data.
    patch(
      "localStorage.setItem('pitiPendingProfile',JSON.stringify({name,role}))",
      "sessionStorage.setItem('pitiPendingProfile',JSON.stringify({name,role}))"
    );
    patch(
      "const pending=JSON.parse(localStorage.getItem('pitiPendingProfile')||'null');",
      "const pending=JSON.parse(sessionStorage.getItem('pitiPendingProfile')||'null');"
    );
    patch(
      "localStorage.removeItem('pitiPendingProfile');state.role=profile.role==='member'?'member':'pt';",
      "sessionStorage.removeItem('pitiPendingProfile');localStorage.removeItem('pitiPendingProfile');state.role=profile.role==='member'?'member':'pt';"
    );

    // One-time cleanup of legacy PiTi browser persistence from older demo builds.
    // Supabase's own auth/session storage is intentionally untouched.
    patch(
      "localStorage.removeItem('pitiAccount:'+authUser.id);persistState();render();",
      "localStorage.removeItem('pitiAccount:'+authUser.id);for(let i=localStorage.length-1;i>=0;i--){const k=localStorage.key(i);if(k&&(k.startsWith('pitiAccount:')||k==='pitiDemoV4'||k==='pitiPendingProfile'))localStorage.removeItem(k)}persistState();render();"
    );

    // Persist customer unavailability in the normalized shared availability
    // table. The database RPC validates member ownership and binds the real PT.
    patch(
      " const byLocal=new Map(customers.map(c=>[String(c.id),c]));",
      " if(state.role==='member'){const memberLeaves=(state.events||[]).filter(e=>e.type==='memberoff'&&e.status!=='cancelled'&&String(e.customerId??state.customer.id)===String(state.customer.id)).map(e=>({date:e.date,title:e.title||'Müsait Değilim',note:e.note||'',groupId:e.groupId||'',createdBy:e.createdBy||eventActor()}));const {error:memberLeaveError}=await db.rpc('save_my_unavailability',{p_entries:memberLeaves});if(memberLeaveError)throw memberLeaveError;}\n const byLocal=new Map(customers.map(c=>[String(c.id),c]));"
    );

    // Reload normalized customer unavailability for both PT and member so it
    // survives logout/login and is visible from every device.
    patch(
      ";await loadClientHistories();await loadMemberTrainer();",
      ";await loadClientHistories();const {data:leaveRows,error:leaveRowsError}=await db.from('availability').select('*').eq('kind','unavailable').order('starts_at');if(leaveRowsError)throw leaveRowsError;const remoteLeaves=(leaveRows||[]).map(r=>{let meta={};try{meta=JSON.parse(r.note||'{}')}catch{meta={note:r.note||''}}const c=[state.customer,...(state.manualCustomers||[])].find(x=>x.dbId===r.client_id);return {id:r.id,dbId:r.id,date:meta.date||new Date(r.starts_at).toLocaleDateString('en-CA'),time:'Tüm gün',customerId:r.client_id,customerName:c?.name||'',createdBy:meta.createdBy||('member:'+r.client_id),groupId:meta.groupId||'',type:'memberoff',note:meta.note||'',title:meta.title||'Müsait Değilim',status:'off',cloudManaged:true}});state.events=state.events.filter(e=>e.type!=='memberoff').concat(remoteLeaves);await loadMemberTrainer();"
    );

    // For the customer leave form, don't show a success message until the cloud
    // write has actually completed successfully.
    patch("modal.querySelector('#saveLeave').onclick=()=>{", "modal.querySelector('#saveLeave').onclick=async()=>{");
    patch(
      "save();closeModal();toast('Müsait olmadığın dönem PT takvimine işlendi.');calendar()",
      "if(!await save())return;closeModal();toast('Müsait olmadığın dönem buluta kaydedildi.');calendar()"
    );

    const headers = new Headers(response.headers);
    headers.set('content-type', 'text/html; charset=utf-8');
    headers.set('cache-control', 'no-cache, no-store, must-revalidate');
    headers.set('x-piti-runtime-patches', String(patches));
    return new Response(html, { status: response.status, headers });
  }
};
