-- Run only in the dedicated DEMO project.
begin;
create table public.demo_state (
 id text primary key check(id='main'), data jsonb not null,
 version integer not null default 1, updated_at timestamptz not null default now()
);
create table public.demo_versions (
 id bigint generated always as identity primary key,
 data jsonb not null, created_at timestamptz not null default now()
);
alter table public.demo_state enable row level security;
alter table public.demo_versions enable row level security;
revoke all on public.demo_state,public.demo_versions from public,anon,authenticated;
grant select on public.demo_state to anon,authenticated;
grant all on public.demo_state,public.demo_versions to service_role;
grant usage,select on sequence public.demo_versions_id_seq to service_role;
create policy demo_public_read on public.demo_state for select to anon,authenticated using(id='main');
create function public.publish_demo(p_action text,p_args jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare snapshot jsonb; current_version integer;
begin
 select version into current_version from public.demo_state where id='main' for update;
 if current_version is distinct from (p_args->>'version')::integer then
  raise exception 'Demo değişmiş. Yeniden yükle.';
 end if;
 if p_action='save_demo' then snapshot=p_args->'data';
 elsif p_action='restore_demo' then select data into snapshot from public.demo_versions where id=(p_args->>'id')::bigint;
 else raise exception 'Geçersiz işlem.';end if;
 if snapshot is null or jsonb_typeof(snapshot)<>'object'
 or jsonb_typeof(snapshot->'events') is distinct from 'array'
 or jsonb_typeof(snapshot->'customer') is distinct from 'object'
 or coalesce(snapshot->>'cloudOwner','')<>''
 or coalesce(snapshot->'customer'->>'id','') not like 'demo-%'
 or octet_length(snapshot::text)>2000000 then raise exception 'Geçersiz demo verisi.';end if;
 insert into public.demo_versions(data) select data from public.demo_state where id='main';
 update public.demo_state set data=snapshot,version=version+1,updated_at=now() where id='main';
 return '{"ok":true}';
end $$;
revoke all on function public.publish_demo(text,jsonb) from public,anon,authenticated;
grant execute on function public.publish_demo(text,jsonb) to service_role;
commit;
