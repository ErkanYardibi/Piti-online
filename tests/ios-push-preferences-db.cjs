// Disposable database only; no live credentials or network connections.
const assert=require('node:assert/strict'),fs=require('node:fs');
const {PGlite}=require(process.env.PITI_PGLITE_PATH||'@electric-sql/pglite');
(async()=>{
 const db=new PGlite(),uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
 await db.exec(fs.readFileSync('tests/fixtures/ios-push-schema.sql','utf8'));
 for(const n of [1,2]){
  await db.query('insert into auth.users values($1)',[uid(n)]);
  await db.query('insert into public.profiles(id) values($1)',[uid(n)]);
  await db.query('insert into auth.sessions(id,user_id) values($1,$2)',[uid(n+10),uid(n)]);
 }
 await db.query('insert into public.clients(id,pt_id,user_id) values($1,$2,$3)',[uid(20),uid(1),uid(2)]);
 for(const file of ['20260921174149_ios_push_foundation.sql','20260921183640_push_notification_preferences.sql'])await db.exec(fs.readFileSync('supabase/migrations/'+file,'utf8'));
 await db.exec('update piti_private.push_settings set enabled=true');
 const login=async n=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:uid(n),session_id:uid(n+10)})]);await db.exec('set role authenticated');};
 const reg=token=>db.query("select public.register_push_device($1,'production','online.mypiti.app.staging','1')",[token.repeat(64)]);
 const set=(m,s,t,p)=>db.query('select public.set_push_preferences($1,$2,$3,$4) data',[m,s,t,p]);
 const get=async()=> (await db.query('select public.get_push_preferences() data')).rows[0].data;
 const count=async prefix=>{await db.exec('reset role');return (await db.query('select count(*)::int n from piti_private.push_deliveries where event_key like $1',[prefix+':%'])).rows[0].n;};
 const message=async(id,sender)=>{await db.exec('reset role');await db.query('insert into public.messages values($1,$2,$3)',[uid(id),uid(20),uid(sender)]);};
 await login(1);await reg('a');await login(2);await reg('b');await reg('c');
 assert.deepEqual(await get(),{messages:true,sessions:true,tasks:true,payments:true});
 await assert.rejects(db.query('select * from piti_private.push_preferences'),/permission denied/);
 await assert.rejects(set(null,true,true,true),/Tüm bildirim/);
 await message(30,1);assert.equal(await count('messages'),2,'both member devices receive queued event');
 await login(2);await set(false,true,true,true);
 assert.equal(await count('messages'),0,'opt out removes queued notifications on both devices');
 await message(31,1);assert.equal(await count('messages'),0,'new opted-out events are suppressed');
 await db.query('insert into public.tasks values($1,$2)',[uid(40),uid(20)]);
 assert.equal(await count('tasks'),2,'other categories stay enabled');
 await message(32,2);assert.equal(await count('messages'),1,'PT preferences are independent');
 await login(1);assert.equal((await get()).messages,true);
 await login(2);await set(true,true,true,true);
 assert.equal(await count('messages'),1,'old notifications do not reappear on opt-in');
 await message(33,1);assert.equal(await count('messages'),3,'only new messages resume');
 // Defense in depth for a legacy queue: a dispatcher must recheck even if
 // preferences changed through an operator repair rather than the user API.
 await db.query('update piti_private.push_preferences set messages=false where user_id=$1',[uid(2)]);
 await db.exec('set role service_role');
 const jobs=(await db.query('select public.push_claim() jobs')).rows[0].jobs;
 assert.equal(jobs.length,3);assert.equal(jobs.filter(x=>x.recipient_id===uid(2)&&x.page==='messages').length,2,'only task events are eligible for member');
 // All categories off, including leased jobs; late completion cannot recreate them.
 await login(2);await set(false,false,false,false);await db.exec('reset role');
 assert.equal((await db.query('select count(*)::int n from piti_private.push_deliveries where recipient_id=$1',[uid(2)])).rows[0].n,0);
 await db.query("insert into public.sessions values($1,$2,$3,'planned',now(),now()+interval '1 hour')",[uid(50),uid(20),uid(1)]);
 await db.query('insert into public.tasks values($1,$2)',[uid(41),uid(20)]);
 await login(1);await db.exec('reset role');
 await db.query('insert into public.client_history values($1,$2,1)',[uid(20),{payment:{status:'approved'}}]);
 assert.equal(await count('sessions'),0);assert.equal(await count('tasks'),0);assert.equal(await count('payment'),0);
 await db.exec('set role anon');await assert.rejects(db.query('select public.get_push_preferences()'),/permission denied/);
 await login(2);await db.exec('reset role');await db.query('delete from auth.sessions where user_id=$1',[uid(2)]);
 await login(2);await assert.rejects(get(),/Aktif oturum/);await assert.rejects(set(true,true,true,true),/Aktif oturum/);
 await db.exec('reset role');
 assert.equal((await db.query("select relrowsecurity from pg_class where oid='piti_private.push_preferences'::regclass")).rows[0].relrowsecurity,true);
 await db.close();console.log('PASS: preference ownership, RLS, valid session, four categories, two devices, queue purge, opt-in and claim recheck');
})().catch(error=>{console.error(error);process.exit(1)});
