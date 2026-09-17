begin;

-- Account-scoped application state. Normalized tables remain authoritative for
-- shared records; this snapshot keeps profile preferences and UI-created data
-- available on every device instead of tying them to one browser.
create table public.account_state (
 user_id uuid primary key references auth.users(id) on delete cascade,
 data jsonb not null default '{}'::jsonb check (jsonb_typeof(data)='object'),
 updated_at timestamptz not null default now()
);

alter table public.account_state enable row level security;
revoke all on public.account_state from public, anon, authenticated;
grant select, insert, update on public.account_state to authenticated;

create policy account_state_owner_read on public.account_state
 for select to authenticated using (user_id=(select auth.uid()));
create policy account_state_owner_insert on public.account_state
 for insert to authenticated with check (user_id=(select auth.uid()));
create policy account_state_owner_update on public.account_state
 for update to authenticated
 using (user_id=(select auth.uid()))
 with check (user_id=(select auth.uid()));

commit;
