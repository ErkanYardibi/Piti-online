begin;
alter table public.clients add column relationship_ended_at timestamptz;
create table public.trainer_transfers (
 id uuid primary key default gen_random_uuid(), member_id uuid not null,
 old_client_id uuid not null unique, new_client_id uuid not null,
 old_pt_id uuid not null, new_pt_id uuid not null,
 created_at timestamptz not null default now(), measurements_shared boolean not null,
 snapshot jsonb not null
);
create table public.transfer_notifications (
 id uuid primary key default gen_random_uuid(), recipient_id uuid not null,
 body text not null, created_at timestamptz not null default now(), read_at timestamptz
);
create table piti_private.transfer_invitations (
 id uuid primary key default gen_random_uuid(), member_id uuid not null,
 pt_id uuid not null, token_hash text not null unique,
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '7 days',
 used_at timestamptz, revoked_at timestamptz
);
alter table public.trainer_transfers enable row level security;
alter table public.transfer_notifications enable row level security;
alter table piti_private.transfer_invitations enable row level security;
revoke all on public.trainer_transfers,public.transfer_notifications,piti_private.transfer_invitations from public,anon,authenticated;
grant select on public.trainer_transfers,public.transfer_notifications to authenticated;
create policy own_transfer_history on public.trainer_transfers for select to authenticated
 using((select piti_private.access_ready()) and member_id=(select auth.uid()));
create policy own_transfer_notifications on public.transfer_notifications for select to authenticated
 using((select piti_private.access_ready()) and recipient_id=(select auth.uid()));

-- Every child write locks its relationship: transfer and stale writes serialize.
create function piti_private.protect_closed_relationship() returns trigger
language plpgsql security definer set search_path='' as $$
declare cid uuid; ended timestamptz;
begin
 if tg_table_name='clients' then
  if tg_op='UPDATE' and old.relationship_ended_at is not null then
   if (to_jsonb(new)-'updated_at') is distinct from (to_jsonb(old)-'updated_at') then raise exception 'PT ilişkisi sona erdi. Geçmiş kayıt salt okunur.';end if;
  elsif tg_op='DELETE' and old.relationship_ended_at is not null then raise exception 'PT ilişkisi geçmişi silinemez.';
  elsif tg_op='UPDATE' and new.relationship_ended_at is distinct from old.relationship_ended_at and current_setting('role',true) in ('authenticated','anon') and current_user<>'postgres' then
   raise exception 'İlişki yalnızca PT geçişi ile kapatılabilir.';
  end if;
 else
  cid=case when tg_op='DELETE' then old.client_id else new.client_id end;
  select relationship_ended_at into ended from public.clients where id=cid for share;
  if ended is not null then raise exception 'PT ilişkisi sona erdi. Geçmiş kayıt salt okunur.';end if;
  if tg_op='UPDATE' and old.client_id is distinct from new.client_id then
   select relationship_ended_at into ended from public.clients where id=old.client_id for share;
   if ended is not null then raise exception 'PT ilişkisi geçmişi taşınamaz.';end if;
  end if;
 end if;
 return case when tg_op='DELETE' then old else new end;
end $$;
revoke all on function piti_private.protect_closed_relationship() from public,anon,authenticated;
create trigger protect_closed_relationship before update or delete on public.clients for each row execute function piti_private.protect_closed_relationship();
do $$declare t text;begin foreach t in array array['sessions','packages','payments','messages','tasks','availability','client_history'] loop
 execute format('create trigger protect_closed_relationship before insert or update or delete on public.%I for each row execute function piti_private.protect_closed_relationship()',t);
end loop;end $$;
-- Column ACL prevents clients from forging the lifecycle flag; definer transfer owns it.
revoke update on public.clients from authenticated;
grant update(id,pt_id,user_id,full_name,phone,email,blood_type,gender,weight,height,archived,created_at,updated_at) on public.clients to authenticated;
revoke insert on public.clients from authenticated;
grant insert(id,pt_id,user_id,full_name,phone,email,blood_type,gender,weight,height,archived,created_at,updated_at) on public.clients to authenticated;
create function piti_private.guard_member_snapshot_relationship() returns trigger language plpgsql security definer set search_path='' as $$
declare active_id uuid;
begin
 if exists(select 1 from public.profiles where id=new.user_id and role='member') then
  select id into active_id from public.clients where user_id=new.user_id;
  if active_id is not null and new.data#>>'{customer,dbId}' is distinct from active_id::text then
   raise exception 'PT bağlantısı değişti. Sayfayı yenileyip tekrar giriş yap.';
  end if;
 end if;
 return new;
