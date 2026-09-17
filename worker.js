export default {
  async fetch(request, env) {
    const url = new URL(request.url);
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

    // When the customer opens "Müsait Değilim", default both dates to the
    // currently selected calendar day instead of arbitrary future dates.
    patch('id="leaveStart" value="${iso(addDays(today,5))}"', 'id="leaveStart" value="${state.selectedDate||iso(today)}"');
    patch('id="leaveEnd" value="${iso(addDays(today,10))}"', 'id="leaveEnd" value="${state.selectedDate||iso(today)}"');

    // Persist customer unavailability in the normalized shared availability
    // table. The database RPC validates that the signed-in member owns the
    // client record and binds each entry to the real PT.
    patch(
      " const byLocal=new Map(customers.map(c=>[String(c.id),c]));",
      " if(state.role==='member'){const memberLeaves=(state.events||[]).filter(e=>e.type==='memberoff'&&e.status!=='cancelled'&&String(e.customerId??state.customer.id)===String(state.customer.id)).map(e=>({date:e.date,title:e.title||'Müsait Değilim',note:e.note||'',groupId:e.groupId||'',createdBy:e.createdBy||eventActor()}));const {error:memberLeaveError}=await db.rpc('save_my_unavailability',{p_entries:memberLeaves});if(memberLeaveError)throw memberLeaveError;}\n const byLocal=new Map(customers.map(c=>[String(c.id),c]));"
    );

    // Reload normalized customer unavailability for both PT and member so it
    // survives logout/login and is visible on the PT calendar.
    patch(
      ";await loadClientHistories();await loadMemberTrainer();",
      ";await loadClientHistories();const {data:leaveRows,error:leaveRowsError}=await db.from('availability').select('*').eq('kind','unavailable').order('starts_at');if(leaveRowsError)throw leaveRowsError;const remoteLeaves=(leaveRows||[]).map(r=>{let meta={};try{meta=JSON.parse(r.note||'{}')}catch{meta={note:r.note||''}}const c=[state.customer,...(state.manualCustomers||[])].find(x=>x.dbId===r.client_id);return {id:r.id,dbId:r.id,date:meta.date||new Date(r.starts_at).toLocaleDateString('en-CA'),time:'Tüm gün',customerId:r.client_id,customerName:c?.name||'',createdBy:meta.createdBy||('member:'+r.client_id),groupId:meta.groupId||'',type:'memberoff',note:meta.note||'',title:meta.title||'Müsait Değilim',status:'off',cloudManaged:true}});state.events=state.events.filter(e=>e.type!=='memberoff').concat(remoteLeaves);await loadMemberTrainer();"
    );

    const headers = new Headers(response.headers);
    headers.set('content-type', 'text/html; charset=utf-8');
    headers.set('cache-control', 'no-cache, no-store, must-revalidate');
    headers.set('x-piti-runtime-patches', String(patches));
    return new Response(html, { status: response.status, headers });
  }
};
