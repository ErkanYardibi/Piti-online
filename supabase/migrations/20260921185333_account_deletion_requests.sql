begin;
-- Initiation only. Keep OFF until the purge worker, retention policy and restore
-- checks are implemented and verified. This migration deletes no user data.
create table piti_private.account_deletion_settings (
 id boolean primary key default true check(id),
 enabled boolean not null default false,
 worker_ready boolean not null default false,
 policy_version text not null default '',
 notice text not null default '',
 max_hours integer check(max_hours between 1 and 720)
);
insert into piti_private.account_deletion_settings(id) values(true);
create table piti_private.account_deletion_requests (
 id uuid primary key,
 user_id uuid unique references auth.users(id) on delete set null,
 role text not null check(role in ('pt','member')),
 receipt_hash text not null check(receipt_hash ~ '^[a-f0-9]{64}$'),
 policy_version text not null,
 state text not null default 'requested' check(state in ('requested','processing','needs_attention','completed')),
 requested_at timestamptz not null default now(),
 deadline_at timestamptz not null,
 completed_at timestamptz,
 check(state<>'completed' or (completed_at is not null and user_id is null))
);
alter table piti_private.account_deletion_settings enable row level security;
alter table piti_private.account_deletion_requests enable row level security;
revoke all on piti_private.account_deletion_settings,piti_private.account_deletion_requests from public,anon,authenticated;

create function piti_private.deletion_summary(p_user uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('role',p.role,'linked_clients',(select count(*) from public.clients c where c.pt_id=p.id and c.user_id is not null),
 'client_records',(select count(*) from public.clients c where c.pt_id=p.id or c.user_id=p.id),
 'past_transfers',(select count(*) from public.trainer_transfers t where t.member_id=p.id or t.old_pt_id=p.id or t.new_pt_id=p.id))
 from public.profiles p where p.id=p_user
$$;
revoke all on function piti_private.deletion_summary(uuid) from public,anon,authenticated;

create function piti_private.account_deletion_preview() returns jsonb
language plpgsql security definer set search_path='' as $$
declare cfg piti_private.account_deletion_settings; summary jsonb; request jsonb; allowed boolean;
begin
 if auth.uid() is null or not coalesce(piti_private.access_ready(),false) then raise exception 'Aktif oturum gerekli.' using errcode='42501'; end if;
 select * into strict cfg from piti_private.account_deletion_settings where id;
 summary=piti_private.deletion_summary(auth.uid());
 if summary is null then raise exception 'Hesap bulunamadı.'; end if;
 -- Admin removal also needs an MFA/ownership succession flow, not password-only.
 allowed=cfg.enabled and cfg.worker_ready and cfg.max_hours is not null and length(cfg.notice)>0 and length(cfg.policy_version)>0
 and not exists(select 1 from piti_private.admin_users where user_id=auth.uid());
 select jsonb_build_object('id',id,'state',state,'requested_at',requested_at,'deadline_at',deadline_at,'completed_at',completed_at)
 into request from piti_private.account_deletion_requests where user_id=auth.uid();
 return jsonb_build_object('available',allowed,'summary',summary,'notice',cfg.notice,'max_hours',cfg.max_hours,
 'fingerprint',md5(summary::text||cfg.policy_version||cfg.notice||coalesce(cfg.max_hours::text,'')),'request',request);
end $$;
create function public.account_deletion_preview() returns jsonb
language sql security invoker set search_path='' as $$select piti_private.account_deletion_preview()$$;
revoke all on function public.account_deletion_preview(),piti_private.account_deletion_preview() from public,anon;
grant execute on function public.account_deletion_preview(),piti_private.account_deletion_preview() to authenticated;

-- Only the Edge Function can submit after verifying the current password.
-- Session and account state are checked again here to close a revocation race.
create function piti_private.account_deletion_request(p_user uuid,p_session uuid,p_id uuid,p_receipt_hash text,p_fingerprint text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare cfg piti_private.account_deletion_settings; summary jsonb; job piti_private.account_deletion_requests;
begin
 if p_user is null or p_session is null or p_id is null or p_receipt_hash is null or p_receipt_hash !~ '^[a-f0-9]{64}$' then raise exception 'Geçersiz talep.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_user::text,9951));
 if not exists(select 1 from auth.sessions s join public.profiles p on p.id=s.user_id
  where s.id=p_session and s.user_id=p_user and (s.not_after is null or s.not_after>now()) and not p.must_change_password)
 or exists(select 1 from piti_private.account_controls where user_id=p_user and (suspended or archived))
 or exists(select 1 from piti_private.admin_users where user_id=p_user) then raise exception 'Geçerli hesap oturumu gerekli.' using errcode='42501'; end if;
 select * into job from piti_private.account_deletion_requests where user_id=p_user;
 if found then
  if job.id=p_id and job.receipt_hash=p_receipt_hash then return jsonb_build_object('id',job.id,'state',job.state,'deadline_at',job.deadline_at); end if;
  raise exception 'Silme talebin zaten var. Durumunu yeniden yükle.';
 end if;
 select * into strict cfg from piti_private.account_deletion_settings where id for share;
 if not cfg.enabled or not cfg.worker_ready or cfg.max_hours is null or cfg.policy_version='' or cfg.notice='' then raise exception 'Hesap silme henüz etkin değil.'; end if;
 summary=piti_private.deletion_summary(p_user);
 if summary is null or p_fingerprint is distinct from md5(summary::text||cfg.policy_version||cfg.notice||cfg.max_hours::text) then raise exception 'Silme özeti değişti. Yeniden yükle.'; end if;
 insert into piti_private.account_deletion_requests(id,user_id,role,receipt_hash,policy_version,deadline_at)
 values(p_id,p_user,summary->>'role',p_receipt_hash,cfg.policy_version,now()+make_interval(hours=>cfg.max_hours)) returning * into job;
 return jsonb_build_object('id',job.id,'state',job.state,'deadline_at',job.deadline_at);
end $$;
create function piti_private.account_deletion_receipt(p_id uuid,p_receipt_hash text) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('id',id,'state',state,'deadline_at',deadline_at,'completed_at',completed_at)
 from piti_private.account_deletion_requests where id=p_id and receipt_hash=p_receipt_hash
$$;
-- Receipt status needs a definer boundary too; never expose the private table.
alter function piti_private.account_deletion_receipt(uuid,text) security definer;
create function public.account_deletion_request(p_user uuid,p_session uuid,p_id uuid,p_receipt_hash text,p_fingerprint text) returns jsonb
language sql security invoker set search_path='' as $$select piti_private.account_deletion_request(p_user,p_session,p_id,p_receipt_hash,p_fingerprint)$$;
create function public.account_deletion_receipt(p_id uuid,p_receipt_hash text) returns jsonb
language sql security invoker set search_path='' as $$select piti_private.account_deletion_receipt(p_id,p_receipt_hash)$$;
revoke all on function public.account_deletion_request(uuid,uuid,uuid,text,text),piti_private.account_deletion_request(uuid,uuid,uuid,text,text),
 public.account_deletion_receipt(uuid,text),piti_private.account_deletion_receipt(uuid,text) from public,anon,authenticated;
grant usage on schema piti_private to service_role;
grant execute on function public.account_deletion_request(uuid,uuid,uuid,text,text),piti_private.account_deletion_request(uuid,uuid,uuid,text,text),
 public.account_deletion_receipt(uuid,text),piti_private.account_deletion_receipt(uuid,text) to service_role;
commit;
