begin;
alter table public.profiles add column must_change_password boolean not null default false;
-- Roles are assigned once at account creation and cannot be edited by clients.
create function piti_private.initialize_account_profile() returns trigger
language plpgsql security definer set search_path='' as $$
declare account_role text;
begin
 account_role=coalesce(new.raw_app_meta_data->>'account_role',new.raw_user_meta_data->>'account_type','member');
 if account_role not in ('pt','member') then account_role='member'; end if;
 insert into public.profiles(id,role,full_name,must_change_password)
 values(new.id,account_role,left(coalesce(nullif(new.raw_user_meta_data->>'full_name',''),split_part(new.email,'@',1),'Kullanıcı'),160),coalesce((new.raw_app_meta_data->>'must_change_password')::boolean,false));
 return new;
end $$;
create trigger piti_initialize_profile after insert on auth.users for each row execute function piti_private.initialize_account_profile();
-- Existing account roles take precedence; only missing profiles are initialized.
insert into public.profiles(id,role,full_name)
select u.id,case when u.raw_user_meta_data->>'account_type'='pt' then 'pt' else 'member' end,
 left(coalesce(nullif(u.raw_user_meta_data->>'full_name',''),split_part(u.email,'@',1),'Kullanıcı'),160)
from auth.users u where not exists(select 1 from public.profiles p where p.id=u.id);
create function piti_private.guard_profile_role() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if current_user in ('anon','authenticated') then
  if tg_op='INSERT' then
   if not exists(select 1 from public.profiles where id=new.id and role=new.role) then raise exception 'Hesap rolü sunucu tarafından belirlenir.'; end if;
  elsif new.role is distinct from old.role or new.id is distinct from old.id or new.must_change_password is distinct from old.must_change_password then
   raise exception 'Hesap rolü ve şifre zorunluluğu değiştirilemez.';
  end if;
 end if;
 return new;
end $$;
create trigger protect_profile_role before insert or update on public.profiles for each row execute function piti_private.guard_profile_role();
revoke delete on public.profiles from authenticated;

create function piti_private.account_context() returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.profiles; sid uuid; valid_session boolean;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into p from public.profiles where id=auth.uid();
 sid=nullif(auth.jwt()->>'session_id','')::uuid;
 select exists(select 1 from auth.sessions s where s.id=sid and s.user_id=auth.uid() and (s.not_after is null or s.not_after>now())) into valid_session;
 return jsonb_build_object('role',p.role,'must_change_password',coalesce(p.must_change_password,true),'session_valid',valid_session);
end $$;
create function public.account_context() returns jsonb language sql security invoker set search_path='' as $$select piti_private.account_context()$$;
create function piti_private.access_ready() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.profiles p join auth.sessions s on s.user_id=p.id
 where p.id=auth.uid() and not p.must_change_password and s.id=nullif(auth.jwt()->>'session_id','')::uuid and (s.not_after is null or s.not_after>now()))
$$;
create function piti_private.account_role() returns text language sql stable security definer set search_path='' as $$select role from public.profiles where id=auth.uid()$$;
revoke all on function piti_private.account_context(),piti_private.access_ready(),piti_private.account_role(),public.account_context() from public,anon;
grant execute on function piti_private.account_context(),piti_private.access_ready(),piti_private.account_role(),public.account_context() to authenticated;
-- Apply an additional, restrictive session/password gate to every business table.
do $$declare t text; begin
 foreach t in array array['clients','packages','sessions','payments','availability','tasks','messages','client_history','client_invitations'] loop
  execute format('create policy account_ready on public.%I as restrictive for all to authenticated using ((select piti_private.access_ready())) with check ((select piti_private.access_ready()))',t);
 end loop;
end$$;
-- Existing private invitation/history RPCs must obey the same gate.
do $$declare sig text; definition text; begin
 foreach sig in array array['piti_private.create_client_invitation(uuid)','piti_private.revoke_client_invitation(uuid)','piti_private.redeem_client_invitation(text)','piti_private.save_client_history(uuid,jsonb,integer)'] loop
  definition=pg_get_functiondef(sig::regprocedure);
  definition=regexp_replace(definition,E'begin\n',E'begin\n if not piti_private.access_ready() then raise exception ''Önce kendi şifreni belirle veya yeniden giriş yap.''; end if;\n','i');
  execute definition;
 end loop;
end$$;
-- Prevent a member from using PT ownership predicates through direct API calls.
drop policy clients_access on public.clients;
create policy clients_read on public.clients for select to authenticated using
 ((pt_id=(select auth.uid()) and (select piti_private.account_role())='pt') or (user_id=(select auth.uid()) and (select piti_private.account_role())='member'));
