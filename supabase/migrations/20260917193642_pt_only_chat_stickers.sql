create policy messages_pt_stickers on public.messages as restrictive for insert to authenticated with check (sticker is null or (select piti_private.account_role())='pt');
