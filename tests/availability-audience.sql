do $$
declare events jsonb; result jsonb;
begin
 events='[
 {"id":"selected","type":"availability","visibility":"selected","visibleCustomerIds":["a"],"date":"2099-01-01","time":"10:00","note":"private","status":"open"},
 {"id":"none","type":"off","visibility":"none"},
 {"id":"all","type":"off","visibility":"all","note":"secret","title":"private reason"},
 {"id":"legacy","type":"availability","visibility":"Seçili müşteriler görebilir"},
 {"id":"session","type":"session","visibility":"all"},
 {"id":"cancelled","type":"availability","visibility":"all","status":"cancelled"},
 {"id":"customer","type":"availability","customerId":"elsewhere","visibility":"all"}
 ]'::jsonb;
 result=piti_private.shared_calendar_slots(events,'a');
 if jsonb_array_length(result)<>2 then raise exception 'selected visibility test failed'; end if;
 if result::text like '%private%' or result::text like '%secret%' or result::text like '%visibleCustomerIds%' then raise exception 'private metadata leaked'; end if;
 if jsonb_array_length(piti_private.shared_calendar_slots(events,'b'))<>1 then raise exception 'other customer test failed'; end if;
 if piti_private.shared_calendar_slots('null'::jsonb,'a')<>'[]'::jsonb then raise exception 'null legacy data test failed'; end if;
 begin
 perform public.get_my_trainer_availability();
 raise exception 'unexpected anonymous access';
 exception when raise_exception then if sqlerrm<>'Önce giriş yap.' then raise; end if;
 end;
end $$;
select has_function_privilege('anon','public.get_my_trainer_availability()','execute') as anon_allowed,
has_function_privilege('authenticated','public.get_my_trainer_availability()','execute') as authenticated_allowed;
