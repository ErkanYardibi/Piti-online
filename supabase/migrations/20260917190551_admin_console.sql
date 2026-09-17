begin;
create table piti_private.admin_users(user_id uuid primary key references auth.users(id) on delete cascade);
create table piti_private.account_controls(user_id uuid primary key references auth.users(id) on delete cascade, suspended boolean not null default false, archived boolean not null default false);
create table piti_private.presence(session_id uuid primary key references auth.sessions(id) on delete cascade,user_id uuid not null references auth.users(id) on delete cascade,last_seen timestamptz not null default now());
create table piti_private.admin_audit(id bigint generated always as identity primary key,actor_id uuid,entity text not null,record_id text,action text not null,changed_fields text[],created_at timestamptz not null default now());
create index admin_audit_created on piti_private.admin_audit(created_at desc);
create table piti_private.system_settings(id boolean primary key default true check(id),registration_open boolean not null default true,maintenance boolean not null default false,announcement text not null default '');
insert into piti_private.system_settings(id) values(true);
alter table piti_private.admin_users enable row level security;
alter table piti_private.account_controls enable row level security;
alter table piti_private.presence enable row level security;
alter table piti_private.admin_audit enable row level security;
alter table piti_private.system_settings enable row level security;
revoke all on piti_private.admin_users,piti_private.account_controls,piti_private.presence,piti_private.admin_audit,piti_private.system_settings from public,anon,authenticated;
create or replace function piti_private.account_context() returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.profiles; valid_session boolean; admin boolean;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into p from public.profiles where id=auth.uid();
 select exists(select 1 from piti_private.admin_users where user_id=auth.uid()) into admin;
 select exists(select 1 from auth.sessions s where s.id=nullif(auth.jwt()->>'session_id','')::uuid and s.user_id=auth.uid() and (s.not_after is null or s.not_after>now()))
 and not exists(select 1 from piti_private.account_controls where user_id=auth.uid() and (suspended or archived)) into valid_session;
 return jsonb_build_object('role',p.role,'is_admin',admin,'must_change_password',coalesce(p.must_change_password,true),'session_valid',valid_session);
end $$;
create or replace function piti_private.access_ready() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.profiles p join auth.sessions s on s.user_id=p.id
 where p.id=auth.uid() and not p.must_change_password and s.id=nullif(auth.jwt()->>'session_id','')::uuid and (s.not_after is null or s.not_after>now()))
 and not exists(select 1 from piti_private.account_controls where user_id=auth.uid() and (suspended or archived))
 and (not (select maintenance from piti_private.system_settings where id) or exists(select 1 from piti_private.admin_users where user_id=auth.uid()))
$$;
create policy account_ready on public.account_state as restrictive for all to authenticated using((select piti_private.access_ready())) with check((select piti_private.access_ready()));
create function piti_private.require_admin() returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not piti_private.access_ready() or auth.jwt()->>'aal' is distinct from 'aal2' or not exists(select 1 from piti_private.admin_users where user_id=auth.uid()) then raise exception 'Admin yetkisi ve çift doğrulama gerekli.' using errcode='42501'; end if;
end $$;
create function piti_private.heartbeat() returns void language plpgsql security definer set search_path='' as $$
begin
 if not piti_private.access_ready() then raise exception 'Oturum geçersiz veya uygulama bakımda.'; end if;
 insert into piti_private.presence(session_id,user_id) values((auth.jwt()->>'session_id')::uuid,auth.uid()) on conflict(session_id) do update set last_seen=now();
