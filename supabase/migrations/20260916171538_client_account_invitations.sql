-- Link a verified account to an existing client without changing that client's ID.
begin;
create schema if not exists piti_private;
revoke all on schema piti_private from public, anon;
grant usage on schema piti_private to authenticated;
create table public.client_invitations (
 id uuid primary key default gen_random_uuid(),
 client_id uuid not null references public.clients(id) on delete cascade,
 pt_id uuid not null references auth.users(id),
 email text not null,
 token_hash text not null unique,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '7 days',
 used_at timestamptz, revoked_at timestamptz,
 used_by uuid references auth.users(id)
);
create index client_invitations_client_idx on public.client_invitations(client_id);
create index client_invitations_pt_idx on public.client_invitations(pt_id);
create index client_invitations_used_by_idx on public.client_invitations(used_by);
alter table public.client_invitations enable row level security;
revoke all on public.client_invitations from anon, authenticated;
grant select(id,client_id,pt_id,email,created_at,expires_at,used_at,revoked_at) on public.client_invitations to authenticated;
create policy invitations_owner_read on public.client_invitations for select to authenticated
 using (pt_id=(select auth.uid()));

-- Preserve the application's existing per-client history, which predates normalized tables.
create table public.client_history (
 client_id uuid primary key references public.clients(id) on delete cascade,
 data jsonb not null default '{}'::jsonb check (jsonb_typeof(data)='object'),
 version integer not null default 1,
 updated_at timestamptz not null default now()
);
alter table public.client_history enable row level security;
revoke all on public.client_history from anon, authenticated;
grant select on public.client_history to authenticated;
create policy history_participants_read on public.client_history for select to authenticated
 using (exists(select 1 from public.clients c where c.id=client_id and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid()))));

-- Ordinary API writes cannot reassign a client's account or trainer.
create function piti_private.guard_client_link() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='UPDATE' and (new.user_id is distinct from old.user_id or new.pt_id is distinct from old.pt_id) then
   raise exception 'Hesap bağlantısı yalnızca müşteri davetiyle değiştirilebilir.';
  elsif tg_op='INSERT' and not (
   (new.user_id=auth.uid() and new.pt_id is null) or
   (new.user_id is null and new.pt_id=auth.uid())
  ) then raise exception 'Geçersiz müşteri sahipliği.';
  end if;
 end if;
 return new;
end $$;
create trigger protect_client_link before insert or update on public.clients
 for each row execute function piti_private.guard_client_link();

create function piti_private.create_client_invitation(p_client_id uuid) returns jsonb
 language plpgsql security definer set search_path='' as $$
declare c public.clients; token text; invitation public.client_invitations;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into c from public.clients where id=p_client_id for update;
 if c.id is null or c.pt_id is distinct from auth.uid() then raise exception 'Bu müşteriye davet oluşturamazsın.'; end if;
 if c.user_id is not null then raise exception 'Müşterinin hesabı zaten bağlı.'; end if;
 if c.archived then raise exception 'Önce müşteriyi aktif hale getir.'; end if;
 if coalesce(c.email,'') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Müşterinin geçerli e-posta adresini kaydet.'; end if;
 update public.client_invitations set revoked_at=now() where client_id=c.id and used_at is null and revoked_at is null;
 token='PITI-'||upper(encode(extensions.gen_random_bytes(16),'hex'));
 insert into public.client_invitations(client_id,pt_id,email,token_hash)
 values(c.id,auth.uid(),lower(trim(c.email)),encode(extensions.digest(token,'sha256'),'hex')) returning * into invitation;
 return jsonb_build_object('id',invitation.id,'code',token,'email',invitation.email,'expires_at',invitation.expires_at);
end $$;
create function piti_private.revoke_client_invitation(p_client_id uuid) returns void
 language plpgsql security definer set search_path='' as $$
declare c public.clients;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into c from public.clients where id=p_client_id for update;
 if c.id is null or c.pt_id is distinct from auth.uid() then raise exception 'Bu daveti iptal edemezsin.'; end if;
 update public.client_invitations set revoked_at=now() where client_id=c.id and used_at is null and revoked_at is null;
end $$;
create function piti_private.redeem_client_invitation(p_code text) returns uuid
 language plpgsql security definer set search_path='' as $$
