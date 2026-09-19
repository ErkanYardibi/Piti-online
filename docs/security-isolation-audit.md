# Data isolation audit — 2026-09-19

Status: initial database review and first remediation complete; NOT a complete security certification.

## Verified and fixed

- All public base tables inspected have RLS enabled. Enabling RLS alone does not establish correctness.
- The previous `sessions_access` policy accepted a session carrying the caller's PT ID and another PT's client ID. A synthetic transaction reproduced the unauthorized insert.
- The policy now requires an accessible client whose PT ID matches the session PT ID, for both existing and proposed rows. Existing `account_ready` restrictions remain in place.
- Applied migration: `enforce_session_tenant_relationship`. Reproducible SQL: `supabase/admin/session-tenant-isolation.sql`.
- `tests/session-tenant-isolation.sql` failed before the change, passed in a rollback-only rehearsal and passed after deployment.
- Tests cover foreign-client inserts, cross-tenant reassignment, foreign session reads/updates, account-state ownership, legitimate member muscle-group edits, and revoked sessions.
- No existing session/client PT mismatch was found. Test users and their sessions were rolled back; zero fixture users remained.
- The existing incident backup remains present and authenticated users have no SELECT privilege on it. It is in the same database, is incident-specific, and is not a complete disaster-recovery backup.

## Remaining review

- Frontend cloud loading and saving use mutable global account state across asynchronous boundaries. The start-of-save ownership check alone is insufficient proof of race safety; test logout/login, demo entry, and delayed requests at each await boundary.
- Review all privileged RPC bodies, payment/package write privileges, storage policies, and account-state JSON ownership. The session tests above do not establish these are safe.
- Shared DEMO UI still obtains its published fixture from the production project's `demo_state`; a physically separate backend is not yet provisioned.
- Existing change-audit triggers need recovery-coverage and retention review, especially complete before/after images and uploaded files.
- Run browser-level regressions in addition to SQL tests before declaring the audit complete.

## Advisor findings

- `save_my_unavailability` is exposed as SECURITY DEFINER. Its inspected body checks a valid session, member role, and selects the client using `auth.uid()`; the warning is not by itself evidence of unauthorized access. Consider a private implementation/public invoker wrapper and test it.
- Leaked-password protection is disabled; not changed in this pass.
- Private tables intentionally have RLS without client policies. Do not add broad policies to silence informational advisories.

References:

- https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable
- https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection
- https://supabase.com/docs/guides/database/postgres/row-level-security

## Backup and isolation rollout — pending decisions

The connected organization is on the Free plan. Current official documentation promises managed daily backups for Pro/Team/Enterprise, not Free. No managed backup inventory endpoint is available through the connected tools, so actual restore-point availability has NOT been verified.

1. Finish the isolation review and asynchronous regression tests.
2. Confirm the organization and cost before provisioning a DEMO project. Keep UI/components shared; configure storage/auth separately. Never copy real customer data into DEMO.
3. Choose managed daily backups and/or encrypted off-site database exports, including separate coverage for uploaded objects. Agree on retention, destination, credentials and a maximum tolerated data-loss window before scheduling.
4. Restore to an isolated environment, verify row counts and relationships, then rehearse a single-account repair. Do not rewind the entire production database to repair one user.
5. Record measured recovery time, last successful backup, verification result and failure alerts. Do not advertise a working backup system until a restoration has succeeded.

Database backups do not include Storage object contents. A daily backup can still lose nearly a day of changes. Same-database audit history does not protect against loss of the project itself.

Source: https://supabase.com/docs/guides/platform/backups

No paid service, off-site data transfer, production data restore, or scheduled backup was started in this pass.
