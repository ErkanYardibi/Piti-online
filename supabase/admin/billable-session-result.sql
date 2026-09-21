-- Commit a PT session result and its financial history in one transaction.
-- Older application versions do not know this field; their saves must retain it.
create or replace function piti_private.preserve_session_billing() returns trigger
language plpgsql set search_path='' as $$
begin
 if old.data ? 'sessionBilling' and not (new.data ? 'sessionBilling') then
  new.data=jsonb_set(new.data,'{sessionBilling}',old.data->'sessionBilling',true);
 end if;
 return new;
end $$;
revoke all on function piti_private.preserve_session_billing() from public,anon,authenticated;
drop trigger if exists preserve_session_billing on public.client_history;
create trigger preserve_session_billing before update on public.client_history for each row execute function piti_private.preserve_session_billing();

create or replace function piti_private.save_billable_session_result(
 p_session_id uuid,p_status text,p_counts boolean,p_groups text[],p_history jsonb,p_version integer,p_expected_status text
) returns integer language plpgsql security definer set search_path='' as $$
declare s public.sessions; c public.clients; v integer;
begin
 if auth.uid() is null or not piti_private.access_ready() or piti_private.account_role()<>'pt' then
  raise exception 'Aktif PT girişi gerekli.' using errcode='42501';
 end if;
 select * into s from public.sessions where id=p_session_id for update;
 if s.id is null or s.pt_id is distinct from auth.uid() then raise exception 'Seans yetkisi yok.' using errcode='42501'; end if;
 select * into c from public.clients where id=s.client_id for update;
 if c.pt_id is distinct from auth.uid() or c.relationship_ended_at is not null then raise exception 'Aktif öğrenci bağlantısı gerekli.' using errcode='42501'; end if;
 if s.status not in ('planned','completed','no_show') or s.status is distinct from p_expected_status
  or p_status not in ('completed','no_show') or p_status is null or p_counts is null
  or coalesce(s.ends_at,s.starts_at+interval '1 hour')>now() then raise exception 'Seans durumu veya zamanı uygun değil.'; end if;
 if p_status='completed' and not p_counts then raise exception 'Tamamlanan seans ücretlendirilmelidir.'; end if;
 if jsonb_typeof(p_history#>'{sessionBilling,charges}') is distinct from 'array'
  or jsonb_typeof(p_history#>'{sessionBilling,receipts}') is distinct from 'array' then raise exception 'Geçersiz ödeme kaydı.'; end if;
 if exists(select 1 from jsonb_array_elements(p_history#>'{sessionBilling,charges}') e group by e->>'sessionId' having count(*)>1) then raise exception 'Aynı seans iki kez borçlandırılamaz.'; end if;
 -- Version check in save_client_history rolls the entire RPC back on conflict.
 v=piti_private.save_client_history(s.client_id,p_history,p_version);
 update public.sessions set status=p_status,counts_against_package=p_counts,muscle_groups=coalesce(p_groups,'{}'::text[]),updated_at=now() where id=s.id;
 return v;
end $$;
create or replace function public.save_billable_session_result(
 p_session_id uuid,p_status text,p_counts boolean,p_groups text[],p_history jsonb,p_version integer,p_expected_status text
) returns integer language sql security invoker set search_path='' as $$
 select piti_private.save_billable_session_result(p_session_id,p_status,p_counts,p_groups,p_history,p_version,p_expected_status);
$$;
revoke all on function piti_private.save_billable_session_result(uuid,text,boolean,text[],jsonb,integer,text),public.save_billable_session_result(uuid,text,boolean,text[],jsonb,integer,text) from public,anon;
grant execute on function piti_private.save_billable_session_result(uuid,text,boolean,text[],jsonb,integer,text),public.save_billable_session_result(uuid,text,boolean,text[],jsonb,integer,text) to authenticated;
