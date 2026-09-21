-- Hourly retention of live chat and embedded task photos. Recovery copies retain their existing lifecycle.
alter table piti_private.system_settings add column chat_retention_days integer not null default 90 check(chat_retention_days between 1 and 3650);
alter table piti_private.system_settings add column chat_retention_started_at timestamptz not null default now();
alter table public.tasks drop constraint tasks_message_id_fkey;
alter table public.tasks add constraint tasks_message_id_fkey foreign key(message_id) references public.messages(id) on delete set null;
alter table public.tasks add column photo_expired_at timestamptz;
create index if not exists messages_retention_created_idx on public.messages(created_at);

create function piti_private.chat_policy() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Giriş gerekli.' using errcode='42501';end if;
 return (select jsonb_build_object('days',chat_retention_days,'legacy_started_at',chat_retention_started_at,'cleanup_interval_hours',1) from piti_private.system_settings where id);
end $$;
create function public.chat_policy() returns jsonb language sql stable security invoker set search_path='' as $$select piti_private.chat_policy()$$;
revoke all on function piti_private.chat_policy(),public.chat_policy() from public,anon;
grant execute on function piti_private.chat_policy(),public.chat_policy() to authenticated;

create function piti_private.chat_item_time(v jsonb,fallback_time timestamptz) returns timestamptz language plpgsql stable set search_path='' as $$
declare raw text;
begin
 raw=coalesce(v->>'completed_at',v->>'created_at',v->>'date');
 if raw ~ '^\d{4}-\d{2}-\d{2}' then return raw::timestamptz;end if;
 return fallback_time;
exception when others then return fallback_time;
end $$;

create function piti_private.prune_chat_json(v jsonb,cutoff timestamptz,fallback_time timestamptz) returns jsonb language plpgsql set search_path='' as $$
declare result jsonb; item record;
begin
 if jsonb_typeof(v)='object' then
  result='{}';
  for item in select key,value from jsonb_each(v) loop
   if item.key='messages' and jsonb_typeof(item.value)='array' then
    result=result||jsonb_build_object(item.key,(select coalesce(jsonb_agg(x order by ord),'[]') from jsonb_array_elements(item.value) with ordinality a(x,ord) where piti_private.chat_item_time(x,fallback_time)>cutoff));
   else result=result||jsonb_build_object(item.key,piti_private.prune_chat_json(item.value,cutoff,fallback_time));end if;
  end loop;
  if result ? 'result_photo' and result->>'result_photo' is not null and piti_private.chat_item_time(result,fallback_time)<=cutoff then result=(result-'result_photo')||jsonb_build_object('photo_expired_at',now());end if;
  return result;
 elsif jsonb_typeof(v)='array' then
  return (select coalesce(jsonb_agg(piti_private.prune_chat_json(x,cutoff,fallback_time) order by ord),'[]') from jsonb_array_elements(v) with ordinality a(x,ord));
 end if;
 return v;
end $$;

create function piti_private.prune_chat_snapshot() returns trigger language plpgsql security definer set search_path='' as $$
declare cutoff timestamptz; fallback_time timestamptz;
begin
 select now()-make_interval(days=>chat_retention_days),chat_retention_started_at into cutoff,fallback_time from piti_private.system_settings where id;
 new.data=piti_private.prune_chat_json(new.data,cutoff,fallback_time);
 return new;
end $$;
create trigger zz_prune_chat_snapshot before insert or update on public.account_state for each row execute function piti_private.prune_chat_snapshot();
create trigger zz_prune_chat_snapshot before insert or update on public.client_history for each row execute function piti_private.prune_chat_snapshot();

create function piti_private.cleanup_chat_retention() returns jsonb language plpgsql security invoker set search_path='' as $$
declare cutoff timestamptz; fallback_time timestamptz; deleted_count integer; photos_count integer;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('piti-chat-retention',0)) then return '{"skipped":true}';end if;
 select now()-make_interval(days=>chat_retention_days),chat_retention_started_at into cutoff,fallback_time from piti_private.system_settings where id;
 perform set_config('piti.chat_cleanup','on',true);
 update public.tasks set result_photo=null,photo_expired_at=now() where result_photo is not null and coalesce(completed_at,created_at)<=cutoff;
 get diagnostics photos_count=row_count;
 delete from public.messages where created_at<=cutoff;
 get diagnostics deleted_count=row_count;
 update public.client_history set data=piti_private.prune_chat_json(data,cutoff,fallback_time),version=version+1 where data is distinct from piti_private.prune_chat_json(data,cutoff,fallback_time);
 update public.account_state set data=piti_private.prune_chat_json(data,cutoff,fallback_time) where data is distinct from piti_private.prune_chat_json(data,cutoff,fallback_time);
 perform set_config('piti.chat_cleanup','off',true);
 return jsonb_build_object('messages_deleted',deleted_count,'photos_deleted',photos_count);
