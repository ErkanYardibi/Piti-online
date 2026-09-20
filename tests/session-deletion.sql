-- Synthetic fixtures only. Every change, including auth sessions, is rolled back.
begin;
create temporary table isolation_fixture(k text primary key,id uuid default gen_random_uuid(),sid uuid default gen_random_uuid());
insert into isolation_fixture(k) values ('pt'),('pt2'),('member'),('member2'),('client'),('client2'),('session');
grant select on isolation_fixture to authenticated;
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)
select id,id::text||'@isolation-test.invalid',now(),jsonb_build_object('account_role',case when k like 'pt%' then 'pt' else 'member' end),'{"full_name":"Isolation test"}'
from isolation_fixture where k in ('pt','pt2','member','member2');
insert into auth.sessions(id,user_id,created_at,updated_at)
select sid,id,now(),now() from isolation_fixture where k in ('pt','pt2','member','member2');
insert into public.clients(id,pt_id,user_id,full_name)
select c.id,p.id,m.id,'Isolation fixture' from isolation_fixture c,isolation_fixture p,isolation_fixture m
where (c.k='client' and p.k='pt' and m.k='member') or (c.k='client2' and p.k='pt2' and m.k='member2');
create function pg_temp.fixture_id(key text) returns uuid language sql as $$select id from isolation_fixture where k=key$$;
create function pg_temp.login(key text) returns text language sql as $$select set_config('request.jwt.claims',jsonb_build_object('sub',id,'session_id',sid,'role','authenticated','aal','aal1')::text,true) from isolation_fixture where k=key$$;
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'FAIL: %',label;end if;end$$;
create function pg_temp.denied(q text) returns void language plpgsql as $$begin begin execute q;exception when insufficient_privilege then return;end;raise exception 'FAIL: unauthorized write accepted';end$$;
set local role authenticated;
select pg_temp.login('pt');
select pg_temp.assert_true(piti_private.access_ready(),'fixture session is valid');

insert into public.sessions(id,client_id,pt_id,starts_at,workout_title) values(pg_temp.fixture_id('session'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),now()+interval '1 day','Deletion fixture');
select pg_temp.login('member');
select pg_temp.denied(format('select public.delete_planned_session(%L)',pg_temp.fixture_id('session')));
select pg_temp.login('pt2');
select pg_temp.denied(format('select public.delete_planned_session(%L)',pg_temp.fixture_id('session')));
select pg_temp.login('pt');
update public.sessions set status='completed' where id=pg_temp.fixture_id('session');
select pg_temp.denied(format('select public.delete_planned_session(%L)',pg_temp.fixture_id('session')));
update public.sessions set status='planned' where id=pg_temp.fixture_id('session');
select pg_temp.assert_true((public.delete_planned_session(pg_temp.fixture_id('session'))->>'deleted')::boolean,'PT deletion confirmed');
select pg_temp.assert_true((public.delete_planned_session(pg_temp.fixture_id('session'))->>'deleted')::boolean,'retry idempotent');
select pg_temp.assert_true((select count(*)=0 from public.sessions where id=pg_temp.fixture_id('session')),'PT reload has no session');
insert into public.sessions(id,client_id,pt_id,starts_at) values(pg_temp.fixture_id('session'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),now())
on conflict(id) do update set status='planned';
select pg_temp.assert_true((select count(*)=0 from public.sessions where id=pg_temp.fixture_id('session')),'stale PT upsert cannot resurrect');
insert into public.account_state(user_id,data) values(auth.uid(),jsonb_build_object('isolationVersion',1,'events',jsonb_build_array(jsonb_build_object('id',pg_temp.fixture_id('session'),'type','session','status','planned'),jsonb_build_object('id','keep-slot','type','availability'))))
on conflict(user_id) do update set data=excluded.data;
select pg_temp.assert_true((select jsonb_array_length(data->'events')=1 from public.account_state where user_id=auth.uid()),'snapshot pruned, availability preserved');
select pg_temp.login('member');
select pg_temp.assert_true((select count(*)=0 from public.sessions where id=pg_temp.fixture_id('session')),'student reload has no session');
select pg_temp.assert_true(jsonb_array_length(public.get_deleted_session_ids(array[pg_temp.fixture_id('session')]))=1,'student sees deletion marker');
select pg_temp.assert_true((select count(*)=1 from public.messages where client_id=pg_temp.fixture_id('client') and body like '%Deletion fixture%'),'exactly one student notification');
insert into public.sessions(id,client_id,pt_id,starts_at) values(pg_temp.fixture_id('session'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),now())
on conflict(id) do update set status='planned';
select pg_temp.assert_true((select count(*)=0 from public.sessions where id=pg_temp.fixture_id('session')),'stale member upsert cannot resurrect');
select pg_temp.login('pt2');
select pg_temp.assert_true(jsonb_array_length(public.get_deleted_session_ids(array[pg_temp.fixture_id('session')]))=0,'other tenant cannot see deletion');
reset role;
select pg_temp.assert_true((select count(*)=1 from piti_private.deleted_sessions where session_id=pg_temp.fixture_id('session')),'private recovery record exists');
rollback;
select 'PASS: DB deletion, PT/member reload, stale upserts, snapshot, notification, permissions, idempotency; all fixtures rolled back' as result;
