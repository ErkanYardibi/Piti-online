-- Existing eight tables are retained. Profiles choose a role once; relationship ownership is immutable.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;
alter table public.clients add column if not exists invite_token uuid not null default gen_random_uuid();
create unique index if not exists clients_invite_token_idx on public.clients(invite_token);
create unique index if not exists clients_user_id_unique on public.clients(user_id) where user_id is not null;
create index if not exists clients_pt_id_idx on public.clients(pt_id);

create function private.protect_identity() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_table_name='profiles' then
   if new.role is distinct from old.role or new.id is distinct from old.id then raise exception 'Account identity cannot be changed'; end if;
 elsif tg_table_name='clients' then
   if new.pt_id is distinct from old.pt_id or new.id is distinct from old.id then raise exception 'Client ownership cannot be changed'; end if;
 end if;
 return new;
end $$;
create trigger protect_profile_identity before update on public.profiles for each row execute function private.protect_identity();
create trigger protect_client_identity before update on public.clients for each row execute function private.protect_identity();

-- Link a verified account using an unguessable, single-use invitation.
-- Elevated access is narrowly limited to consuming the invitation; it cannot transfer an existing client.
create function private.accept_invitation(token uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare client_id uuid;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='member') then raise exception 'Customer account required'; end if;
 update public.clients set user_id=auth.uid(), invite_token=gen_random_uuid(), updated_at=now()
 where invite_token=token and user_id is null returning id into client_id;
 if client_id is null then raise exception 'Invalid or already used invitation'; end if;
 return client_id;
end $$;
revoke all on function private.accept_invitation(uuid) from public,anon;
grant execute on function private.accept_invitation(uuid) to authenticated;
create function public.accept_invitation(token uuid) returns uuid language sql security invoker set search_path='' as $$select private.accept_invitation(token)$$;
revoke all on function public.accept_invitation(uuid) from public,anon;
grant execute on function public.accept_invitation(uuid) to authenticated;

revoke all on public.profiles,public.clients,public.packages,public.sessions,public.payments,public.availability,public.tasks,public.messages from anon,authenticated;
grant select,insert on public.profiles to authenticated;
grant update(full_name,phone,avatar_url) on public.profiles to authenticated;
grant select,insert on public.clients to authenticated;
grant update(full_name,phone,email,blood_type,gender,weight,height,archived) on public.clients to authenticated;
grant select,insert,update on public.packages,public.sessions,public.payments,public.availability to authenticated;
grant delete on public.availability to authenticated;
grant select,insert on public.tasks,public.messages to authenticated;
grant update(status,result) on public.tasks to authenticated;
grant update(read_at) on public.messages to authenticated;

create policy clients_read on public.clients for select to authenticated using(pt_id=(select auth.uid()) or user_id=(select auth.uid()));
create policy clients_create on public.clients for insert to authenticated with check(pt_id=(select auth.uid()) and user_id is null and exists(select 1 from public.profiles where id=(select auth.uid()) and role='pt'));
create policy clients_edit on public.clients for update to authenticated using(pt_id=(select auth.uid())) with check(pt_id=(select auth.uid()));

create policy packages_read on public.packages for select to authenticated using(exists(select 1 from public.clients c where c.id=client_id));
create policy packages_create on public.packages for insert to authenticated with check(exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid())));
create policy packages_edit on public.packages for update to authenticated using(exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid()))) with check(exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid())));

create policy sessions_read on public.sessions for select to authenticated using(exists(select 1 from public.clients c where c.id=client_id));
create policy sessions_create on public.sessions for insert to authenticated with check(pt_id=(select auth.uid()) and exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid())));
create policy sessions_edit on public.sessions for update to authenticated using(pt_id=(select auth.uid()) and exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid()))) with check(pt_id=(select auth.uid()) and exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid())));

create policy payments_read on public.payments for select to authenticated using(exists(select 1 from public.clients c where c.id=client_id));
create policy payments_create on public.payments for insert to authenticated with check(amount>0 and status='pending' and exists(select 1 from public.clients c where c.id=client_id) and (package_id is null or exists(select 1 from public.packages p where p.id=package_id and p.client_id=payments.client_id)));
create policy payments_edit on public.payments for update to authenticated using(exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid()))) with check(amount>0 and exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid())) and (package_id is null or exists(select 1 from public.packages p where p.id=package_id and p.client_id=payments.client_id)));

-- PT availability remains private until an explicit availability-sharing feature is added.
create policy availability_read on public.availability for select to authenticated using((client_id is null and pt_id=(select auth.uid())) or exists(select 1 from public.clients c where c.id=client_id));
create policy availability_create on public.availability for insert to authenticated with check((client_id is null and pt_id=(select auth.uid()) and exists(select 1 from public.profiles where id=(select auth.uid()) and role='pt')) or (pt_id is null and kind='unavailable' and exists(select 1 from public.clients c where c.id=client_id and c.user_id=(select auth.uid()))));
create policy availability_edit on public.availability for update to authenticated using((client_id is null and pt_id=(select auth.uid())) or (pt_id is null and exists(select 1 from public.clients c where c.id=client_id and c.user_id=(select auth.uid())))) with check((client_id is null and pt_id=(select auth.uid())) or (pt_id is null and kind='unavailable' and exists(select 1 from public.clients c where c.id=client_id and c.user_id=(select auth.uid()))));
create policy availability_delete on public.availability for delete to authenticated using((client_id is null and pt_id=(select auth.uid())) or (pt_id is null and exists(select 1 from public.clients c where c.id=client_id and c.user_id=(select auth.uid()))));

create policy tasks_read on public.tasks for select to authenticated using(exists(select 1 from public.clients c where c.id=client_id));
create policy tasks_create on public.tasks for insert to authenticated with check(pt_id=(select auth.uid()) and exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid())));
create policy tasks_edit on public.tasks for update to authenticated using(exists(select 1 from public.clients c where c.id=client_id)) with check(exists(select 1 from public.clients c where c.id=client_id) and status in ('open','done','cancelled'));

create policy messages_read on public.messages for select to authenticated using(exists(select 1 from public.clients c where c.id=client_id));
create policy messages_create on public.messages for insert to authenticated with check(sender_id=(select auth.uid()) and body is not null and char_length(body) between 1 and 5000 and exists(select 1 from public.clients c where c.id=client_id));
create policy messages_mark_read on public.messages for update to authenticated using(sender_id<>(select auth.uid()) and exists(select 1 from public.clients c where c.id=client_id)) with check(sender_id<>(select auth.uid()) and exists(select 1 from public.clients c where c.id=client_id));

alter table public.sessions add constraint sessions_time_order check(ends_at is null or ends_at>starts_at);
alter table public.availability add constraint availability_time_order check(ends_at is null or ends_at>starts_at);
alter table public.packages add constraint packages_valid check(price>=0 and total_sessions>0 and expiry_date>=start_date);

do $$ declare t text; begin
 foreach t in array array['packages','sessions','payments','availability','tasks','messages'] loop
 execute format('create index if not exists %I on public.%I(client_id)', t||'_client_id_idx',t);
 end loop;
end $$;
create index if not exists sessions_pt_id_idx on public.sessions(pt_id);
create index if not exists availability_pt_id_idx on public.availability(pt_id);
create index if not exists tasks_pt_id_idx on public.tasks(pt_id);
create index if not exists messages_sender_id_idx on public.messages(sender_id);
create index if not exists payments_package_id_idx on public.payments(package_id);

alter table public.sessions add column cancelled_from_status text check(cancelled_from_status in ('planned','completed','no_show'));
