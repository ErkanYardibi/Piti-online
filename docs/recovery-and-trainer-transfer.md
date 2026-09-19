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

## Trainer transfer — implementation specification, NOT live

Current code deliberately refuses invitation redemption if an account already has another PT/history. Reassigning `clients.pt_id` would expose the entire old relationship to the new PT. That operation must not be used.

Proposed flow:

1. New PT creates a one-time invitation for the existing customer.
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

Business decision before activation: does the old PT need to approve departure? Recommended: customer + new PT consent is sufficient; the old PT receives an in-app notice, and unsettled money/credits remain in the old relationship. Pending future sessions must be shown explicitly before cancellation; never silently move them.

Acceptance tests: wrong/expired/reused invitation, another member, same PT, suspended account, stale link, concurrent submissions, former PT/new PT visibility, retained customer history, old browser writes, pending packages/sessions, DEMO parity, and transaction rollback.

No production customer relationship has been changed as part of this specification.
