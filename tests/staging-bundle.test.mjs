import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

test('staging build isolates backend, blocks DEMO writes, and retains runtime patches', async () => {
 const base=mkdtempSync(join(tmpdir(),'piti-staging-test-'));
 try {
  const out=join(base,'bundle');
  execFileSync('python3',['scripts/build-staging.py',out]);
  const html=readFileSync(join(out,'public/index.html'),'utf8');
  assert(!html.includes('objwhegswugyeibcnjfr'));
  assert(html.includes("const SUPABASE_URL='https://ldufxzwgwbaogpmwqhlw.supabase.co'"));
  assert.equal(JSON.parse(readFileSync(join(out,'wrangler.json'))).name,'piti-staging');
  const worker=(await import(pathToFileURL(join(out,'worker.js')))).default;
  const env={ASSETS:{fetch:async()=>new Response(html,{headers:{'Content-Type':'text/html'}})}};
  const blocked=await worker.fetch(new Request('https://example.test/api/demo-admin',{method:'POST'}),env);
  assert.equal(blocked.status,403);
  const response=await worker.fetch(new Request('https://example.test/'),env);
  assert.equal(response.headers.get('X-PiTi-Environment'),'staging');
  assert(!response.headers.get('Content-Security-Policy').includes('objwhegswugyeibcnjfr'));
  assert(Number(response.headers.get('x-piti-runtime-patches'))>0);
  assert.throws(()=>execFileSync('python3',['scripts/build-staging.py',out],{stdio:'pipe'}));
 } finally {rmSync(base,{recursive:true,force:true});}
});
