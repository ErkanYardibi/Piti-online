-- Read only profile photos of the caller's current linked clients.
begin;
create or replace function piti_private.get_my_client_photos(p_client_id uuid default null)
returns table(client_id uuid, photo text)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 if piti_private.account_role()<>'pt' then raise exception 'PT hesabı gerekli.'; end if;
 return query select c.id,p.avatar_url
 from public.clients c join public.profiles p on p.id=c.user_id and p.role='member'
 where c.pt_id=auth.uid() and c.relationship_ended_at is null
 and (p_client_id is null or c.id=p_client_id);
end $$;
create or replace function public.get_my_client_photos(p_client_id uuid default null)
returns table(client_id uuid, photo text)
language sql stable security invoker set search_path='' as $$
 select * from piti_private.get_my_client_photos(p_client_id);
$$;
revoke all on function piti_private.get_my_client_photos(uuid) from public,anon;
revoke all on function public.get_my_client_photos(uuid) from public,anon;
grant execute on function piti_private.get_my_client_photos(uuid) to authenticated;
grant execute on function public.get_my_client_photos(uuid) to authenticated;
commit;
