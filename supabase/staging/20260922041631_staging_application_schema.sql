-- Dedicated bootstrap for existing piti-demo only. Never a production migration.
begin;
set local lock_timeout='3s';
do $$ begin
 if to_regclass('public.profiles') is not null or to_regclass('public.demo_state') is null or exists(select 1 from auth.users) then
 raise exception 'Staging bootstrap requires the empty-account DEMO project'; end if;
end $$;
create temp table staging_demo_before as select md5(data::text) hash,version,updated_at from public.demo_state where id='main';


-- Source migration: 20260914065346 create_private_user_profiles

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 role text not null check (role in ('pt','member')),
 full_name text not null check (char_length(full_name) between 1 and 160),
 phone text,
 avatar_url text,
 created_at timestamptz not null default now()
 );
 alter table public.profiles enable row level security;
 revoke all on public.profiles from anon, authenticated;
 grant select, insert on public.profiles to authenticated;
 grant update (full_name, phone, avatar_url) on public.profiles to authenticated;
 create policy profiles_read_self on public.profiles for select to authenticated using ((select auth.uid()) = id);
 create policy profiles_create_self on public.profiles for insert to authenticated with check ((select auth.uid()) = id);
 create policy profiles_edit_self on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- Source migration: 20260916034117 create_piti_core_schema

create extension if not exists pgcrypto;

create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  pt_id uuid references auth.users(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  full_name text not null,
  phone text,
  email text,
  blood_type text,
  gender text,
  weight numeric(6,2),
  height numeric(6,2),
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.packages (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  name text not null default '12 Seans / 30 Gün',
  price numeric(12,2) not null default 0,
  total_sessions integer,
  start_date date,
  expiry_date date,
  status text not null default 'active',
  created_at timestamptz not null default now()
);

create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  pt_id uuid references auth.users(id) on delete set null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  status text not null default 'planned' check (status in ('planned','completed','no_show','cancelled')),
  workout_title text,
  muscle_groups text[] not null default '{}',
  salon text,
  notes text,
  counts_against_package boolean not null default true,
  client_confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  package_id uuid references public.packages(id) on delete set null,
  amount numeric(12,2) not null,
  method text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  receipt_path text,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.availability (
  id uuid primary key default gen_random_uuid(),
  pt_id uuid references auth.users(id) on delete cascade,
  client_id uuid references public.clients(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz,
  all_day boolean not null default false,
  kind text not null default 'available' check (kind in ('available','unavailable','leave','off')),
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  pt_id uuid references auth.users(id) on delete set null,
  title text not null,
  due_at timestamptz,
  status text not null default 'open' check (status in ('open','done','cancelled')),
  result text,
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  sender_id uuid references auth.users(id) on delete set null,
  body text,
  attachment_path text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists sessions_client_starts_idx on public.sessions(client_id, starts_at);
create index if not exists payments_client_created_idx on public.payments(client_id, created_at desc);
create index if not exists messages_client_created_idx on public.messages(client_id, created_at);

alter table public.clients enable row level security;
alter table public.packages enable row level security;
alter table public.sessions enable row level security;
alter table public.payments enable row level security;
alter table public.availability enable row level security;
alter table public.tasks enable row level security;
alter table public.messages enable row level security;

-- PiTi Supabase access rules.
-- The publishable browser key is safe only while these RLS policies stay enabled.

revoke all on table public.clients, public.packages, public.sessions,
  public.payments, public.availability, public.tasks, public.messages from anon;

grant select, insert, update, delete on table public.profiles, public.clients,
  public.packages, public.sessions, public.payments, public.availability,
  public.tasks, public.messages to authenticated;

drop policy if exists clients_access on public.clients;
create policy clients_access on public.clients for all to authenticated
using ((select auth.uid()) = pt_id or (select auth.uid()) = user_id)
with check ((select auth.uid()) = pt_id or (select auth.uid()) = user_id);

drop policy if exists sessions_access on public.sessions;
create policy sessions_access on public.sessions for all to authenticated
using (
  (select auth.uid()) = pt_id or exists (
    select 1 from public.clients c
    where c.id = sessions.client_id and c.user_id = (select auth.uid())
  )
)
with check (
  (select auth.uid()) = pt_id or exists (
    select 1 from public.clients c
    where c.id = sessions.client_id and c.user_id = (select auth.uid())
  )
);

drop policy if exists packages_access on public.packages;
create policy packages_access on public.packages for all to authenticated
using (exists (select 1 from public.clients c where c.id = packages.client_id
  and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))))
with check (exists (select 1 from public.clients c where c.id = packages.client_id
  and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))));

drop policy if exists payments_access on public.payments;
create policy payments_access on public.payments for all to authenticated
using (exists (select 1 from public.clients c where c.id = payments.client_id
  and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))))
with check (exists (select 1 from public.clients c where c.id = payments.client_id
  and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))));

drop policy if exists availability_access on public.availability;
create policy availability_access on public.availability for all to authenticated
using ((select auth.uid()) = pt_id or exists (
  select 1 from public.clients c where c.id = availability.client_id
    and c.user_id = (select auth.uid())))
with check ((select auth.uid()) = pt_id or exists (
  select 1 from public.clients c where c.id = availability.client_id
    and c.user_id = (select auth.uid())));

drop policy if exists tasks_access on public.tasks;
create policy tasks_access on public.tasks for all to authenticated
using ((select auth.uid()) = pt_id or exists (
  select 1 from public.clients c where c.id = tasks.client_id
    and c.user_id = (select auth.uid())))
with check ((select auth.uid()) = pt_id or exists (
  select 1 from public.clients c where c.id = tasks.client_id
    and c.user_id = (select auth.uid())));

drop policy if exists messages_access on public.messages;
create policy messages_access on public.messages for all to authenticated
using (sender_id = (select auth.uid()) or exists (
  select 1 from public.clients c where c.id = messages.client_id
    and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))))
with check (sender_id = (select auth.uid()) and exists (
  select 1 from public.clients c where c.id = messages.client_id
    and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))));

-- Foreign-key and ownership lookups used by RLS and the application.
create index if not exists clients_pt_id_idx on public.clients(pt_id);
create unique index if not exists clients_user_id_unique_idx
  on public.clients(user_id) where user_id is not null;
create index if not exists availability_pt_id_idx on public.availability(pt_id);
create index if not exists availability_client_id_idx on public.availability(client_id);
create index if not exists sessions_pt_id_idx on public.sessions(pt_id);
create index if not exists packages_client_id_idx on public.packages(client_id);
create index if not exists payments_package_id_idx on public.payments(package_id);
create index if not exists tasks_client_id_idx on public.tasks(client_id);
create index if not exists tasks_pt_id_idx on public.tasks(pt_id);
create index if not exists messages_sender_id_idx on public.messages(sender_id);


-- Source migration: 20260916171953 client_account_invitations

-- Link a verified account to an existing client without changing that client's ID.

create schema if not exists piti_private;
revoke all on schema piti_private from public, anon;
grant usage on schema piti_private to authenticated;
create table public.client_invitations (
 id uuid primary key default gen_random_uuid(),
 client_id uuid not null references public.clients(id) on delete cascade,
 pt_id uuid not null references auth.users(id),
 email text not null,
 token_hash text not null unique,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '7 days',
 used_at timestamptz, revoked_at timestamptz,
 used_by uuid references auth.users(id)
);
create index client_invitations_client_idx on public.client_invitations(client_id);
create index client_invitations_pt_idx on public.client_invitations(pt_id);
create index client_invitations_used_by_idx on public.client_invitations(used_by);
alter table public.client_invitations enable row level security;
revoke all on public.client_invitations from anon, authenticated;
grant select(id,client_id,pt_id,email,created_at,expires_at,used_at,revoked_at) on public.client_invitations to authenticated;
create policy invitations_owner_read on public.client_invitations for select to authenticated
 using (pt_id=(select auth.uid()));

-- Preserve the application's existing per-client history, which predates normalized tables.
create table public.client_history (
 client_id uuid primary key references public.clients(id) on delete cascade,
 data jsonb not null default '{}'::jsonb check (jsonb_typeof(data)='object'),
 version integer not null default 1,
 updated_at timestamptz not null default now()
);
alter table public.client_history enable row level security;
revoke all on public.client_history from anon, authenticated;
grant select on public.client_history to authenticated;
create policy history_participants_read on public.client_history for select to authenticated
 using (exists(select 1 from public.clients c where c.id=client_id and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid()))));

-- Ordinary API writes cannot reassign a client's account or trainer.
create function piti_private.guard_client_link() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='UPDATE' and (new.user_id is distinct from old.user_id or new.pt_id is distinct from old.pt_id) then
   raise exception 'Hesap bağlantısı yalnızca müşteri davetiyle değiştirilebilir.';
  elsif tg_op='INSERT' and not (
   (new.user_id=auth.uid() and new.pt_id is null) or
   (new.user_id is null and new.pt_id=auth.uid())
  ) then raise exception 'Geçersiz müşteri sahipliği.';
  end if;
 end if;
 return new;
end $$;
create trigger protect_client_link before insert or update on public.clients
 for each row execute function piti_private.guard_client_link();

create function piti_private.create_client_invitation(p_client_id uuid) returns jsonb
 language plpgsql security definer set search_path='' as $$
declare c public.clients; token text; invitation public.client_invitations;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into c from public.clients where id=p_client_id for update;
 if c.id is null or c.pt_id is distinct from auth.uid() then raise exception 'Bu müşteriye davet oluşturamazsın.'; end if;
 if c.user_id is not null then raise exception 'Müşterinin hesabı zaten bağlı.'; end if;
 if c.archived then raise exception 'Önce müşteriyi aktif hale getir.'; end if;
 if coalesce(c.email,'') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Müşterinin geçerli e-posta adresini kaydet.'; end if;
 update public.client_invitations set revoked_at=now() where client_id=c.id and used_at is null and revoked_at is null;
 token='PITI-'||upper(encode(extensions.gen_random_bytes(16),'hex'));
 insert into public.client_invitations(client_id,pt_id,email,token_hash)
 values(c.id,auth.uid(),lower(trim(c.email)),encode(extensions.digest(token,'sha256'),'hex')) returning * into invitation;
 return jsonb_build_object('id',invitation.id,'code',token,'email',invitation.email,'expires_at',invitation.expires_at);
end $$;
create function piti_private.revoke_client_invitation(p_client_id uuid) returns void
 language plpgsql security definer set search_path='' as $$
declare c public.clients;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into c from public.clients where id=p_client_id for update;
 if c.id is null or c.pt_id is distinct from auth.uid() then raise exception 'Bu daveti iptal edemezsin.'; end if;
 update public.client_invitations set revoked_at=now() where client_id=c.id and used_at is null and revoked_at is null;
end $$;
create function piti_private.redeem_client_invitation(p_code text) returns uuid
 language plpgsql security definer set search_path='' as $$
