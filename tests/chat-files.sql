begin;
create temporary table attachment_check (like public.messages including constraints);
do $test$
declare c uuid:=gen_random_uuid();m uuid:=gen_random_uuid(); rejected int:=0;
begin
 insert into attachment_check(id,client_id,message_type,body,created_at) values (m,c,'text','existing message',now());
 insert into attachment_check(id,client_id,message_type,media_path,media_name,media_mime,media_size,created_at)
 values(m,c,'file',c::text||'/'||m::text||'/file.pdf','Antrenman planı.pdf','application/pdf',128,now());
 begin update attachment_check set media_size=15728641 where message_type='file'; exception when check_violation then rejected:=rejected+1;end;
 begin update attachment_check set media_name=null where message_type='file'; exception when check_violation then rejected:=rejected+1;end;
 begin update attachment_check set media_mime='text/html' where message_type='file'; exception when check_violation then rejected:=rejected+1;end;
 begin update attachment_check set media_size=null where message_type='file'; exception when check_violation then rejected:=rejected+1;end;
 begin update attachment_check set media_name='../file.pdf' where message_type='file'; exception when check_violation then rejected:=rejected+1;end;
 begin update attachment_check set media_path='other/path/file.pdf' where message_type='file'; exception when check_violation then rejected:=rejected+1;end;
 if rejected<>6 then raise exception 'Expected six rejected invalid attachments, got %',rejected;end if;
 if not exists(select 1 from storage.buckets where id='chat-media' and not public and file_size_limit=15728640 and 'application/pdf'=any(allowed_mime_types)) then raise exception 'Private bucket restriction failed';end if;
 if not has_column_privilege('authenticated','public.messages','media_name','INSERT') or has_column_privilege('anon','public.messages','media_name','INSERT') then raise exception 'Attachment grant check failed';end if;
end $test$;
rollback;
select 'PASS: valid text/file; rejected oversized, missing name/size, HTML, unsafe name and foreign path; private bucket and grants preserved' as result;
