begin;
do $$declare uid uuid; sid uuid; denied boolean; result jsonb;begin
 select id into uid from public.profiles limit 1;
 sid=gen_random_uuid();
 insert into auth.sessions(id,user_id,created_at,updated_at) values(sid,uid,now(),now());
 perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'session_id',sid,'role','authenticated','aal','aal1')::text,true);
 denied=false;begin perform public.admin_console('users');exception when insufficient_privilege then denied=true;end;
 if not denied then raise exception 'Normal kullanıcı admin verilerini okudu';end if;
 insert into piti_private.admin_users values(uid);
 denied=false;begin perform public.admin_console('users');exception when insufficient_privilege then denied=true;end;
 if not denied then raise exception 'MFA olmadan admin erişimi';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'session_id',sid,'role','authenticated','aal','aal2')::text,true);
 update public.profiles set must_change_password=false where id=uid;
 result=public.admin_console('users');if jsonb_array_length(result)<1 then raise exception 'Admin kullanıcıları göremedi';end if;
 perform public.admin_console('sessions');perform public.admin_console('logins');perform public.admin_console('links');perform public.admin_console('settings');perform public.admin_console('audit');
 perform public.heartbeat();
 delete from auth.sessions where id=sid;
 if piti_private.access_ready() then raise exception 'Kapatılan oturum hâlâ erişebiliyor';end if;
 denied=false;begin perform public.admin_console('users');exception when insufficient_privilege then denied=true;end;
 if not denied then raise exception 'Kapatılan admin oturumu hâlâ erişebiliyor';end if;
end $$;

rollback;