declare inv public.client_invitations; c public.clients; existing public.clients; verified_email text;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 -- Serialize competing redemptions by the same user, including across different invitations.
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 select lower(trim(email)) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if verified_email is null then raise exception 'Önce e-posta adresini doğrula.'; end if;
 if not exists(select 1 from public.profiles where id=auth.uid() and role='member') then raise exception 'Davet için müşteri hesabıyla giriş yap.'; end if;
 select * into inv from public.client_invitations where token_hash=encode(extensions.digest(upper(trim(p_code)),'sha256'),'hex');
 if inv.id is null then raise exception 'Davet geçersiz veya süresi dolmuş.'; end if;
 select * into c from public.clients where id=inv.client_id for update;
 select * into inv from public.client_invitations where id=inv.id for update;
 if inv.used_at is not null or inv.revoked_at is not null or inv.expires_at<=now() then raise exception 'Davet geçersiz veya süresi dolmuş.'; end if;
 if verified_email<>inv.email then raise exception 'Bu davet başka bir e-posta adresine ait. Davet edilen adresle giriş yap.'; end if;
 if c.user_id is not null or c.archived or c.pt_id is distinct from inv.pt_id or lower(trim(c.email)) is distinct from inv.email then raise exception 'Müşteri bilgileri değişmiş; PT yeni davet oluşturmalı.'; end if;
 select * into existing from public.clients where user_id=auth.uid() for update;
 if existing.id is not null then
  -- Only release an empty self-registration shell; never delete or move existing history.
  if existing.pt_id is not null
   or exists(select 1 from public.sessions where client_id=existing.id)
   or exists(select 1 from public.packages where client_id=existing.id)
   or exists(select 1 from public.payments where client_id=existing.id)
   or exists(select 1 from public.messages where client_id=existing.id)
   or exists(select 1 from public.tasks where client_id=existing.id)
   or exists(select 1 from public.availability where client_id=existing.id)
   or exists(select 1 from public.client_history where client_id=existing.id and data<>'{}'::jsonb)
  then raise exception 'Hesabında başka bir müşteri kaydı veya geçmiş var. Güvenli birleştirme için PT ile iletişime geç.'; end if;
  update public.clients set user_id=null,archived=true where id=existing.id;
 end if;
 update public.clients set user_id=auth.uid(),updated_at=now() where id=c.id;
 update public.client_invitations set used_at=now(),used_by=auth.uid() where id=inv.id;
 return c.id;
end $$;
create function piti_private.save_client_history(p_client_id uuid,p_data jsonb,p_version integer) returns integer
 language plpgsql security definer set search_path='' as $$
declare c public.clients; v integer; old_data jsonb; allowed text[]; k text;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into c from public.clients where id=p_client_id for update;
 if c.id is null or (c.pt_id is distinct from auth.uid() and c.user_id is distinct from auth.uid()) then raise exception 'Bu geçmişe erişemezsin.'; end if;
 if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Geçersiz geçmiş verisi.'; end if;
 select version,data into v,old_data from public.client_history where client_id=c.id;
 if coalesce(v,0)<>p_version then raise exception 'Kayıt başka bir cihazda değişti. Sayfayı yenileyip tekrar dene.'; end if;
 if c.pt_id is distinct from auth.uid() then
  allowed=array['messages','tasks','progressData','unread','payment','financeHistory'];
  for k in select jsonb_object_keys(p_data) loop
   if not k=any(allowed) and p_data->k is distinct from old_data->k then raise exception 'Bu alanı yalnızca PT değiştirebilir.'; end if;
  end loop;
  if p_data->'package' is distinct from old_data->'package' then raise exception 'Paketi yalnızca PT değiştirebilir.'; end if;
  if p_data->'payment' is distinct from old_data->'payment' and coalesce(p_data#>>'{payment,status}','')<>'pending' then raise exception 'Ödemeyi yalnızca PT onaylayabilir.'; end if;
 end if;
 insert into public.client_history(client_id,data,version) values(c.id,p_data,1)
 on conflict(client_id) do update set data=excluded.data,version=public.client_history.version+1,updated_at=now()
 returning version into v;
 return v;
end $$;
create function public.create_client_invitation(p_client_id uuid) returns jsonb language sql security invoker set search_path='' as $$select piti_private.create_client_invitation(p_client_id)$$;
create function public.revoke_client_invitation(p_client_id uuid) returns void language sql security invoker set search_path='' as $$select piti_private.revoke_client_invitation(p_client_id)$$;
create function public.redeem_client_invitation(p_code text) returns uuid language sql security invoker set search_path='' as $$select piti_private.redeem_client_invitation(p_code)$$;
create function public.save_client_history(p_client_id uuid,p_data jsonb,p_version integer) returns integer language sql security invoker set search_path='' as $$select piti_private.save_client_history(p_client_id,p_data,p_version)$$;
revoke all on all functions in schema piti_private from public, anon;
grant execute on function piti_private.create_client_invitation(uuid),piti_private.revoke_client_invitation(uuid),piti_private.redeem_client_invitation(text),piti_private.save_client_history(uuid,jsonb,integer) to authenticated;
revoke all on function public.create_client_invitation(uuid),public.revoke_client_invitation(uuid),public.redeem_client_invitation(text),public.save_client_history(uuid,jsonb,integer) from public,anon;
grant execute on function public.create_client_invitation(uuid),public.revoke_client_invitation(uuid),public.redeem_client_invitation(text),public.save_client_history(uuid,jsonb,integer) to authenticated;


-- Source migration: 20260916175242 managed_accounts_roles_messages


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
 return jsonb_build_object('operation_id',op.id,'client_id',c.id,'user_id',c.user_id,'email',c.email,'full_name',c.full_name);
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
  if c.pt_id is distinct from op.actor_id or lower(trim(c.email))<>lower(trim(u.email)) or not exists(select 1 from public.profiles where id=p_user and role='member') then raise exception 'Hesap bilgileri eşleşmiyor.'; end if;
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


-- Source migration: 20260916201635 delete_archived_client


-- The public wrapper is invoker-only. Ownership, role, live session, archive
-- status and typed confirmation are checked again inside the private boundary.
create function piti_private.delete_archived_client(p_client_id uuid,p_confirmation text)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.clients%rowtype;
begin
 if auth.uid() is null or not piti_private.access_ready() or not exists(
  select 1 from public.profiles p where p.id=auth.uid() and p.role='pt'
 ) then raise exception 'Bu işlem yalnızca PT hesabına açık.'; end if;
 select * into c from public.clients where id=p_client_id and pt_id=auth.uid() for update;
 if not found then raise exception 'Müşteri bulunamadı veya silme yetkin yok.'; end if;
 if not c.archived then raise exception 'Önce müşteriyi arşive kaldır.'; end if;
 if p_confirmation is null or btrim(p_confirmation)<>btrim(c.full_name) then
  raise exception 'Onay için müşterinin adını aynen yaz.';
 end if;
 if exists(select 1 from piti_private.account_operations o where o.client_id=c.id and o.finished_at is null and o.expires_at>now()) then
  raise exception 'Hesap işlemi sürüyor. Tamamlandıktan sonra tekrar dene.';
 end if;
 -- All client-owned tables use ON DELETE CASCADE, including invitations,
 -- history, messages and private entry links. Auth users/profiles are untouched.
 delete from public.clients where id=c.id;
 return c.id;
end $$;
revoke all on function piti_private.delete_archived_client(uuid,text) from public,anon;
grant execute on function piti_private.delete_archived_client(uuid,text) to authenticated;
create function public.delete_archived_client(p_client_id uuid,p_confirmation text)
returns uuid language sql security invoker set search_path='' as $$
 select piti_private.delete_archived_client(p_client_id,p_confirmation);
$$;
revoke all on function public.delete_archived_client(uuid,text) from public,anon;
grant execute on function public.delete_archived_client(uuid,text) to authenticated;


-- Source migration: 20260917030816 chat_tasks_stickers


alter table public.messages add column sticker text check(sticker in ('water','weigh','meal','move','sleep','cheer'));
grant insert(sticker) on public.messages to authenticated;
create function piti_private.guard_sticker() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='UPDATE' and new.sticker is distinct from old.sticker then raise exception 'Sticker değiştirilemez.'; end if;
 return new;
end $$;
create trigger protect_sticker before update on public.messages for each row execute function piti_private.guard_sticker();
alter table public.tasks add column message_id uuid unique references public.messages(id) on delete cascade,
 add column response_type text not null default 'done' check(response_type in ('done','kg','litre','photo')),
 add column result_photo text check(result_photo is null or (length(result_photo)<=700000 and result_photo ~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$')),
 add column completed_at timestamptz;
create index if not exists tasks_client_due_idx on public.tasks(client_id,due_at);
create index if not exists tasks_pt_idx on public.tasks(pt_id);
drop policy tasks_access on public.tasks;
revoke all on public.tasks from anon,authenticated;
grant select on public.tasks to authenticated;
grant insert(id,client_id,pt_id,title,due_at,message_id,response_type) on public.tasks to authenticated;
grant update(status,result,result_photo) on public.tasks to authenticated;
create policy tasks_read on public.tasks for select to authenticated using(exists(select 1 from public.clients c where c.id=client_id and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid()))));
create policy tasks_assign on public.tasks for insert to authenticated with check(pt_id=(select auth.uid()) and (select piti_private.account_role())='pt' and exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid()) and not c.archived));
create policy tasks_complete on public.tasks for update to authenticated using((select piti_private.account_role())='member' and exists(select 1 from public.clients c where c.id=client_id and c.user_id=(select auth.uid()))) with check((select piti_private.account_role())='member' and exists(select 1 from public.clients c where c.id=client_id and c.user_id=(select auth.uid())));
create function piti_private.guard_chat_task() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if current_user<>'authenticated' then return new; end if;
 if tg_op='INSERT' then
  if new.due_at is null or new.due_at<=now() then raise exception 'Gelecekte bir son tarih seç.'; end if;
  if char_length(btrim(new.title))<1 or char_length(new.title)>4000 then raise exception 'Görev açıklaması geçersiz.'; end if;
  if new.message_id is null or not exists(select 1 from public.messages m where m.id=new.message_id and m.client_id=new.client_id and m.sender_id=auth.uid() and m.sender_role='pt') then raise exception 'Yalnızca kendi mesajını göreve dönüştürebilirsin.'; end if;
 else
  if old.status='done' then raise exception 'Görev zaten tamamlandı.'; end if;
  if new.status<>'done' then raise exception 'Görev yalnızca tamamlanabilir.'; end if;
  if new.response_type in ('kg','litre') then
   if new.result is null or new.result !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' then raise exception 'Geçerli bir sayı gir.'; end if;
   if new.result::numeric<=0 or (new.response_type='kg' and new.result::numeric>700) or (new.response_type='litre' and new.result::numeric>100) then raise exception 'Geçerli bir sayı gir.'; end if;
   new.result_photo=null;
  elsif new.response_type='photo' then
   if new.result_photo is null then raise exception 'Fotoğraf ekle.'; end if;
   new.result='Fotoğraf gönderildi';
  else new.result='Tamamlandı';new.result_photo=null;
  end if;
  new.completed_at=now();
 end if;
 return new;
end $$;
create trigger protect_chat_task before insert or update on public.tasks for each row execute function piti_private.guard_chat_task();
create function public.assign_chat_task(p_client_id uuid,p_message_id uuid,p_body text,p_sticker text,p_due_at timestamptz,p_response_type text,p_create_message boolean)
returns uuid language plpgsql security invoker set search_path='' as $$
declare mid uuid; tid uuid; msg public.messages;
begin
 if auth.uid() is null or not piti_private.access_ready() or piti_private.account_role()<>'pt' then raise exception 'Görev atamak için PT hesabı gerekli.'; end if;
 -- The client-supplied message UUID makes a retried request idempotent.
 select * into msg from public.messages where id=p_message_id;
 if found then
  if msg.client_id<>p_client_id or msg.sender_id<>auth.uid() then raise exception 'Mesaj bulunamadı.'; end if;
  select id into tid from public.tasks where message_id=msg.id;
  if tid is not null then return tid; end if;
 elsif p_create_message then
  insert into public.messages(id,client_id,sender_id,body,sticker) values(p_message_id,p_client_id,auth.uid(),p_body,p_sticker) returning * into msg;
 else raise exception 'Mesaj bulunamadı.';
 end if;
 insert into public.tasks(client_id,pt_id,title,due_at,message_id,response_type)
 values(p_client_id,auth.uid(),msg.body,p_due_at,msg.id,p_response_type) returning id into tid;
 return tid;
end $$;
revoke all on function public.assign_chat_task(uuid,uuid,text,text,timestamptz,text,boolean) from public,anon;
grant execute on function public.assign_chat_task(uuid,uuid,text,text,timestamptz,text,boolean) to authenticated;
revoke all on function piti_private.guard_chat_task(),piti_private.guard_sticker() from public,anon,authenticated;


-- Source migration: 20260917033312 username_accounts


