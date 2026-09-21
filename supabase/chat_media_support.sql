-- PiTi chat media support. Apply to a non-production Supabase project first.
alter table public.messages
  add column if not exists message_type text not null default 'text',
  add column if not exists media_path text,
  add column if not exists media_mime text,
  add column if not exists media_size bigint,
  add column if not exists media_width integer,
  add column if not exists media_height integer,
  add column if not exists media_duration numeric(7,1);

alter table public.messages drop constraint if exists messages_message_type_check;
alter table public.messages add constraint messages_message_type_check
  check (message_type in ('text','image','video','audio'));

alter table public.messages drop constraint if exists messages_content_check;
alter table public.messages add constraint messages_content_check
  check (
    nullif(btrim(body),'') is not null
    or sticker is not null
    or (message_type <> 'text' and media_path is not null)
  );

alter table public.messages drop constraint if exists messages_media_path_check;
alter table public.messages add constraint messages_media_path_check
  check (
    media_path is null
    or media_path like client_id::text || '/' || id::text || '/%'
  );

alter table public.messages drop constraint if exists messages_media_metadata_check;
alter table public.messages add constraint messages_media_metadata_check
  check (
    (message_type = 'text' and media_path is null and media_mime is null and media_size is null)
    or
    (message_type = 'image' and media_path is not null and media_mime = 'image/jpeg'
      and media_size between 1 and 15728640
      and media_width > 0 and media_height > 0
      and greatest(media_width,media_height) <= 1920
      and least(media_width,media_height) <= 1080)
    or
    (message_type = 'video' and media_path is not null
      and media_mime in ('video/mp4','video/webm','video/quicktime')
      and media_size between 1 and 15728640
      and media_duration > 0 and media_duration <= 60.5
      and media_width > 0 and media_height > 0
      and greatest(media_width,media_height) <= 854
      and least(media_width,media_height) <= 480)
    or
    (message_type = 'audio' and media_path is not null
      and media_mime in ('audio/mp4','audio/webm','audio/ogg','audio/mpeg')
      and media_size between 1 and 15728640
      and media_duration > 0 and media_duration <= 180.5
      and media_width is null and media_height is null)
  );

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values (
  'chat-media',
  'chat-media',
  false,
  15728640,
  array['image/jpeg','video/mp4','video/webm','video/quicktime','audio/mp4','audio/webm','audio/ogg','audio/mpeg']
)
on conflict (id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists chat_media_read on storage.objects;
create policy chat_media_read on storage.objects
for select to authenticated
using (
  bucket_id='chat-media'
  and (select piti_private.access_ready())
  and exists (
    select 1 from public.clients c
    where c.id::text=(storage.foldername(name))[1]
      and (
        (c.pt_id=(select auth.uid()) and (select piti_private.account_role())='pt')
        or
        (c.user_id=(select auth.uid()) and c.pt_id is not null and (select piti_private.account_role())='member')
      )
  )
);

drop policy if exists chat_media_insert on storage.objects;
create policy chat_media_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='chat-media'
  and owner_id=(select auth.uid())::text
  and (select piti_private.access_ready())
  and exists (
    select 1 from public.clients c
    where c.id::text=(storage.foldername(name))[1]
      and (
        (c.pt_id=(select auth.uid()) and (select piti_private.account_role())='pt')
        or
        (c.user_id=(select auth.uid()) and c.pt_id is not null and (select piti_private.account_role())='member')
      )
  )
);

drop policy if exists chat_media_delete_own on storage.objects;
create policy chat_media_delete_own on storage.objects
for delete to authenticated
using (
  bucket_id='chat-media'
  and owner_id=(select auth.uid())::text
  and (select piti_private.access_ready())
  and exists (
    select 1 from public.clients c
    where c.id::text=(storage.foldername(name))[1]
      and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid()))
  )
);

comment on column public.messages.message_type is 'text, image, video, or audio';
comment on column public.messages.media_path is 'Private chat-media bucket object path; never a public URL';

-- Match existing column-level grants; recipients can update read_at only.
grant insert(message_type,media_path,media_mime,media_size,media_width,media_height,media_duration) on public.messages to authenticated;
grant select(message_type,media_path,media_mime,media_size,media_width,media_height,media_duration) on public.messages to authenticated;
create or replace function piti_private.guard_message() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='INSERT' then
  if new.sender_id is distinct from auth.uid() and current_user='authenticated' then raise exception 'Mesaj göndereni değiştirilemez.';end if;
  if current_user='authenticated' then new.created_at=now();new.read_at=null;end if;
  new.sender_role=(select role from public.profiles where id=new.sender_id);
  if char_length(coalesce(new.body,''))>4000 or (nullif(trim(new.body),'') is null and new.media_path is null and new.sticker is null) then raise exception 'Mesaj veya medya gerekli.';end if;
  if new.media_path is not null and current_user='authenticated' and not exists(
   select 1 from storage.objects o where o.bucket_id='chat-media' and o.name=new.media_path
    and o.owner_id=auth.uid()::text and (o.metadata->>'size')::bigint=new.media_size
  ) then raise exception 'Medya yüklemesi doğrulanamadı.';end if;
 elsif current_user='authenticated' then
  if (to_jsonb(new)-'read_at') is distinct from (to_jsonb(old)-'read_at') then raise exception 'Mesaj içeriği değiştirilemez.';end if;
  new.read_at=coalesce(old.read_at,now());
 end if;
 return new;
end $$;
-- NULL must never bypass media metadata checks.
alter table public.messages add constraint messages_media_required check (
 message_type='text' or (media_path is not null and media_mime is not null and media_size is not null
 and (message_type='image' or media_duration is not null)
 and (message_type='audio' or (media_width is not null and media_height is not null))));
