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

insert into public.sessions(id,client_id,pt_id,starts_at,ends_at,counts_against_package) values(pg_temp.fixture_id('session'),pg_temp.fixture_id('client'),pg_temp.fixture_id('pt'),now()-interval '2 hour',now()-interval '1 hour',false);
create function pg_temp.billing_payload() returns jsonb language sql as $$select jsonb_build_object('package',jsonb_build_object('billingType','per_session','status','active','price',500,'autoCharge',true),'sessionBilling',jsonb_build_object('charges',jsonb_build_array(jsonb_build_object('id','charge-1','sessionId',pg_temp.fixture_id('session'),'amount',500)),'receipts','[]'::jsonb))$$;
select pg_temp.login('member');
select pg_temp.denied(format('select public.save_billable_session_result(%L,''completed'',true,array[]::text[],pg_temp.billing_payload(),0,''planned'')',pg_temp.fixture_id('session')));
select pg_temp.login('pt2');
select pg_temp.denied(format('select public.save_billable_session_result(%L,''completed'',true,array[]::text[],pg_temp.billing_payload(),0,''planned'')',pg_temp.fixture_id('session')));
select pg_temp.login('pt');
select pg_temp.assert_true(public.save_billable_session_result(pg_temp.fixture_id('session'),'completed',true,array['Sırt'],pg_temp.billing_payload(),0,'planned')=1,'atomic result version');
select pg_temp.assert_true((select status='completed' from public.sessions where id=pg_temp.fixture_id('session')),'session persisted');
select pg_temp.assert_true((select (data#>>'{sessionBilling,charges,0,amount}')::numeric=500 from public.client_history where client_id=pg_temp.fixture_id('client')),'debt persisted');
do $$begin
 begin
  perform public.save_billable_session_result(pg_temp.fixture_id('session'),'no_show',false,array[]::text[],pg_temp.billing_payload(),0,'completed');
  raise exception 'TEST: conflict accepted';
 exception when others then
  if sqlerrm='TEST: conflict accepted' then raise; end if;
 end;
end$$;
select pg_temp.assert_true((select status='completed' from public.sessions where id=pg_temp.fixture_id('session')),'conflict leaves result unchanged');
select pg_temp.assert_true((select version=1 from public.client_history where client_id=pg_temp.fixture_id('client')),'conflict leaves billing unchanged');
select pg_temp.login('member');
select pg_temp.assert_true((select jsonb_array_length(data#>'{sessionBilling,charges}')=1 from public.client_history where client_id=pg_temp.fixture_id('client')),'student reads debt');
select public.save_client_history(pg_temp.fixture_id('client'),jsonb_set(pg_temp.billing_payload(),'{sessionBilling}',jsonb_build_object('charges','[]'::jsonb,'receipts',jsonb_build_array(jsonb_build_object('amount',500)))),1);
select pg_temp.assert_true((select jsonb_array_length(data#>'{sessionBilling,charges}')=1 and jsonb_array_length(data#>'{sessionBilling,receipts}')=0 from public.client_history where client_id=pg_temp.fixture_id('client')),'student cannot erase debt or fabricate receipt');
select pg_temp.login('pt');
select public.save_client_history(pg_temp.fixture_id('client'),jsonb_set(pg_temp.billing_payload(),'{sessionBilling,receipts}',jsonb_build_array(jsonb_build_object('id','receipt-1','chargeId','charge-1','amount',500,'date','2026-09-21','method','Nakit'))),2);
select pg_temp.login('member');
select pg_temp.assert_true((select (data#>>'{sessionBilling,receipts,0,amount}')::numeric=500 from public.client_history where client_id=pg_temp.fixture_id('client')),'PT direct receipt visible to student after reload');
select pg_temp.login('pt');
select public.save_client_history(pg_temp.fixture_id('client'),(select data-'sessionBilling' from public.client_history where client_id=pg_temp.fixture_id('client')),3);
select pg_temp.assert_true((select (data#>>'{sessionBilling,receipts,0,amount}')::numeric=500 from public.client_history where client_id=pg_temp.fixture_id('client')),'older client cannot erase ledger');
select pg_temp.login('pt2');
select pg_temp.assert_true((select count(*)=0 from public.client_history where client_id=pg_temp.fixture_id('client')),'other PT cannot read finances');
rollback;
select 'PASS: atomic session and charge, conflict rollback, student read-only ledger, PT direct receipt, tenant isolation; fixtures rolled back' as result;
