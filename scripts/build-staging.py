#!/usr/bin/env python3
"""Build an isolated Cloudflare staging bundle. Does not deploy or change production."""
import argparse
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
TEST_REF = 'ldufxzwgwbaogpmwqhlw'
LIVE_REF = 'objwhegswugyeibcnjfr'


def build(destination):
    destination = Path(destination).resolve()
    if destination.exists():
        raise ValueError('Output must be a new directory; existing files are never overwritten.')
    html = (ROOT / 'index.html').read_text()
    key = re.search(r"const DEMO_KEY='([^']+)';", html).group(1)
    html, count = re.subn(r"const SUPABASE_URL='[^']+';\nconst SUPABASE_KEY='[^']+';",
                         f"const SUPABASE_URL='https://{TEST_REF}.supabase.co';\nconst SUPABASE_KEY='{key}';", html)
    if count != 1 or LIVE_REF in html:
        raise ValueError('Unexpected frontend configuration or remaining live backend reference.')
    html = html.replace('<title>myPiti</title>', '<title>PiTi Test</title>')
    html = html.replace('<head>', '<head>\n<meta name="robots" content="noindex,nofollow">', 1)
    public = destination / 'public'
    public.mkdir(parents=True)
    (public / 'index.html').write_text(html)
    for folder in ['assets', 'vendor']:
        shutil.copytree(ROOT / folder, public / folder)
    # Keep existing runtime corrections, but intercept shared DEMO administration.
    (destination / 'runtime-worker.js').write_text((ROOT / 'worker.js').read_text())
    (destination / 'worker.js').write_text('''import runtime from './runtime-worker.js';
export default {
 async fetch(request, env) {
  const path = new URL(request.url).pathname;
  if (path === '/api/demo-admin') return new Response(JSON.stringify({error:'DEMO yönetimi test ortamında kapalı.'}), {status:403,headers:{'Content-Type':'application/json'}});
  const response = await runtime.fetch(request, env);
  const headers = new Headers(response.headers);
  headers.set('X-PiTi-Environment','staging');
  headers.set('X-Robots-Tag','noindex, nofollow');
  headers.set('Cache-Control','no-store');
  headers.set('Content-Security-Policy', "connect-src 'self' https://ldufxzwgwbaogpmwqhlw.supabase.co wss://ldufxzwgwbaogpmwqhlw.supabase.co; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'self'");
  return new Response(response.body,{status:response.status,statusText:response.statusText,headers});
 }
};
''')
    (destination / 'wrangler.json').write_text(json.dumps({
        'name': 'piti-staging', 'main': 'worker.js', 'compatibility_date': '2026-09-17',
        'workers_dev': True,
        'assets': {'directory': './public', 'binding': 'ASSETS', 'run_worker_first': True}
    }, indent=2) + '\n')
    print(destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', help='New directory outside the source tree')
    args = parser.parse_args()
    target = Path(args.destination).resolve()
    if target == ROOT or ROOT in target.parents:
        parser.error('Use a directory outside the source tree.')
    build(target)
