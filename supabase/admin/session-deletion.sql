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
