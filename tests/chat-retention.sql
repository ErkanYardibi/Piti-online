-- Synthetic fixtures only. Every change, including auth sessions, is rolled back.
begin;
create temporary table isolation_fixture(k text primary key,id uuid default gen_random_uuid(),sid uuid default gen_random_uuid());
insert into isolation_fixture(k) values ('pt'),('pt2'),('member'),('member2'),('client'),('client2'),('session'),('old_message'),('new_message'),('old_photo'),('new_photo'),('weight');
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

insert into public.messages(id,client_id,sender_id,body,created_at) values
(pg_temp.fixture_id('old_message'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),'old',now()-interval '91 days'),
(pg_temp.fixture_id('new_message'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),'new',now());
insert into public.tasks(id,client_id,pt_id,message_id,title,status,response_type,result,result_photo,created_at,completed_at) values
(pg_temp.fixture_id('old_photo'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),pg_temp.fixture_id('old_message'),'photo','done','photo','Fotoğraf gönderildi','data:image/jpeg;base64,YQ==',now()-interval '91 days',now()-interval '91 days'),
(pg_temp.fixture_id('new_photo'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),pg_temp.fixture_id('new_message'),'photo','done','photo','Fotoğraf gönderildi','data:image/jpeg;base64,YQ==',now(),now()),
(pg_temp.fixture_id('weight'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),null,'weight','done','kg','89.5',null,now()-interval '91 days',now()-interval '91 days');
set local role authenticated;
select pg_temp.login('pt');
select pg_temp.assert_true((public.chat_policy()->>'days')::integer=90,'default retention');
update public.messages set read_at=now() where id=pg_temp.fixture_id('new_message');
select pg_temp.assert_true((select read_at is null from public.messages where id=pg_temp.fixture_id('new_message')),'sender cannot mark own message read');
select pg_temp.login('pt2');
select pg_temp.assert_true((select count(*)=0 from public.messages where id=pg_temp.fixture_id('new_message')),'other PT cannot read');
select pg_temp.login('member');
update public.messages set read_at=now() where id=pg_temp.fixture_id('new_message');
select pg_temp.assert_true((select read_at is not null from public.messages where id=pg_temp.fixture_id('new_message')),'recipient can mark read');
select pg_temp.denied('select public.admin_console(''save_settings'',''{"chat_retention_days":7}'')');
select pg_temp.denied('select piti_private.cleanup_chat_retention()');
reset role;
-- Closed relationships must still expire while normal user edits remain prohibited.
update public.clients set relationship_ended_at=now() where id=pg_temp.fixture_id('client');
select piti_private.cleanup_chat_retention();
select pg_temp.assert_true(not exists(select 1 from public.messages where id=pg_temp.fixture_id('old_message')),'old message physically deleted');
select pg_temp.assert_true(exists(select 1 from public.messages where id=pg_temp.fixture_id('new_message')),'recent message retained');
select pg_temp.assert_true((select result_photo is null and photo_expired_at is not null and message_id is null from public.tasks where id=pg_temp.fixture_id('old_photo')),'photo physically cleared, task preserved');
select pg_temp.assert_true((select result_photo is not null from public.tasks where id=pg_temp.fixture_id('new_photo')),'recent photo retained');
select pg_temp.assert_true((select result='89.5' from public.tasks where id=pg_temp.fixture_id('weight')),'weight retained');
select pg_temp.assert_true(jsonb_array_length(piti_private.prune_chat_json(jsonb_build_object('messages',jsonb_build_array(jsonb_build_object('text','old','created_at',now()-interval '91 days'),jsonb_build_object('text','recent','created_at',now()))),now()-interval '90 days',now())->'messages')=1,'legacy snapshot pruning');
insert into public.account_state(user_id,data) values(pg_temp.fixture_id('pt'),jsonb_build_object('cloudOwner',pg_temp.fixture_id('pt'),'role','pt','customer',jsonb_build_object('id',pg_temp.fixture_id('client'),'dbId',pg_temp.fixture_id('client')),'messages',jsonb_build_array(jsonb_build_object('text','expired snapshot','created_at',now()-interval '91 days'))));
select pg_temp.assert_true((select jsonb_array_length(data->'messages')=0 from public.account_state where user_id=pg_temp.fixture_id('pt')),'stale snapshot cannot resurrect expired message');
insert into piti_private.admin_users(user_id) values(pg_temp.fixture_id('pt2'));
set local role authenticated;
select pg_temp.login('pt2');
select set_config('request.jwt.claims',(current_setting('request.jwt.claims')::jsonb||'{"aal":"aal2"}'::jsonb)::text,true);
select public.admin_console('save_settings','{"chat_retention_days":30}');
select pg_temp.assert_true((public.chat_policy()->>'days')::integer=30,'admin setting roundtrip');
do $$begin begin perform public.admin_console('save_settings','{"chat_retention_days":0}');raise exception 'TEST accepted invalid setting';exception when others then if sqlerrm='TEST accepted invalid setting' then raise;end if;end;end$$;
reset role;
select pg_temp.assert_true((select count(*)=1 from cron.job where jobname='piti-chat-retention' and active),'hourly cleanup scheduled');
rollback;
