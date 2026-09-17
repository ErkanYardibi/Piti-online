begin;

create or replace function piti_private.save_client_history(p_client_id uuid, p_data jsonb, p_version integer)
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
begin
 if not piti_private.access_ready() then raise exception 'Önce kendi şifreni belirle veya yeniden giriş yap.'; end if;
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into c from public.clients where id=p_client_id for update;
 if c.id is null or (c.pt_id is distinct from auth.uid() and c.user_id is distinct from auth.uid()) then raise exception 'Bu geçmişe erişemezsin.'; end if;
 if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Geçersiz geçmiş verisi.'; end if;
 select version,data into v,old_data from public.client_history where client_id=c.id;
 if coalesce(v,0)<>p_version then raise exception 'Kayıt başka bir cihazda değişti. Sayfayı yenileyip tekrar dene.'; end if;
 if c.pt_id is distinct from auth.uid() then
  allowed=array['messages','tasks','progressData','unread','payment','financeHistory'];
  old_data=coalesce(old_data,'{}'::jsonb);

  -- PT-controlled snapshot fields are server-owned. A member client may send
  -- cached/derived values (for example memberTrainer with an added PT id), but
  -- those values must neither fail the login flow nor overwrite the PT's data.
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

  -- Members may submit a payment for PT approval, but cannot approve or alter
  -- an existing payment state themselves. A default unpaid value on a brand-new
  -- snapshot is treated as UI cache and omitted.
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
 insert into public.client_history(client_id,data,version) values(c.id,p_data,1)
 on conflict(client_id) do update set data=excluded.data,version=public.client_history.version+1,updated_at=now()
 returning version into v;
 return v;
end $$;

commit;
