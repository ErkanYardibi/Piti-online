begin;

create or replace function piti_private.save_client_history(p_client_id uuid,p_data jsonb,p_version integer)
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
 c public.clients;
 v integer;
 old_data jsonb;
 allowed text[];
 k text;
 old_member_leaves jsonb := '[]'::jsonb;
 incoming_non_member_extra jsonb := '[]'::jsonb;
begin
 if not piti_private.access_ready() then raise exception 'Önce kendi şifreni belirle veya yeniden giriş yap.'; end if;
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into c from public.clients where id=p_client_id for update;
 if c.id is null or (c.pt_id is distinct from auth.uid() and c.user_id is distinct from auth.uid()) then raise exception 'Bu geçmişe erişemezsin.'; end if;
 if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Geçersiz geçmiş verisi.'; end if;
 select version,data into v,old_data from public.client_history where client_id=c.id;
 if coalesce(v,0)<>p_version then raise exception 'Kayıt başka bir cihazda değişti. Sayfayı yenileyip tekrar dene.'; end if;
 old_data=coalesce(old_data,'{}'::jsonb);

 if c.pt_id is distinct from auth.uid() then
  allowed=array['messages','tasks','progressData','unread','payment','financeHistory'];

  -- PT-controlled snapshot fields are server-owned. Member-side cached/derived
  -- values must not block login and must not overwrite PT-owned data.
  for k in select jsonb_object_keys(p_data) loop
   if not k=any(allowed) then
    if old_data ? k then
     p_data=jsonb_set(p_data,array[k],old_data->k,true);
    else
     p_data=p_data-k;
    end if;
   end if;
  end loop;
  for k in select jsonb_object_keys(old_data) loop
   if not k=any(allowed) and not (p_data ? k) then
    p_data=jsonb_set(p_data,array[k],old_data->k,true);
   end if;
  end loop;

  if p_data->'payment' is distinct from old_data->'payment' then
   if coalesce(p_data#>>'{payment,status}','')='pending' then
    null;
   elsif not (old_data ? 'payment') and coalesce(p_data#>>'{payment,status}','') in ('','unpaid') then
    p_data=p_data-'payment';
   else
    raise exception 'Ödemeyi yalnızca PT onaylayabilir.';
   end if;
  end if;
 end if;

 -- Customer "müsait değilim" records are owned by the member account-state
 -- trigger. Normal PT/member history saves preserve them until that trigger
 -- explicitly adds, changes or removes them.
 select coalesce(jsonb_agg(e),'[]'::jsonb) into old_member_leaves
 from jsonb_array_elements(coalesce(old_data->'extraEvents','[]'::jsonb)) e
 where e->>'type'='memberoff';

 select coalesce(jsonb_agg(e),'[]'::jsonb) into incoming_non_member_extra
 from jsonb_array_elements(coalesce(p_data->'extraEvents','[]'::jsonb)) e
 where e->>'type'<>'memberoff';

 if jsonb_array_length(old_member_leaves)>0 or (p_data ? 'extraEvents') then
  p_data=jsonb_set(p_data,'{extraEvents}',incoming_non_member_extra||old_member_leaves,true);
 end if;

 insert into public.client_history(client_id,data,version) values(c.id,p_data,1)
 on conflict(client_id) do update set data=excluded.data,version=public.client_history.version+1,updated_at=now()
 returning version into v;
 return v;
end
$$;

commit;
