-- Minimal disposable test schema, NOT a deployable PiTi database.
create role anon; create role authenticated; create role service_role;
create schema auth; create schema piti_private;
grant usage on schema public,piti_private,auth to authenticated,service_role;
create table auth.users(id uuid primary key);
create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz);
create function auth.jwt() returns jsonb language sql as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
create function auth.uid() returns uuid language sql as $$ select (auth.jwt()->>'sub')::uuid $$;
create table public.profiles(id uuid primary key,must_change_password boolean default false);
create table public.clients(id uuid primary key,pt_id uuid,user_id uuid,archived boolean default false,relationship_ended_at timestamptz);
create table public.messages(id uuid primary key,client_id uuid,sender_id uuid);
create table public.tasks(id uuid primary key,client_id uuid);
create table public.sessions(id uuid primary key,client_id uuid,pt_id uuid,status text,starts_at timestamptz,ends_at timestamptz);
create table public.client_history(client_id uuid primary key,data jsonb,version int);
create table piti_private.account_controls(user_id uuid,suspended boolean default false,archived boolean default false);
create function piti_private.access_ready() returns boolean language sql security definer set search_path='' as $$
 select exists(select 1 from auth.sessions s join public.profiles p on p.id=s.user_id where s.id=(auth.jwt()->>'session_id')::uuid
 and s.user_id=auth.uid() and not p.must_change_password and (s.not_after is null or s.not_after>now()))
 and not exists(select 1 from piti_private.account_controls where user_id=auth.uid() and (suspended or archived)) $$;
