begin;
-- Preparation only: no Auth user, Storage object or historical row is deleted.
alter table piti_private.account_deletion_requests add column prepared_at timestamptz;
alter table piti_private.account_deletion_requests add column preparation_result jsonb;
create table piti_private.account_deletion_links (
 deletion_id uuid not null references piti_private.account_deletion_requests(id),
 old_client_id uuid not null,
 member_id uuid references auth.users(id) on delete set null,
 new_client_id uuid references public.clients(id) on delete set null,
 primary key(deletion_id,old_client_id)
);
alter table piti_private.account_deletion_links enable row level security;
revoke all on piti_private.account_deletion_links from public,anon,authenticated;

-- Prevent a stale invitation or in-flight create from attaching to a deleting PT
-- after preparation commits. Closing an existing relationship remains allowed.
create function piti_private.guard_deleting_trainer_link() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' or new.pt_id is distinct from old.pt_id or new.user_id is distinct from old.user_id then
  if new.pt_id is not null and new.relationship_ended_at is null
   and exists(select 1 from piti_private.account_deletion_requests where user_id=new.pt_id and state in ('processing','needs_attention','completed'))
  then raise exception 'Bu PT hesabı silinme sürecinde. Başka bir PT seç.' using errcode='42501'; end if;
 end if;
 return new;
end $$;
revoke all on function piti_private.guard_deleting_trainer_link() from public,anon,authenticated;
create trigger guard_deleting_trainer_link before insert or update on public.clients
 for each row execute function piti_private.guard_deleting_trainer_link();

create function piti_private.prepare_trainer_deletion(p_job uuid) returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='2s' as $$
declare job piti_private.account_deletion_requests; cfg piti_private.account_deletion_settings;
 c public.clients; new_id uuid; linked integer=0; retained integer; cancelled integer; result jsonb;
begin
 select * into job from piti_private.account_deletion_requests where id=p_job for update;
 if not found or job.role<>'pt' or job.user_id is null then raise exception 'PT silme işi bulunamadı.'; end if;
 if job.prepared_at is not null then return job.preparation_result; end if;
 select * into strict cfg from piti_private.account_deletion_settings where id for share;
 if not cfg.enabled or not cfg.worker_ready then raise exception 'Hesap silme henüz etkin değil.'; end if;
 if job.state not in ('requested','processing','needs_attention') or
 not exists(select 1 from public.profiles where id=job.user_id and role='pt') or
 exists(select 1 from piti_private.admin_users where user_id=job.user_id)
 then raise exception 'Silme işi hazırlanamıyor.' using errcode='42501'; end if;

 -- Deliberately short, coarse write barrier for the first implementation.
 -- Reads continue. Lock timeout/deadlock aborts the entire transaction for retry.
 -- This includes member writes and legacy snapshot writers, not only PT writes.
 lock table public.clients,public.sessions,public.packages,public.payments,
 public.messages,public.tasks,public.availability,public.client_history,
 public.account_state,public.trainer_transfers in share row exclusive mode;
 update piti_private.account_deletion_requests set state='processing' where id=job.id;
 insert into piti_private.account_controls(user_id,suspended) values(job.user_id,true)
 on conflict(user_id) do update set suspended=true;
 update piti_private.push_devices set enabled=false where user_id=job.user_id;
 delete from auth.sessions where user_id=job.user_id;

 -- Cancel future requests/plans while the relationship is still writable.
 update public.sessions s set status='cancelled',counts_against_package=false,updated_at=now()
 from public.clients source where source.id=s.client_id and source.pt_id=job.user_id
 and source.relationship_ended_at is null and s.status in ('planned','requested') and s.starts_at>=now();
 get diagnostics cancelled=row_count;
 perform piti_private.capture_member_retained_history(job.id);
 -- Never detach if even one entitled member's history is missing.
 if exists(
  (select source.user_id,source.id from public.clients source where source.pt_id=job.user_id and source.user_id is not null and source.user_id<>job.user_id
   union select t.member_id,t.old_client_id from public.trainer_transfers t join auth.users u on u.id=t.member_id where t.old_pt_id=job.user_id and t.member_id<>job.user_id)
  except select h.member_id,h.source_client_id from piti_private.member_retained_history h where h.deletion_id=job.id
 ) then raise exception 'Müşteri geçmişi arşivi eksik. İşlem geri alındı.'; end if;
 select count(*) into retained from piti_private.member_retained_history where deletion_id=job.id;

 for c in select * from public.clients where pt_id=job.user_id and relationship_ended_at is null order by id loop
  new_id=null;
  update public.clients set user_id=null,archived=true,relationship_ended_at=now(),updated_at=now() where id=c.id;
  if c.user_id is not null then
   if c.user_id=job.user_id or not exists(select 1 from public.profiles where id=c.user_id and role='member') then raise exception 'Bağlı müşteri hesabının rolü geçersiz.'; end if;
   insert into public.clients(user_id,pt_id,full_name,phone,email,blood_type,gender,weight,height)
   values(c.user_id,null,c.full_name,c.phone,c.email,c.blood_type,c.gender,c.weight,c.height) returning id into new_id;
   -- Empty shell can be linked again without transferring old balances/history.
   delete from public.account_state where user_id=c.user_id;
   update piti_private.transfer_invitations set revoked_at=now() where member_id=c.user_id and used_at is null and revoked_at is null;
   insert into public.transfer_notifications(recipient_id,body)
   values(c.user_id,'PT hesabının silinme işlemi başladı. PT bağlantın sona erdi. Seans ve ödeme geçmişin PT’im ekranındaki arşivde korunuyor.');
   linked=linked+1;
  end if;
  insert into piti_private.account_deletion_links(deletion_id,old_client_id,member_id,new_client_id) values(job.id,c.id,c.user_id,new_id);
 end loop;
 -- Already closed relationships remain immutable. Their archives were captured
 -- through trainer_transfers; their member's current relationship is untouched.
 update public.client_invitations set revoked_at=now() where pt_id=job.user_id and used_at is null and revoked_at is null;
 update piti_private.transfer_invitations set revoked_at=now() where pt_id=job.user_id and used_at is null and revoked_at is null;
 update piti_private.entry_links set revoked_at=now() where revoked_at is null and
 (user_id=job.user_id or client_id in(select id from public.clients where pt_id=job.user_id));
 delete from piti_private.push_deliveries where recipient_id=job.user_id or client_id in(select id from public.clients where pt_id=job.user_id);
 delete from public.account_state where user_id=job.user_id;
 result=jsonb_build_object('state','processing','phase','prepared','detached_members',linked,'retained_histories',retained,'cancelled_sessions',cancelled);
 update piti_private.account_deletion_requests set prepared_at=now(),preparation_result=result where id=job.id;
 return result;
end $$;
create function public.prepare_trainer_deletion(p_job uuid) returns jsonb
language sql security invoker set search_path='' as $$select piti_private.prepare_trainer_deletion(p_job)$$;
revoke all on function public.prepare_trainer_deletion(uuid),piti_private.prepare_trainer_deletion(uuid) from public,anon,authenticated;
grant execute on function public.prepare_trainer_deletion(uuid),piti_private.prepare_trainer_deletion(uuid) to service_role;
commit;
