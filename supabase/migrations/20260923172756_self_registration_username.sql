begin;

-- Self-registration supplies only a display/login identifier in user metadata.
-- Roles and managed-account flags keep their existing trusted metadata rules.
-- The unique profiles.username constraint makes user + profile creation atomic.
create or replace function piti_private.initialize_account_profile()
returns trigger language plpgsql security definer set search_path='' as $$
declare account_role text; chosen_username text;
begin
 account_role=coalesce(new.raw_app_meta_data->>'account_role',new.raw_user_meta_data->>'account_type','member');
 if account_role not in ('pt','member') then account_role='member'; end if;
 if nullif(new.raw_app_meta_data->>'username','') is not null then
  chosen_username=piti_private.normalize_username(new.raw_app_meta_data->>'username');
 elsif new.raw_user_meta_data ? 'username' then
  chosen_username=piti_private.normalize_username(new.raw_user_meta_data->>'username');
  if chosen_username !~ '^[a-z0-9][a-z0-9._-]{2,29}$' or chosen_username in ('admin','demo') then
   raise exception 'Geçerli bir kullanıcı adı gerekli.' using errcode='23514';
  end if;
 end if;
 -- Older email-only clients remain compatible; existing accounts are not changed.
 insert into public.profiles(id,role,full_name,must_change_password,username)
 values(new.id,account_role,left(coalesce(nullif(new.raw_user_meta_data->>'full_name',''),split_part(new.email,'@',1),'Kullanıcı'),160),coalesce((new.raw_app_meta_data->>'must_change_password')::boolean,false),chosen_username);
 return new;
end $$;
revoke all on function piti_private.initialize_account_profile() from public,anon,authenticated;

-- Deliberately anonymous, read-only availability check for the signup form.
-- Returns a boolean only: no emails, profile data, user IDs or login lookup.
create or replace function piti_private.registration_username_available(p_username text)
returns boolean language sql stable security definer set search_path='' as $$
 select canonical ~ '^[a-z0-9][a-z0-9._-]{2,29}$'
  and canonical not in ('admin','demo')
  and not exists(select 1 from public.profiles p where p.username=canonical)
 from (select piti_private.normalize_username(p_username) as canonical) n
$$;
create or replace function public.registration_username_available(p_username text)
returns boolean language sql stable security invoker set search_path='' as $$
 select piti_private.registration_username_available(p_username)
$$;
revoke all on function piti_private.registration_username_available(text),public.registration_username_available(text) from public;
grant usage on schema piti_private to anon,authenticated;
grant execute on function piti_private.registration_username_available(text),public.registration_username_available(text) to anon,authenticated;

commit;
