begin;
-- Account-wide choices apply to all registered devices. They never grant OS consent.
create table piti_private.push_preferences (
 user_id uuid primary key references auth.users(id) on delete cascade,
 messages boolean not null default true,
 sessions boolean not null default true,
 tasks boolean not null default true,
 payments boolean not null default true,
 updated_at timestamptz not null default now()
);
alter table piti_private.push_preferences enable row level security;
revoke all on piti_private.push_preferences from public,anon,authenticated;

create function piti_private.push_category_allowed(p_user uuid,p_event text)
returns boolean language sql stable security invoker set search_path='' as $$
 select case split_part(p_event,':',1)
  when 'messages' then coalesce((select messages from piti_private.push_preferences where user_id=p_user),true)
  when 'sessions' then coalesce((select sessions from piti_private.push_preferences where user_id=p_user),true)
  when 'tasks' then coalesce((select tasks from piti_private.push_preferences where user_id=p_user),true)
  when 'payment' then coalesce((select payments from piti_private.push_preferences where user_id=p_user),true)
  else false end
$$;
revoke all on function piti_private.push_category_allowed(uuid,text) from public,anon,authenticated;

create function piti_private.get_push_preferences()
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not coalesce(piti_private.access_ready(),false) then
  raise exception 'Aktif oturum gerekli.' using errcode='42501';
 end if;
 select jsonb_build_object('messages',messages,'sessions',sessions,'tasks',tasks,'payments',payments)
 into result from piti_private.push_preferences where user_id=auth.uid();
 return coalesce(result,'{"messages":true,"sessions":true,"tasks":true,"payments":true}'::jsonb);
end $$;

create function piti_private.set_push_preferences(p_messages boolean,p_sessions boolean,p_tasks boolean,p_payments boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(piti_private.access_ready(),false) then
  raise exception 'Aktif oturum gerekli.' using errcode='42501';
 end if;
 if p_messages is null or p_sessions is null or p_tasks is null or p_payments is null then
  raise exception 'Tüm bildirim tercihlerini belirt.' using errcode='22023';
 end if;
 -- Serialize enqueue and preference changes for this account.
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,4424));
 insert into piti_private.push_preferences(user_id,messages,sessions,tasks,payments)
 values(auth.uid(),p_messages,p_sessions,p_tasks,p_payments)
 on conflict(user_id) do update set messages=excluded.messages,sessions=excluded.sessions,
 tasks=excluded.tasks,payments=excluded.payments,updated_at=now();
 -- Do not resurrect old notifications if the user later opts back in.
 delete from piti_private.push_deliveries q where recipient_id=auth.uid()
 and state in ('pending','sending') and not piti_private.push_category_allowed(auth.uid(),q.event_key);
 return piti_private.get_push_preferences();
end $$;

create function public.get_push_preferences()
returns jsonb language sql security invoker set search_path='' as $$select piti_private.get_push_preferences()$$;
create function public.set_push_preferences(p_messages boolean,p_sessions boolean,p_tasks boolean,p_payments boolean)
returns jsonb language sql security invoker set search_path='' as $$select piti_private.set_push_preferences(p_messages,p_sessions,p_tasks,p_payments)$$;
revoke all on function public.get_push_preferences(),piti_private.get_push_preferences(),
 public.set_push_preferences(boolean,boolean,boolean,boolean),piti_private.set_push_preferences(boolean,boolean,boolean,boolean) from public,anon;
grant execute on function public.get_push_preferences(),piti_private.get_push_preferences(),
 public.set_push_preferences(boolean,boolean,boolean,boolean),piti_private.set_push_preferences(boolean,boolean,boolean,boolean) to authenticated;

create function piti_private.filter_push_preference()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(new.recipient_id::text,4424));
 if not piti_private.push_category_allowed(new.recipient_id,new.event_key) then return null; end if;
 return new;
end $$;
revoke all on function piti_private.filter_push_preference() from public,anon,authenticated;
create trigger piti_filter_push_preference before insert on piti_private.push_deliveries
for each row execute function piti_private.filter_push_preference();

-- The dispatcher also rechecks preferences before claiming a delivery.
create or replace function piti_private.push_claim()
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
   and piti_private.push_category_allowed(q.recipient_id,q.event_key)
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
commit;
