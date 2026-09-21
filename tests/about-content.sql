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

set local role anon;
select pg_temp.assert_true(public.get_about_content() ? 'content','all users can read published copy');
select pg_temp.assert_true(not (public.get_about_content() ? 'registration_open'),'private settings not exposed');
reset role;
insert into piti_private.admin_users(user_id) values(pg_temp.fixture_id('pt2'));
set local role authenticated;
select pg_temp.login('pt');
select pg_temp.denied('select public.save_about_content((public.get_about_content()->''content''),1)');
select pg_temp.login('member');
select pg_temp.denied('select public.save_about_content((public.get_about_content()->''content''),1)');
select pg_temp.login('pt2');
select pg_temp.denied('select public.save_about_content((public.get_about_content()->''content''),1)');
select set_config('request.jwt.claims',(current_setting('request.jwt.claims')::jsonb||'{"aal":"aal2"}')::text,true);
select public.save_about_content((public.get_about_content()->'content')||'{"title":"Shared fixture","intro":"<script>alert(1)</script>"}',(public.get_about_content()->>'version')::integer);
select pg_temp.assert_true(public.get_about_content()#>>'{content,title}'='Shared fixture','admin publish persisted');
do $$begin begin perform public.save_about_content(public.get_about_content()->'content',(public.get_about_content()->>'version')::integer-1);raise exception 'TEST conflict accepted';exception when serialization_failure then null;end;end$$;
reset role;
set local role anon;
select pg_temp.assert_true(public.get_about_content()#>>'{content,title}'='Shared fixture','shared result is public');
reset role;
rollback;