end $$;
revoke all on function piti_private.chat_item_time(jsonb,timestamptz),piti_private.prune_chat_json(jsonb,timestamptz,timestamptz),piti_private.prune_chat_snapshot(),piti_private.cleanup_chat_retention() from public,anon,authenticated;
select cron.schedule('piti-chat-retention','17 * * * *','select piti_private.cleanup_chat_retention()');

CREATE OR REPLACE FUNCTION piti_private.admin_console(p_action text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; target uuid; sid uuid; page integer; n integer;
begin
 perform piti_private.require_admin();
 page=greatest(0,least(coalesce((p_args->>'page')::integer,0),100000));
 if p_action='overview' then
  select jsonb_build_object('users',(select count(*) from auth.users),'trainers',(select count(*) from public.profiles where role='pt'),'clients',(select count(*) from public.profiles where role='member'),'online',(select count(distinct user_id) from piti_private.presence where last_seen>now()-interval '90 seconds')) into result;
 elsif p_action='users' then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from (select p.id,p.full_name,p.username,p.role,u.email,u.created_at,u.last_sign_in_at,p.must_change_password,coalesce(c.suspended,false) suspended,coalesce(c.archived,false) archived,exists(select 1 from piti_private.admin_users a where a.user_id=p.id) is_admin,(select max(last_seen) from piti_private.presence r where r.user_id=p.id) last_seen from public.profiles p join auth.users u on u.id=p.id left join piti_private.account_controls c on c.user_id=p.id where concat_ws(' ',p.full_name,p.username,u.email) ilike '%'||left(coalesce(p_args->>'search',''),100)||'%' order by u.created_at desc,p.id limit 50 offset page*50) x;
 elsif p_action='links' then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from (select c.id,c.full_name,c.user_id,c.pt_id,p.full_name trainer,c.archived,c.created_at from public.clients c left join public.profiles p on p.id=c.pt_id order by c.created_at desc,c.id limit 50 offset page*50) x;
 elsif p_action='sessions' then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from (select s.id,s.user_id,p.full_name,s.created_at,s.updated_at,s.user_agent,s.ip,r.last_seen from auth.sessions s join public.profiles p on p.id=s.user_id left join piti_private.presence r on r.session_id=s.id where s.not_after is null or s.not_after>now() order by s.created_at desc,s.id limit 50 offset page*50) x;
 elsif p_action='audit' then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from (select a.*,p.full_name actor from piti_private.admin_audit a left join public.profiles p on p.id=a.actor_id order by a.id desc limit 50 offset page*50) x;
 elsif p_action='logins' then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from (select id,created_at,ip_address,payload->>'action' action,payload->>'actor_id' actor_id,payload->>'actor_username' username from auth.audit_log_entries order by created_at desc,id limit 50 offset page*50) x;
 elsif p_action='demo' then
  select jsonb_build_object('data',data,'version',version) into result from public.demo_state where id='main';
 elsif p_action='demo_versions' then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from (select id,created_at,actor_id from piti_private.demo_versions order by id desc limit 50 offset page*50) x;
 elsif p_action in ('save_demo','restore_demo') then
  perform 1 from public.demo_state where id='main' and version=(p_args->>'version')::integer for update;
  if not found then raise exception 'Demo başka bir işlemde güncellendi. Yeniden yükle.'; end if;
  if p_action='save_demo' then result=p_args->'data';
  else select data into result from piti_private.demo_versions where id=(p_args->>'id')::bigint;end if;
  if result is null or jsonb_typeof(result)<>'object' or jsonb_typeof(result->'events') is distinct from 'array' or jsonb_typeof(result->'customer') is distinct from 'object' or octet_length(result::text)>2000000 then raise exception 'Geçersiz demo verisi.';end if;
  insert into piti_private.demo_versions(data,actor_id) select data,auth.uid() from public.demo_state where id='main';
  update public.demo_state set data=result,version=version+1,updated_at=now() where id='main';
  result='{"ok":true}';
 elsif p_action='settings' then
  select to_jsonb(s)-'id' into result from piti_private.system_settings s where id;
 elsif p_action='save_settings' then
  if p_args ? 'chat_retention_days' then
   if jsonb_typeof(p_args->'chat_retention_days')<>'number' or (p_args->>'chat_retention_days') !~ '^[0-9]+$' or (p_args->>'chat_retention_days')::integer not between 1 and 3650 then raise exception 'Mesaj saklama süresi 1–3650 gün olmalı.';end if;
   update piti_private.system_settings set chat_retention_days=(p_args->>'chat_retention_days')::integer where id;
  end if;
  update piti_private.system_settings set registration_open=coalesce((p_args->>'registration_open')::boolean,registration_open),maintenance=coalesce((p_args->>'maintenance')::boolean,maintenance),announcement=left(coalesce(p_args->>'announcement',announcement),1000) where id;
  result='{"ok":true}';
 elsif p_action in ('suspend','archive','restore','revoke_user','password_prepare') then
  target=(p_args->>'user_id')::uuid;
  if target is null or not exists(select 1 from public.profiles where id=target) then raise exception 'Kullanıcı bulunamadı.'; end if;
  if exists(select 1 from piti_private.admin_users where user_id=target) then raise exception 'Admin hesabı bu işlemden korunuyor.'; end if;
  if p_action='suspend' then
   insert into piti_private.account_controls(user_id,suspended) values(target,true) on conflict(user_id) do update set suspended=true;
  elsif p_action='archive' then
   insert into piti_private.account_controls(user_id,archived) values(target,true) on conflict(user_id) do update set archived=true;
  elsif p_action='restore' then
   update piti_private.account_controls set suspended=false,archived=false where user_id=target;
  elsif p_action='password_prepare' then
   update public.profiles set must_change_password=true where id=target;
  end if;
  if p_action<>'restore' then
   delete from auth.sessions where user_id=target;
   update piti_private.entry_links set revoked_at=now() where user_id=target and revoked_at is null;
  end if;
  result='{"ok":true}';
 elsif p_action='revoke_session' then
  sid=(p_args->>'session_id')::uuid;
  if sid=(auth.jwt()->>'session_id')::uuid then raise exception 'Kendi oturumunu kapatmak için Çıkış kullan.'; end if;
  delete from auth.sessions where id=sid; get diagnostics n=row_count;
  if n=0 then raise exception 'Oturum bulunamadı.'; end if;
  result='{"ok":true}';
 else raise exception 'Desteklenmeyen admin işlemi.';
 end if;
 if p_action in ('save_demo','restore_demo','save_settings','suspend','archive','restore','revoke_user','password_prepare','revoke_session') then
  insert into piti_private.admin_audit(actor_id,entity,record_id,action) values(auth.uid(),'admin',coalesce(target::text,sid::text,'settings'),p_action);
 end if;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION piti_private.guard_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if tg_op='INSERT' then
  if new.sender_id is distinct from auth.uid() and current_user='authenticated' then raise exception 'Mesaj göndereni değiştirilemez.'; end if;
  if current_user='authenticated' then new.created_at=now();new.read_at=null;end if;
  new.sender_role=(select role from public.profiles where id=new.sender_id);
  if new.body is null or char_length(trim(new.body))<1 or char_length(new.body)>4000 then raise exception 'Mesaj 1–4000 karakter olmalı.'; end if;
 elsif current_user='authenticated' then
  if new.client_id is distinct from old.client_id or new.sender_id is distinct from old.sender_id or new.body is distinct from old.body or new.sender_role is distinct from old.sender_role then raise exception 'Mesaj içeriği ve alıcısı değiştirilemez.'; end if;
  new.read_at=coalesce(old.read_at,now());
 end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION piti_private.protect_closed_relationship()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare cid uuid; ended timestamptz;
begin
 -- Retention maintenance runs only as the database job owner, never an API role.
 if current_setting('role',true) not in ('authenticated','anon') and current_setting('piti.chat_cleanup',true)='on' and tg_table_name in ('messages','tasks','client_history') then return case when tg_op='DELETE' then old else new end;end if;
 if tg_table_name='clients' then
  if tg_op='UPDATE' and old.relationship_ended_at is not null then
   if (to_jsonb(new)-'updated_at') is distinct from (to_jsonb(old)-'updated_at') then raise exception 'PT ilişkisi sona erdi. Geçmiş kayıt salt okunur.';end if;
  elsif tg_op='DELETE' and old.relationship_ended_at is not null then raise exception 'PT ilişkisi geçmişi silinemez.';
  elsif tg_op='UPDATE' and new.relationship_ended_at is distinct from old.relationship_ended_at and current_setting('role',true) in ('authenticated','anon') and current_user<>'postgres' then
   raise exception 'İlişki yalnızca PT geçişi ile kapatılabilir.';
  end if;
 else
  cid=case when tg_op='DELETE' then old.client_id else new.client_id end;
  select relationship_ended_at into ended from public.clients where id=cid for share;
  if ended is not null then raise exception 'PT ilişkisi sona erdi. Geçmiş kayıt salt okunur.';end if;
  if tg_op='UPDATE' and old.client_id is distinct from new.client_id then
   select relationship_ended_at into ended from public.clients where id=old.client_id for share;
   if ended is not null then raise exception 'PT ilişkisi geçmişi taşınamaz.';end if;
  end if;
 end if;
 return case when tg_op='DELETE' then old else new end;
end $function$;
