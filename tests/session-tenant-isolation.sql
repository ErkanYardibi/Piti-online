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
insert into public.sessions(id,client_id,pt_id,starts_at) values(pg_temp.fixture_id('session'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),now());
select pg_temp.denied(format('insert into public.sessions(client_id,pt_id,starts_at) values(%L,%L,now())',pg_temp.fixture_id('client2'),pg_temp.fixture_id('pt')));
select pg_temp.denied(format('update public.sessions set client_id=%L where id=%L',pg_temp.fixture_id('client2'),pg_temp.fixture_id('session')));
insert into public.account_state(user_id,data) values(auth.uid(),'{"isolationVersion":1}');
select pg_temp.denied(format('insert into public.account_state(user_id,data) values(%L,''{}'')',pg_temp.fixture_id('pt2')));
select pg_temp.login('pt2');
select pg_temp.assert_true((select count(*)=0 from public.sessions where id=pg_temp.fixture_id('session')),'other PT cannot read session');
select pg_temp.assert_true((select count(*)=0 from public.account_state where user_id=pg_temp.fixture_id('pt')),'other PT cannot read account snapshot');
with changed as (update public.sessions set notes='forbidden' where id=pg_temp.fixture_id('session') returning id)
select pg_temp.assert_true(count(*)=0,'other PT cannot update session') from changed;
select pg_temp.login('member');
select pg_temp.assert_true((select count(*)=1 from public.sessions where id=pg_temp.fixture_id('session')),'linked member can read session');
update public.sessions set muscle_groups=array['back','legs'] where id=pg_temp.fixture_id('session');
select pg_temp.denied(format('update public.sessions set pt_id=%L where id=%L',pg_temp.fixture_id('pt2'),pg_temp.fixture_id('session')));
select pg_temp.login('member2');
select pg_temp.assert_true((select count(*)=0 from public.sessions where id=pg_temp.fixture_id('session')),'other member cannot read session');
select pg_temp.login('pt');
select pg_temp.assert_true((select muscle_groups=array['back','legs'] from public.sessions where id=pg_temp.fixture_id('session')),'legitimate member edit preserved');
reset role;
delete from auth.sessions where id=(select sid from isolation_fixture where k='pt');
set local role authenticated;
select pg_temp.assert_true(not piti_private.access_ready(),'revoked session rejected');
select pg_temp.assert_true((select count(*)=0 from public.sessions where id=pg_temp.fixture_id('session')),'revoked session cannot read');
select 'PASS: session tenant isolation, account snapshots, member edit, revoked session' as result;
rollback;