end $$;
create function public.heartbeat() returns void language sql security invoker set search_path='' as $$ select piti_private.heartbeat() $$;
create function piti_private.audit_change() returns trigger language plpgsql security definer set search_path='' as $$
declare a jsonb; b jsonb; fields text[];
begin
 a=case when tg_op='INSERT' then '{}'::jsonb else to_jsonb(old) end;
 b=case when tg_op='DELETE' then '{}'::jsonb else to_jsonb(new) end;
 if a=b then return coalesce(new,old); end if;
 select array_agg(k) into fields from (select jsonb_object_keys(a||b) k) x where a->k is distinct from b->k;
 insert into piti_private.admin_audit(actor_id,entity,record_id,action,changed_fields) values(auth.uid(),tg_table_name,coalesce(b->>'id',a->>'id',b->>'client_id',a->>'client_id',b->>'user_id',a->>'user_id'),tg_op,fields);
 return coalesce(new,old);
end $$;
do $$declare t text;begin foreach t in array array['profiles','clients','sessions','packages','payments','availability','tasks','client_history','account_state'] loop
 execute format('create trigger admin_change_audit after insert or update or delete on public.%I for each row execute function piti_private.audit_change()',t);
end loop;end $$;
create table piti_private.demo_versions(id bigint generated always as identity primary key,data jsonb not null,created_at timestamptz not null default now(),actor_id uuid);
alter table piti_private.demo_versions enable row level security;
revoke all on piti_private.demo_versions from public,anon,authenticated;
insert into piti_private.demo_versions(data) select data from public.demo_state where id='main';
create function piti_private.admin_console(p_action text,p_args jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
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
end $$;
create function public.admin_console(p_action text,p_args jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$ select piti_private.admin_console(p_action,p_args) $$;
create function piti_private.registration_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not (select registration_open from piti_private.system_settings where id) and coalesce(new.raw_app_meta_data->>'managed_client_id','')='' then raise exception 'Yeni kayıtlar geçici olarak kapalı.'; end if;
 return new;
end $$;
create trigger admin_registration_guard before insert on auth.users for each row execute function piti_private.registration_guard();
create function piti_private.app_settings() returns jsonb language sql stable security definer set search_path='' as $$ select jsonb_build_object('registration_open',registration_open,'maintenance',maintenance,'announcement',announcement) from piti_private.system_settings where id $$;
create function public.app_settings() returns jsonb language sql security invoker set search_path='' as $$ select piti_private.app_settings() $$;
revoke all on function piti_private.require_admin(),piti_private.heartbeat(),public.heartbeat(),piti_private.audit_change(),piti_private.admin_console(text,jsonb),public.admin_console(text,jsonb),piti_private.registration_guard(),piti_private.app_settings(),public.app_settings() from public,anon,authenticated;
grant execute on function piti_private.require_admin(),piti_private.heartbeat(),public.heartbeat(),piti_private.admin_console(text,jsonb),public.admin_console(text,jsonb) to authenticated;
grant execute on function piti_private.app_settings(),public.app_settings() to anon,authenticated;
create function piti_private.finish_password_change(p_user uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 update public.profiles set must_change_password=false where id=p_user;
 delete from auth.sessions where user_id=p_user;
 insert into piti_private.admin_audit(actor_id,entity,record_id,action) values(p_user,'profiles',p_user::text,'password_changed');
end $$;
create function public.finish_password_change(p_user uuid) returns void language sql security invoker set search_path='' as $$ select piti_private.finish_password_change(p_user) $$;
revoke all on function piti_private.finish_password_change(uuid),public.finish_password_change(uuid) from public,anon,authenticated;
grant execute on function piti_private.finish_password_change(uuid),public.finish_password_change(uuid) to service_role;
-- ADMIN is a server-side alias, never a self-selected privilege.
alter table public.profiles add constraint reserved_usernames check(username is null or username not in ('admin','demo'));
do $outer$declare definition text;begin
 definition=pg_get_functiondef('piti_private.username_login_lookup(text)'::regprocedure);
 definition=replace(definition,'select u.email into address from public.profiles p join auth.users u on u.id=p.id where p.username=canonical;',
 'if canonical=''admin'' then select u.email into address from auth.users u join piti_private.admin_users a on a.user_id=u.id; else select u.email into address from public.profiles p join auth.users u on u.id=p.id where p.username=canonical; end if;');
 execute definition;
end $outer$;
commit;