create function piti_private.normalize_username(value text) returns text language sql immutable set search_path='' as $$select lower(translate(btrim(coalesce(value,'')),'ÇĞİÖŞÜçğıöşüI','CGIOSUcgiosui'))$$;
alter table public.profiles add column username text unique check(username is null or (username ~ '^[a-z0-9][a-z0-9._-]{2,29}$'));
create table piti_private.username_login_attempts(identifier_hash text primary key,started_at timestamptz not null,attempts integer not null);
alter table piti_private.username_login_attempts enable row level security;
revoke all on piti_private.username_login_attempts from public,anon,authenticated;
create function piti_private.username_login_lookup(p_username text) returns text language plpgsql security definer set search_path='' as $$
declare canonical text; n integer; address text;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 canonical=piti_private.normalize_username(p_username);
 if canonical !~ '^[a-z0-9][a-z0-9._-]{2,29}$' then return null; end if;
 insert into piti_private.username_login_attempts(identifier_hash,started_at,attempts) values(md5(canonical),now(),1)
 on conflict(identifier_hash) do update set attempts=case when username_login_attempts.started_at<now()-interval '5 minutes' then 1 else username_login_attempts.attempts+1 end,started_at=case when username_login_attempts.started_at<now()-interval '5 minutes' then now() else username_login_attempts.started_at end returning attempts into n;
 if n>20 then return null; end if;
 select u.email into address from public.profiles p join auth.users u on u.id=p.id where p.username=canonical;
 return address;
end $$;
create function public.username_login_lookup(p_username text) returns text language sql security invoker set search_path='' as $$select piti_private.username_login_lookup(p_username)$$;
revoke all on function public.username_login_lookup(text),piti_private.username_login_lookup(text) from public,anon,authenticated;
grant execute on function public.username_login_lookup(text),piti_private.username_login_lookup(text) to service_role;
create function piti_private.set_own_username(p_username text) returns text language plpgsql security definer set search_path='' as $$
declare canonical text;
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 canonical=piti_private.normalize_username(p_username);
 if canonical !~ '^[a-z0-9][a-z0-9._-]{2,29}$' then raise exception 'Kullanıcı adı 3–30 karakter; harf, rakam, nokta, alt çizgi veya tire içermeli.'; end if;
 update public.profiles set username=canonical where id=auth.uid();
 return canonical;
exception when unique_violation then raise exception 'Bu kullanıcı adı alınmış. Başka bir ad seç.';
end $$;
create function public.set_own_username(p_username text) returns text language sql security invoker set search_path='' as $$select piti_private.set_own_username(p_username)$$;
revoke all on function public.set_own_username(text),piti_private.set_own_username(text) from public,anon;
grant execute on function public.set_own_username(text),piti_private.set_own_username(text) to authenticated;
revoke all on function piti_private.normalize_username(text) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION piti_private.initialize_account_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare account_role text;
begin
 account_role=coalesce(new.raw_app_meta_data->>'account_role',new.raw_user_meta_data->>'account_type','member');
 if account_role not in ('pt','member') then account_role='member'; end if;
 insert into public.profiles(id,role,full_name,must_change_password,username)
 values(new.id,account_role,left(coalesce(nullif(new.raw_user_meta_data->>'full_name',''),split_part(new.email,'@',1),'Kullanıcı'),160),coalesce((new.raw_app_meta_data->>'must_change_password')::boolean,false),nullif(piti_private.normalize_username(new.raw_app_meta_data->>'username'),''));
 return new;
end $function$;

CREATE OR REPLACE FUNCTION piti_private.guard_profile_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if current_user in ('anon','authenticated') then
  if tg_op='INSERT' then
   if not exists(select 1 from public.profiles where id=new.id and role=new.role) then raise exception 'Hesap rolü sunucu tarafından belirlenir.'; end if;
  elsif new.username is distinct from old.username then raise exception 'Kullanıcı adı yalnızca hesap ayarlarından değiştirilebilir.';
  elsif new.role is distinct from old.role or new.id is distinct from old.id or new.must_change_password is distinct from old.must_change_password then
   raise exception 'Hesap rolü ve şifre zorunluluğu değiştirilemez.';
  end if;
 end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION piti_private.managed_account_finish(p_operation uuid, p_user uuid, p_token_hash text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if c.pt_id is distinct from op.actor_id or (op.kind='create' and not ((nullif(btrim(c.email),'') is not null and lower(btrim(c.email))=lower(btrim(u.email))) or (u.raw_app_meta_data->>'managed_client_id'=c.id::text and u.raw_app_meta_data->>'managed_operation_id'=op.id::text))) or not exists(select 1 from public.profiles where id=p_user and role='member') then raise exception 'Hesap bilgileri eşleşmiyor.'; end if;
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
end $function$;


-- Source migration: 20260917033825 finalize_managed_username


CREATE OR REPLACE FUNCTION piti_private.managed_account_finish(p_operation uuid, p_user uuid, p_token_hash text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if c.pt_id is distinct from op.actor_id or (op.kind='create' and not ((nullif(btrim(c.email),'') is not null and lower(btrim(c.email))=lower(btrim(u.email))) or (u.raw_app_meta_data->>'managed_client_id'=c.id::text and u.raw_app_meta_data->>'managed_operation_id'=op.id::text))) or not exists(select 1 from public.profiles where id=p_user and role='member') then raise exception 'Hesap bilgileri eşleşmiyor.'; end if;
  if op.kind='create' then
   if nullif(u.raw_app_meta_data->>'username','') is not null then
    update public.profiles set username=piti_private.normalize_username(u.raw_app_meta_data->>'username') where id=p_user;
   end if;
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
end $function$;


-- Source migration: 20260917035607 member_trainer_summary


-- Expose only the current member's linked trainer name, never other profiles.
create function piti_private.get_my_trainer() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 if piti_private.account_role()<>'member' then return null; end if;
 select jsonb_build_object('client_id',c.id,'id',p.id,'name',p.full_name) into result
 from public.clients c join public.profiles p on p.id=c.pt_id and p.role='pt'
 where c.user_id=auth.uid();
 return result;
end $$;
create function public.get_my_trainer() returns jsonb
language sql stable security invoker set search_path='' as $$select piti_private.get_my_trainer()$$;
revoke all on function piti_private.get_my_trainer(),public.get_my_trainer() from public,anon;
grant execute on function piti_private.get_my_trainer(),public.get_my_trainer() to authenticated;


-- Source migration: 20260917080429 account_cloud_state


create table public.account_state (
 user_id uuid primary key references auth.users(id) on delete cascade,
 data jsonb not null default '{}'::jsonb check (jsonb_typeof(data)='object'),
 updated_at timestamptz not null default now()
);

alter table public.account_state enable row level security;
revoke all on public.account_state from public, anon, authenticated;
grant select, insert, update on public.account_state to authenticated;

create policy account_state_owner_read on public.account_state
 for select to authenticated using (user_id=(select auth.uid()));
create policy account_state_owner_insert on public.account_state
 for insert to authenticated with check (user_id=(select auth.uid()));
create policy account_state_owner_update on public.account_state
 for update to authenticated
 using (user_id=(select auth.uid()))
 with check (user_id=(select auth.uid()));


-- Source migration: 20260917140215 member_history_server_fields

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

-- Source migration: 20260917142253 sync_member_leave_to_shared_history


create or replace function piti_private.sync_member_leave_from_account_state()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_client_id uuid;
  v_member_leaves jsonb := '[]'::jsonb;
  v_existing jsonb := '{}'::jsonb;
  v_non_member_extra jsonb := '[]'::jsonb;
begin
  select c.id into v_client_id
  from public.clients c
  join public.profiles p on p.id=c.user_id and p.role='member'
  where c.user_id=new.user_id
  limit 1;

  if v_client_id is null then
    return new;
  end if;

  select coalesce(jsonb_agg(e), '[]'::jsonb)
    into v_member_leaves
  from jsonb_array_elements(coalesce(new.data->'events','[]'::jsonb)) e
  where e->>'type'='memberoff'
    and coalesce(e->>'status','')<>'cancelled';

  select data into v_existing
  from public.client_history
  where client_id=v_client_id;

  v_existing:=coalesce(v_existing,'{}'::jsonb);

  select coalesce(jsonb_agg(e), '[]'::jsonb)
    into v_non_member_extra
  from jsonb_array_elements(coalesce(v_existing->'extraEvents','[]'::jsonb)) e
  where e->>'type'<>'memberoff';

  insert into public.client_history(client_id,data,version,updated_at)
  values(
    v_client_id,
    jsonb_set(v_existing,'{extraEvents}',coalesce(v_non_member_extra,'[]'::jsonb)||coalesce(v_member_leaves,'[]'::jsonb),true),
    1,
    now()
  )
  on conflict(client_id) do update
    set data=jsonb_set(public.client_history.data,'{extraEvents}',coalesce(v_non_member_extra,'[]'::jsonb)||coalesce(v_member_leaves,'[]'::jsonb),true),
        updated_at=now();

  return new;
end
$$;

drop trigger if exists sync_member_leave_from_account_state on public.account_state;
create trigger sync_member_leave_from_account_state
after insert or update on public.account_state
for each row execute function piti_private.sync_member_leave_from_account_state();

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
 member_leaves jsonb := '[]'::jsonb;
 non_member_extra jsonb := '[]'::jsonb;
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
  if (p_data-allowed) is distinct from (coalesce(old_data,'{}'::jsonb)-allowed) then raise exception 'Bu alanı yalnızca PT değiştirebilir.'; end if;
  for k in select jsonb_object_keys(p_data) loop
   if not k=any(allowed) and p_data->k is distinct from old_data->k then raise exception 'Bu alanı yalnızca PT değiştirebilir.'; end if;
  end loop;
  if p_data->'package' is distinct from old_data->'package' then raise exception 'Paketi yalnızca PT değiştirebilir.'; end if;
  if p_data->'payment' is distinct from old_data->'payment' and coalesce(p_data#>>'{payment,status}','')<>'pending' then raise exception 'Ödemeyi yalnızca PT onaylayabilir.'; end if;
 end if;

 -- Müşterinin kendi takvimine girdiği "müsait değilim" kayıtları ortak geçmişte korunur.
 if c.user_id is not null then
  select coalesce(jsonb_agg(e),'[]'::jsonb) into member_leaves
  from public.account_state s,
       jsonb_array_elements(coalesce(s.data->'events','[]'::jsonb)) e
  where s.user_id=c.user_id
    and e->>'type'='memberoff'
    and coalesce(e->>'status','')<>'cancelled';
 end if;

 select coalesce(jsonb_agg(e),'[]'::jsonb) into non_member_extra
 from jsonb_array_elements(coalesce(p_data->'extraEvents','[]'::jsonb)) e
 where e->>'type'<>'memberoff';

 p_data:=jsonb_set(p_data,'{extraEvents}',coalesce(non_member_extra,'[]'::jsonb)||coalesce(member_leaves,'[]'::jsonb),true);

 insert into public.client_history(client_id,data,version) values(c.id,p_data,1)
 on conflict(client_id) do update set data=excluded.data,version=public.client_history.version+1,updated_at=now()
 returning version into v;
 return v;
end
$$;

-- Mevcut müşteri kayıtlarını da hemen ortak geçmişe aktar.
update public.account_state s
set updated_at=s.updated_at
where exists(select 1 from public.clients c join public.profiles p on p.id=c.user_id and p.role='member' where c.user_id=s.user_id);


-- Source migration: 20260917142434 preserve_member_leave_and_server_fields


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
 -- trigger. Normal PT/member history saves must preserve them until that trigger
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


-- Source migration: 20260917161516 member_unavailability_normalized


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


-- Source migration: 20260917191510 admin_console


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


-- Source migration: 20260917193657 pt_only_chat_stickers

create policy messages_pt_stickers on public.messages as restrictive for insert to authenticated with check (sticker is null or (select piti_private.account_role())='pt');

-- Source migration: 20260919082449 enforce_session_tenant_relationship

-- Narrow the existing session policy without changing any business records.

alter policy sessions_access on public.sessions
using (
 exists (select 1 from public.clients c
 where c.id=sessions.client_id
 and c.pt_id is not distinct from sessions.pt_id
 and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid())))
)
with check (
 exists (select 1 from public.clients c
 where c.id=sessions.client_id
 and c.pt_id is not distinct from sessions.pt_id
 and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid())))
);


