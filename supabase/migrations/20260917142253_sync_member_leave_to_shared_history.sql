begin;

create or replace function piti_private.sync_member_leave_from_account_state()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_client_id uuid;
  v_member_leaves jsonb := '[]'::jsonb;
  v_existing jsonb := '{}'::jsonb;
  v_non_member_extra jsonb := '[]'::jsonb;
begin
  select c.id into v_client_id
  from public.clients c
  join public.profiles p on p.id=c.user_id and p.role='member'
  where c.user_id=new.user_id
  limit 1;

  if v_client_id is null then
    return new;
  end if;

  select coalesce(jsonb_agg(e), '[]'::jsonb)
    into v_member_leaves
  from jsonb_array_elements(coalesce(new.data->'events','[]'::jsonb)) e
  where e->>'type'='memberoff'
    and coalesce(e->>'status','')<>'cancelled';

  select data into v_existing
  from public.client_history
  where client_id=v_client_id;

  v_existing:=coalesce(v_existing,'{}'::jsonb);

  select coalesce(jsonb_agg(e), '[]'::jsonb)
    into v_non_member_extra
  from jsonb_array_elements(coalesce(v_existing->'extraEvents','[]'::jsonb)) e
  where e->>'type'<>'memberoff';

  insert into public.client_history(client_id,data,version,updated_at)
  values(
    v_client_id,
    jsonb_set(v_existing,'{extraEvents}',coalesce(v_non_member_extra,'[]'::jsonb)||coalesce(v_member_leaves,'[]'::jsonb),true),
    1,
    now()
  )
  on conflict(client_id) do update
    set data=jsonb_set(public.client_history.data,'{extraEvents}',coalesce(v_non_member_extra,'[]'::jsonb)||coalesce(v_member_leaves,'[]'::jsonb),true),
        updated_at=now();

  return new;
end
$$;

drop trigger if exists sync_member_leave_from_account_state on public.account_state;
create trigger sync_member_leave_from_account_state
after insert or update on public.account_state
for each row execute function piti_private.sync_member_leave_from_account_state();

-- Backfill existing member account-state snapshots once so already-saved leave
-- records become visible to the linked PT immediately.
update public.account_state s
set updated_at=s.updated_at
where exists(
  select 1
  from public.clients c
  join public.profiles p on p.id=c.user_id and p.role='member'
  where c.user_id=s.user_id
);

commit;
