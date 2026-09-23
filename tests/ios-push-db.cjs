// Disposable in-memory Postgres. Never connects to real Supabase.
const assert=require('node:assert/strict'),fs=require('node:fs');
const {PGlite}=require(process.env.PITI_PGLITE_PATH||'@electric-sql/pglite');
(async()=>{
 const db=new PGlite();
 await db.exec(fs.readFileSync('tests/fixtures/ios-push-schema.sql','utf8'));
 const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
 for(const n of [1,2,3]){
  await db.query('insert into auth.users values($1);',[uid(n)]);
  await db.query('insert into public.profiles(id) values($1);',[uid(n)]);
  await db.query('insert into auth.sessions(id,user_id) values($1,$2);',[uid(n+10),uid(n)]);
 }
 await db.query('insert into public.clients(id,pt_id,user_id) values($1,$2,$3)',[uid(20),uid(1),uid(2)]);
 await db.exec(fs.readFileSync('supabase/migrations/20260921174149_ios_push_foundation.sql','utf8'));
 const login=async n=>{
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:uid(n),session_id:uid(n+10)})]);
  await db.exec('set role authenticated');
 };
 const reg=token=>db.query("select public.register_push_device($1,'production','online.mypiti.app.staging','1')",[token]);
 await login(1);await assert.rejects(reg('a'.repeat(64)),/henüz etkin/);
 await assert.rejects(db.query('select * from piti_private.push_devices'),/permission denied/);
 await assert.rejects(db.query('select public.push_claim()'),/permission denied/);
 await db.exec('reset role; update piti_private.push_settings set enabled=true');
 await login(1);await reg('a'.repeat(64));
 await assert.rejects(reg('short'),/Geçersiz/);
 await login(2);await reg('b'.repeat(64));
 await db.exec('reset role');
 await db.query('insert into public.messages values($1,$2,$3)',[uid(31),uid(20),uid(2)]);
 let queue=await db.query('select recipient_id from piti_private.push_deliveries');
 assert.equal(queue.rows.length,1);assert.equal(queue.rows[0].recipient_id,uid(1));
 await db.query("insert into public.sessions values($1,$2,$3,'requested',now()+interval '2 hours',now()+interval '3 hours')",[uid(40),uid(20),uid(1)]);
 let count=()=>db.query('select count(*)::int n from piti_private.push_deliveries');
 assert.equal((await count()).rows[0].n,2);
 await db.query("update public.sessions set starts_at=starts_at,status=status where id=$1",[uid(40)]);
 assert.equal((await count()).rows[0].n,2,'autosave does not enqueue duplicates');
 await db.query("update public.sessions set status='planned' where id=$1",[uid(40)]);
 assert.equal((await count()).rows[0].n,3);
 await db.exec('set role service_role');
 const claim=async()=> (await db.query('select public.push_claim() jobs')).rows[0].jobs;
 const jobs=await claim();assert.equal(jobs.length,3);
 assert.equal((await claim()).length,0,'leases prevent concurrent duplicate claim');
 await db.query('select public.push_finish($1,$2,true,false,null)',[jobs[0].id,jobs[0].lease]);
 await db.query("select public.push_finish($1,$2,false,false,'transient')",[jobs[1].id,jobs[1].lease]);
 await db.query("select public.push_finish($1,$2,false,true,'Unregistered')",[jobs[2].id,jobs[2].lease]);
 await db.exec('reset role');
 const states=(await db.query('select state from piti_private.push_deliveries')).rows.map(x=>x.state).sort();
 assert.deepEqual(states,['failed','pending','sent']);
 await login(3);await reg('a'.repeat(64));await db.exec('reset role');
 assert.equal((await db.query('select count(*)::int n from piti_private.push_deliveries where recipient_id=$1',[uid(1)])).rows[0].n,0,'account switch purges old queue');
 await db.query('delete from auth.sessions where id=$1',[uid(13)]);
 await login(3);await assert.rejects(reg('c'.repeat(64)),/Aktif oturum/);
 await db.exec('reset role');
 assert.equal((await db.query('select count(*)::int n from piti_private.push_devices where user_id=$1',[uid(3)])).rows[0].n,0,'revocation cascades devices');
 const rls=await db.query("select count(*)::int n from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='piti_private' and c.relname like 'push_%' and c.relkind='r' and c.relrowsecurity");
 assert.equal(rls.rows[0].n,3);
 await db.close();console.log('PASS: Postgres migration, default-OFF, RLS, sessions, routing, autosave dedup, leases, retries, invalid tokens and account switch');
})().catch(e=>{console.error(e);process.exit(1)});
