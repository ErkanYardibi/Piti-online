-- Public About copy is shared; writes require the existing ADMIN + MFA guard.
alter table piti_private.system_settings add column about_content jsonb not null default '{"title": "Hakkında", "tagline": "Antrenman yolculuğun, tek bir yerde.", "introHeading": "PiTi nedir?", "intro": "PiTi, kişisel antrenörler (PT) ve öğrencilerinin antrenman sürecini birlikte yönetmesini kolaylaştırır. Seans planlamasını, paket ve ödeme takibini, iletişimi ve gelişim kayıtlarını tek bir yerde buluşturur.", "featuresHeading": "Daha düzenli bir antrenman süreci", "features": "PT’ler müşterilerini ve müsaitliklerini yönetebilir, seans planlayabilir, antrenman sonuçlarını kaydedebilir ve tahsilatlarını takip edebilir. Öğrenciler yaklaşan seanslarını, paket ve ödeme durumlarını görebilir; PT’leriyle mesajlaşabilir ve gelişimlerini izleyebilir.", "summary": "PiTi, günlük takibi kolaylaştırarak antrenmana ve kişisel hedeflere daha fazla zaman ayırmanı sağlar.", "contactHeading": "İletişim", "contactIntro": "Soru, öneri ve geri bildirimlerin için:", "email": "eyardibi@gmail.com", "credit": "Designed by Yardibi Production"}'::jsonb;
alter table piti_private.system_settings add column about_version integer not null default 1;
alter table piti_private.system_settings add column about_updated_at timestamptz not null default now();
create function piti_private.get_about_content() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('content',about_content,'version',about_version,'updated_at',about_updated_at) from piti_private.system_settings where id
$$;
create function public.get_about_content() returns jsonb language sql stable security invoker set search_path='' as $$select piti_private.get_about_content()$$;
revoke all on function piti_private.get_about_content(),public.get_about_content() from public;
grant execute on function piti_private.get_about_content(),public.get_about_content() to anon,authenticated;
grant usage on schema piti_private to anon;
create function piti_private.save_about_content(p_content jsonb,p_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare k text; clean jsonb='{}';
begin
 perform piti_private.require_admin();
 if jsonb_typeof(p_content) is distinct from 'object' or octet_length(p_content::text)>30000 then raise exception 'Geçersiz Hakkında içeriği.';end if;
 foreach k in array array['title','tagline','introHeading','intro','featuresHeading','features','summary','contactHeading','contactIntro','email','credit'] loop
  if jsonb_typeof(p_content->k) is distinct from 'string' or char_length(p_content->>k)>(case when k in ('intro','features','summary') then 5000 else 300 end) then raise exception 'Geçersiz veya çok uzun alan: %',k;end if;
  clean=clean||jsonb_build_object(k,btrim(p_content->>k));
 end loop;
 if clean->>'title'='' then raise exception 'Sayfa başlığı boş olamaz.';end if;
 if clean->>'email'<>'' and clean->>'email' !~ '^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' then raise exception 'Geçerli bir e-posta gir.';end if;
 update piti_private.system_settings set about_content=clean,about_version=about_version+1,about_updated_at=now() where id and about_version=p_version;
 if not found then raise exception 'İçerik başka bir oturumda değişti. Sayfayı yenileyip tekrar düzenle.' using errcode='40001';end if;
 insert into piti_private.admin_audit(actor_id,entity,record_id,action) values(auth.uid(),'about_content','shared','publish');
 return piti_private.get_about_content();
end $$;
create function public.save_about_content(p_content jsonb,p_version integer) returns jsonb language sql security invoker set search_path='' as $$select piti_private.save_about_content(p_content,p_version)$$;
revoke all on function piti_private.save_about_content(jsonb,integer),public.save_about_content(jsonb,integer) from public,anon;
grant execute on function piti_private.save_about_content(jsonb,integer),public.save_about_content(jsonb,integer) to authenticated;
