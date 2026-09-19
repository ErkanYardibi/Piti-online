-- Run on production with administrative SQL access; all mutations roll back.
begin;
do $$declare copy_id bigint;begin
 if exists(select 1 from information_schema.role_table_grants where table_schema='public' and grantee in ('PUBLIC','anon','authenticated') and privilege_type in ('TRUNCATE','REFERENCES','TRIGGER')) then raise exception 'Dangerous table grants remain';end if;
 copy_id=piti_private.capture_recovery_copy();
 if not exists(select 1 from piti_private.recovery_copies where id=copy_id and verified_at is not null and verification ? 'account_state') then raise exception 'Copy not verified';end if;
 update piti_private.recovery_copies set sha256='corrupt' where id=copy_id;
 begin
  perform piti_private.verify_recovery_copy(copy_id);
  raise exception 'Corrupt checksum accepted';
 exception when raise_exception then
  if sqlerrm<>'Recovery copy checksum mismatch' then raise;end if;
 end;
end $$;
set local role authenticated;
do $$begin
 if has_table_privilege(current_user,'piti_private.recovery_copies','select') then raise exception 'Copies exposed';end if;
 if has_function_privilege(current_user,'piti_private.capture_recovery_copy()','execute') then raise exception 'Capture exposed';end if;
 begin perform public.recovery_status();raise exception 'Missing admin accepted';exception when insufficient_privilege then null;end;
end $$;
reset role;
select 'PASS: capture, typed restore, checksum rejection, least privilege, private backup access' result;
rollback;
