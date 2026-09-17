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
select pg_temp.login('pt');
select public.assign_chat_task((select id from fixture where k='client'),(select sid from fixture where k='client'),'Su iç','water',now()+interval '1 day','litre',true);
select pg_temp.assert_true((select count(*)=1 from public.tasks where message_id=(select sid from fixture where k='client')),'task created with message');
select public.assign_chat_task((select id from fixture where k='client'),(select sid from fixture where k='client'),'Su iç','water',now()+interval '1 day','litre',true);
select pg_temp.assert_true((select count(*)=1 from public.tasks where message_id=(select sid from fixture where k='client')),'retry is idempotent');
select pg_temp.expect_error(format('select public.assign_chat_task(%L,gen_random_uuid(),''Bad'',''water'',now()-interval ''1 day'',''done'',true)',(select id from fixture where k='client')),'Gelecekte');
select pg_temp.assert_true((select count(*)=0 from public.messages where body='Bad'),'invalid task rolls back message');
insert into public.messages(id,client_id,sender_id,body) select id,(select id from fixture where k='client'),auth.uid(),'Tartıl' from fixture where k='manual';
select public.assign_chat_task((select id from fixture where k='client'),(select id from fixture where k='manual'),null,null,now()+interval '1 day','kg',false);
select pg_temp.assert_true((select count(*)=2 from public.tasks),'existing message converted');
select pg_temp.expect_error(format('select public.assign_chat_task(%L,gen_random_uuid(),''Other client'',null,now()+interval ''1 day'',''done'',true)',(select id from fixture where k='client2')),'row-level security');
select pg_temp.login('member2');
select pg_temp.assert_true((select count(*)=0 from public.tasks),'other member sees no tasks');
select pg_temp.login('pt2');
select pg_temp.assert_true((select count(*)=0 from public.tasks),'other PT sees no tasks');
select pg_temp.login('member');
select pg_temp.expect_error(format('select public.assign_chat_task(%L,gen_random_uuid(),''Fake'',null,now()+interval ''1 day'',''done'',true)',(select id from fixture where k='client')),'PT hesabı');
select pg_temp.expect_error('update public.tasks set title=''changed''','permission denied');
select pg_temp.expect_error('update public.tasks set status=''done'',result=''-1'' where response_type=''litre''','Geçerli');
update public.tasks set status='done',result='2.5' where response_type='litre';
select pg_temp.assert_true((select status='done' and result='2.5' and completed_at is not null from public.tasks where response_type='litre'),'member completion stored');
select pg_temp.expect_error('update public.tasks set status=''done'',result=''3'' where response_type=''litre''','zaten tamamlandı');
select pg_temp.login('pt');
select pg_temp.assert_true((select status='done' and result='2.5' from public.tasks where response_type='litre'),'PT sees completion');
select public.assign_chat_task((select id from fixture where k='client'),gen_random_uuid(),'Öğün','meal',now()+interval '1 day','photo',true);
select pg_temp.login('member');
select pg_temp.expect_error('update public.tasks set status=''done'' where response_type=''photo''','Fotoğraf ekle');
update public.tasks set status='done',result_photo='data:image/jpeg;base64,/9j/2Q==' where response_type='photo';
select pg_temp.assert_true((select result_photo is not null and status='done' from public.tasks where response_type='photo'),'photo completion stored');
select 'PASS: atomic assignment, retry, conversion, isolation, validation, immutable assignment, numeric/photo completion' as result;
rollback;
