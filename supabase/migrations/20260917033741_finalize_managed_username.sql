begin;
CREATE OR REPLACE FUNCTION piti_private.managed_account_finish(p_operation uuid, p_user uuid, p_token_hash text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare op piti_private.account_operations;c public.clients; u auth.users;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 select * into op from piti_private.account_operations where id=p_operation;
 select * into c from public.clients where id=op.client_id for update;
 select * into op from piti_private.account_operations where id=p_operation for update;
 if op.id is null or op.finished_at is not null or op.expires_at<=now() then raise exception 'Hesap işleminin süresi doldu; tekrar dene.'; end if;
 select * into u from auth.users where id=p_user;
 if u.id is null then raise exception 'Hesap bulunamadı.'; end if;
 if op.kind='password' then
  if c.user_id is distinct from p_user or op.actor_id<>p_user then raise exception 'Şifre değişim yetkisi yok.'; end if;
  update public.profiles set must_change_password=false where id=p_user;
  delete from auth.sessions where user_id=p_user;
 else
  if c.pt_id is distinct from op.actor_id or (op.kind='create' and not ((nullif(btrim(c.email),'') is not null and lower(btrim(c.email))=lower(btrim(u.email))) or (u.raw_app_meta_data->>'managed_client_id'=c.id::text and u.raw_app_meta_data->>'managed_operation_id'=op.id::text))) or not exists(select 1 from public.profiles where id=p_user and role='member') then raise exception 'Hesap bilgileri eşleşmiyor.'; end if;
  if op.kind='create' then
   if nullif(u.raw_app_meta_data->>'username','') is not null then
    update public.profiles set username=piti_private.normalize_username(u.raw_app_meta_data->>'username') where id=p_user;
   end if;
   if c.user_id is not null or exists(select 1 from public.clients where user_id=p_user) then raise exception 'Hesap zaten bağlı.'; end if;
   update public.clients set user_id=p_user,updated_at=now() where id=c.id;
  elsif c.user_id is distinct from p_user then raise exception 'Hesap bağlantısı değişmiş.';
  end if;
  update public.profiles set must_change_password=true where id=p_user;
 end if;
 update piti_private.entry_links set revoked_at=now() where client_id=c.id and revoked_at is null;
 update public.client_invitations set revoked_at=now() where client_id=c.id and used_at is null and revoked_at is null;
 if op.kind<>'password' then
  if p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then raise exception 'Geçersiz bağlantı.'; end if;
  insert into piti_private.entry_links(client_id,user_id,token_hash) values(c.id,p_user,p_token_hash);
 end if;
 update piti_private.account_operations set finished_at=now() where id=op.id;
 insert into public.account_audit(client_id,actor_id,action) values(c.id,op.actor_id,op.kind||'_completed');
 return jsonb_build_object('client_id',c.id,'user_id',p_user);
end $function$;
commit;
