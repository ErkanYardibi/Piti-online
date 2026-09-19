# Recovery copies and trainer transfer

## Deployed recovery layer (2026-09-19)

- Free plan retained. No external service purchased.
- Production SQL source: `supabase/admin/daily-recovery-copies.sql`.
- Daily cron: 00:15 UTC / 03:15 Turkey. Keep 7 successful copies; 10 MB payload ceiling per copy to protect free storage capacity.
- Includes all public application base tables except historical `demo_state`, in one consistent SQL snapshot. Does not include Auth credentials, schema definitions, private administrative tables, external Storage objects or secrets.
- Every capture verifies SHA-256, restores typed records into temporary tables and compares the reconstructed values. It then removes temporary tables. This does not test full project recovery, foreign-key recreation or an actual production rollback.
- First capture and verification succeeded. The first scheduled run has not yet been observed.
- Admin > Geri Dönüş Kopyaları shows latest copies, last cron outcome, and an overdue warning after 26 hours. There is no external push/email alert.
- Copies live in the same database. They protect against accidental application-data edits, not loss/deletion of the database. Off-site destination and secure export still need selection.
- Recovery is operator-assisted and scoped to the affected account. No automatic global rewind or one-click production restore is exposed.
- Normal users cannot read copies, trigger capture, or view admin status. Redundant TRUNCATE/REFERENCES/TRIGGER privileges were revoked from public/anon/authenticated.

## Trainer transfer — implemented 2026-09-19

Normal invitation redemption still refuses accounts already linked to a PT. A separate `trainer_transfer` flow creates a new relationship instead of reassigning `clients.pt_id` and exposing the previous relationship.

Proposed flow:

1. New PT uses Customers > Başka PT’deki müşteriyi davet et and enters the member's existing username. The seven-day, one-use transfer code is bound to that member and the new PT. No new login/password is created.
2. The customer opens PT'im > PT değiştir, enters the invitation and sees current/new PT, pending sessions and package/payment summary.
3. The customer explicitly confirms the change. The new PT's issued invitation is the new PT's consent; no silent admin or PT reassignment.
4. One atomic transaction locks the member, old relationship and invitation, verifies current auth, invitation ownership/expiry and expected relationship version, then closes the old relationship and opens a separate one. Concurrent/stale requests fail without a partial transfer.
5. In-flight saves and all other tabs lose permission to mutate the ended relationship. The application clears the former account snapshot before loading the new relationship.

Data visibility:

| Data | Customer | Former PT | New PT |
| --- | --- | --- | --- |
| Former messages, payments, sessions | Read-only former relationship | Own historical relationship | No access |
| New messages, payments, sessions | Current relationship | No access | Current relationship |
| Personal measurements | Retained | Only values from former relationship | Only measurements explicitly shared by customer |
| Former package/credit/debt | Remains in former relationship | Remains in former relationship | Does not automatically transfer |

Required model changes:

- Separate relationship identity/lifecycle from login identity. Preserve read-only history access for the customer, who currently loads a single client row by `user_id`.
- Keep an immutable transfer receipt/snapshot and ended-at marker. Block reconnect, deletion or new account creation on the former client record by ordinary APIs.
- Replace `maybeSingle()` assumptions only where active relationship selection requires it. RLS and privileged RPCs must distinguish current and former relationships.
- Measurements become member-owned or are copied only with an explicit sharing choice; chat task-derived weights require the same choice.
- DEMO uses the common transfer screens with synthetic relationships, without production calls.

Confirmed decision: the old PT's approval is NOT required. Customer + new PT consent is sufficient. The old PT receives a persistent in-app notice with an acknowledgement button. Notices refresh on login and approximately every 30 seconds while the app is visible; this is not email or OS push. Unsettled money/credits remain in the old archived relationship. Future planned sessions are counted in the confirmation screen and cancelled in the transfer transaction.

Acceptance tests: wrong/expired/reused invitation, another member, same PT, suspended account, stale link, concurrent submissions, former PT/new PT visibility, retained customer history, old browser writes, pending packages/sessions, DEMO parity, and transaction rollback.

SQL source: `supabase/admin/trainer-transfer.sql`; isolated fixture test: `tests/trainer-transfer.sql`. It passed in a rollback rehearsal and against the deployed schema, with measurement sharing both enabled and disabled. `tests/trainer-transfer-ui.cjs` exercises the common UI using the DEMO adapter, including explicit consent, history access, former-PT notice and acknowledgement with production calls blocked.

UI module source `assets/trainer-transfer.js` is embedded in the main index.html IIFE between BEGIN/END trainer transfer module markers; keep both in sync. The application is not bundled and its lexical state is private to the IIFE.

DEMO: member > PT'im > PT değiştir, code `DEMO-PT-GECIS`. A synthetic second PT is created for this test session. The PT view provides a toggle to see the former PT's notification. Reload DEMO to reset. This uses the same forms and confirmation flow; data operations are adapter-specific.

No real customer was transferred during implementation. Every test relationship and notification was rolled back. Former snapshots and notifications are public-schema application tables covered by the existing daily recovery-copy collector; pending secret invitation tokens remain private and are not part of that application-data backup.
