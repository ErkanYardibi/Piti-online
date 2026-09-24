# Staging release — 24 September 2026

Source: `6c54bb85f90c6b261b95f458e532e383bd5c8158` (latest registration/recovery release supplied for synchronization). Direct HTTP comparison with the active production Worker could not be performed from this session; the source tree matches GitHub exactly.

Only the `staging` branch is modified. Do not merge this branch wholesale into main: its root Wrangler config targets `piti-staging` and serves `staging-public` only. Production source is preserved in index.html/assets/vendor/worker.js for reproducibility.

## One-time Cloudflare connection

Select existing Worker `piti-staging`, Settings > Builds > Connect Git. Repository `ErkanYardibi/Piti-online`, production branch `staging`, root `/`, build command empty, deploy command `npx wrangler@4.137.0 deploy`. Disable builds for other branches on this Worker. Choose a valid Workers Builds token. No user terminal is needed. Never change `piti-online` production branch to staging.

## Release generation

Run scripts/build-staging.py into a fresh directory outside the repository. Copy generated public to staging-public. Use the generated worker as staging-worker.js with its import pointing at ./worker.js. Retain staging CSP, shared-DEMO administration deny, no-store and noindex. Root config targets piti-staging with assets ./staging-public and main staging-worker.js. Update source commit in staging-release.json and the X-PiTi-Source-Commit response header. Regenerate artifacts after every source change before advancing staging.

## Applied backend changes

Applied self_registration_username to the existing DEMO/staging database ldufxzwgwbaogpmwqhlw. Deployed manage-client-account version 3 with staging.ts, the current handler, explicit deno.json import map, and staging-only CORS. JWT gateway remains off because the handler validates sessions/roles and supports unauthenticated username login/one-time entry.

DEMO snapshot stayed at version 4, checksum b305a9fec8ef64344168711b9c38a590. Auth/profile counts remained zero. No production data copied. Existing security-advisor warnings unchanged.

## Limits and deployment verification

Web publication is pending Cloudflare Git connection. After it succeeds check X-PiTi-Environment=staging, X-PiTi-Source-Commit, signup username/email UI, and backend pointing only at the staging project. No real accounts exist in staging yet. SMTP, Auth redirects, admin-account Edge Function, APNs credentials and deletion schedules are not synchronized by this release. Email delivery and all native features are not certified by this synchronization. The shared DEMO snapshot remains shared with the production app's DEMO mode and must not be edited during release validation.