-- Source migration: 20260919085825 daily_application_recovery_copies_and_least_privilege

-- Free-plan application-data recovery copies, in the SAME production database.
-- Not an Auth/Storage/schema backup and not off-site disaster recovery.

revoke truncate,references,trigger on all tables in schema public from public,anon,authenticated;
alter default privileges for role postgres in schema public revoke truncate,references,trigger on tables from public,anon,authenticated;
create extension if not exists pg_cron;
create table piti_private.recovery_copies (
 id bigint generated always as identity primary key,
 created_at timestamptz not null default now(),
 data jsonb not null,
 sha256 text not null,
 bytes integer not null,
 verified_at timestamptz,
 verification jsonb
);
alter table piti_private.recovery_copies enable row level security;
revoke all on piti_private.recovery_copies from public,anon,authenticated;
revoke all on sequence piti_private.recovery_copies_id_seq from public,anon,authenticated;

create function piti_private.verify_recovery_copy(p_id bigint) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare b piti_private.recovery_copies; item record; restored jsonb; results jsonb='{}';
begin
 select * into strict b from piti_private.recovery_copies where id=p_id;
 if encode(extensions.digest(b.data::text,'sha256'),'hex')<>b.sha256 then raise exception 'Recovery copy checksum mismatch';end if;
 for item in select key,value from jsonb_each(b.data) loop
  if not exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=item.key and c.relkind='r') then raise exception 'Source table unavailable: %',item.key;end if;
  -- Materialize real typed rows into isolated temporary tables, never production.
  execute format('create temporary table recovery_verify_%I (like public.%I including defaults including constraints) on commit drop',item.key,item.key);
  execute format('insert into pg_temp.recovery_verify_%I select * from jsonb_populate_recordset(null::public.%I,$1)',item.key,item.key) using item.value;
  execute format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from pg_temp.recovery_verify_%I t',item.key) into restored;
  if restored is distinct from item.value then raise exception 'Recovery copy round-trip mismatch: %',item.key;end if;
  results=results||jsonb_build_object(item.key,jsonb_array_length(restored));
  execute format('drop table pg_temp.recovery_verify_%I',item.key);
 end loop;
 update piti_private.recovery_copies set verified_at=now(),verification=results where id=p_id;
 return results;
end $$;

create function piti_private.capture_recovery_copy() returns bigint
language plpgsql security invoker set search_path='' as $$
declare query_text text; payload jsonb; copy_id bigint; payload_bytes integer;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('piti_daily_recovery',0)) then raise exception 'Recovery copy already running';end if;
 -- One SQL statement provides one consistent MVCC snapshot across every table.
 select 'select jsonb_build_object('||string_agg(format('%L,(select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from public.%I t)',c.relname,c.relname),', ' order by c.relname)||')'
 into query_text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relkind='r' and c.relname<>'demo_state';
 execute query_text into payload;
 payload_bytes=octet_length(payload::text);
 if payload_bytes>10000000 then raise exception 'Recovery copy exceeds 10MB budget; arrange independent backup storage';end if;
 insert into piti_private.recovery_copies(data,sha256,bytes)
 values(payload,encode(extensions.digest(payload::text,'sha256'),'hex'),payload_bytes) returning id into copy_id;
 perform piti_private.verify_recovery_copy(copy_id);
 -- Keep the latest 7 successful copies. Never discard a good copy on failure.
 delete from piti_private.recovery_copies where id not in (select id from piti_private.recovery_copies order by id desc limit 7);
 return copy_id;
end $$;
revoke all on function piti_private.capture_recovery_copy(),piti_private.verify_recovery_copy(bigint) from public,anon,authenticated;

create function piti_private.recovery_status() returns jsonb
language plpgsql security definer set search_path='' as $$
declare latest timestamptz; copies jsonb; job_status jsonb;
begin
 perform piti_private.require_admin();
 select max(created_at) into latest from piti_private.recovery_copies where verified_at is not null;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]') into copies
 from (select id,created_at,bytes,sha256,verified_at,verification from piti_private.recovery_copies order by id desc limit 7) x;
 select to_jsonb(x) into job_status from (select d.status,d.start_time,d.end_time from cron.job_run_details d join cron.job j using(jobid) where j.jobname='piti-daily-recovery' order by d.runid desc limit 1) x;
 return jsonb_build_object('copies',copies,'stale',latest is null or latest<now()-interval '26 hours','last_job',job_status,'schedule','Her gün 03:15 Türkiye saati','scope','Aynı veritabanında uygulama verisi; Auth, dış dosyalar ve veritabanı kaybı kapsam dışıdır.');
end $$;
create function public.recovery_status() returns jsonb language sql security invoker set search_path='' as $$select piti_private.recovery_status()$$;
revoke all on function piti_private.recovery_status(),public.recovery_status() from public,anon;
grant execute on function piti_private.recovery_status(),public.recovery_status() to authenticated;


-- Source migration: 20260919091549 member_confirmed_trainer_transfer_with_history_and_notifications


alter table public.clients add column relationship_ended_at timestamptz;
create table public.trainer_transfers (
 id uuid primary key default gen_random_uuid(), member_id uuid not null,
 old_client_id uuid not null unique, new_client_id uuid not null,
 old_pt_id uuid not null, new_pt_id uuid not null,
 created_at timestamptz not null default now(), measurements_shared boolean not null,
 snapshot jsonb not null
);
create table public.transfer_notifications (
 id uuid primary key default gen_random_uuid(), recipient_id uuid not null,
 body text not null, created_at timestamptz not null default now(), read_at timestamptz
);
create table piti_private.transfer_invitations (
 id uuid primary key default gen_random_uuid(), member_id uuid not null,
 pt_id uuid not null, token_hash text not null unique,
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '7 days',
 used_at timestamptz, revoked_at timestamptz
);
alter table public.trainer_transfers enable row level security;
alter table public.transfer_notifications enable row level security;
alter table piti_private.transfer_invitations enable row level security;
revoke all on public.trainer_transfers,public.transfer_notifications,piti_private.transfer_invitations from public,anon,authenticated;
grant select on public.trainer_transfers,public.transfer_notifications to authenticated;
create policy own_transfer_history on public.trainer_transfers for select to authenticated
 using((select piti_private.access_ready()) and member_id=(select auth.uid()));
create policy own_transfer_notifications on public.transfer_notifications for select to authenticated
 using((select piti_private.access_ready()) and recipient_id=(select auth.uid()));

-- Every child write locks its relationship: transfer and stale writes serialize.
create function piti_private.protect_closed_relationship() returns trigger
language plpgsql security definer set search_path='' as $$
declare cid uuid; ended timestamptz;
begin
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
end $$;
revoke all on function piti_private.protect_closed_relationship() from public,anon,authenticated;
create trigger protect_closed_relationship before update or delete on public.clients for each row execute function piti_private.protect_closed_relationship();
do $$declare t text;begin foreach t in array array['sessions','packages','payments','messages','tasks','availability','client_history'] loop
 execute format('create trigger protect_closed_relationship before insert or update or delete on public.%I for each row execute function piti_private.protect_closed_relationship()',t);
end loop;end $$;
-- Column ACL prevents clients from forging the lifecycle flag; definer transfer owns it.
revoke update on public.clients from authenticated;
grant update(id,pt_id,user_id,full_name,phone,email,blood_type,gender,weight,height,archived,created_at,updated_at) on public.clients to authenticated;
revoke insert on public.clients from authenticated;
grant insert(id,pt_id,user_id,full_name,phone,email,blood_type,gender,weight,height,archived,created_at,updated_at) on public.clients to authenticated;
create function piti_private.guard_member_snapshot_relationship() returns trigger language plpgsql security definer set search_path='' as $$
declare active_id uuid;
begin
 if exists(select 1 from public.profiles where id=new.user_id and role='member') then
  select id into active_id from public.clients where user_id=new.user_id;
  if active_id is not null and new.data#>>'{customer,dbId}' is distinct from active_id::text then
   raise exception 'PT bağlantısı değişti. Sayfayı yenileyip tekrar giriş yap.';
  end if;
 end if;
 return new;
end $$;
revoke all on function piti_private.guard_member_snapshot_relationship() from public,anon,authenticated;
create trigger guard_member_snapshot_relationship before insert or update on public.account_state for each row execute function piti_private.guard_member_snapshot_relationship();

