begin;

create table public.demo_state (
 id text primary key,
 data jsonb not null check (jsonb_typeof(data)='object'),
 version integer not null default 1 check (version>0),
 updated_at timestamptz not null default now()
);

alter table public.demo_state enable row level security;
revoke all on public.demo_state from public, anon, authenticated;
grant select on public.demo_state to anon, authenticated;
create policy demo_state_public_read on public.demo_state
 for select to anon, authenticated using (id='main');

insert into public.demo_state(id,data) values ('main',
 '{"role":"pt","page":"dashboard","demoCustomers":[{"id":"demo-ayse","name":"Ayşe Demir","session":{"time":"09:00","title":"İtiş Günü","completed":true}},{"id":"demo-zeynep","name":"Zeynep Aslan","session":{"time":"14:00","title":"Core & Kardiyo","completed":false}}],"customer":{"id":1,"name":"Erkan Yardibi","initials":"EY","weight":89.4,"status":"active","demoDate":"","photo":""},"ptProfile":{"name":"Mehmet Kaya","bio":"Fonksiyonel antrenman ve kuvvet gelişimi","specialties":"Kuvvet, Fonksiyonel Antrenman, Kilo Kontrolü","locations":[{"id":1,"name":"X Fitness Lara","address":"Lara, Antalya"},{"id":2,"name":"Core Gym Konyaaltı","address":"Konyaaltı, Antalya"}],"photo":""},"progressData":[{"d":"1 Haz","w":94,"waist":104},{"d":"15 Haz","w":93.1,"waist":102},{"d":"1 Tem","w":92.4,"waist":100},{"d":"1 Ağu","w":91.2,"waist":98},{"d":"1 Eyl","w":90.1,"waist":96},{"d":"Bugün","w":89.4,"waist":95}],"unread":{"pt":2,"member":1},"package":{"name":"12 Seans / 30 Gün","price":7500,"totalSessions":12,"usedSessions":4,"freezeDays":0,"status":"active","rule":"Hangisi önce biterse"},"payment":{"status":"pending","amount":7500,"method":"EFT/Havale","receipt":"EFT_Dekontu.pdf","submitted":true},"events":[],"tasks":[{"id":1,"title":"Sabah tartıl","status":"done","result":"89,4 kg"},{"id":2,"title":"2,5 litre su iç","status":"open","result":""},{"id":3,"title":"Öğle yemeğinin fotoğrafını gönder","status":"open","result":""}],"messages":[{"from":"pt","text":"Akşam bacak çalışacağız. Antrenmandan önce çok ağır yemek yeme. 💪"},{"from":"member","text":"Tamam hocam 👍"}],"invite":{"ptCode":"MEHMET-4821","oneTimeCodes":[],"pending":[{"id":101,"name":"Selin Aksoy","email":"selin.aksoy@example.com","code":"MEHMET-4821","status":"pending"}],"approved":[]},"memberTrainer":{"name":"Mehmet Kaya","code":"MEHMET-4821","status":"connected"},"financeHistory":[]}'::jsonb);

commit;
