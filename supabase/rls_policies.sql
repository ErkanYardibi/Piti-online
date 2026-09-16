-- PiTi Supabase access rules.
-- The publishable browser key is safe only while these RLS policies stay enabled.

revoke all on table public.clients, public.packages, public.sessions,
  public.payments, public.availability, public.tasks, public.messages from anon;

grant select, insert, update, delete on table public.profiles, public.clients,
  public.packages, public.sessions, public.payments, public.availability,
  public.tasks, public.messages to authenticated;

drop policy if exists clients_access on public.clients;
create policy clients_access on public.clients for all to authenticated
using ((select auth.uid()) = pt_id or (select auth.uid()) = user_id)
with check ((select auth.uid()) = pt_id or (select auth.uid()) = user_id);

drop policy if exists sessions_access on public.sessions;
create policy sessions_access on public.sessions for all to authenticated
using (
  (select auth.uid()) = pt_id or exists (
    select 1 from public.clients c
    where c.id = sessions.client_id and c.user_id = (select auth.uid())
  )
)
with check (
  (select auth.uid()) = pt_id or exists (
    select 1 from public.clients c
    where c.id = sessions.client_id and c.user_id = (select auth.uid())
  )
);

drop policy if exists packages_access on public.packages;
create policy packages_access on public.packages for all to authenticated
using (exists (select 1 from public.clients c where c.id = packages.client_id
  and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))))
with check (exists (select 1 from public.clients c where c.id = packages.client_id
  and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))));

drop policy if exists payments_access on public.payments;
create policy payments_access on public.payments for all to authenticated
using (exists (select 1 from public.clients c where c.id = payments.client_id
  and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))))
with check (exists (select 1 from public.clients c where c.id = payments.client_id
  and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))));

drop policy if exists availability_access on public.availability;
create policy availability_access on public.availability for all to authenticated
using ((select auth.uid()) = pt_id or exists (
  select 1 from public.clients c where c.id = availability.client_id
    and c.user_id = (select auth.uid())))
with check ((select auth.uid()) = pt_id or exists (
  select 1 from public.clients c where c.id = availability.client_id
    and c.user_id = (select auth.uid())));

drop policy if exists tasks_access on public.tasks;
create policy tasks_access on public.tasks for all to authenticated
using ((select auth.uid()) = pt_id or exists (
  select 1 from public.clients c where c.id = tasks.client_id
    and c.user_id = (select auth.uid())))
with check ((select auth.uid()) = pt_id or exists (
  select 1 from public.clients c where c.id = tasks.client_id
    and c.user_id = (select auth.uid())));

drop policy if exists messages_access on public.messages;
create policy messages_access on public.messages for all to authenticated
using (sender_id = (select auth.uid()) or exists (
  select 1 from public.clients c where c.id = messages.client_id
    and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))))
with check (sender_id = (select auth.uid()) and exists (
  select 1 from public.clients c where c.id = messages.client_id
    and (c.pt_id = (select auth.uid()) or c.user_id = (select auth.uid()))));

-- Foreign-key and ownership lookups used by RLS and the application.
create index if not exists clients_pt_id_idx on public.clients(pt_id);
create unique index if not exists clients_user_id_unique_idx
  on public.clients(user_id) where user_id is not null;
create index if not exists availability_pt_id_idx on public.availability(pt_id);
create index if not exists availability_client_id_idx on public.availability(client_id);
create index if not exists sessions_pt_id_idx on public.sessions(pt_id);
create index if not exists packages_client_id_idx on public.packages(client_id);
create index if not exists payments_package_id_idx on public.payments(package_id);
create index if not exists tasks_client_id_idx on public.tasks(client_id);
create index if not exists tasks_pt_id_idx on public.tasks(pt_id);
create index if not exists messages_sender_id_idx on public.messages(sender_id);
