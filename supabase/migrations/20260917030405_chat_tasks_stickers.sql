begin;
alter table public.messages add column sticker text check(sticker in ('water','weigh','meal','move','sleep','cheer'));
grant insert(sticker) on public.messages to authenticated;
create function piti_private.guard_sticker() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='UPDATE' and new.sticker is distinct from old.sticker then raise exception 'Sticker değiştirilemez.'; end if;
 return new;
end $$;
create trigger protect_sticker before update on public.messages for each row execute function piti_private.guard_sticker();
alter table public.tasks add column message_id uuid unique references public.messages(id) on delete cascade,
 add column response_type text not null default 'done' check(response_type in ('done','kg','litre','photo')),
 add column result_photo text check(result_photo is null or (length(result_photo)<=700000 and result_photo ~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$')),
 add column completed_at timestamptz;
create index if not exists tasks_client_due_idx on public.tasks(client_id,due_at);
create index if not exists tasks_pt_idx on public.tasks(pt_id);
drop policy tasks_access on public.tasks;
revoke all on public.tasks from anon,authenticated;
grant select on public.tasks to authenticated;
grant insert(id,client_id,pt_id,title,due_at,message_id,response_type) on public.tasks to authenticated;
grant update(status,result,result_photo) on public.tasks to authenticated;
create policy tasks_read on public.tasks for select to authenticated using(exists(select 1 from public.clients c where c.id=client_id and (c.pt_id=(select auth.uid()) or c.user_id=(select auth.uid()))));
create policy tasks_assign on public.tasks for insert to authenticated with check(pt_id=(select auth.uid()) and (select piti_private.account_role())='pt' and exists(select 1 from public.clients c where c.id=client_id and c.pt_id=(select auth.uid()) and not c.archived));
create policy tasks_complete on public.tasks for update to authenticated using((select piti_private.account_role())='member' and exists(select 1 from public.clients c where c.id=client_id and c.user_id=(select auth.uid()))) with check((select piti_private.account_role())='member' and exists(select 1 from public.clients c where c.id=client_id and c.user_id=(select auth.uid())));
create function piti_private.guard_chat_task() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if current_user<>'authenticated' then return new; end if;
 if tg_op='INSERT' then
  if new.due_at is null or new.due_at<=now() then raise exception 'Gelecekte bir son tarih seç.'; end if;
  if char_length(btrim(new.title))<1 or char_length(new.title)>4000 then raise exception 'Görev açıklaması geçersiz.'; end if;
  if new.message_id is null or not exists(select 1 from public.messages m where m.id=new.message_id and m.client_id=new.client_id and m.sender_id=auth.uid() and m.sender_role='pt') then raise exception 'Yalnızca kendi mesajını göreve dönüştürebilirsin.'; end if;
 else
  if old.status='done' then raise exception 'Görev zaten tamamlandı.'; end if;
  if new.status<>'done' then raise exception 'Görev yalnızca tamamlanabilir.'; end if;
  if new.response_type in ('kg','litre') then
   if new.result is null or new.result !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' then raise exception 'Geçerli bir sayı gir.'; end if;
   if new.result::numeric<=0 or (new.response_type='kg' and new.result::numeric>700) or (new.response_type='litre' and new.result::numeric>100) then raise exception 'Geçerli bir sayı gir.'; end if;
   new.result_photo=null;
  elsif new.response_type='photo' then
   if new.result_photo is null then raise exception 'Fotoğraf ekle.'; end if;
   new.result='Fotoğraf gönderildi';
  else new.result='Tamamlandı';new.result_photo=null;
  end if;
  new.completed_at=now();
 end if;
 return new;
end $$;
create trigger protect_chat_task before insert or update on public.tasks for each row execute function piti_private.guard_chat_task();
create function public.assign_chat_task(p_client_id uuid,p_message_id uuid,p_body text,p_sticker text,p_due_at timestamptz,p_response_type text,p_create_message boolean)
returns uuid language plpgsql security invoker set search_path='' as $$
declare mid uuid; tid uuid; msg public.messages;
begin
 if auth.uid() is null or not piti_private.access_ready() or piti_private.account_role()<>'pt' then raise exception 'Görev atamak için PT hesabı gerekli.'; end if;
 -- The client-supplied message UUID makes a retried request idempotent.
 select * into msg from public.messages where id=p_message_id;
 if found then
  if msg.client_id<>p_client_id or msg.sender_id<>auth.uid() then raise exception 'Mesaj bulunamadı.'; end if;
  select id into tid from public.tasks where message_id=msg.id;
  if tid is not null then return tid; end if;
 elsif p_create_message then
  insert into public.messages(id,client_id,sender_id,body,sticker) values(p_message_id,p_client_id,auth.uid(),p_body,p_sticker) returning * into msg;
 else raise exception 'Mesaj bulunamadı.';
 end if;
 insert into public.tasks(client_id,pt_id,title,due_at,message_id,response_type)
 values(p_client_id,auth.uid(),msg.body,p_due_at,msg.id,p_response_type) returning id into tid;
 return tid;
end $$;
revoke all on function public.assign_chat_task(uuid,uuid,text,text,timestamptz,text,boolean) from public,anon;
grant execute on function public.assign_chat_task(uuid,uuid,text,text,timestamptz,text,boolean) to authenticated;
revoke all on function piti_private.guard_chat_task(),piti_private.guard_sticker() from public,anon,authenticated;
commit;