create function piti_private.trainer_transfer(p_action text,p_args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare inv piti_private.transfer_invitations; old_c public.clients; target_user uuid;
 token text; new_id uuid; snapshot jsonb; hist jsonb; weights jsonb; pt_name text; old_name text;
 share_weights boolean; fingerprint text; future_count integer; receipt_id uuid;
begin
 if not piti_private.access_ready() then raise exception 'Geçerli oturum gerekli.' using errcode='42501';end if;
 if p_action='ack' then
  update public.transfer_notifications set read_at=now() where id=(p_args->>'id')::uuid and recipient_id=auth.uid();return '{"ok":true}';
 end if;
 if p_action='create' then
  if piti_private.account_role()<>'pt' then raise exception 'PT hesabı gerekli.' using errcode='42501';end if;
  select p.id into target_user from public.profiles p join public.clients c on c.user_id=p.id
  where lower(p.username)=lower(trim(p_args->>'username')) and p.role='member' and c.pt_id is not null and c.pt_id<>auth.uid() and not c.archived;
  if target_user is null then raise exception 'Geçişe uygun müşteri kullanıcı adı bulunamadı.';end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||target_user::text,1));
  update piti_private.transfer_invitations set revoked_at=now() where member_id=target_user and pt_id=auth.uid() and used_at is null and revoked_at is null;
  token='TRANSFER-'||upper(encode(extensions.gen_random_bytes(16),'hex'));
  insert into piti_private.transfer_invitations(member_id,pt_id,token_hash) values(target_user,auth.uid(),encode(extensions.digest(token,'sha256'),'hex')) returning * into inv;
  return jsonb_build_object('code',token,'expires_at',inv.expires_at);
 end if;
 if p_action not in ('preview','accept') or piti_private.account_role()<>'member' then raise exception 'Müşteri hesabı gerekli.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 select * into inv from piti_private.transfer_invitations where token_hash=encode(extensions.digest(upper(trim(p_args->>'code')),'sha256'),'hex') for update;
 if inv.id is null or inv.member_id<>auth.uid() or inv.used_at is not null or inv.revoked_at is not null or inv.expires_at<=now() then raise exception 'Davet geçersiz, başka hesaba ait veya süresi dolmuş.';end if;
 select * into old_c from public.clients where user_id=auth.uid() for update;
 if old_c.id is null or old_c.pt_id is null or old_c.pt_id=inv.pt_id or old_c.archived then raise exception 'Mevcut PT bağlantısı geçişe uygun değil.';end if;
 select full_name into pt_name from public.profiles where id=inv.pt_id and role='pt';
 if pt_name is null or exists(select 1 from piti_private.account_controls where user_id=inv.pt_id and (suspended or archived)) then raise exception 'Yeni PT hesabı aktif değil.';end if;
 select full_name into old_name from public.profiles where id=old_c.pt_id;
 select coalesce(data,'{}') into hist from public.client_history where client_id=old_c.id;
 hist=coalesce(hist,'{}');
 select count(*) into future_count from public.sessions where client_id=old_c.id and status='planned' and starts_at>=now();
 -- Preview is invalidated by changed client/history/session details.
 select md5(to_jsonb(old_c)::text||hist::text||coalesce((select jsonb_agg(to_jsonb(s) order by s.id)::text from public.sessions s where s.client_id=old_c.id),'[]')) into fingerprint;
 if p_action='preview' then
  return jsonb_build_object('old_pt',old_name,'new_pt',pt_name,'old_client_id',old_c.id,'fingerprint',fingerprint,'future_sessions',future_count,'package',hist->'package','payment',hist->'payment');
 end if;
 if p_args->>'fingerprint' is distinct from fingerprint or (p_args->>'old_client_id')::uuid is distinct from old_c.id then raise exception 'Bilgiler değişmiş. Geçiş özetini yeniden aç.';end if;
 if coalesce((p_args->>'confirmed')::boolean,false) is not true then raise exception 'Geçişi açıkça onayla.';end if;
 share_weights=coalesce((p_args->>'share_measurements')::boolean,false);
 -- Cancel future appointments only after the member explicitly approves the summary.
 update public.sessions set status='cancelled',counts_against_package=false,updated_at=now() where client_id=old_c.id and status='planned' and starts_at>=now();
 select jsonb_build_object('trainer',old_name,'client',to_jsonb(old_c),'history',hist,
  'sessions',(select coalesce(jsonb_agg(to_jsonb(t) order by starts_at),'[]') from public.sessions t where client_id=old_c.id),
  'messages',(select coalesce(jsonb_agg(to_jsonb(t) order by created_at),'[]') from public.messages t where client_id=old_c.id),
  'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by created_at),'[]') from public.tasks t where client_id=old_c.id),
  'packages',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.packages t where client_id=old_c.id),
  'payments',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.payments t where client_id=old_c.id)) into snapshot;
 weights=coalesce(hist->'progressData','[]');
 weights=weights||coalesce((select jsonb_agg(jsonb_build_object('date',(completed_at at time zone 'Europe/Istanbul')::date,'w',result::numeric,'taskId',id)) from public.tasks where client_id=old_c.id and status='done' and response_type='kg' and result ~ '^[0-9]+([.][0-9]+)?$'),'[]');
 snapshot=snapshot||jsonb_build_object('measurements',weights);
 update public.clients set user_id=null,archived=true,relationship_ended_at=now(),updated_at=now() where id=old_c.id;
 insert into public.clients(user_id,pt_id,full_name,phone,email,blood_type,gender,weight,height)
 values(auth.uid(),inv.pt_id,old_c.full_name,old_c.phone,old_c.email,null,null,case when share_weights then old_c.weight else null end,null) returning id into new_id;
 insert into public.client_history(client_id,data) values(new_id,jsonb_build_object('progressData',case when share_weights then weights else '[]'::jsonb end));
 -- Invalidate the member's old snapshot; stale tabs cannot restore the old client.
 delete from public.account_state where user_id=auth.uid();
 insert into public.trainer_transfers(member_id,old_client_id,new_client_id,old_pt_id,new_pt_id,measurements_shared,snapshot)
 values(auth.uid(),old_c.id,new_id,old_c.pt_id,inv.pt_id,share_weights,snapshot) returning id into receipt_id;
 update piti_private.transfer_invitations set used_at=now() where id=inv.id;
 update piti_private.transfer_invitations set revoked_at=now() where member_id=auth.uid() and id<>inv.id and used_at is null and revoked_at is null;
 insert into public.transfer_notifications(recipient_id,body) values
 (old_c.pt_id,old_c.full_name||' başka bir PT’ye geçti. İlişkiniz kapatıldı; geçmiş kayıtlarınız arşivde korundu. İleri tarihli planlı seanslar iptal edildi.'),
 (inv.pt_id,old_c.full_name||' PT geçişini onayladı. Yeni müşteri ilişkiniz başladı.'),
 (auth.uid(),'PT geçişin tamamlandı. Yeni PT: '||pt_name||'. Eski geçmişini PT’im ekranından açabilirsin.');
 return jsonb_build_object('client_id',new_id,'receipt_id',receipt_id);
end $$;
create function public.trainer_transfer(p_action text,p_args jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select piti_private.trainer_transfer(p_action,p_args)$$;
revoke all on function public.trainer_transfer(text,jsonb),piti_private.trainer_transfer(text,jsonb) from public,anon;
grant execute on function public.trainer_transfer(text,jsonb),piti_private.trainer_transfer(text,jsonb) to authenticated;


-- Source migration: 20260920114548 permanent_session_deletion

-- Permanent session deletion with private recovery record and stale-write guard.
create table if not exists piti_private.deleted_sessions (
 session_id uuid primary key,
 pt_id uuid not null,
 client_id uuid not null,
 deleted_at timestamptz not null default now(),
 snapshot jsonb not null
);
alter table piti_private.deleted_sessions enable row level security;
revoke all on piti_private.deleted_sessions from public,anon,authenticated;

create or replace function piti_private.block_deleted_session_insert() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('session-delete:'||new.id::text,0));
 if exists(select 1 from piti_private.deleted_sessions where session_id=new.id) then return null; end if;
 return new;
end $$;
revoke all on function piti_private.block_deleted_session_insert() from public,anon,authenticated;
drop trigger if exists a_block_deleted_session_insert on public.sessions;
create trigger a_block_deleted_session_insert before insert on public.sessions
 for each row execute function piti_private.block_deleted_session_insert();

create or replace function piti_private.prune_deleted_session_snapshot() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if jsonb_typeof(new.data->'events')='array' then
  new.data=jsonb_set(new.data,'{events}',coalesce((select jsonb_agg(e order by n)
   from jsonb_array_elements(new.data->'events') with ordinality as entries(e,n)
   where not (e->>'type'='session' and exists(select 1 from piti_private.deleted_sessions d
    where d.session_id::text=coalesce(e->>'dbId',e->>'id')))),'[]'::jsonb));
 end if;
 return new;
end $$;
revoke all on function piti_private.prune_deleted_session_snapshot() from public,anon,authenticated;
drop trigger if exists a_prune_deleted_session_snapshot on public.account_state;
create trigger a_prune_deleted_session_snapshot before insert or update on public.account_state
 for each row execute function piti_private.prune_deleted_session_snapshot();

create or replace function piti_private.delete_planned_session(p_session_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.sessions; c public.clients;
begin
 if auth.uid() is null or not piti_private.access_ready() or piti_private.account_role()<>'pt' then
  raise exception 'Aktif PT girişi gerekli.' using errcode='42501';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('session-delete:'||p_session_id::text,0));
 if exists(select 1 from piti_private.deleted_sessions where session_id=p_session_id and pt_id=auth.uid()) then
  return jsonb_build_object('id',p_session_id,'deleted',true);
 end if;
 select * into s from public.sessions where id=p_session_id for update;
 if s.id is null or s.pt_id is distinct from auth.uid() then
  raise exception 'Seans bulunamadı veya silme yetkin yok.' using errcode='42501';
 end if;
 select * into c from public.clients where id=s.client_id for share;
 if c.pt_id is distinct from auth.uid() or c.relationship_ended_at is not null or s.status<>'planned' then
  raise exception 'Yalnızca bağlı öğrencinin planlı seansı silinebilir.' using errcode='42501';
 end if;
 insert into piti_private.deleted_sessions(session_id,pt_id,client_id,snapshot)
 values(s.id,s.pt_id,s.client_id,to_jsonb(s));
 delete from public.sessions where id=s.id;
 insert into public.messages(client_id,sender_id,sender_role,body)
 values(s.client_id,auth.uid(),'pt',to_char(s.starts_at at time zone 'Europe/Istanbul','DD.MM.YYYY HH24:MI')||' tarihli '||coalesce(s.workout_title,'PT Seansı')||' seansı PT tarafından silindi.');
 return jsonb_build_object('id',s.id,'deleted',true);
end $$;
create or replace function public.delete_planned_session(p_session_id uuid) returns jsonb
language sql security invoker set search_path='' as $$ select piti_private.delete_planned_session(p_session_id); $$;
revoke all on function piti_private.delete_planned_session(uuid),public.delete_planned_session(uuid) from public,anon;
grant execute on function piti_private.delete_planned_session(uuid),public.delete_planned_session(uuid) to authenticated;

create or replace function piti_private.get_deleted_session_ids(p_session_ids uuid[]) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(d.session_id),'[]'::jsonb) from piti_private.deleted_sessions d
 where auth.uid() is not null and piti_private.access_ready() and d.session_id=any(p_session_ids)
 and (d.pt_id=auth.uid() or exists(select 1 from public.clients c where c.id=d.client_id and c.user_id=auth.uid()));
$$;
create or replace function public.get_deleted_session_ids(p_session_ids uuid[]) returns jsonb
language sql security invoker set search_path='' as $$ select piti_private.get_deleted_session_ids(p_session_ids); $$;
revoke all on function piti_private.get_deleted_session_ids(uuid[]),public.get_deleted_session_ids(uuid[]) from public,anon;
grant execute on function piti_private.get_deleted_session_ids(uuid[]),public.get_deleted_session_ids(uuid[]) to authenticated;


-- Source migration: 20260921082550 billable_session_result_and_ledger_preservation

-- Commit a PT session result and its financial history in one transaction.
-- Older application versions do not know this field; their saves must retain it.
create or replace function piti_private.preserve_session_billing() returns trigger
language plpgsql set search_path='' as $$
begin
 if old.data ? 'sessionBilling' and not (new.data ? 'sessionBilling') then
  new.data=jsonb_set(new.data,'{sessionBilling}',old.data->'sessionBilling',true);
 end if;
 return new;
end $$;
revoke all on function piti_private.preserve_session_billing() from public,anon,authenticated;
drop trigger if exists preserve_session_billing on public.client_history;
create trigger preserve_session_billing before update on public.client_history for each row execute function piti_private.preserve_session_billing();

