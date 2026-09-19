-- Only the authenticated member's current linked trainer is returned.
create or replace function piti_private.get_my_trainer() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 if piti_private.account_role()<>'member' then return null; end if;
 select jsonb_build_object('client_id',c.id,'id',p.id,'name',p.full_name,'photo',p.avatar_url) into result
 from public.clients c join public.profiles p on p.id=c.pt_id and p.role='pt'
 where c.user_id=auth.uid();
 return result;
end $$;
revoke all on function piti_private.get_my_trainer() from public,anon;
grant execute on function piti_private.get_my_trainer() to authenticated;
