# iOS staging on the existing DEMO project

Approved by the owner on 22 September 2026 to keep the two-project Free plan.
Production: `objwhegswugyeibcnjfr`. DEMO plus staging: `ldufxzwgwbaogpmwqhlw`.
This is isolation from production, not a separate infrastructure boundary from DEMO.

## Installed and verified

- Applied `supabase/staging/20260922041631_staging_application_schema.sql` to DEMO,
  first rehearsed in a rolled-back transaction. This bootstrap is intentionally
  outside normal production migrations and refuses a database with existing accounts/profiles.
- Core schema was recovered from production migration definitions, never user data.
  Supplemental calendar/photo schema and iOS push/deletion schema were included.
- Existing public DEMO snapshot and version history remain unchanged. Snapshot
  checksum before/after: `77d455e776bb1090d83e6994965dc685`, version 1, 95 events.
- All 16 public tables have RLS. Real database username/role/linking tests and
  shared DEMO publication/exact-restoration tests passed with fixtures rolled back.
- No persistent test accounts seeded yet. No live accounts copied.
- `manage-client-account` deployed with `staging.ts`, restricted CORS origin
  `https://piti-staging.erkan-yardibi.workers.dev`. Uses custom Auth/session/role
  checks; gateway JWT verification is disabled for username login and one-time entry.
- Push, deletion, recovery and retention schedules are not enabled. No APNs key
  is configured. This is not yet an end-to-end push test environment.
- Security advisors: no ERROR findings. Two authenticated SECURITY DEFINER RPC
  warnings (`member_retained_history`, `save_my_unavailability`) concern intentional
  self/relationship-checked endpoints. Private tables and DEMO versions intentionally
  deny direct API access (RLS with no policies).
  See https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable

## Publish only the staging frontend

There is no Cloudflare deployment credential/connector in the working session.
Run from the updated repository on the Mac; use a NEW output directory:

```sh
python3 scripts/build-staging.py /tmp/piti-staging-web
cd /tmp/piti-staging-web
npx wrangler login
npx wrangler deploy --config wrangler.json
```

The generated config is named `piti-staging`, with a separate asset directory;
do not use the repository-root production Wrangler config. The expected URL above
is not published/verified yet. If Cloudflare prints a different hostname, update
the staging function's explicit origin before testing login.

The bundle rewrites the application backend to DEMO, retains existing Worker
runtime corrections, sets no-store/noindex, limits browser data connections to
DEMO, and blocks the shared DEMO admin proxy. Ordinary DEMO snapshot reads work.
Staging admin RPC also rejects DEMO administration actions.

After deployment verify `X-PiTi-Environment: staging`, CSP, actual HTML backend,
DEMO loading and real login before assigning `PITI_STAGING_URL` in the ignored
`ios/Config/Local.xcconfig`. This value stays blank until verification. Rebuild
on the Mac: the iOS content rule now permits approved DEMO while blocking production.
The user confirmed installation on the real iPhone 15; the revised native source
still needs to be installed. TestFlight upload has not happened.

## Remaining functional setup

Create synthetic PT/member test accounts and populate application tables with
selected DEMO examples; the existing shared snapshot is UI demo data, not real
Auth accounts. Then verify cross-device persistence and complete staging APNs
setup for push tests. Do not enable account deletion until permanent cleanup exists.

## Checks

`node --test tests/staging-bundle.test.mjs tests/managed-account-edge.test.mjs`

Do not rerun the bootstrap against an already initialized database. Subsequent
schema work needs new staging changes with rollback/recovery planning; shared DEMO
must be checked after each change.
