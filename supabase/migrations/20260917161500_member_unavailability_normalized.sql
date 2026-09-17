begin;

create or replace function public.save_my_unavailability(p_entries jsonb)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  c public.clients;
  item jsonb;
  d date;
  title text;
  note_text text;
  group_key text;
  created_by text;
begin
  if auth.uid() is null or not piti_private.access_ready() or piti_private.account_role()<>'member' then
    raise exception 'Bu işlem müşteri hesabına açık.';
  end if;

  select * into c
  from public.clients
  where user_id=auth.uid() and not archived
  for update;

  if c.id is null then raise exception 'Müşteri kaydı bulunamadı.'; end if;
  if c.pt_id is null then raise exception 'Bağlı PT bulunamadı.'; end if;
  if jsonb_typeof(coalesce(p_entries,'[]'::jsonb))<>'array' then raise exception 'Geçersiz müsaitlik verisi.'; end if;
  if jsonb_array_length(coalesce(p_entries,'[]'::jsonb))>366 then raise exception 'Tek seferde en fazla 366 gün kaydedilebilir.'; end if;

  delete from public.availability where client_id=c.id and kind='unavailable';

  for item in select value from jsonb_array_elements(coalesce(p_entries,'[]'::jsonb)) loop
    begin
      d=(item->>'date')::date;
    exception when others then
      raise exception 'Geçersiz tarih.';
    end;
    if d is null or d<current_date-interval '2 years' or d>current_date+interval '5 years' then
      raise exception 'Müsaitlik tarihi desteklenen aralığın dışında.';
    end if;
    title=left(coalesce(nullif(btrim(item->>'title'),''),'Müsait Değilim'),80);
    note_text=left(coalesce(item->>'note',''),1000);
    group_key=left(coalesce(item->>'groupId',''),120);
    created_by=left(coalesce(item->>'createdBy',''),120);

    insert into public.availability(pt_id,client_id,starts_at,ends_at,all_day,kind,note)
    values(
      c.pt_id,
      c.id,
      (d::timestamp at time zone 'Europe/Istanbul'),
      ((d+1)::timestamp at time zone 'Europe/Istanbul'),
      true,
      'unavailable',
      jsonb_build_object('date',d::text,'title',title,'note',note_text,'groupId',group_key,'createdBy',created_by)::text
    );
  end loop;
end
$$;

revoke all on function public.save_my_unavailability(jsonb) from public,anon;
grant execute on function public.save_my_unavailability(jsonb) to authenticated;

create or replace function piti_private.guard_availability_write()
returns trigger
language plpgsql
security invoker
set search_path=''
as $$
declare
  role_name text;
  target_client public.clients;
  row_client uuid;
  row_pt uuid;
  row_kind text;
begin
  if current_user<>'authenticated' then
    return coalesce(new,old);
  end if;
  role_name=piti_private.account_role();
  row_client=coalesce(new.client_id,old.client_id);
  row_pt=coalesce(new.pt_id,old.pt_id);
  row_kind=coalesce(new.kind,old.kind);

  if role_name='member' then
    select * into target_client from public.clients where id=row_client;
    if target_client.id is null or target_client.user_id is distinct from auth.uid() or row_pt is distinct from target_client.pt_id or row_kind<>'unavailable' then
      raise exception 'Müşteri yalnızca kendi müsait değil kayıtlarını yönetebilir.';
    end if;
  elsif role_name='pt' then
    if row_pt is distinct from auth.uid() then raise exception 'PT yalnızca kendi takvimini yönetebilir.'; end if;
    if row_client is not null and not exists(select 1 from public.clients c where c.id=row_client and c.pt_id=auth.uid()) then
      raise exception 'Bu müşteri PT hesabına bağlı değil.';
    end if;
  else
    raise exception 'Takvim yetkisi bulunamadı.';
  end if;
  return coalesce(new,old);
end
$$;

drop trigger if exists guard_availability_write on public.availability;
create trigger guard_availability_write
before insert or update or delete on public.availability
for each row execute function piti_private.guard_availability_write();

commit;
