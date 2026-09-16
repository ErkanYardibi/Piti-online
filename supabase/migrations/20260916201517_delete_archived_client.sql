begin;
-- The public wrapper is invoker-only. Ownership, role, live session, archive
-- status and typed confirmation are checked again inside the private boundary.
create function piti_private.delete_archived_client(p_client_id uuid,p_confirmation text)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.clients%rowtype;
begin
 if auth.uid() is null or not piti_private.access_ready() or not exists(
  select 1 from public.profiles p where p.id=auth.uid() and p.role='pt'
 ) then raise exception 'Bu işlem yalnızca PT hesabına açık.'; end if;
 select * into c from public.clients where id=p_client_id and pt_id=auth.uid() for update;
 if not found then raise exception 'Müşteri bulunamadı veya silme yetkin yok.'; end if;
 if not c.archived then raise exception 'Önce müşteriyi arşive kaldır.'; end if;
 if p_confirmation is null or btrim(p_confirmation)<>btrim(c.full_name) then
  raise exception 'Onay için müşterinin adını aynen yaz.';
 end if;
 if exists(select 1 from piti_private.account_operations o where o.client_id=c.id and o.finished_at is null and o.expires_at>now()) then
  raise exception 'Hesap işlemi sürüyor. Tamamlandıktan sonra tekrar dene.';
 end if;
 -- All client-owned tables use ON DELETE CASCADE, including invitations,
 -- history, messages and private entry links. Auth users/profiles are untouched.
 delete from public.clients where id=c.id;
 return c.id;
end $$;
revoke all on function piti_private.delete_archived_client(uuid,text) from public,anon;
grant execute on function piti_private.delete_archived_client(uuid,text) to authenticated;
create function public.delete_archived_client(p_client_id uuid,p_confirmation text)
returns uuid language sql security invoker set search_path='' as $$
 select piti_private.delete_archived_client(p_client_id,p_confirmation);
$$;
revoke all on function public.delete_archived_client(uuid,text) from public,anon;
grant execute on function public.delete_archived_client(uuid,text) to authenticated;
commit;
