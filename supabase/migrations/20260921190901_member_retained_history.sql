begin;
-- Member-owned history survives deletion of the trainer, but not the member.
-- No trainer identity, messages, health measurements, notes or attachments.
create table piti_private.member_retained_history (
 id uuid primary key default gen_random_uuid(),
 member_id uuid not null references auth.users(id) on delete cascade,
 deletion_id uuid not null references piti_private.account_deletion_requests(id),
 source_client_id uuid not null,
 archived_at timestamptz not null default now(),
 snapshot jsonb not null,
 unique(deletion_id,source_client_id,member_id)
);
create index member_retained_history_owner on piti_private.member_retained_history(member_id,archived_at desc);
alter table piti_private.member_retained_history enable row level security;
revoke all on piti_private.member_retained_history from public,anon,authenticated;

create function piti_private.history_fields(p_data jsonb,p_keys text[]) returns jsonb
language sql immutable set search_path='' as $$
 select coalesce(jsonb_object_agg(key,value),'{}'::jsonb)
 from jsonb_each(case when jsonb_typeof(p_data)='object' then p_data else '{}'::jsonb end)
 where key=any(p_keys) and jsonb_typeof(value) in ('string','number','boolean','null')
$$;
create function piti_private.retained_snapshot(p_data jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare result jsonb='{}'; k text; keys text[]; items jsonb; entries jsonb;
begin
 foreach k in array array['sessions','packages','payments','financeHistory','charges','receipts','previousPackages','previousPayments'] loop
  keys=case k
   when 'sessions' then array['starts_at','ends_at','status','workout_title','counts_against_package']
   when 'packages' then array['name','price','total_sessions','start_date','expiry_date','status']
   when 'payments' then array['amount','method','status','paid_at','created_at']
   when 'charges' then array['id','date','amount','createdAt','voided']
   when 'receipts' then array['chargeId','amount','date','method','recordedAt']
   when 'previousPackages' then array['name','price','totalSessions','usedSessions','start','end','expireDate','status','billingType']
   when 'previousPayments' then array['amount','receivedAmount','method','status','submittedAt','paidAt']
   else array['date','createdAt','amount','status','type'] end;
  items=case when k='financeHistory' then p_data#>'{history,financeHistory}'
   when k in ('charges','receipts') then p_data#>array['history','sessionBilling',k]
   when k in ('previousPackages','previousPayments') then p_data#>'{history,financeHistory}' else p_data->k end;
  if k in ('previousPackages','previousPayments') then
   select coalesce(jsonb_agg(value->(case k when 'previousPackages' then 'packageSnapshot' else 'paymentSnapshot' end)),'[]'::jsonb) into entries
    from jsonb_array_elements(case when jsonb_typeof(items)='array' then items else '[]'::jsonb end);
   items=entries;
  end if;
  select coalesce(jsonb_agg(piti_private.history_fields(value,keys)),'[]'::jsonb) into items
   from jsonb_array_elements(case when jsonb_typeof(items)='array' then items else '[]'::jsonb end);
  result=result||jsonb_build_object(k,items);
 end loop;
 return result||jsonb_build_object(
  'package',piti_private.history_fields(p_data#>'{history,package}',array['name','price','totalSessions','usedSessions','start','end','expireDate','status','billingType']),
  'payment',piti_private.history_fields(p_data#>'{history,payment}',array['amount','receivedAmount','method','status','date','submittedAt','paidAt']));
end $$;

-- A future cleanup worker calls this BEFORE removing any trainer data. It does
-- not detach clients, delete accounts, or mark a deletion as completed.
create function piti_private.capture_member_retained_history(p_job uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare job piti_private.account_deletion_requests; n integer;
begin
 select * into job from piti_private.account_deletion_requests where id=p_job for update;
 if not found or job.role<>'pt' or job.user_id is null or job.state<>'processing'
 or not exists(select 1 from piti_private.account_controls where user_id=job.user_id and suspended)
 then raise exception 'Dondurulmuş PT silme işi gerekli.' using errcode='42501'; end if;
 -- Include former members using their immutable transfer snapshot, even when
 -- the old client no longer has user_id. Never assign history to the new PT.
 insert into piti_private.member_retained_history(member_id,deletion_id,source_client_id,snapshot)
 select src.member_id,job.id,src.client_id,piti_private.retained_snapshot(src.data)
 from (
  select c.user_id member_id,c.id client_id,jsonb_build_object(
   'sessions',(select jsonb_agg(to_jsonb(s) order by s.starts_at,s.id) from public.sessions s where s.client_id=c.id),
   'packages',(select jsonb_agg(to_jsonb(p) order by p.id) from public.packages p where p.client_id=c.id),
   'payments',(select jsonb_agg(to_jsonb(p) order by p.id) from public.payments p where p.client_id=c.id),
   'history',h.data) data
  from public.clients c left join public.client_history h on h.client_id=c.id
  where c.pt_id=job.user_id and c.user_id is not null
  union all
  select t.member_id,t.old_client_id,t.snapshot from public.trainer_transfers t where t.old_pt_id=job.user_id
 ) src join auth.users u on u.id=src.member_id
 where src.member_id<>job.user_id
 on conflict(deletion_id,source_client_id,member_id) do nothing;
 get diagnostics n=row_count;
 return n;
end $$;
create function public.member_retained_history() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(piti_private.access_ready(),false) then raise exception 'Aktif oturum gerekli.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'archived_at',archived_at,'snapshot',snapshot) order by archived_at desc,id)
 from piti_private.member_retained_history where member_id=auth.uid()),'[]'::jsonb);
end $$;
revoke all on function piti_private.history_fields(jsonb,text[]),piti_private.retained_snapshot(jsonb),piti_private.capture_member_retained_history(uuid) from public,anon,authenticated;
grant execute on function piti_private.capture_member_retained_history(uuid) to service_role;
revoke all on function public.member_retained_history() from public,anon;
grant execute on function public.member_retained_history() to authenticated;
commit;
