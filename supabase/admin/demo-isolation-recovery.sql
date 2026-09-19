-- Incident repair: targeted, backed up and atomic. No normalized business rows deleted.
begin;
do $$ begin
 if not exists(select 1 from piti_private.incident_backups where id='demo-isolation-20260919-eyardibi') then raise exception 'Backup required'; end if;
end $$;
do $$
declare d jsonb; uid uuid:='019221e2-9804-4446-b35e-c750df2ba1ff';
begin
 select data into d from public.account_state where user_id=uid for update;
 d=jsonb_set(d,'{events}',coalesce((select jsonb_agg(e order by n) from jsonb_array_elements(d->'events') with ordinality t(e,n) where not ((e->>'customerId' ~ '^(demo-(ayse|zeynep)|test-customer-[0-9]+)$') and coalesce(e->>'cloudManaged','false')<>'true')),'[]'));
 d=jsonb_set(d,'{customerAccounts}',coalesce((select jsonb_object_agg(key,value) from jsonb_each(d->'customerAccounts') where not ((key='1' or key ~ '^(demo-(ayse|zeynep)|test-customer-[0-9]+)$') and coalesce(value#>>'{customer,cloudManaged}','false')<>'true')),'{}'));
 d=jsonb_set(d,'{ptProfile,name}','"Erkan Yardibi"');
 if d#>>'{ptProfile,bio}'='Fonksiyonel antrenman ve kuvvet gelişimi' then d=jsonb_set(d,'{ptProfile,bio}','""');end if;
 if d#>>'{ptProfile,specialties}'='Kuvvet, Fonksiyonel Antrenman, Kilo Kontrolü' then d=jsonb_set(d,'{ptProfile,specialties}','""');end if;
 d=jsonb_set(d,'{ptProfile,locations}',coalesce((select jsonb_agg(l) from jsonb_array_elements(d#>'{ptProfile,locations}') l where not ((l->>'name'='X Fitness Lara' and l->>'address'='Lara, Antalya') or (l->>'name'='Core Gym Konyaaltı' and l->>'address'='Konyaaltı, Antalya'))),'[]'));
 d=jsonb_set(d,'{invite,pending}',coalesce((select jsonb_agg(i) from jsonb_array_elements(d#>'{invite,pending}') i where not (i->>'email'='selin.aksoy@example.com' and i->>'code'='MEHMET-4821')),'[]'));
 if d#>>'{invite,ptCode}'='MEHMET-4821' then d=jsonb_set(d,'{invite,ptCode}','""');end if;
 d=jsonb_set(d,'{financeCustomerId}',d#>'{customer,id}');
 d=jsonb_set(d,'{isolationVersion}','1');
 update public.account_state set data=d,updated_at=now() where user_id=uid;
 update public.profiles set full_name='Erkan Yardibi' where id=uid and full_name='Mehmet Kaya';
end $$;
create or replace function piti_private.reject_demo_account_state() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if new.data ? 'demoFixtureVersion' or new.data ? 'demoCloudVersion'
 or exists(select 1 from jsonb_each(coalesce(new.data->'customerAccounts','{}')) t where t.key ~ '^(demo-|test-customer-)')
 or exists(select 1 from jsonb_array_elements(coalesce(new.data->'events','[]')) e where e->>'customerId' ~ '^(demo-|test-customer-)') then
  raise exception 'Demo verisi gerçek hesaba kaydedilemez. Sayfayı yenileyin.';
 end if;
 if tg_op='UPDATE' and old.data->>'isolationVersion'='1' and new.data->>'isolationVersion' is distinct from '1' then
  raise exception 'Eski uygulama sürümü. Sayfayı yenileyin.';
 end if;
 return new;
end $$;
revoke all on function piti_private.reject_demo_account_state() from public,anon,authenticated;
create trigger reject_demo_account_state before insert or update on public.account_state for each row execute function piti_private.reject_demo_account_state();
create or replace function piti_private.protect_recovered_profile() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if current_setting('request.headers',true) is not null and current_setting('request.headers',true)<>'' and coalesce(current_setting('request.headers',true)::jsonb->>'x-piti-state-version','')<>'1' then
  raise exception 'Hesap koruması: eski sekmeyi kapatıp sayfayı yenileyin.';
 end if;
 return new;
end $$;
revoke all on function piti_private.protect_recovered_profile() from public,anon,authenticated;
create trigger protect_recovered_profile before update on public.profiles for each row when (old.id='019221e2-9804-4446-b35e-c750df2ba1ff'::uuid) execute function piti_private.protect_recovered_profile();
commit;
