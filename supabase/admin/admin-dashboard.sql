begin;
create or replace function piti_private.admin_insights(p_view text default 'dashboard',p_page integer default 0,p_search text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform piti_private.require_admin();
 if p_view in ('trainers','members') then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into result from (
   select p.id,p.full_name,p.username,p.role,u.email,u.created_at,u.last_sign_in_at,
    coalesce(c.suspended,false) suspended,coalesce(c.archived,false) archived,
    exists(select 1 from piti_private.admin_users a where a.user_id=p.id) is_admin,
    (select max(last_seen) from piti_private.presence r where r.user_id=p.id) last_seen
   from public.profiles p join auth.users u on u.id=p.id left join piti_private.account_controls c on c.user_id=p.id
   where p.role::text=case when p_view='trainers' then 'pt' else 'member' end
    and concat_ws(' ',p.full_name,p.username,u.email) ilike '%'||left(coalesce(p_search,''),100)||'%'
   order by u.created_at desc,p.id limit 50 offset greatest(0,least(coalesce(p_page,0),100000))*50
  ) x;
 elsif p_view='dashboard' then
  select jsonb_build_object(
   'growth',(select jsonb_agg(to_jsonb(x) order by x.month) from (
    select to_char(m,'YYYY-MM') as "month",
     count(*) filter(where p.role='pt') trainers,count(*) filter(where p.role='member') members
    from generate_series(date_trunc('month',now())-interval '11 months',date_trunc('month',now()),interval '1 month') m
    left join auth.users u on u.created_at<m+interval '1 month'
    left join public.profiles p on p.id=u.id group by m
   ) x),
   'recent_trainers',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (
    select p.id,p.full_name,u.created_at from public.profiles p join auth.users u on u.id=p.id where p.role='pt' order by u.created_at desc,p.id limit 5
   ) x),
   'new_this_month',(select count(*) from auth.users where created_at>=date_trunc('month',now())),
   'client_records',(select count(*) from public.clients where not coalesce(archived,false)),
   'generated_at',now()
  ) into result;
 else raise exception 'Geçersiz görünüm.';
 end if;
 return result;
end $$;
create or replace function public.admin_insights(p_view text default 'dashboard',p_page integer default 0,p_search text default '') returns jsonb
language sql security invoker set search_path='' as $$select piti_private.admin_insights(p_view,p_page,p_search)$$;
revoke all on function piti_private.admin_insights(text,integer,text),public.admin_insights(text,integer,text) from public,anon;
grant execute on function piti_private.admin_insights(text,integer,text),public.admin_insights(text,integer,text) to authenticated;
commit;
