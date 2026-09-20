begin;
alter table public.sessions drop constraint sessions_status_check;
alter table public.sessions add constraint sessions_status_check check(status in ('planned','requested','rejected','completed','no_show','cancelled'));
alter table public.sessions add column if not exists request_origin boolean not null default false;

-- Prevent general account autosaves / stale clients from approving a request.
create or replace function piti_private.guard_session_request() returns trigger
language plpgsql set search_path='' as $$
begin
 if current_user<>'authenticated' then return new; end if;
 if tg_op='INSERT' then
  if exists(select 1 from public.sessions where id=new.id) then return new; end if;
  if piti_private.account_role()='member' then
   raise exception 'Randevu için seans talep et işlemini kullan.';
  end if;
  if new.status in ('requested','rejected') or new.request_origin then raise exception 'Talep için onay akışını kullan.'; end if;
 elsif old.request_origin or new.request_origin then
  if piti_private.account_role()<>'pt' or old.pt_id is distinct from auth.uid() then
   raise exception 'Talebi yalnızca bağlı PT değerlendirebilir.';
  end if;
  if old.status in ('requested','rejected') or new.status in ('requested','rejected') or new.request_origin is distinct from old.request_origin
     or new.client_id is distinct from old.client_id or new.pt_id is distinct from old.pt_id then
   raise exception 'Talep için onay akışını kullan.';
  end if;
 end if;
 return new;
end $$;
drop trigger if exists guard_session_request on public.sessions;
create trigger guard_session_request before insert or update on public.sessions for each row execute function piti_private.guard_session_request();

create or replace function piti_private.request_trainer_slot(p_slot_id text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.clients; slot jsonb; a timestamptz; b timestamptz; result public.sessions;
begin
 if auth.uid() is null or not piti_private.access_ready() or piti_private.account_role()<>'member' then raise exception 'Müşteri girişi gerekli.'; end if;
 select * into c from public.clients where user_id=auth.uid() and not archived and relationship_ended_at is null;
 if c.pt_id is null then raise exception 'Aktif PT bağlantısı gerekli.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(c.pt_id::text,0));
 select e into slot from jsonb_array_elements(piti_private.get_my_trainer_availability()) e where e->>'id'=p_slot_id and e->>'type'='availability' and e->>'status'='open' limit 1;
 if slot is null then raise exception 'Bu müsaitlik artık sana açık değil.'; end if;
 if slot->>'time'='Tüm gün' then raise exception 'Tüm gün yerine belirli saat aralığı olan müsaitlik seç.'; end if;
 a=((slot->>'date')||' '||(slot->>'time'))::timestamp at time zone 'Europe/Istanbul';
 b=case when nullif(slot->>'endTime','') is not null then ((slot->>'date')||' '||(slot->>'endTime'))::timestamp at time zone 'Europe/Istanbul' else a+interval '1 hour' end;
 if b<=a then b=b+interval '1 day'; end if;
 if a<=now() then raise exception 'Geçmiş saat için talep gönderilemez.'; end if;
 if exists(select 1 from public.sessions where pt_id=c.pt_id and status='planned' and starts_at<b and coalesce(ends_at,starts_at+interval '1 hour')>a) then raise exception 'Bu saat artık dolu.'; end if;
 select * into result from public.sessions where client_id=c.id and pt_id=c.pt_id and status='requested' and starts_at=a and ends_at=b limit 1;
 if result.id is null then
  insert into public.sessions(pt_id,client_id,starts_at,ends_at,status,workout_title,counts_against_package,request_origin)
  values(c.pt_id,c.id,a,b,'requested','PT Randevu Talebi',false,true) returning * into result;
 end if;
 return to_jsonb(result);
end $$;

create or replace function piti_private.decide_session_request(p_session_id uuid,p_approve boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.sessions;
begin
 if auth.uid() is null or not piti_private.access_ready() or piti_private.account_role()<>'pt' then raise exception 'PT girişi gerekli.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 select * into s from public.sessions where id=p_session_id and pt_id=auth.uid() for update;
 if s.id is null or s.status<>'requested' then raise exception 'Talep artık onay beklemiyor.'; end if;
 if not exists(select 1 from public.clients c where c.id=s.client_id and c.pt_id=auth.uid() and not c.archived and c.relationship_ended_at is null) then raise exception 'Aktif müşteri bağlantısı gerekli.'; end if;
 if p_approve then
  if s.starts_at<=now() then raise exception 'Geçmiş talep onaylanamaz.'; end if;
  if exists(select 1 from public.sessions x where x.pt_id=auth.uid() and x.id<>s.id and x.status='planned' and x.starts_at<coalesce(s.ends_at,s.starts_at+interval '1 hour') and coalesce(x.ends_at,x.starts_at+interval '1 hour')>s.starts_at) then raise exception 'Bu saatte başka seans var.'; end if;
 end if;
 update public.sessions set status=case when p_approve then 'planned' else 'rejected' end,
 workout_title=case when p_approve then 'PT Seansı' else workout_title end,counts_against_package=p_approve,request_origin=true,updated_at=now()
 where id=s.id returning * into s;
 return to_jsonb(s);
end $$;
create or replace function public.request_trainer_slot(p_slot_id text) returns jsonb language sql security invoker set search_path='' as $$ select piti_private.request_trainer_slot(p_slot_id); $$;
create or replace function public.decide_session_request(p_session_id uuid,p_approve boolean) returns jsonb language sql security invoker set search_path='' as $$ select piti_private.decide_session_request(p_session_id,p_approve); $$;
revoke all on function piti_private.request_trainer_slot(text),public.request_trainer_slot(text),piti_private.decide_session_request(uuid,boolean),public.decide_session_request(uuid,boolean) from public,anon;
grant execute on function piti_private.request_trainer_slot(text),public.request_trainer_slot(text),piti_private.decide_session_request(uuid,boolean),public.decide_session_request(uuid,boolean) to authenticated;
-- Repair only future rows with the original request title AND matching pending member evidence.
update public.sessions s set status='requested',request_origin=true,counts_against_package=false,updated_at=now()
from public.clients c join public.account_state a on a.user_id=c.user_id
where s.client_id=c.id and c.relationship_ended_at is null and s.starts_at>now() and s.status='planned' and s.workout_title='PT Randevu Talebi'
and exists(select 1 from jsonb_array_elements(a.data->'events') e where e->>'dbId'=s.id::text and e->>'status'='requested');
commit;