create policy clients_insert on public.clients for insert to authenticated with check
 ((pt_id=(select auth.uid()) and user_id is null and (select piti_private.account_role())='pt') or (user_id=(select auth.uid()) and pt_id is null and (select piti_private.account_role())='member'));
create policy clients_update on public.clients for update to authenticated using
 ((pt_id=(select auth.uid()) and (select piti_private.account_role())='pt') or (user_id=(select auth.uid()) and (select piti_private.account_role())='member')) with check
 ((pt_id=(select auth.uid()) and (select piti_private.account_role())='pt') or (user_id=(select auth.uid()) and (select piti_private.account_role())='member'));
-- Deletion has no application flow; archive instead, preserving account ownership.
revoke delete on public.clients from authenticated;

create table piti_private.account_operations(
 client_id uuid primary key references public.clients(id) on delete cascade,
 id uuid not null unique default gen_random_uuid(), actor_id uuid not null references auth.users(id),
 kind text not null check(kind in ('create','reset','password')), expires_at timestamptz not null default now()+interval '2 minutes',
 finished_at timestamptz
);
create table piti_private.entry_links(
 id uuid primary key default gen_random_uuid(), token_hash text not null unique,
 client_id uuid not null references public.clients(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 expires_at timestamptz not null default now()+interval '24 hours', used_at timestamptz,revoked_at timestamptz
);
create table public.account_audit(
 id uuid primary key default gen_random_uuid(),client_id uuid not null references public.clients(id) on delete cascade,
 actor_id uuid references auth.users(id),action text not null,created_at timestamptz not null default now()
);
create index account_audit_client_idx on public.account_audit(client_id);
create index account_audit_actor_idx on public.account_audit(actor_id);
create index account_operations_actor_idx on piti_private.account_operations(actor_id);
create index entry_links_client_idx on piti_private.entry_links(client_id);
create index entry_links_user_idx on piti_private.entry_links(user_id);
alter table piti_private.entry_links enable row level security;
alter table piti_private.account_operations enable row level security;
alter table public.account_audit enable row level security;
revoke all on piti_private.entry_links,piti_private.account_operations,public.account_audit from public,anon,authenticated;
grant select on public.account_audit to authenticated;
create policy account_audit_read on public.account_audit for select to authenticated using
 ((select piti_private.access_ready()) and exists(select 1 from public.clients c where c.id=client_id and (c.pt_id=auth.uid() or c.user_id=auth.uid())));

-- These server-only operations never accept authorization from user_metadata.
create function piti_private.managed_account_begin(p_actor uuid,p_client uuid,p_kind text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.clients; p public.profiles; op piti_private.account_operations;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 select * into c from public.clients where id=p_client for update;
 select * into p from public.profiles where id=p_actor;
 if c.id is null or p.id is null then raise exception 'Hesap bulunamadı.'; end if;
 if p_kind='password' then
  if c.user_id is distinct from p_actor or p.role<>'member' or not p.must_change_password then raise exception 'Şifre değişim yetkisi yok.'; end if;
 elsif p_kind in ('create','reset') then
  if p.role<>'pt' or p.must_change_password or c.pt_id is distinct from p_actor or c.archived then raise exception 'Yalnızca kendi aktif müşterilerini yönetebilirsin.'; end if;
  if p_kind='create' and c.user_id is not null then raise exception 'Müşterinin hesabı zaten bağlı.'; end if;
  if p_kind='reset' and (c.user_id is null or not exists(select 1 from public.profiles where id=c.user_id and role='member')) then raise exception 'Bağlı müşteri hesabı bulunamadı.'; end if;
 else raise exception 'Geçersiz işlem.';
 end if;
 select * into op from piti_private.account_operations where client_id=c.id;
 if op.id is not null and op.finished_at is null and op.expires_at>now() then raise exception 'Bu hesapta bir işlem sürüyor; biraz sonra tekrar dene.'; end if;
 insert into piti_private.account_operations(client_id,actor_id,kind) values(c.id,p_actor,p_kind)
 on conflict(client_id) do update set id=gen_random_uuid(),actor_id=p_actor,kind=p_kind,expires_at=now()+interval '2 minutes',finished_at=null returning * into op;
 if p_kind='reset' then
  update public.profiles set must_change_password=true where id=c.user_id;
  update piti_private.entry_links set revoked_at=now() where client_id=c.id and revoked_at is null;
  delete from auth.sessions where user_id=c.user_id;
 end if;
 insert into public.account_audit(client_id,actor_id,action) values(c.id,p_actor,p_kind||'_started');
 return jsonb_build_object('operation_id',op.id,'client_id',c.id,'user_id',c.user_id,'email',case when c.user_id is null then c.email else (select email from auth.users where id=c.user_id) end,'full_name',c.full_name);
end $$;
create function piti_private.managed_account_finish(p_operation uuid,p_user uuid,p_token_hash text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare op piti_private.account_operations;c public.clients; u auth.users;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 select * into op from piti_private.account_operations where id=p_operation;
 select * into c from public.clients where id=op.client_id for update;
 select * into op from piti_private.account_operations where id=p_operation for update;
 if op.id is null or op.finished_at is not null or op.expires_at<=now() then raise exception 'Hesap işleminin süresi doldu; tekrar dene.'; end if;
 select * into u from auth.users where id=p_user;
 if u.id is null then raise exception 'Hesap bulunamadı.'; end if;
 if op.kind='password' then
  if c.user_id is distinct from p_user or op.actor_id<>p_user then raise exception 'Şifre değişim yetkisi yok.'; end if;
  update public.profiles set must_change_password=false where id=p_user;
  delete from auth.sessions where user_id=p_user;
 else
  if c.pt_id is distinct from op.actor_id or (op.kind='create' and lower(trim(c.email))<>lower(trim(u.email))) or not exists(select 1 from public.profiles where id=p_user and role='member') then raise exception 'Hesap bilgileri eşleşmiyor.'; end if;
  if op.kind='create' then
   if c.user_id is not null or exists(select 1 from public.clients where user_id=p_user) then raise exception 'Hesap zaten bağlı.'; end if;
   update public.clients set user_id=p_user,updated_at=now() where id=c.id;
  elsif c.user_id is distinct from p_user then raise exception 'Hesap bağlantısı değişmiş.';
  end if;
  update public.profiles set must_change_password=true where id=p_user;
 end if;
 update piti_private.entry_links set revoked_at=now() where client_id=c.id and revoked_at is null;
 update public.client_invitations set revoked_at=now() where client_id=c.id and used_at is null and revoked_at is null;
 if op.kind<>'password' then
  if p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then raise exception 'Geçersiz bağlantı.'; end if;
  insert into piti_private.entry_links(client_id,user_id,token_hash) values(c.id,p_user,p_token_hash);
 end if;
 update piti_private.account_operations set finished_at=now() where id=op.id;
 insert into public.account_audit(client_id,actor_id,action) values(c.id,op.actor_id,op.kind||'_completed');
 return jsonb_build_object('client_id',c.id,'user_id',p_user);
end $$;
create function piti_private.managed_account_cancel(p_operation uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 update piti_private.account_operations set finished_at=now() where id=p_operation and finished_at is null;
end $$;
create function piti_private.consume_entry_link(p_hash text) returns jsonb language plpgsql security definer set search_path='' as $$
declare entry piti_private.entry_links;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 select * into entry from piti_private.entry_links where token_hash=p_hash for update;
 if entry.id is null or entry.expires_at<=now() or entry.used_at is not null or entry.revoked_at is not null then raise exception 'Bağlantı geçersiz veya kullanılmış. E-posta ve geçici şifrenle giriş yapabilir ya da PT’nden yeni bağlantı isteyebilirsin.'; end if;
 if not exists(select 1 from public.clients c join public.profiles p on p.id=c.user_id where c.id=entry.client_id and c.user_id=entry.user_id and p.role='member' and p.must_change_password and not c.archived) then raise exception 'Bu giriş bağlantısı artık geçerli değil.'; end if;
 update piti_private.entry_links set used_at=now() where id=entry.id;
 return jsonb_build_object('user_id',entry.user_id,'email',(select email from auth.users where id=entry.user_id));
end $$;
create function piti_private.check_new_password(p_user uuid,p_password text) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 return not exists(select 1 from auth.users where id=p_user and encrypted_password=extensions.crypt(p_password,encrypted_password));
end $$;
create function public.managed_account_begin(p_actor uuid,p_client uuid,p_kind text) returns jsonb language sql security invoker set search_path='' as $$select piti_private.managed_account_begin(p_actor,p_client,p_kind)$$;
create function public.managed_account_finish(p_operation uuid,p_user uuid,p_token_hash text default null) returns jsonb language sql security invoker set search_path='' as $$select piti_private.managed_account_finish(p_operation,p_user,p_token_hash)$$;
create function public.managed_account_cancel(p_operation uuid) returns void language sql security invoker set search_path='' as $$select piti_private.managed_account_cancel(p_operation)$$;
create function public.consume_entry_link(p_hash text) returns jsonb language sql security invoker set search_path='' as $$select piti_private.consume_entry_link(p_hash)$$;
create function public.check_new_password(p_user uuid,p_password text) returns boolean language sql security invoker set search_path='' as $$select piti_private.check_new_password(p_user,p_password)$$;
revoke all on function public.managed_account_begin(uuid,uuid,text),public.managed_account_finish(uuid,uuid,text),public.managed_account_cancel(uuid),public.consume_entry_link(text),public.check_new_password(uuid,text) from public,anon,authenticated;
revoke all on function piti_private.managed_account_begin(uuid,uuid,text),piti_private.managed_account_finish(uuid,uuid,text),piti_private.managed_account_cancel(uuid),piti_private.consume_entry_link(text),piti_private.check_new_password(uuid,text),piti_private.initialize_account_profile(),piti_private.guard_profile_role() from public,anon,authenticated;
grant usage on schema piti_private to service_role;
grant execute on function public.managed_account_begin(uuid,uuid,text),public.managed_account_finish(uuid,uuid,text),public.managed_account_cancel(uuid),public.consume_entry_link(text),public.check_new_password(uuid,text),piti_private.managed_account_begin(uuid,uuid,text),piti_private.managed_account_finish(uuid,uuid,text),piti_private.managed_account_cancel(uuid),piti_private.consume_entry_link(text),piti_private.check_new_password(uuid,text) to service_role;

-- A conversation is one client row: no arbitrary recipient or sender can be supplied.
alter table public.messages add column sender_role text check(sender_role in ('pt','member'));
create index if not exists messages_client_created_idx on public.messages(client_id,created_at,id);
create function piti_private.guard_message() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='INSERT' then
  if new.sender_id is distinct from auth.uid() and current_user='authenticated' then raise exception 'Mesaj göndereni değiştirilemez.'; end if;
  new.sender_role=(select role from public.profiles where id=new.sender_id);
  if new.body is null or char_length(trim(new.body))<1 or char_length(new.body)>4000 then raise exception 'Mesaj 1–4000 karakter olmalı.'; end if;
 elsif current_user='authenticated' then
  if new.client_id is distinct from old.client_id or new.sender_id is distinct from old.sender_id or new.body is distinct from old.body or new.sender_role is distinct from old.sender_role then raise exception 'Mesaj içeriği ve alıcısı değiştirilemez.'; end if;
  new.read_at=now();
 end if;
 return new;
end $$;
create trigger protect_message before insert or update on public.messages for each row execute function piti_private.guard_message();
drop policy messages_access on public.messages;
revoke all on public.messages from anon,authenticated;
grant select on public.messages to authenticated;
grant insert(id,client_id,sender_id,body) on public.messages to authenticated;
grant update(read_at) on public.messages to authenticated;
create policy messages_read on public.messages for select to authenticated using
 (exists(select 1 from public.clients c where c.id=client_id and ((c.pt_id=auth.uid() and (select piti_private.account_role())='pt') or (c.user_id=auth.uid() and (select piti_private.account_role())='member'))));
create policy messages_send on public.messages for insert to authenticated with check
 (sender_id=auth.uid() and exists(select 1 from public.clients c where c.id=client_id and ((c.pt_id=auth.uid() and (select piti_private.account_role())='pt') or (c.user_id=auth.uid() and c.pt_id is not null and (select piti_private.account_role())='member'))));
create policy messages_read_receipt on public.messages for update to authenticated using
 (sender_id<>auth.uid() and exists(select 1 from public.clients c where c.id=client_id and (c.pt_id=auth.uid() or c.user_id=auth.uid()))) with check
 (sender_id<>auth.uid() and exists(select 1 from public.clients c where c.id=client_id and (c.pt_id=auth.uid() or c.user_id=auth.uid())));
-- Future history snapshots cannot fabricate/overwrite the legacy chat history.
create function piti_private.guard_legacy_messages() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='UPDATE' then new.data=jsonb_set(new.data,'{messages}',coalesce(old.data->'messages','[]'::jsonb));
 elsif not exists(select 1 from public.clients where id=new.client_id and pt_id=auth.uid()) then new.data=jsonb_set(new.data,'{messages}','[]'::jsonb); end if;
 return new;
end $$;
create trigger preserve_legacy_messages before insert or update on public.client_history for each row execute function piti_private.guard_legacy_messages();
revoke all on function piti_private.guard_message(),piti_private.guard_legacy_messages() from public,anon,authenticated;
commit;
