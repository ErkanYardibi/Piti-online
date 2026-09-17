begin;
create function piti_private.normalize_username(value text) returns text language sql immutable set search_path='' as $$select lower(translate(btrim(coalesce(value,'')),'ÇĞİÖŞÜçğıöşüI','CGIOSUcgiosui'))$$;
alter table public.profiles add column username text unique check(username is null or (username ~ '^[a-z0-9][a-z0-9._-]{2,29}$'));
create table piti_private.username_login_attempts(identifier_hash text primary key,started_at timestamptz not null,attempts integer not null);
alter table piti_private.username_login_attempts enable row level security;
revoke all on piti_private.username_login_attempts from public,anon,authenticated;
create function piti_private.username_login_lookup(p_username text) returns text language plpgsql security definer set search_path='' as $$
declare canonical text; n integer; address text;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Sunucu yetkisi gerekli.'; end if;
 canonical=piti_private.normalize_username(p_username);
 if canonical !~ '^[a-z0-9][a-z0-9._-]{2,29}$' then return null; end if;
 insert into piti_private.username_login_attempts(identifier_hash,started_at,attempts) values(md5(canonical),now(),1)
 on conflict(identifier_hash) do update set attempts=case when username_login_attempts.started_at<now()-interval '5 minutes' then 1 else username_login_attempts.attempts+1 end,started_at=case when username_login_attempts.started_at<now()-interval '5 minutes' then now() else username_login_attempts.started_at end returning attempts into n;
 if n>20 then return null; end if;
 select u.email into address from public.profiles p join auth.users u on u.id=p.id where p.username=canonical;
 return address;
end $$;
create function public.username_login_lookup(p_username text) returns text language sql security invoker set search_path='' as $$select piti_private.username_login_lookup(p_username)$$;
revoke all on function public.username_login_lookup(text),piti_private.username_login_lookup(text) from public,anon,authenticated;
grant execute on function public.username_login_lookup(text),piti_private.username_login_lookup(text) to service_role;
create function piti_private.set_own_username(p_username text) returns text language plpgsql security definer set search_path='' as $$
declare canonical text;
begin
 if auth.uid() is null or not piti_private.access_ready() then raise exception 'Önce giriş yap.'; end if;
 canonical=piti_private.normalize_username(p_username);
 if canonical !~ '^[a-z0-9][a-z0-9._-]{2,29}$' then raise exception 'Kullanıcı adı 3–30 karakter; harf, rakam, nokta, alt çizgi veya tire içermeli.'; end if;
 update public.profiles set username=canonical where id=auth.uid();
 return canonical;
exception when unique_violation then raise exception 'Bu kullanıcı adı alınmış. Başka bir ad seç.';
end $$;
create function public.set_own_username(p_username text) returns text language sql security invoker set search_path='' as $$select piti_private.set_own_username(p_username)$$;
revoke all on function public.set_own_username(text),piti_private.set_own_username(text) from public,anon;
grant execute on function public.set_own_username(text),piti_private.set_own_username(text) to authenticated;
revoke all on function piti_private.normalize_username(text) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION piti_private.initialize_account_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare account_role text;
begin
 account_role=coalesce(new.raw_app_meta_data->>'account_role',new.raw_user_meta_data->>'account_type','member');
 if account_role not in ('pt','member') then account_role='member'; end if;
 insert into public.profiles(id,role,full_name,must_change_password,username)
 values(new.id,account_role,left(coalesce(nullif(new.raw_user_meta_data->>'full_name',''),split_part(new.email,'@',1),'Kullanıcı'),160),coalesce((new.raw_app_meta_data->>'must_change_password')::boolean,false),nullif(piti_private.normalize_username(new.raw_app_meta_data->>'username'),''));
 return new;
end $function$;

CREATE OR REPLACE FUNCTION piti_private.guard_profile_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if current_user in ('anon','authenticated') then
  if tg_op='INSERT' then
   if not exists(select 1 from public.profiles where id=new.id and role=new.role) then raise exception 'Hesap rolü sunucu tarafından belirlenir.'; end if;
  elsif new.username is distinct from old.username then raise exception 'Kullanıcı adı yalnızca hesap ayarlarından değiştirilebilir.';
  elsif new.role is distinct from old.role or new.id is distinct from old.id or new.must_change_password is distinct from old.must_change_password then
   raise exception 'Hesap rolü ve şifre zorunluluğu değiştirilemez.';
  end if;
 end if;
 return new;
end $function$;

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
