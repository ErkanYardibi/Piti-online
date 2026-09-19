-- Dedicated DEMO project only. Publish/restore rehearsal rolls back all changes.
begin;
create temporary table expected_demo as select data,version from public.demo_state where id='main';
set local role anon;
do $$begin
 if (select count(*) from public.demo_state)<>1 then raise exception 'Public fixture unavailable';end if;
 begin update public.demo_state set version=999;raise exception 'Public write accepted';exception when insufficient_privilege then null;end;
 begin perform public.publish_demo('save_demo','{}');raise exception 'Public RPC accepted';exception when insufficient_privilege then null;end;
end $$;
reset role;
select public.publish_demo('save_demo',jsonb_build_object('version',version,'data',data||'{"restoreTest":true}')) from public.demo_state where id='main';
do $$begin
 begin perform public.publish_demo('save_demo',jsonb_build_object('version',-1,'data','{}'::jsonb));raise exception 'Version conflict accepted';
 exception when raise_exception then if sqlerrm='Version conflict accepted' then raise;end if;end;
end $$;
select public.publish_demo('restore_demo',jsonb_build_object('version',version,'id',(select max(id) from public.demo_versions))) from public.demo_state where id='main';
do $$begin
 if (select data from public.demo_state where id='main') is distinct from (select data from expected_demo) then raise exception 'Restore mismatch';end if;
 if (select version from public.demo_state where id='main')<>(select version+2 from expected_demo) then raise exception 'Version mismatch';end if;
end $$;
select 'PASS: public read, denied public writes/RPC, publish, version conflict, exact restore' result;
rollback;
