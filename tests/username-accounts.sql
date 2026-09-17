-- Real RLS/service RPC integration assertions; every fixture is rolled back.
begin;
create temporary table fixture(k text primary key,id uuid default gen_random_uuid(),sid uuid default gen_random_uuid(),op uuid);
insert into fixture(k) values('pt'),('pt2'),('member'),('member2'),('new_member'),('client'),('client2'),('manual');
grant all on fixture to authenticated,service_role;
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,encrypted_password)
select id,k||'@managed-test.invalid',now(),jsonb_build_object('account_role',case when k in ('pt','pt2') then 'pt' else 'member' end,'must_change_password',k='new_member','username',case when k='member' then 'Müşteri1' else null end),'{"full_name":"Test user"}',extensions.crypt('TemporaryTest!1234',extensions.gen_salt('bf'))
from fixture where k in ('pt','pt2','member','member2','new_member');
insert into auth.sessions(id,user_id,created_at,updated_at) select sid,id,now(),now() from fixture where k in ('pt','pt2','member','member2','new_member');
insert into public.clients(id,pt_id,user_id,full_name,email)
values((select id from fixture where k='client'),(select id from fixture where k='pt'),(select id from fixture where k='member'),'Member','member@managed-test.invalid'),
((select id from fixture where k='client2'),(select id from fixture where k='pt2'),(select id from fixture where k='member2'),'Member 2','member2@managed-test.invalid'),
((select id from fixture where k='manual'),(select id from fixture where k='pt'),null,'New member','new_member@managed-test.invalid');
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'TEST FAILED: %',label; end if; end$$;
create function pg_temp.expect_error(q text,needle text) returns void language plpgsql as $$begin begin execute q; exception when others then if position(needle in sqlerrm)>0 then return; end if; raise; end; raise exception 'TEST FAILED: expected error %',needle; end$$;
create function pg_temp.login(k text) returns text language sql as $$select set_config('request.jwt.claims',jsonb_build_object('sub',id,'session_id',sid,'role','authenticated')::text,true) from fixture where fixture.k=login.k$$;

select pg_temp.assert_true((select username='musteri1' from public.profiles where id=(select id from fixture where k='member')),'username normalized on create');
set local role authenticated;
select pg_temp.login('pt');
select public.set_own_username('Koç1');
select pg_temp.assert_true((select username='koc1' from public.profiles where id=auth.uid()),'own PT username');
select pg_temp.expect_error('select public.set_own_username(''MUSTERI1'')','alınmış');
select pg_temp.expect_error('update public.profiles set username=''changed'' where id=auth.uid()','hesap ayarlarından');
select pg_temp.expect_error('select public.username_login_lookup(''musteri1'')','permission denied');
select pg_temp.login('member');
select public.set_own_username('MÜŞTERİ1');
select pg_temp.assert_true((select username='musteri1' from public.profiles where id=auth.uid()),'case insensitive same username');
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select pg_temp.assert_true(public.username_login_lookup('MÜŞTERİ1')='member@managed-test.invalid','server resolves username');
select pg_temp.assert_true(public.username_login_lookup('absent_user') is null,'unknown username no disclosure');
do $$begin for i in 1..20 loop perform public.username_login_lookup('musteri1'); end loop; end$$;
select pg_temp.assert_true(public.username_login_lookup('musteri1') is null,'login rate bounded');
reset role;
-- Email-less account linking uses trusted operation metadata, never editable user metadata.
update public.clients set email=null where id=(select id from fixture where k='manual');
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
update fixture set op=(public.managed_account_begin((select id from fixture where k='pt'),id,'create')->>'operation_id')::uuid where k='manual';
reset role;
update auth.users set raw_app_meta_data=raw_app_meta_data||jsonb_build_object('username','lateusername','managed_client_id',(select id from fixture where k='manual'),'managed_operation_id',(select op from fixture where k='manual')) where id=(select id from fixture where k='new_member');
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select public.managed_account_finish((select op from fixture where k='manual'),(select id from fixture where k='new_member'),repeat('d',64));
reset role;
select pg_temp.assert_true((select user_id=(select id from fixture where k='new_member') and email is null from public.clients where id=(select id from fixture where k='manual')),'email-less client linked');
select pg_temp.assert_true((select username='lateusername' from public.profiles where id=(select id from fixture where k='new_member')),'Auth metadata arriving after insert is finalized');
select 'PASS: normalization, uniqueness, role restrictions, private lookup, rate limit, email-less linking' as result;
rollback;
