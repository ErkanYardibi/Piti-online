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

update public.clients set archived=true where id=(select id from fixture where k='client');
insert into public.packages(client_id) select id from fixture where k='client';
insert into public.payments(client_id,amount) select id,100 from fixture where k='client';
insert into public.tasks(client_id,title) select id,'Task' from fixture where k='client';
insert into public.availability(client_id,starts_at) select id,now() from fixture where k='client';
insert into public.sessions(client_id,pt_id,starts_at) select id,(select id from fixture where k='pt'),now() from fixture where k='client';
insert into public.client_history(client_id,data) select id,'{"progressData":[{"w":80}]}' from fixture where k='client';
insert into public.messages(client_id,sender_id,body) select id,(select id from fixture where k='pt'),'History' from fixture where k='client';
set local role authenticated;
select pg_temp.login('member');
select pg_temp.expect_error(format('select public.delete_archived_client(%L,''Member'')',(select id from fixture where k='client')),'yalnızca PT');
select pg_temp.login('pt2');
select pg_temp.expect_error(format('select public.delete_archived_client(%L,''Member'')',(select id from fixture where k='client')),'silme yetkin');
select pg_temp.login('pt');
select pg_temp.expect_error(format('delete from public.clients where id=%L',(select id from fixture where k='client')),'permission denied');
select pg_temp.expect_error(format('select public.delete_archived_client(%L,''New member'')',(select id from fixture where k='manual')),'arşive');
select pg_temp.expect_error(format('select public.delete_archived_client(%L,''Wrong Name'')',(select id from fixture where k='client')),'adını aynen');
select public.delete_archived_client((select id from fixture where k='client'),'Member');
select pg_temp.expect_error(format('select public.delete_archived_client(%L,''Member'')',(select id from fixture where k='client')),'silme yetkin');
reset role;
select pg_temp.assert_true(exists(select 1 from auth.users where id=(select id from fixture where k='member')),'login account preserved');
select pg_temp.assert_true(exists(select 1 from public.profiles where id=(select id from fixture where k='member')),'member profile preserved');
select pg_temp.assert_true(exists(select 1 from public.clients where id=(select id from fixture where k='client2')),'other client preserved');
do $$declare t text; n bigint; begin
 foreach t in array array['clients','packages','sessions','payments','tasks','availability','messages','client_history','client_invitations','account_audit'] loop
 execute format('select count(*) from public.%I where %I=$1',t,case when t='clients' then 'id' else 'client_id' end) into n using (select id from fixture where k='client');
 if n<>0 then raise exception 'TEST FAILED: remaining data in %',t; end if;
 end loop;
end$$;
select 'Delete checks passed: ownership, role, archive, confirmation, cascading cleanup, auth account preserved' as result;
rollback;
