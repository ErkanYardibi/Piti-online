-- Staging first. This migration is deliberately OFF until an operator verifies
-- the database, app topic, APNs secrets and the scheduler. Never enable on DEMO.
begin;
create table piti_private.push_settings (
  id boolean primary key default true check(id), enabled boolean not null default false,
  topic text not null default 'online.mypiti.app.staging'
);
insert into piti_private.push_settings(id) values(true);
create table piti_private.push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null references auth.sessions(id) on delete cascade,
  token text not null check(token ~ '^[a-f0-9]+$' and length(token) between 64 and 512 and length(token)%2=0),
  environment text not null check(environment in ('sandbox','production')),
  topic text not null, enabled boolean not null default true,
  app_version text, updated_at timestamptz not null default now(),
  unique(topic,environment,token)
);
create index push_devices_user_idx on piti_private.push_devices(user_id);
create index push_devices_session_idx on piti_private.push_devices(session_id);
create table piti_private.push_deliveries (
  id uuid primary key default gen_random_uuid(),
  event_key text not null, device_id uuid not null references piti_private.push_devices(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  page text not null check(page in ('messages','calendar','finance')),
  body text not null, entity_id text not null,
  state text not null default 'pending' check(state in ('pending','sending','sent','failed')),
  attempts integer not null default 0, lease uuid, lease_until timestamptz,
  available_at timestamptz not null default now(),
  created_at timestamptz not null default now(), last_error text,
  unique(event_key,device_id)
);
create index push_due_idx on piti_private.push_deliveries(available_at) where state in ('pending','sending');
create index push_delivery_device_idx on piti_private.push_deliveries(device_id);
create index push_delivery_recipient_idx on piti_private.push_deliveries(recipient_id);
create index push_delivery_client_idx on piti_private.push_deliveries(client_id);
alter table piti_private.push_settings enable row level security;
alter table piti_private.push_devices enable row level security;
alter table piti_private.push_deliveries enable row level security;
revoke all on piti_private.push_settings,piti_private.push_devices,piti_private.push_deliveries from public,anon,authenticated;

create function piti_private.register_push_device(p_token text,p_environment text,p_topic text,p_app_version text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(piti_private.access_ready(),false) then raise exception 'Aktif oturum gerekli.' using errcode='42501'; end if;
 if not exists(select 1 from piti_private.push_settings where enabled and topic=p_topic) then raise exception 'Bildirim servisi henüz etkin değil.'; end if;
 if p_token is null or p_token !~ '^[a-f0-9]+$' or length(p_token) not between 64 and 512 or length(p_token)%2<>0 or p_environment is null or p_environment not in ('sandbox','production') then raise exception 'Geçersiz cihaz kaydı.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_token,0));
 -- Never hand an old recipient's queued delivery to a different login.
 delete from piti_private.push_deliveries q using piti_private.push_devices d
 where q.device_id=d.id and d.token=p_token and d.topic=p_topic and d.environment=p_environment
 and (d.user_id<>auth.uid() or d.session_id<>(auth.jwt()->>'session_id')::uuid);
 if (select count(*) from piti_private.push_devices where user_id=auth.uid())>=20
 and not exists(select 1 from piti_private.push_devices where token=p_token and topic=p_topic and environment=p_environment) then raise exception 'Cihaz sınırına ulaşıldı.'; end if;
 insert into piti_private.push_devices(user_id,session_id,token,environment,topic,app_version)
 values(auth.uid(),(auth.jwt()->>'session_id')::uuid,p_token,p_environment,p_topic,left(p_app_version,32))
 on conflict(topic,environment,token) do update set user_id=excluded.user_id,session_id=excluded.session_id,
 enabled=true,updated_at=now(),app_version=excluded.app_version;
end $$;

create function piti_private.disable_push_device(p_token text,p_environment text,p_topic text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Giriş gerekli.'; end if;
 update piti_private.push_devices set enabled=false where token=p_token and environment=p_environment
 and topic=p_topic and user_id=auth.uid();
end $$;

create function public.register_push_device(p_token text,p_environment text,p_topic text,p_app_version text default '')
returns void language sql security invoker set search_path='' as $$ select piti_private.register_push_device(p_token,p_environment,p_topic,p_app_version) $$;
create function public.disable_push_device(p_token text,p_environment text,p_topic text)
returns void language sql security invoker set search_path='' as $$ select piti_private.disable_push_device(p_token,p_environment,p_topic) $$;
revoke all on function public.register_push_device(text,text,text,text),piti_private.register_push_device(text,text,text,text),public.disable_push_device(text,text,text),piti_private.disable_push_device(text,text,text) from public,anon;
grant execute on function public.register_push_device(text,text,text,text),piti_private.register_push_device(text,text,text,text),public.disable_push_device(text,text,text),piti_private.disable_push_device(text,text,text) to authenticated;

create function piti_private.enqueue_push(p_user uuid,p_client uuid,p_key text,p_body text,p_page text,p_entity text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from piti_private.push_settings where enabled) then return; end if;
 if not exists(select 1 from public.clients where id=p_client and not archived and relationship_ended_at is null
 and (user_id=p_user or pt_id=p_user)) then return; end if;
 insert into piti_private.push_deliveries(event_key,device_id,recipient_id,client_id,page,body,entity_id)
 select p_key,d.id,p_user,p_client,p_page,p_body,p_entity from piti_private.push_devices d
 where d.user_id=p_user and d.enabled
 on conflict(event_key,device_id) do nothing;
end $$;

create function piti_private.push_business_event() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.clients; recipient uuid; msg text; page text; key text;
begin
 if not exists(select 1 from piti_private.push_settings where enabled) then return new; end if;
 select * into c from public.clients where id=new.client_id and not archived and relationship_ended_at is null;
 if not found then return new; end if;
 key=tg_table_name||':'||new.id::text;
 if tg_table_name='messages' then
  if new.sender_id is distinct from c.pt_id and new.sender_id is distinct from c.user_id then return new; end if;
  recipient=case when new.sender_id=c.pt_id then c.user_id else c.pt_id end;
  msg='Yeni bir mesajınız var.'; page='messages';
 elsif tg_table_name='tasks' then
  recipient=c.user_id; msg='PT’niz yeni bir görev gönderdi.'; page='messages';
 else
  if new.pt_id is distinct from c.pt_id then return new; end if;
  if tg_op='UPDATE' then
   if (new.status,new.starts_at,new.ends_at) is not distinct from (old.status,old.starts_at,old.ends_at) then return new; end if;
   key=key||':'||gen_random_uuid()::text;
  end if;
  recipient=case when new.status='requested' then c.pt_id else c.user_id end;
  msg=case new.status when 'requested' then 'Yeni bir seans talebiniz var.'
   when 'planned' then 'Seans planınız güncellendi.' when 'rejected' then 'Seans talebiniz sonuçlandı.'
   else 'Seans durumunuz güncellendi.' end;
  page='calendar';
 end if;
 perform piti_private.enqueue_push(recipient,c.id,key,msg,page,new.id::text);
 return new;
end $$;
create trigger piti_push_message after insert on public.messages for each row execute function piti_private.push_business_event();
create trigger piti_push_task after insert on public.tasks for each row execute function piti_private.push_business_event();
create trigger piti_push_session after insert or update on public.sessions for each row execute function piti_private.push_business_event();

-- Existing payment data is in client_history rather than the payments table.
create function piti_private.push_payment_event() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.clients; prior text; next text;
begin
 if tg_op='UPDATE' then prior=old.data#>>'{payment,status}'; end if;
 next=new.data#>>'{payment,status}';
 if next is not distinct from prior then return new; end if;
 select * into c from public.clients where id=new.client_id;
 if next='pending' and auth.uid()=c.user_id then
  perform piti_private.enqueue_push(c.pt_id,c.id,'payment:'||c.id||':'||new.version,'Ödeme onayı bekleniyor.','finance',c.id::text);
 elsif next in ('approved','rejected') and auth.uid()=c.pt_id then
  perform piti_private.enqueue_push(c.user_id,c.id,'payment:'||c.id||':'||new.version,'Ödeme bildiriminiz sonuçlandı.','finance',c.id::text);
 end if;
 return new;
end $$;
create trigger piti_push_payment after insert or update on public.client_history for each row execute function piti_private.push_payment_event();

-- Service-only batch with leases: per-device retries cannot duplicate other
-- devices' already-completed deliveries. APNs acceptance is not device receipt.
create function piti_private.push_claim()
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not exists(select 1 from piti_private.push_settings where enabled) then return '[]'::jsonb; end if;
 -- Dead-letter stale/exhausted jobs and prune retained operational metadata.
 update piti_private.push_deliveries set state='failed',last_error='expired'
 where state in ('pending','sending') and (created_at<now()-interval '24 hours' or attempts>=5)
 and (lease_until is null or lease_until<now());
 delete from piti_private.push_deliveries where created_at<now()-interval '7 days';
 with picked as (
  select q.id from piti_private.push_deliveries q
  join piti_private.push_devices d on d.id=q.device_id and d.user_id=q.recipient_id and d.enabled
  join auth.sessions s on s.id=d.session_id and s.user_id=d.user_id and (s.not_after is null or s.not_after>now())
  join public.profiles p on p.id=d.user_id and not p.must_change_password
  join public.clients c on c.id=q.client_id and not c.archived and c.relationship_ended_at is null
    and (c.pt_id=q.recipient_id or c.user_id=q.recipient_id)
  join piti_private.push_settings cfg on cfg.topic=d.topic and cfg.enabled
  where q.state in ('pending','sending') and q.available_at<=now() and (q.lease_until is null or q.lease_until<now())
   and q.attempts<5 and not exists(select 1 from piti_private.account_controls a where a.user_id=d.user_id and (a.suspended or a.archived))
  order by q.available_at limit 10 for update of q skip locked
 ), claimed as (
  update piti_private.push_deliveries q set state='sending',lease=gen_random_uuid(),lease_until=now()+interval '2 minutes',attempts=attempts+1
  from picked where q.id=picked.id returning q.*
 )
 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'lease',q.lease,'recipient_id',q.recipient_id,'client_id',q.client_id,
 'page',q.page,'body',q.body,'entity_id',q.entity_id,'token',d.token,'topic',d.topic,'environment',d.environment)),'[]'::jsonb)
 into result from claimed q join piti_private.push_devices d on d.id=q.device_id;
 return result;