create or replace function piti_private.save_billable_session_result(
 p_session_id uuid,p_status text,p_counts boolean,p_groups text[],p_history jsonb,p_version integer,p_expected_status text
) returns integer language plpgsql security definer set search_path='' as $$
declare s public.sessions; c public.clients; v integer;
begin
 if auth.uid() is null or not piti_private.access_ready() or piti_private.account_role()<>'pt' then
  raise exception 'Aktif PT girişi gerekli.' using errcode='42501';
 end if;
 select * into s from public.sessions where id=p_session_id for update;
 if s.id is null or s.pt_id is distinct from auth.uid() then raise exception 'Seans yetkisi yok.' using errcode='42501'; end if;
 select * into c from public.clients where id=s.client_id for update;
 if c.pt_id is distinct from auth.uid() or c.relationship_ended_at is not null then raise exception 'Aktif öğrenci bağlantısı gerekli.' using errcode='42501'; end if;
 if s.status not in ('planned','completed','no_show') or s.status is distinct from p_expected_status
  or p_status not in ('completed','no_show') or p_status is null or p_counts is null
  or coalesce(s.ends_at,s.starts_at+interval '1 hour')>now() then raise exception 'Seans durumu veya zamanı uygun değil.'; end if;
 if p_status='completed' and not p_counts then raise exception 'Tamamlanan seans ücretlendirilmelidir.'; end if;
 if jsonb_typeof(p_history#>'{sessionBilling,charges}') is distinct from 'array'
  or jsonb_typeof(p_history#>'{sessionBilling,receipts}') is distinct from 'array' then raise exception 'Geçersiz ödeme kaydı.'; end if;
 if exists(select 1 from jsonb_array_elements(p_history#>'{sessionBilling,charges}') e group by e->>'sessionId' having count(*)>1) then raise exception 'Aynı seans iki kez borçlandırılamaz.'; end if;
 -- Version check in save_client_history rolls the entire RPC back on conflict.
 v=piti_private.save_client_history(s.client_id,p_history,p_version);
 update public.sessions set status=p_status,counts_against_package=p_counts,muscle_groups=coalesce(p_groups,'{}'::text[]),updated_at=now() where id=s.id;
 return v;
end $$;
create or replace function public.save_billable_session_result(
 p_session_id uuid,p_status text,p_counts boolean,p_groups text[],p_history jsonb,p_version integer,p_expected_status text
) returns integer language sql security invoker set search_path='' as $$
 select piti_private.save_billable_session_result(p_session_id,p_status,p_counts,p_groups,p_history,p_version,p_expected_status);
$$;
revoke all on function piti_private.save_billable_session_result(uuid,text,boolean,text[],jsonb,integer,text),public.save_billable_session_result(uuid,text,boolean,text[],jsonb,integer,text) from public,anon;
grant execute on function piti_private.save_billable_session_result(uuid,text,boolean,text[],jsonb,integer,text),public.save_billable_session_result(uuid,text,boolean,text[],jsonb,integer,text) to authenticated;


-- Source migration: 20260921115907 chat_read_receipts_and_retention

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


-- Source migration: 20260921134841 admin_shared_about_content

-- Public About copy is shared; writes require the existing ADMIN + MFA guard.
alter table piti_private.system_settings add column about_content jsonb not null default '{"title": "Hakkında", "tagline": "Antrenman yolculuğun, tek bir yerde.", "introHeading": "PiTi nedir?", "intro": "PiTi, kişisel antrenörler (PT) ve öğrencilerinin antrenman sürecini birlikte yönetmesini kolaylaştırır. Seans planlamasını, paket ve ödeme takibini, iletişimi ve gelişim kayıtlarını tek bir yerde buluşturur.", "featuresHeading": "Daha düzenli bir antrenman süreci", "features": "PT’ler müşterilerini ve müsaitliklerini yönetebilir, seans planlayabilir, antrenman sonuçlarını kaydedebilir ve tahsilatlarını takip edebilir. Öğrenciler yaklaşan seanslarını, paket ve ödeme durumlarını görebilir; PT’leriyle mesajlaşabilir ve gelişimlerini izleyebilir.", "summary": "PiTi, günlük takibi kolaylaştırarak antrenmana ve kişisel hedeflere daha fazla zaman ayırmanı sağlar.", "contactHeading": "İletişim", "contactIntro": "Soru, öneri ve geri bildirimlerin için:", "email": "eyardibi@gmail.com", "credit": "Designed by Yardibi Production"}'::jsonb;
alter table piti_private.system_settings add column about_version integer not null default 1;
alter table piti_private.system_settings add column about_updated_at timestamptz not null default now();
create function piti_private.get_about_content() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('content',about_content,'version',about_version,'updated_at',about_updated_at) from piti_private.system_settings where id
$$;
create function public.get_about_content() returns jsonb language sql stable security invoker set search_path='' as $$select piti_private.get_about_content()$$;
revoke all on function piti_private.get_about_content(),public.get_about_content() from public;
grant execute on function piti_private.get_about_content(),public.get_about_content() to anon,authenticated;
grant usage on schema piti_private to anon;
create function piti_private.save_about_content(p_content jsonb,p_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare k text; clean jsonb='{}';
begin
 perform piti_private.require_admin();
 if jsonb_typeof(p_content) is distinct from 'object' or octet_length(p_content::text)>30000 then raise exception 'Geçersiz Hakkında içeriği.';end if;
 foreach k in array array['title','tagline','introHeading','intro','featuresHeading','features','summary','contactHeading','contactIntro','email','credit'] loop
  if jsonb_typeof(p_content->k) is distinct from 'string' or char_length(p_content->>k)>(case when k in ('intro','features','summary') then 5000 else 300 end) then raise exception 'Geçersiz veya çok uzun alan: %',k;end if;
  clean=clean||jsonb_build_object(k,btrim(p_content->>k));
 end loop;
 if clean->>'title'='' then raise exception 'Sayfa başlığı boş olamaz.';end if;
 if clean->>'email'<>'' and clean->>'email' !~ '^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' then raise exception 'Geçerli bir e-posta gir.';end if;
 update piti_private.system_settings set about_content=clean,about_version=about_version+1,about_updated_at=now() where id and about_version=p_version;
 if not found then raise exception 'İçerik başka bir oturumda değişti. Sayfayı yenileyip tekrar düzenle.' using errcode='40001';end if;
 insert into piti_private.admin_audit(actor_id,entity,record_id,action) values(auth.uid(),'about_content','shared','publish');
 return piti_private.get_about_content();
end $$;
create function public.save_about_content(p_content jsonb,p_version integer) returns jsonb language sql security invoker set search_path='' as $$select piti_private.save_about_content(p_content,p_version)$$;
revoke all on function piti_private.save_about_content(jsonb,integer),public.save_about_content(jsonb,integer) from public,anon;
grant execute on function piti_private.save_about_content(jsonb,integer),public.save_about_content(jsonb,integer) to authenticated;


-- Source migration: 20260921170833 chat_media_support

-- PiTi chat media support. Apply to a non-production Supabase project first.
alter table public.messages
  add column if not exists message_type text not null default 'text',
  add column if not exists media_path text,
  add column if not exists media_mime text,
  add column if not exists media_size bigint,
  add column if not exists media_width integer,
  add column if not exists media_height integer,
  add column if not exists media_duration numeric(7,1);

alter table public.messages drop constraint if exists messages_message_type_check;
alter table public.messages add constraint messages_message_type_check
  check (message_type in ('text','image','video','audio'));

alter table public.messages drop constraint if exists messages_content_check;
alter table public.messages add constraint messages_content_check
  check (
    nullif(btrim(body),'') is not null
    or sticker is not null
    or (message_type <> 'text' and media_path is not null)
  );

alter table public.messages drop constraint if exists messages_media_path_check;
alter table public.messages add constraint messages_media_path_check
  check (
    media_path is null
    or media_path like client_id::text || '/' || id::text || '/%'
  );

alter table public.messages drop constraint if exists messages_media_metadata_check;
alter table public.messages add constraint messages_media_metadata_check
  check (
    (message_type = 'text' and media_path is null and media_mime is null and media_size is null)
    or
    (message_type = 'image' and media_path is not null and media_mime = 'image/jpeg'
      and media_size between 1 and 15728640
      and media_width > 0 and media_height > 0
      and greatest(media_width,media_height) <= 1920
      and least(media_width,media_height) <= 1080)
    or
    (message_type = 'video' and media_path is not null
      and media_mime in ('video/mp4','video/webm','video/quicktime')
      and media_size between 1 and 15728640
      and media_duration > 0 and media_duration <= 60.5
      and media_width > 0 and media_height > 0
      and greatest(media_width,media_height) <= 854
      and least(media_width,media_height) <= 480)
    or
    (message_type = 'audio' and media_path is not null
      and media_mime in ('audio/mp4','audio/webm','audio/ogg','audio/mpeg')
      and media_size between 1 and 15728640
      and media_duration > 0 and media_duration <= 180.5
      and media_width is null and media_height is null)
  );

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values (
  'chat-media',
  'chat-media',
  false,
  15728640,
  array['image/jpeg','video/mp4','video/webm','video/quicktime','audio/mp4','audio/webm','audio/ogg','audio/mpeg']
)
on conflict (id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists chat_media_read on storage.objects;
create policy chat_media_read on storage.objects
for select to authenticated
using (
  bucket_id='chat-media'
  and (select piti_private.access_ready())
  and exists (
    select 1 from public.clients c
    where c.id::text=(storage.foldername(name))[1]
      and (
        (c.pt_id=(select auth.uid()) and (select piti_private.account_role())='pt')
        or
        (c.user_id=(select auth.uid()) and c.pt_id is not null and (select piti_private.account_role())='member')
      )
  )
);

drop policy if exists chat_media_insert on storage.objects;
create policy chat_media_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='chat-media'
  and owner_id=(select auth.uid())::text
  and (select piti_private.access_ready())
  and exists (
    select 1 from public.clients c
    where c.id::text=(storage.foldername(name))[1]
      and (
        (c.pt_id=(select auth.uid()) and (select piti_private.account_role())='pt')
        or
        (c.user_id=(select auth.uid()) and c.pt_id is not null and (select piti_private.account_role())='member')
      )
  )
);

drop policy if exists chat_media_delete_own on storage.objects;
create policy chat_media_delete_own on storage.objects
for delete to authenticated
using (
  bucket_id='chat-media'
  and owner_id=(select auth.uid())::text
  and (select piti_private.access_ready())
  and exists (
    select 1 from public.clients c
    where c.id::text=(storage.foldername(name))[1]
      and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid()))
  )
);

comment on column public.messages.message_type is 'text, image, video, or audio';
comment on column public.messages.media_path is 'Private chat-media bucket object path; never a public URL';

-- Match existing column-level grants; recipients can update read_at only.
grant insert(message_type,media_path,media_mime,media_size,media_width,media_height,media_duration) on public.messages to authenticated;
grant select(message_type,media_path,media_mime,media_size,media_width,media_height,media_duration) on public.messages to authenticated;
create or replace function piti_private.guard_message() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='INSERT' then
  if new.sender_id is distinct from auth.uid() and current_user='authenticated' then raise exception 'Mesaj göndereni değiştirilemez.';end if;
  if current_user='authenticated' then new.created_at=now();new.read_at=null;end if;
  new.sender_role=(select role from public.profiles where id=new.sender_id);
  if char_length(coalesce(new.body,''))>4000 or (nullif(trim(new.body),'') is null and new.media_path is null and new.sticker is null) then raise exception 'Mesaj veya medya gerekli.';end if;
  if new.media_path is not null and current_user='authenticated' and not exists(
   select 1 from storage.objects o where o.bucket_id='chat-media' and o.name=new.media_path
    and o.owner_id=auth.uid()::text and (o.metadata->>'size')::bigint=new.media_size
  ) then raise exception 'Medya yüklemesi doğrulanamadı.';end if;
 elsif current_user='authenticated' then
  if (to_jsonb(new)-'read_at') is distinct from (to_jsonb(old)-'read_at') then raise exception 'Mesaj içeriği değiştirilemez.';end if;
  new.read_at=coalesce(old.read_at,now());
 end if;
 return new;
end $$;
-- NULL must never bypass media metadata checks.
alter table public.messages add constraint messages_media_required check (
 message_type='text' or (media_path is not null and media_mime is not null and media_size is not null
 and (message_type='image' or media_duration is not null)
 and (message_type='audio' or (media_width is not null and media_height is not null))));


-- Supplemental schema: session-requests


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


-- Supplemental schema: client-profile-photos

-- Read only profile photos of the caller's current linked clients.

create or replace function piti_private.get_my_client_photos(p_client_id uuid default null)
returns table(client_id uuid, photo text)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 if piti_private.account_role()<>'pt' then raise exception 'PT hesabı gerekli.'; end if;
 return query select c.id,p.avatar_url
 from public.clients c join public.profiles p on p.id=c.user_id and p.role='member'
 where c.pt_id=auth.uid() and c.relationship_ended_at is null
 and (p_client_id is null or c.id=p_client_id);
end $$;
create or replace function public.get_my_client_photos(p_client_id uuid default null)
returns table(client_id uuid, photo text)
language sql stable security invoker set search_path='' as $$
 select * from piti_private.get_my_client_photos(p_client_id);
$$;
revoke all on function piti_private.get_my_client_photos(uuid) from public,anon;
revoke all on function public.get_my_client_photos(uuid) from public,anon;
grant execute on function piti_private.get_my_client_photos(uuid) to authenticated;
grant execute on function public.get_my_client_photos(uuid) to authenticated;


-- Supplemental schema: availability-audience

-- Read only explicitly shared slots from the current PT's existing account state.
-- Unknown/legacy visibility is private. No other account state fields are returned.

create or replace function piti_private.shared_calendar_slots(p_events jsonb,p_client_id text)
returns jsonb language sql immutable security invoker set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
 'id','pt-slot-'||(e->>'id'),'sourceSlotId',e->>'id','date',e->>'date','time',e->>'time','endTime',e->>'endTime',
 'type',case when e->>'type'='availability' or (e->>'type' is null and e->>'status'='open') then 'availability' else 'off' end,
 'status',case when e->>'type'='availability' or (e->>'type' is null and e->>'status'='open') then 'open' else 'off' end,
 'title',case when e->>'type'='availability' or (e->>'type' is null and e->>'status'='open') then 'Müsait' else 'PT müsait değil' end,
 'createdBy','pt','sharedTrainerAvailability',true,'visibility','all')), '[]'::jsonb)
 from jsonb_array_elements(case when jsonb_typeof(p_events)='array' then p_events else '[]'::jsonb end) e
 where (e->>'customerId') is null and (e->>'type' in ('availability','off','closed','excused') or (e->>'type' is null and e->>'status' in ('open','off')))
 and coalesce(e->>'status','')<>'cancelled'
 and ((e->>'visibility' in ('all','Tüm müşteriler görebilir')) or
 (e->>'visibility' in ('selected','Seçili müşteriler görebilir') and
 case when jsonb_typeof(e->'visibleCustomerIds')='array' then (e->'visibleCustomerIds') ? p_client_id else false end));