end $$;
revoke all on function piti_private.guard_member_snapshot_relationship() from public,anon,authenticated;
create trigger guard_member_snapshot_relationship before insert or update on public.account_state for each row execute function piti_private.guard_member_snapshot_relationship();

create function piti_private.trainer_transfer(p_action text,p_args jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare inv piti_private.transfer_invitations; old_c public.clients; target_user uuid;
 token text; new_id uuid; snapshot jsonb; hist jsonb; weights jsonb; pt_name text; old_name text;
 share_weights boolean; fingerprint text; future_count integer; receipt_id uuid;
begin
 if not piti_private.access_ready() then raise exception 'Geçerli oturum gerekli.' using errcode='42501';end if;
 if p_action='ack' then
  update public.transfer_notifications set read_at=now() where id=(p_args->>'id')::uuid and recipient_id=auth.uid();return '{"ok":true}';
 end if;
 if p_action='create' then
  if piti_private.account_role()<>'pt' then raise exception 'PT hesabı gerekli.' using errcode='42501';end if;
  select p.id into target_user from public.profiles p join public.clients c on c.user_id=p.id
  where lower(p.username)=lower(trim(p_args->>'username')) and p.role='member' and c.pt_id is not null and c.pt_id<>auth.uid() and not c.archived;
  if target_user is null then raise exception 'Geçişe uygun müşteri kullanıcı adı bulunamadı.';end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||target_user::text,1));
  update piti_private.transfer_invitations set revoked_at=now() where member_id=target_user and pt_id=auth.uid() and used_at is null and revoked_at is null;
  token='TRANSFER-'||upper(encode(extensions.gen_random_bytes(16),'hex'));
  insert into piti_private.transfer_invitations(member_id,pt_id,token_hash) values(target_user,auth.uid(),encode(extensions.digest(token,'sha256'),'hex')) returning * into inv;
  return jsonb_build_object('code',token,'expires_at',inv.expires_at);
 end if;
 if p_action not in ('preview','accept') or piti_private.account_role()<>'member' then raise exception 'Müşteri hesabı gerekli.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 select * into inv from piti_private.transfer_invitations where token_hash=encode(extensions.digest(upper(trim(p_args->>'code')),'sha256'),'hex') for update;
 if inv.id is null or inv.member_id<>auth.uid() or inv.used_at is not null or inv.revoked_at is not null or inv.expires_at<=now() then raise exception 'Davet geçersiz, başka hesaba ait veya süresi dolmuş.';end if;
 select * into old_c from public.clients where user_id=auth.uid() for update;
 if old_c.id is null or old_c.pt_id is null or old_c.pt_id=inv.pt_id or old_c.archived then raise exception 'Mevcut PT bağlantısı geçişe uygun değil.';end if;
 select full_name into pt_name from public.profiles where id=inv.pt_id and role='pt';
 if pt_name is null or exists(select 1 from piti_private.account_controls where user_id=inv.pt_id and (suspended or archived)) then raise exception 'Yeni PT hesabı aktif değil.';end if;
 select full_name into old_name from public.profiles where id=old_c.pt_id;
 select coalesce(data,'{}') into hist from public.client_history where client_id=old_c.id;
 hist=coalesce(hist,'{}');
 select count(*) into future_count from public.sessions where client_id=old_c.id and status='planned' and starts_at>=now();
 -- Preview is invalidated by changed client/history/session details.
 select md5(to_jsonb(old_c)::text||hist::text||coalesce((select jsonb_agg(to_jsonb(s) order by s.id)::text from public.sessions s where s.client_id=old_c.id),'[]')) into fingerprint;
 if p_action='preview' then
  return jsonb_build_object('old_pt',old_name,'new_pt',pt_name,'old_client_id',old_c.id,'fingerprint',fingerprint,'future_sessions',future_count,'package',hist->'package','payment',hist->'payment');
 end if;
 if p_args->>'fingerprint' is distinct from fingerprint or (p_args->>'old_client_id')::uuid is distinct from old_c.id then raise exception 'Bilgiler değişmiş. Geçiş özetini yeniden aç.';end if;
 if coalesce((p_args->>'confirmed')::boolean,false) is not true then raise exception 'Geçişi açıkça onayla.';end if;
 share_weights=coalesce((p_args->>'share_measurements')::boolean,false);
 -- Cancel future appointments only after the member explicitly approves the summary.
 update public.sessions set status='cancelled',counts_against_package=false,updated_at=now() where client_id=old_c.id and status='planned' and starts_at>=now();
 select jsonb_build_object('trainer',old_name,'client',to_jsonb(old_c),'history',hist,
  'sessions',(select coalesce(jsonb_agg(to_jsonb(t) order by starts_at),'[]') from public.sessions t where client_id=old_c.id),
  'messages',(select coalesce(jsonb_agg(to_jsonb(t) order by created_at),'[]') from public.messages t where client_id=old_c.id),
  'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by created_at),'[]') from public.tasks t where client_id=old_c.id),
  'packages',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.packages t where client_id=old_c.id),
  'payments',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from public.payments t where client_id=old_c.id)) into snapshot;
 weights=coalesce(hist->'progressData','[]');
 weights=weights||coalesce((select jsonb_agg(jsonb_build_object('date',(completed_at at time zone 'Europe/Istanbul')::date,'w',result::numeric,'taskId',id)) from public.tasks where client_id=old_c.id and status='done' and response_type='kg' and result ~ '^[0-9]+([.][0-9]+)?$'),'[]');
 snapshot=snapshot||jsonb_build_object('measurements',weights);
 update public.clients set user_id=null,archived=true,relationship_ended_at=now(),updated_at=now() where id=old_c.id;
 insert into public.clients(user_id,pt_id,full_name,phone,email,blood_type,gender,weight,height)
 values(auth.uid(),inv.pt_id,old_c.full_name,old_c.phone,old_c.email,null,null,case when share_weights then old_c.weight else null end,null) returning id into new_id;
 insert into public.client_history(client_id,data) values(new_id,jsonb_build_object('progressData',case when share_weights then weights else '[]'::jsonb end));
 -- Invalidate the member's old snapshot; stale tabs cannot restore the old client.
 delete from public.account_state where user_id=auth.uid();
 insert into public.trainer_transfers(member_id,old_client_id,new_client_id,old_pt_id,new_pt_id,measurements_shared,snapshot)
 values(auth.uid(),old_c.id,new_id,old_c.pt_id,inv.pt_id,share_weights,snapshot) returning id into receipt_id;
 update piti_private.transfer_invitations set used_at=now() where id=inv.id;
 update piti_private.transfer_invitations set revoked_at=now() where member_id=auth.uid() and id<>inv.id and used_at is null and revoked_at is null;
 insert into public.transfer_notifications(recipient_id,body) values
 (old_c.pt_id,old_c.full_name||' başka bir PT’ye geçti. İlişkiniz kapatıldı; geçmiş kayıtlarınız arşivde korundu. İleri tarihli planlı seanslar iptal edildi.'),
 (inv.pt_id,old_c.full_name||' PT geçişini onayladı. Yeni müşteri ilişkiniz başladı.'),
 (auth.uid(),'PT geçişin tamamlandı. Yeni PT: '||pt_name||'. Eski geçmişini PT’im ekranından açabilirsin.');
 return jsonb_build_object('client_id',new_id,'receipt_id',receipt_id);
end $$;
create function public.trainer_transfer(p_action text,p_args jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select piti_private.trainer_transfer(p_action,p_args)$$;
revoke all on function public.trainer_transfer(text,jsonb),piti_private.trainer_transfer(text,jsonb) from public,anon;
grant execute on function public.trainer_transfer(text,jsonb),piti_private.trainer_transfer(text,jsonb) to authenticated;
commit;
