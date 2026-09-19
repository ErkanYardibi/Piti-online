-- Free-plan application-data recovery copies, in the SAME production database.
-- Not an Auth/Storage/schema backup and not off-site disaster recovery.
begin;
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
select cron.schedule('piti-daily-recovery','15 0 * * *','select piti_private.capture_recovery_copy();');
commit;