$$;
create or replace function piti_private.get_my_trainer_availability()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 if piti_private.account_role()<>'member' then raise exception 'Müşteri hesabı gerekli.'; end if;
 select piti_private.shared_calendar_slots(s.data->'events',c.id::text) into result
 from public.clients c join public.profiles p on p.id=c.pt_id and p.role='pt'
 join public.account_state s on s.user_id=c.pt_id
 where c.user_id=auth.uid() and not coalesce(c.archived,false) and c.relationship_ended_at is null;
 return coalesce(result,'[]'::jsonb);
end $$;
create or replace function public.get_my_trainer_availability()
returns jsonb language sql stable security invoker set search_path='' as $$
 select piti_private.get_my_trainer_availability();
$$;
revoke all on function piti_private.shared_calendar_slots(jsonb,text) from public,anon,authenticated;
revoke all on function piti_private.get_my_trainer_availability() from public,anon;
revoke all on function public.get_my_trainer_availability() from public,anon;
grant execute on function piti_private.get_my_trainer_availability() to authenticated;
grant execute on function public.get_my_trainer_availability() to authenticated;


-- Supplemental schema: trainer-card-photo

-- Only the authenticated member's current linked trainer is returned.
create or replace function piti_private.get_my_trainer() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 if piti_private.account_role()<>'member' then return null; end if;
 select jsonb_build_object('client_id',c.id,'id',p.id,'name',p.full_name,'photo',p.avatar_url) into result
 from public.clients c join public.profiles p on p.id=c.pt_id and p.role='pt'
 where c.user_id=auth.uid();
 return result;
end $$;
revoke all on function piti_private.get_my_trainer() from public,anon;
grant execute on function piti_private.get_my_trainer() to authenticated;


-- iOS schema: 20260921174149_ios_push_foundation.sql

-- Staging first. This migration is deliberately OFF until an operator verifies
-- the database, app topic, APNs secrets and the scheduler. Never enable on DEMO.

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


-- iOS schema: 20260921183640_push_notification_preferences.sql


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


-- iOS schema: 20260921185333_account_deletion_requests.sql


-- Initiation only. Keep OFF until the purge worker, retention policy and restore
-- checks are implemented and verified. This migration deletes no user data.
create table piti_private.account_deletion_settings (
 id boolean primary key default true check(id),
 enabled boolean not null default false,
 worker_ready boolean not null default false,
 policy_version text not null default '',
 notice text not null default '',
 max_hours integer check(max_hours between 1 and 720)
);
insert into piti_private.account_deletion_settings(id) values(true);
create table piti_private.account_deletion_requests (
 id uuid primary key,
 user_id uuid unique references auth.users(id) on delete set null,
 role text not null check(role in ('pt','member')),
 receipt_hash text not null check(receipt_hash ~ '^[a-f0-9]{64}$'),
 policy_version text not null,
 state text not null default 'requested' check(state in ('requested','processing','needs_attention','completed')),
 requested_at timestamptz not null default now(),
 deadline_at timestamptz not null,
 completed_at timestamptz,
 check(state<>'completed' or (completed_at is not null and user_id is null))
);
alter table piti_private.account_deletion_settings enable row level security;
alter table piti_private.account_deletion_requests enable row level security;
revoke all on piti_private.account_deletion_settings,piti_private.account_deletion_requests from public,anon,authenticated;

