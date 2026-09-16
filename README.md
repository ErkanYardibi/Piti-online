# PiTi Online

This branch replaces the local-only home page with email/password authentication and Supabase-backed clients, sessions, packages, payments, availability, tasks and text messages. The blue responsive layout is retained. The original prototype remains at `demo.html`; its browser-local sample data is separate.

## Activation status

**Not live.** The shared-database migration was rejected by automatic approval review because it changes permissions and RLS across the existing database. No database change was applied. Obtain explicit approval for the reviewed migration before running it. Do not publish this branch until migration and live validation succeed.

Target repository: `ErkanYardibi/Piti-online`.
Target Supabase project: `piti-online` (`objwhegswugyeibcnjfr`).

The project already contains eight public tables. `supabase/migrations/20260916035940_connect_shared_database.sql` is an incremental migration for that existing schema, not a fresh project bootstrap. It adds single-use invitations, access policies, grants, validation constraints and indexes. No existing table or user data is dropped. Account roles and client ownership become immutable through the client API. Invitations link a customer account to one trainer.

`src/config.js` contains only the public project URL and publishable key. No service-role or secret key belongs in frontend code.

## Development

```sh
npm ci
npm test
npm run build
python -m http.server 4173
```

The build produces `app.bundle.js`, which is committed so the current static hosting can serve the root directory without a build command.

`npm test` runs domain checks and a real isolated PostgreSQL engine (PGlite). The database fixture captures the current public table definitions and provides a minimal `auth.uid()` shim. Tests cover invitation replay, unrelated trainer/customer isolation, payment approval authorization, message sender spoofing, absence ownership and unauthenticated access. They do not exercise hosted Supabase Auth, PostgREST or email delivery.

## First live verification after approval

1. Apply the reviewed incremental migration to the target project.
2. Run Supabase security advisors and verify the hosted API grants/policies.
3. Verify Supabase Auth site URL and allowed redirects against the actual hosting domain, including `mypiti.online` if it is the active domain. Verify signup email delivery without turning off confirmation.
4. Use a PT account and a customer account in separate browser sessions: create a client, consume its invitation, create a session, send a message, submit a payment and approve it as PT.
5. Check an unrelated account cannot read either account's records.
6. Publish only after those checks pass.

The interface refreshes visible data every 20 seconds while the user is not typing, and provides a manual refresh button. Writes show success only after the API confirms them.

## Included flows

- Email/password signup and login; one-time profile role choice.
- PT-created clients, one-use invitation codes, archive visibility.
- Monday-first calendar; past session entry, muscle groups, salon, notes, completion/No Show, cancellation and restoration.
- Packages with date/session limits; pending payment reporting and PT approval.
- PT availability/leave; customer absence notes visible to PT and deletable by the customer.
- Tasks with result entry, text chat and unread counts.

## Remaining scope

- Live Auth, email delivery and multi-browser hosted API checks are blocked until the migration is approved.
- Photo/video, receipts, push notifications, availability sharing/booking requests, measurement graphs and automatic session confirmation are not implemented in the connected version.
- Package usage is derived from counted completed/No Show sessions within each package's date range. Overlapping packages for one client require explicit session-to-package allocation before supporting that workflow.
- Password-reset UI is not yet included.
