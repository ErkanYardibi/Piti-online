-- Read only explicitly shared slots from the current PT's existing account state.
-- Unknown/legacy visibility is private. No other account state fields are returned.
begin;
create or replace function piti_private.shared_calendar_slots(p_events jsonb,p_client_id text)
returns jsonb language sql immutable security invoker set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
 'id','pt-slot-'||(e->>'id'),'sourceSlotId',e->>'id','date',e->>'date','time',e->>'time','endTime',e->>'endTime',
 'type',case when e->>'type'='availability' or (e->>'type' is null and e->>'status'='open') then 'availability' else 'off' end,
 'status',case when e->>'type'='availability' or (e->>'type' is null and e->>'status'='open') then 'open' else 'off' end,
 'title',case when e->>'type'='availability' or (e->>'type' is null and e->>'status'='open') then 'Müsait' else 'PT müsait değil' end,
 'createdBy','pt','sharedTrainerAvailability',true,'visibility','all')), '[]'::jsonb)
 from jsonb_array_elements(case when jsonb_typeof(p_events)='array' then p_events else '[]'::jsonb end) e
 where (e->>'customerId') is null and (e->>'type' in ('availability','off','closed','excused') or (e->>'type' is null and e->>'status' in ('open','off')))
 and coalesce(e->>'status','')<>'cancelled'
 and ((e->>'visibility' in ('all','Tüm müşteriler görebilir')) or
 (e->>'visibility' in ('selected','Seçili müşteriler görebilir') and
 case when jsonb_typeof(e->'visibleCustomerIds')='array' then (e->'visibleCustomerIds') ? p_client_id else false end));
$$;
create or replace function piti_private.get_my_trainer_availability()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 if piti_private.account_role()<>'member' then raise exception 'Müşteri hesabı gerekli.'; end if;
 select piti_private.shared_calendar_slots(s.data->'events',c.id::text) into result
 from public.clients c join public.profiles p on p.id=c.pt_id and p.role='pt'
 join public.account_state s on s.user_id=c.pt_id
 where c.user_id=auth.uid() and not coalesce(c.archived,false) and c.relationship_ended_at is null;
 return coalesce(result,'[]'::jsonb);
end $$;
create or replace function public.get_my_trainer_availability()
returns jsonb language sql stable security invoker set search_path='' as $$
 select piti_private.get_my_trainer_availability();
$$;
revoke all on function piti_private.shared_calendar_slots(jsonb,text) from public,anon,authenticated;
revoke all on function piti_private.get_my_trainer_availability() from public,anon;
revoke all on function public.get_my_trainer_availability() from public,anon;
grant execute on function piti_private.get_my_trainer_availability() to authenticated;
grant execute on function public.get_my_trainer_availability() to authenticated;
commit;