end $$;
create function piti_private.push_finish(p_id uuid,p_lease uuid,p_ok boolean,p_permanent boolean,p_error text)
returns void language plpgsql security definer set search_path='' as $$
declare q piti_private.push_deliveries;
begin
 select * into q from piti_private.push_deliveries where id=p_id and lease=p_lease and state='sending' for update;
 if not found then return; end if;
 update piti_private.push_deliveries set state=case when p_ok then 'sent' when p_permanent or attempts>=5 then 'failed' else 'pending' end,
 lease=null,lease_until=null,last_error=left(p_error,100),available_at=now()+make_interval(secs=>least(3600,30*power(2,attempts)::integer))
 where id=q.id;
 if p_permanent then update piti_private.push_devices set enabled=false where id=q.device_id and user_id=q.recipient_id; end if;
end $$;
create function public.push_claim() returns jsonb language sql security invoker set search_path='' as $$ select piti_private.push_claim() $$;
create function public.push_finish(p_id uuid,p_lease uuid,p_ok boolean,p_permanent boolean,p_error text)
returns void language sql security invoker set search_path='' as $$ select piti_private.push_finish(p_id,p_lease,p_ok,p_permanent,p_error) $$;
revoke all on function piti_private.enqueue_push(uuid,uuid,text,text,text,text),piti_private.push_business_event(),piti_private.push_payment_event() from public,anon,authenticated;
revoke all on function public.push_claim(),piti_private.push_claim(),public.push_finish(uuid,uuid,boolean,boolean,text),piti_private.push_finish(uuid,uuid,boolean,boolean,text) from public,anon,authenticated;
grant usage on schema piti_private to service_role;
grant execute on function public.push_claim(),piti_private.push_claim(),public.push_finish(uuid,uuid,boolean,boolean,text),piti_private.push_finish(uuid,uuid,boolean,boolean,text) to service_role;
commit;
