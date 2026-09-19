-- Narrow the existing session policy without changing any business records.
begin;
alter policy sessions_access on public.sessions
using (
 exists (select 1 from public.clients c
 where c.id=sessions.client_id
 and c.pt_id is not distinct from sessions.pt_id
 and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid())))
)
with check (
 exists (select 1 from public.clients c
 where c.id=sessions.client_id
 and c.pt_id is not distinct from sessions.pt_id
 and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid())))
);
commit;
