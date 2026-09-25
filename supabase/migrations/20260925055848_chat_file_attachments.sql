-- Add private document attachments without changing existing PT/member access policies.
alter table public.messages add column if not exists media_name text;
alter table public.messages drop constraint messages_message_type_check;
alter table public.messages add constraint messages_message_type_check
 check(message_type in ('text','image','video','audio','file'));

-- Preserve all current image/audio/video checks, extending only the file case.
do $migration$
declare current_check text; constraint_name text;
begin
 foreach constraint_name in array array['messages_media_metadata_check','messages_media_required'] loop
  select pg_get_expr(conbin,conrelid) into strict current_check from pg_constraint
   where conrelid='public.messages'::regclass and conname=constraint_name;
  execute format('alter table public.messages drop constraint %I',constraint_name);
  execute format($check$alter table public.messages add constraint %I check ((%s) or (
   message_type='file' and media_path is not null and media_mime is not null
   and media_size is not null and media_size between 1 and 15728640
   and media_mime in ('application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation','text/plain','text/csv','application/zip')
   and media_width is null and media_height is null and media_duration is null
  ))$check$,constraint_name,current_check);
 end loop;
end $migration$;
alter table public.messages add constraint messages_file_name_check check (
 (message_type='file' and media_name is not null and char_length(btrim(media_name)) between 1 and 255
  and media_name !~ '[[:cntrl:]/\\]')
 or (message_type<>'file' and media_name is null)
);
grant select(media_name),insert(media_name) on public.messages to authenticated;
comment on column public.messages.media_name is 'Display filename for private file attachments; never used as an object path';
update storage.buckets set allowed_mime_types=(
 select array_agg(distinct mime) from unnest(allowed_mime_types || array[
 'application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
 'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-powerpoint',
 'application/vnd.openxmlformats-officedocument.presentationml.presentation','text/plain','text/csv','application/zip']) mime
) where id='chat-media' and public=false and file_size_limit=15728640;
