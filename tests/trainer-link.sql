-- Real RLS/service RPC integration assertions; every fixture is rolled back.
begin;
create temporary table fixture(k text primary key,id uuid default gen_random_uuid(),sid uuid default gen_random_uuid(),op uuid);
insert into fixture(k) values('pt'),('pt2'),('member'),('member2'),('new_member'),('client'),('client2'),('manual');
grant all on fixture to authenticated,service_role;
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,encrypted_password)
select id,k||'@managed-test.invalid',now(),jsonb_build_object('account_role',case when k in ('pt','pt2') then 'pt' else 'member' end,'must_change_password',k='new_member'),'{"full_name":"Test user"}',extensions.crypt('TemporaryTest!1234',extensions.gen_salt('bf'))
from fixture where k in ('pt','pt2','member','member2','new_member');
insert into auth.sessions(id,user_id,created_at,updated_at) select sid,id,now(),now() from fixture where k in ('pt','pt2','member','member2','new_member');
insert into public.clients(id,pt_id,user_id,full_name,email)
values((select id from fixture where k='client'),(select id from fixture where k='pt'),(select id from fixture where k='member'),'Member','member@managed-test.invalid'),
((select id from fixture where k='client2'),(select id from fixture where k='pt2'),(select id from fixture where k='member2'),'Member 2','member2@managed-test.invalid'),
((select id from fixture where k='manual'),(select id from fixture where k='pt'),null,'New member','new_member@managed-test.invalid');
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'TEST FAILED: %',label; end if; end$$;
create function pg_temp.expect_error(q text,needle text) returns void language plpgsql as $$begin begin execute q; exception when others then if position(needle in sqlerrm)>0 then return; end if; raise; end; raise exception 'TEST FAILED: expected error %',needle; end$$;
create function pg_temp.login(k text) returns text language sql as $$select set_config('request.jwt.claims',jsonb_build_object('sub',id,'session_id',sid,'role','authenticated')::text,true) from fixture where fixture.k=login.k$$;

set local role authenticated;
select pg_temp.login('member');
select pg_temp.assert_true((public.get_my_trainer()->>'id')::uuid=(select id from fixture where k='pt'),'member sees own trainer');
select pg_temp.assert_true((public.get_my_trainer()->>'client_id')::uuid=(select id from fixture where k='client'),'own client only');
select pg_temp.login('member2');
select pg_temp.assert_true((public.get_my_trainer()->>'id')::uuid=(select id from fixture where k='pt2'),'other member sees only other trainer');
select pg_temp.login('pt');
select pg_temp.assert_true(public.get_my_trainer() is null,'PT cannot enumerate member links');
reset role;
update public.clients set pt_id=null where id=(select id from fixture where k='client');
set local role authenticated;
select pg_temp.login('member');
select pg_temp.assert_true(public.get_my_trainer() is null,'unlinked member gets no trainer');
reset role;
select pg_temp.assert_true(not has_function_privilege('anon','public.get_my_trainer()','execute'),'anonymous access denied');
select 'PASS: trainer summary isolation, linked and unlinked accounts, anonymous denial' as result;
rollback;