create function piti_private.deletion_summary(p_user uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('role',p.role,'linked_clients',(select count(*) from public.clients c where c.pt_id=p.id and c.user_id is not null),
 'client_records',(select count(*) from public.clients c where c.pt_id=p.id or c.user_id=p.id),
 'past_transfers',(select count(*) from public.trainer_transfers t where t.member_id=p.id or t.old_pt_id=p.id or t.new_pt_id=p.id))
 from public.profiles p where p.id=p_user
$$;
revoke all on function piti_private.deletion_summary(uuid) from public,anon,authenticated;

create function piti_private.account_deletion_preview() returns jsonb
language plpgsql security definer set search_path='' as $$
declare cfg piti_private.account_deletion_settings; summary jsonb; request jsonb; allowed boolean;
begin
 if auth.uid() is null or not coalesce(piti_private.access_ready(),false) then raise exception 'Aktif oturum gerekli.' using errcode='42501'; end if;
 select * into strict cfg from piti_private.account_deletion_settings where id;
 summary=piti_private.deletion_summary(auth.uid());
 if summary is null then raise exception 'Hesap bulunamadı.'; end if;
 -- Admin removal also needs an MFA/ownership succession flow, not password-only.
 allowed=cfg.enabled and cfg.worker_ready and cfg.max_hours is not null and length(cfg.notice)>0 and length(cfg.policy_version)>0
 and not exists(select 1 from piti_private.admin_users where user_id=auth.uid());
 select jsonb_build_object('id',id,'state',state,'requested_at',requested_at,'deadline_at',deadline_at,'completed_at',completed_at)
 into request from piti_private.account_deletion_requests where user_id=auth.uid();
 return jsonb_build_object('available',allowed,'summary',summary,'notice',cfg.notice,'max_hours',cfg.max_hours,
 'fingerprint',md5(summary::text||cfg.policy_version||cfg.notice||coalesce(cfg.max_hours::text,'')),'request',request);
end $$;
create function public.account_deletion_preview() returns jsonb
language sql security invoker set search_path='' as $$select piti_private.account_deletion_preview()$$;
revoke all on function public.account_deletion_preview(),piti_private.account_deletion_preview() from public,anon;
grant execute on function public.account_deletion_preview(),piti_private.account_deletion_preview() to authenticated;

-- Only the Edge Function can submit after verifying the current password.
-- Session and account state are checked again here to close a revocation race.
create function piti_private.account_deletion_request(p_user uuid,p_session uuid,p_id uuid,p_receipt_hash text,p_fingerprint text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare cfg piti_private.account_deletion_settings; summary jsonb; job piti_private.account_deletion_requests;
begin
 if p_user is null or p_session is null or p_id is null or p_receipt_hash is null or p_receipt_hash !~ '^[a-f0-9]{64}$' then raise exception 'Geçersiz talep.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_user::text,9951));
 if not exists(select 1 from auth.sessions s join public.profiles p on p.id=s.user_id
  where s.id=p_session and s.user_id=p_user and (s.not_after is null or s.not_after>now()) and not p.must_change_password)
 or exists(select 1 from piti_private.account_controls where user_id=p_user and (suspended or archived))
 or exists(select 1 from piti_private.admin_users where user_id=p_user) then raise exception 'Geçerli hesap oturumu gerekli.' using errcode='42501'; end if;
 select * into job from piti_private.account_deletion_requests where user_id=p_user;
 if found then
  if job.id=p_id and job.receipt_hash=p_receipt_hash then return jsonb_build_object('id',job.id,'state',job.state,'deadline_at',job.deadline_at); end if;
  raise exception 'Silme talebin zaten var. Durumunu yeniden yükle.';
 end if;
 select * into strict cfg from piti_private.account_deletion_settings where id for share;
 if not cfg.enabled or not cfg.worker_ready or cfg.max_hours is null or cfg.policy_version='' or cfg.notice='' then raise exception 'Hesap silme henüz etkin değil.'; end if;
 summary=piti_private.deletion_summary(p_user);
 if summary is null or p_fingerprint is distinct from md5(summary::text||cfg.policy_version||cfg.notice||cfg.max_hours::text) then raise exception 'Silme özeti değişti. Yeniden yükle.'; end if;
 insert into piti_private.account_deletion_requests(id,user_id,role,receipt_hash,policy_version,deadline_at)
 values(p_id,p_user,summary->>'role',p_receipt_hash,cfg.policy_version,now()+make_interval(hours=>cfg.max_hours)) returning * into job;
 return jsonb_build_object('id',job.id,'state',job.state,'deadline_at',job.deadline_at);
end $$;
create function piti_private.account_deletion_receipt(p_id uuid,p_receipt_hash text) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('id',id,'state',state,'deadline_at',deadline_at,'completed_at',completed_at)
 from piti_private.account_deletion_requests where id=p_id and receipt_hash=p_receipt_hash
$$;
-- Receipt status needs a definer boundary too; never expose the private table.
alter function piti_private.account_deletion_receipt(uuid,text) security definer;
create function public.account_deletion_request(p_user uuid,p_session uuid,p_id uuid,p_receipt_hash text,p_fingerprint text) returns jsonb
language sql security invoker set search_path='' as $$select piti_private.account_deletion_request(p_user,p_session,p_id,p_receipt_hash,p_fingerprint)$$;
create function public.account_deletion_receipt(p_id uuid,p_receipt_hash text) returns jsonb
language sql security invoker set search_path='' as $$select piti_private.account_deletion_receipt(p_id,p_receipt_hash)$$;
revoke all on function public.account_deletion_request(uuid,uuid,uuid,text,text),piti_private.account_deletion_request(uuid,uuid,uuid,text,text),
 public.account_deletion_receipt(uuid,text),piti_private.account_deletion_receipt(uuid,text) from public,anon,authenticated;
grant usage on schema piti_private to service_role;
grant execute on function public.account_deletion_request(uuid,uuid,uuid,text,text),piti_private.account_deletion_request(uuid,uuid,uuid,text,text),
 public.account_deletion_receipt(uuid,text),piti_private.account_deletion_receipt(uuid,text) to service_role;


-- iOS schema: 20260921190901_member_retained_history.sql


-- Member-owned history survives deletion of the trainer, but not the member.
-- No trainer identity, messages, health measurements, notes or attachments.
create table piti_private.member_retained_history (
 id uuid primary key default gen_random_uuid(),
 member_id uuid not null references auth.users(id) on delete cascade,
 deletion_id uuid not null references piti_private.account_deletion_requests(id),
 source_client_id uuid not null,
 archived_at timestamptz not null default now(),
 snapshot jsonb not null,
 unique(deletion_id,source_client_id,member_id)
);
create index member_retained_history_owner on piti_private.member_retained_history(member_id,archived_at desc);
alter table piti_private.member_retained_history enable row level security;
revoke all on piti_private.member_retained_history from public,anon,authenticated;

create function piti_private.history_fields(p_data jsonb,p_keys text[]) returns jsonb
language sql immutable set search_path='' as $$
 select coalesce(jsonb_object_agg(key,value),'{}'::jsonb)
 from jsonb_each(case when jsonb_typeof(p_data)='object' then p_data else '{}'::jsonb end)
 where key=any(p_keys) and jsonb_typeof(value) in ('string','number','boolean','null')
$$;
create function piti_private.retained_snapshot(p_data jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare result jsonb='{}'; k text; keys text[]; items jsonb; entries jsonb;
begin
 foreach k in array array['sessions','packages','payments','financeHistory','charges','receipts','previousPackages','previousPayments'] loop
  keys=case k
   when 'sessions' then array['starts_at','ends_at','status','workout_title','counts_against_package']
   when 'packages' then array['name','price','total_sessions','start_date','expiry_date','status']
   when 'payments' then array['amount','method','status','paid_at','created_at']
   when 'charges' then array['id','date','amount','createdAt','voided']
   when 'receipts' then array['chargeId','amount','date','method','recordedAt']
   when 'previousPackages' then array['name','price','totalSessions','usedSessions','start','end','expireDate','status','billingType']
   when 'previousPayments' then array['amount','receivedAmount','method','status','submittedAt','paidAt']
   else array['date','createdAt','amount','status','type'] end;
  items=case when k='financeHistory' then p_data#>'{history,financeHistory}'
   when k in ('charges','receipts') then p_data#>array['history','sessionBilling',k]
   when k in ('previousPackages','previousPayments') then p_data#>'{history,financeHistory}' else p_data->k end;
  if k in ('previousPackages','previousPayments') then
   select coalesce(jsonb_agg(value->(case k when 'previousPackages' then 'packageSnapshot' else 'paymentSnapshot' end)),'[]'::jsonb) into entries
    from jsonb_array_elements(case when jsonb_typeof(items)='array' then items else '[]'::jsonb end);
   items=entries;
  end if;
  select coalesce(jsonb_agg(piti_private.history_fields(value,keys)),'[]'::jsonb) into items
   from jsonb_array_elements(case when jsonb_typeof(items)='array' then items else '[]'::jsonb end);
  result=result||jsonb_build_object(k,items);
 end loop;
 return result||jsonb_build_object(
  'package',piti_private.history_fields(p_data#>'{history,package}',array['name','price','totalSessions','usedSessions','start','end','expireDate','status','billingType']),
  'payment',piti_private.history_fields(p_data#>'{history,payment}',array['amount','receivedAmount','method','status','date','submittedAt','paidAt']));
end $$;

-- A future cleanup worker calls this BEFORE removing any trainer data. It does
-- not detach clients, delete accounts, or mark a deletion as completed.
create function piti_private.capture_member_retained_history(p_job uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare job piti_private.account_deletion_requests; n integer;
begin
 select * into job from piti_private.account_deletion_requests where id=p_job for update;
 if not found or job.role<>'pt' or job.user_id is null or job.state<>'processing'
 or not exists(select 1 from piti_private.account_controls where user_id=job.user_id and suspended)
 then raise exception 'Dondurulmuş PT silme işi gerekli.' using errcode='42501'; end if;
 -- Include former members using their immutable transfer snapshot, even when
 -- the old client no longer has user_id. Never assign history to the new PT.
 insert into piti_private.member_retained_history(member_id,deletion_id,source_client_id,snapshot)
 select src.member_id,job.id,src.client_id,piti_private.retained_snapshot(src.data)
 from (
  select c.user_id member_id,c.id client_id,jsonb_build_object(
   'sessions',(select jsonb_agg(to_jsonb(s) order by s.starts_at,s.id) from public.sessions s where s.client_id=c.id),
   'packages',(select jsonb_agg(to_jsonb(p) order by p.id) from public.packages p where p.client_id=c.id),
   'payments',(select jsonb_agg(to_jsonb(p) order by p.id) from public.payments p where p.client_id=c.id),
   'history',h.data) data
  from public.clients c left join public.client_history h on h.client_id=c.id
  where c.pt_id=job.user_id and c.user_id is not null
  union all
  select t.member_id,t.old_client_id,t.snapshot from public.trainer_transfers t where t.old_pt_id=job.user_id
 ) src join auth.users u on u.id=src.member_id
 where src.member_id<>job.user_id
 on conflict(deletion_id,source_client_id,member_id) do nothing;
 get diagnostics n=row_count;
 return n;
end $$;
create function public.member_retained_history() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(piti_private.access_ready(),false) then raise exception 'Aktif oturum gerekli.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'archived_at',archived_at,'snapshot',snapshot) order by archived_at desc,id)
 from piti_private.member_retained_history where member_id=auth.uid()),'[]'::jsonb);
end $$;
revoke all on function piti_private.history_fields(jsonb,text[]),piti_private.retained_snapshot(jsonb),piti_private.capture_member_retained_history(uuid) from public,anon,authenticated;
grant execute on function piti_private.capture_member_retained_history(uuid) to service_role;
revoke all on function public.member_retained_history() from public,anon;
grant execute on function public.member_retained_history() to authenticated;


-- iOS schema: 20260921191842_account_deletion_prepare.sql


-- Preparation only: no Auth user, Storage object or historical row is deleted.
alter table piti_private.account_deletion_requests add column prepared_at timestamptz;
alter table piti_private.account_deletion_requests add column preparation_result jsonb;
create table piti_private.account_deletion_links (
 deletion_id uuid not null references piti_private.account_deletion_requests(id),
 old_client_id uuid not null,
 member_id uuid references auth.users(id) on delete set null,
 new_client_id uuid references public.clients(id) on delete set null,
 primary key(deletion_id,old_client_id)
);
alter table piti_private.account_deletion_links enable row level security;
revoke all on piti_private.account_deletion_links from public,anon,authenticated;

-- Prevent a stale invitation or in-flight create from attaching to a deleting PT
-- after preparation commits. Closing an existing relationship remains allowed.
create function piti_private.guard_deleting_trainer_link() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' or new.pt_id is distinct from old.pt_id or new.user_id is distinct from old.user_id then
  if new.pt_id is not null and new.relationship_ended_at is null
   and exists(select 1 from piti_private.account_deletion_requests where user_id=new.pt_id and state in ('processing','needs_attention','completed'))
  then raise exception 'Bu PT hesabı silinme sürecinde. Başka bir PT seç.' using errcode='42501'; end if;
 end if;
 return new;
end $$;
revoke all on function piti_private.guard_deleting_trainer_link() from public,anon,authenticated;
create trigger guard_deleting_trainer_link before insert or update on public.clients
 for each row execute function piti_private.guard_deleting_trainer_link();

create function piti_private.prepare_trainer_deletion(p_job uuid) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='2s' as $$
declare job piti_private.account_deletion_requests; cfg piti_private.account_deletion_settings;
 c public.clients; new_id uuid; linked integer=0; retained integer; cancelled integer; result jsonb;
begin
 select * into job from piti_private.account_deletion_requests where id=p_job for update;
 if not found or job.role<>'pt' or job.user_id is null then raise exception 'PT silme işi bulunamadı.'; end if;
 if job.prepared_at is not null then return job.preparation_result; end if;
 select * into strict cfg from piti_private.account_deletion_settings where id for share;
 if not cfg.enabled or not cfg.worker_ready then raise exception 'Hesap silme henüz etkin değil.'; end if;
 if job.state not in ('requested','processing','needs_attention') or
 not exists(select 1 from public.profiles where id=job.user_id and role='pt') or
 exists(select 1 from piti_private.admin_users where user_id=job.user_id)
 then raise exception 'Silme işi hazırlanamıyor.' using errcode='42501'; end if;

 -- Deliberately short, coarse write barrier for the first implementation.
 -- Reads continue. Lock timeout/deadlock aborts the entire transaction for retry.
 -- This includes member writes and legacy snapshot writers, not only PT writes.
 lock table public.clients,public.sessions,public.packages,public.payments,
 public.messages,public.tasks,public.availability,public.client_history,
 public.account_state,public.trainer_transfers in share row exclusive mode;
 update piti_private.account_deletion_requests set state='processing' where id=job.id;
 insert into piti_private.account_controls(user_id,suspended) values(job.user_id,true)
 on conflict(user_id) do update set suspended=true;
 update piti_private.push_devices set enabled=false where user_id=job.user_id;
 delete from auth.sessions where user_id=job.user_id;

 -- Cancel future requests/plans while the relationship is still writable.
 update public.sessions s set status='cancelled',counts_against_package=false,updated_at=now()
 from public.clients source where source.id=s.client_id and source.pt_id=job.user_id
 and source.relationship_ended_at is null and s.status in ('planned','requested') and s.starts_at>=now();
 get diagnostics cancelled=row_count;
 perform piti_private.capture_member_retained_history(job.id);
 -- Never detach if even one entitled member's history is missing.
 if exists(
  (select source.user_id,source.id from public.clients source where source.pt_id=job.user_id and source.user_id is not null and source.user_id<>job.user_id
   union select t.member_id,t.old_client_id from public.trainer_transfers t join auth.users u on u.id=t.member_id where t.old_pt_id=job.user_id and t.member_id<>job.user_id)
  except select h.member_id,h.source_client_id from piti_private.member_retained_history h where h.deletion_id=job.id
 ) then raise exception 'Müşteri geçmişi arşivi eksik. İşlem geri alındı.'; end if;
 select count(*) into retained from piti_private.member_retained_history where deletion_id=job.id;

 for c in select * from public.clients where pt_id=job.user_id and relationship_ended_at is null order by id loop
  new_id=null;
  update public.clients set user_id=null,archived=true,relationship_ended_at=now(),updated_at=now() where id=c.id;
  if c.user_id is not null then
   if c.user_id=job.user_id or not exists(select 1 from public.profiles where id=c.user_id and role='member') then raise exception 'Bağlı müşteri hesabının rolü geçersiz.'; end if;
   insert into public.clients(user_id,pt_id,full_name,phone,email,blood_type,gender,weight,height)
   values(c.user_id,null,c.full_name,c.phone,c.email,c.blood_type,c.gender,c.weight,c.height) returning id into new_id;
   -- Empty shell can be linked again without transferring old balances/history.
   delete from public.account_state where user_id=c.user_id;
   update piti_private.transfer_invitations set revoked_at=now() where member_id=c.user_id and used_at is null and revoked_at is null;
   insert into public.transfer_notifications(recipient_id,body)
   values(c.user_id,'PT hesabının silinme işlemi başladı. PT bağlantın sona erdi. Seans ve ödeme geçmişin PT’im ekranındaki arşivde korunuyor.');
   linked=linked+1;
  end if;
  insert into piti_private.account_deletion_links(deletion_id,old_client_id,member_id,new_client_id) values(job.id,c.id,c.user_id,new_id);
 end loop;
 -- Already closed relationships remain immutable. Their archives were captured
 -- through trainer_transfers; their member's current relationship is untouched.
 update public.client_invitations set revoked_at=now() where pt_id=job.user_id and used_at is null and revoked_at is null;
 update piti_private.transfer_invitations set revoked_at=now() where pt_id=job.user_id and used_at is null and revoked_at is null;
 update piti_private.entry_links set revoked_at=now() where revoked_at is null and
 (user_id=job.user_id or client_id in(select id from public.clients where pt_id=job.user_id));
 delete from piti_private.push_deliveries where recipient_id=job.user_id or client_id in(select id from public.clients where pt_id=job.user_id);
 delete from public.account_state where user_id=job.user_id;
 result=jsonb_build_object('state','processing','phase','prepared','detached_members',linked,'retained_histories',retained,'cancelled_sessions',cancelled);
 update piti_private.account_deletion_requests set prepared_at=now(),preparation_result=result where id=job.id;
 return result;
end $$;
create function public.prepare_trainer_deletion(p_job uuid) returns jsonb
language sql security invoker set search_path='' as $$select piti_private.prepare_trainer_deletion(p_job)$$;
revoke all on function public.prepare_trainer_deletion(uuid),piti_private.prepare_trainer_deletion(uuid) from public,anon,authenticated;
grant execute on function public.prepare_trainer_deletion(uuid),piti_private.prepare_trainer_deletion(uuid) to service_role;


-- The separate shared DEMO publication path remains the only writer.
create or replace function public.admin_console(p_action text,p_args jsonb default '{}'::jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
 if p_action in ('demo','demo_versions','save_demo','restore_demo') then
  raise exception 'Shared DEMO administration is unavailable from staging';
 end if;
 return piti_private.admin_console(p_action,p_args);
end $$;
revoke all on function public.admin_console(text,jsonb) from public,anon;
grant execute on function public.admin_console(text,jsonb) to authenticated;
do $$ begin
 if exists(select 1 from staging_demo_before b full join (select md5(data::text) hash,version,updated_at from public.demo_state where id='main') a using(hash,version,updated_at) where a.hash is null or b.hash is null) then
 raise exception 'Shared DEMO snapshot changed'; end if;
end $$;
commit;
