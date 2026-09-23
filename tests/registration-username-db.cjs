const fs=require('node:fs'),assert=require('node:assert/strict');
const {PGlite}=require(process.env.PITI_PGLITE_PATH||'@electric-sql/pglite');
(async()=>{
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create schema auth;create schema piti_private;
 create table auth.users(id uuid primary key default gen_random_uuid(),email text unique,raw_app_meta_data jsonb default '{}',raw_user_meta_data jsonb default '{}');
 create table public.profiles(id uuid primary key references auth.users(id),role text,full_name text,must_change_password boolean);
 alter table public.profiles enable row level security;`);
 const old=fs.readFileSync('supabase/migrations/20260917032804_username_accounts.sql','utf8');
 await db.exec(old.slice(old.indexOf('create function piti_private.normalize_username'),old.indexOf('create table piti_private.username_login_attempts')));
 await db.exec("alter table public.profiles add constraint reserved_usernames check(username is null or username not in ('admin','demo'));");
 await db.exec(fs.readFileSync('supabase/migrations/20260923172756_self_registration_username.sql','utf8'));
 await db.exec('create trigger piti_initialize_profile after insert on auth.users for each row execute function piti_private.initialize_account_profile();');
 const signup=async(email,meta,app={})=>(await db.query('insert into auth.users(email,raw_user_meta_data,raw_app_meta_data) values($1,$2,$3) returning id',[email,JSON.stringify(meta),JSON.stringify(app)])).rows[0].id;
 const available=async name=>{await db.exec('set role anon');try{return (await db.query('select public.registration_username_available($1) as ok',[name])).rows[0].ok}finally{await db.exec('reset role')}};
 const pt=await signup('pt@example.test',{username:'  ÇAĞRI_1  ',full_name:'Test PT',account_type:'pt'});
 let profile=(await db.query('select * from public.profiles where id=$1',[pt])).rows[0];
 assert.equal(profile.username,'cagri_1');assert.equal(profile.role,'pt');assert.equal(profile.must_change_password,false);
 const member=await signup('student@example.test',{username:'ÖĞRENCİ-2',account_type:'member'});
 assert.equal((await db.query('select username from public.profiles where id=$1',[member])).rows[0].username,'ogrenci-2');
 assert.equal(await available('ÇAĞRI_1'),false);assert.equal(await available('free_name'),true);
 for(const username of ['',null,'ab','has space','x'.repeat(31),'admin','DEMO']){
  assert.equal(await available(username),false);
  await assert.rejects(signup('invalid@example.test',{username}),/Geçerli bir kullanıcı adı/);
 }
 await assert.rejects(signup('duplicate@example.test',{username:'CAGRI_1'}),/unique/);
 assert.equal((await db.query("select count(*)::int n from auth.users where email in ('invalid@example.test','duplicate@example.test')")).rows[0].n,0,'failed signup leaves no auth user');
 assert.equal(await available('race_name'),true);assert.equal(await available('RACE_NAME'),true);
 await signup('winner@example.test',{username:'race_name'});
 await assert.rejects(signup('loser@example.test',{username:'RACE_NAME'}),/unique/);
 assert.equal((await db.query("select count(*)::int n from auth.users where email='loser@example.test'")).rows[0].n,0,'uniqueness wins even after concurrent availability checks');
 const legacy=await signup('legacy@example.test',{account_type:'pt'});
 assert.equal((await db.query('select username from public.profiles where id=$1',[legacy])).rows[0].username,null);
 const managed=await signup('managed@example.test',{username:'untrusted',account_type:'pt',must_change_password:false},{username:'Trusted_Student',account_role:'member',must_change_password:true});
 profile=(await db.query('select * from public.profiles where id=$1',[managed])).rows[0];
 assert.equal(profile.username,'trusted_student');assert.equal(profile.role,'member');assert.equal(profile.must_change_password,true);
 const noAdmin=await signup('no-admin@example.test',{username:'ordinary',account_type:'admin',is_admin:true});
 assert.equal((await db.query('select role from public.profiles where id=$1',[noAdmin])).rows[0].role,'member');
 for(const role of ['anon','authenticated']){
  await db.exec('set role '+role);
  assert.equal((await db.query("select public.registration_username_available('free_name') ok")).rows[0].ok,true);
  await assert.rejects(db.query('select * from public.profiles'),/permission denied/);
  assert.equal((await db.query("select has_function_privilege(current_user,'piti_private.initialize_account_profile()','execute') ok")).rows[0].ok,false);
  await db.exec('reset role');
 }
 await db.close();console.log('PASS: normalized PT/student usernames, availability, atomic uniqueness/race rollback, validation, legacy compatibility, managed metadata precedence and restricted access.');
})().catch(error=>{console.error(error);process.exit(1)});