declare inv public.client_invitations; c public.clients; existing public.clients; verified_email text;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 -- Serialize competing redemptions by the same user, including across different invitations.
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 select lower(trim(email)) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if verified_email is null then raise exception 'Önce e-posta adresini doğrula.'; end if;
 if not exists(select 1 from public.profiles where id=auth.uid() and role='member') then raise exception 'Davet için müşteri hesabıyla giriş yap.'; end if;
 select * into inv from public.client_invitations where token_hash=encode(extensions.digest(upper(trim(p_code)),'sha256'),'hex');
 if inv.id is null then raise exception 'Davet geçersiz veya süresi dolmuş.'; end if;
 select * into c from public.clients where id=inv.client_id for update;
 select * into inv from public.client_invitations where id=inv.id for update;
 if inv.used_at is not null or inv.revoked_at is not null or inv.expires_at<=now() then raise exception 'Davet geçersiz veya süresi dolmuş.'; end if;
 if verified_email<>inv.email then raise exception 'Bu davet başka bir e-posta adresine ait. Davet edilen adresle giriş yap.'; end if;
 if c.user_id is not null or c.archived or c.pt_id is distinct from inv.pt_id or lower(trim(c.email)) is distinct from inv.email then raise exception 'Müşteri bilgileri değişmiş; PT yeni davet oluşturmalı.'; end if;
 select * into existing from public.clients where user_id=auth.uid() for update;
 if existing.id is not null then
  -- Only release an empty self-registration shell; never delete or move existing history.
  if existing.pt_id is not null
   or exists(select 1 from public.sessions where client_id=existing.id)
   or exists(select 1 from public.packages where client_id=existing.id)
   or exists(select 1 from public.payments where client_id=existing.id)
   or exists(select 1 from public.messages where client_id=existing.id)
   or exists(select 1 from public.tasks where client_id=existing.id)
   or exists(select 1 from public.availability where client_id=existing.id)
   or exists(select 1 from public.client_history where client_id=existing.id and data<>'{}'::jsonb)
  then raise exception 'Hesabında başka bir müşteri kaydı veya geçmiş var. Güvenli birleştirme için PT ile iletişime geç.'; end if;
  update public.clients set user_id=null,archived=true where id=existing.id;
 end if;
 update public.clients set user_id=auth.uid(),updated_at=now() where id=c.id;
 update public.client_invitations set used_at=now(),used_by=auth.uid() where id=inv.id;
 return c.id;
end $$;
create function piti_private.save_client_history(p_client_id uuid,p_data jsonb,p_version integer) returns integer
 language plpgsql security definer set search_path='' as $$
declare c public.clients; v integer; old_data jsonb; allowed text[]; k text;
begin
 if auth.uid() is null then raise exception 'Önce giriş yap.'; end if;
 select * into c from public.clients where id=p_client_id for update;
 if c.id is null or (c.pt_id is distinct from auth.uid() and c.user_id is distinct from auth.uid()) then raise exception 'Bu geçmişe erişemezsin.'; end if;
 if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Geçersiz geçmiş verisi.'; end if;
 select version,data into v,old_data from public.client_history where client_id=c.id;
 if coalesce(v,0)<>p_version then raise exception 'Kayıt başka bir cihazda değişti. Sayfayı yenileyip tekrar dene.'; end if;
 if c.pt_id is distinct from auth.uid() then
  allowed=array['messages','tasks','progressData','unread','payment','financeHistory'];
  if (p_data-allowed) is distinct from (coalesce(old_data,'{}'::jsonb)-allowed) then raise exception 'Bu alanı yalnızca PT değiştirebilir.'; end if;
  for k in select jsonb_object_keys(p_data) loop
   if not k=any(allowed) and p_data->k is distinct from old_data->k then raise exception 'Bu alanı yalnızca PT değiştirebilir.'; end if;
  end loop;
  if p_data->'package' is distinct from old_data->'package' then raise exception 'Paketi yalnızca PT değiştirebilir.'; end if;
  if p_data->'payment' is distinct from old_data->'payment' and coalesce(p_data#>>'{payment,status}','')<>'pending' then raise exception 'Ödemeyi yalnızca PT onaylayabilir.'; end if;
 end if;
 insert into public.client_history(client_id,data,version) values(c.id,p_data,1)
 on conflict(client_id) do update set data=excluded.data,version=public.client_history.version+1,updated_at=now()
 returning version into v;
 return v;
end $$;
create function public.create_client_invitation(p_client_id uuid) returns jsonb language sql security invoker set search_path='' as $$select piti_private.create_client_invitation(p_client_id)$$;
create function public.revoke_client_invitation(p_client_id uuid) returns void language sql security invoker set search_path='' as $$select piti_private.revoke_client_invitation(p_client_id)$$;
create function public.redeem_client_invitation(p_code text) returns uuid language sql security invoker set search_path='' as $$select piti_private.redeem_client_invitation(p_code)$$;
create function public.save_client_history(p_client_id uuid,p_data jsonb,p_version integer) returns integer language sql security invoker set search_path='' as $$select piti_private.save_client_history(p_client_id,p_data,p_version)$$;
revoke all on all functions in schema piti_private from public, anon;
grant execute on function piti_private.create_client_invitation(uuid),piti_private.revoke_client_invitation(uuid),piti_private.redeem_client_invitation(text),piti_private.save_client_history(uuid,jsonb,integer) to authenticated;
revoke all on function public.create_client_invitation(uuid),public.revoke_client_invitation(uuid),public.redeem_client_invitation(text),public.save_client_history(uuid,jsonb,integer) from public,anon;
grant execute on function public.create_client_invitation(uuid),public.revoke_client_invitation(uuid),public.redeem_client_invitation(text),public.save_client_history(uuid,jsonb,integer) to authenticated;
commit;
