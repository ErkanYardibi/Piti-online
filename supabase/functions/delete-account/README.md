# Account deletion initiation — NOT deployed or enabled

This implements authenticated preview, password-verified request submission,
idempotent durable request records and secret receipt status. It does NOT yet
implement the purge worker. It must remain OFF and is not an App Store-ready
account deletion feature by itself.

No live account, session, file, history or backup was deleted while implementing
this change. Only live schema metadata was read to identify data dependencies.

## Configuration gates

The migration defaults enabled=false and worker_ready=false. Submission is
unavailable until both are true and a policy version, truthful notice and verified
maximum completion window are configured. Do not enable those flags until the
worker and restore process are implemented, tested and approved for deployment.
The test fixture's 24-hour value is not a production commitment or legal policy.

Backend-only environment: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and
ACCOUNT_DELETION_ORIGINS (comma-separated exact frontend origins). Use an isolated
staging backend first. Existing trainer-transfer and account-access schema are
prerequisites. The frontend never contains the service key.

If deployed later, this function performs its own Auth validation; receipt status
uses a high-entropy secret so it can survive deletion of the login identity.
Gateway settings must support that status route. Validate current CLI options
before any deployment; no deployment command was executed here.

## Security behavior

- POST only, strict field allowlists, bounded request size, no user-selected target.
- Auth /user verifies the bearer token. Database preview checks the live session.
- The password is checked against the verified account's Auth email. The temporary
  session is revoked before job acceptance; its tokens are never returned.
- Only service_role may submit a job or inspect a receipt. SQL rechecks the original
  session, account state and preview fingerprint after password verification.
- Passwords and receipt secrets are never stored in the database. Receipts store
  SHA-256 hashes; no user details are returned by the receipt status endpoint.
- Repeated submission of the same request ID/receipt is idempotent. Another pending
  request for the account is rejected and exposed only in that account's preview.
- Initiation itself does not suspend accounts or revoke sessions. A separate,
  service-only `prepare_trainer_deletion` RPC now atomically suspends the trainer,
  removes their sessions, archives history, detaches members into empty unlinked
  records and revokes old invitations/queued pushes. It remains gated OFF and is
  not called by this initiation handler. No scheduler or permanent purge worker exists.
- Admin self-deletion is unavailable pending MFA and admin succession handling.

## Remaining release work

Shared-history decision: retain session/payment history for the member as
read-only historical information. The member_retained_history migration and UI
implement capture/read primitives, including former members and billing ledgers.
The preparation RPC integrates capture with a transactional write barrier and
detachment. A failed phase rolls back; retries return the same prepared result.
It does not delete Auth identities, Storage or historical rows. Test real concurrent
connections and large-account limits; extend the trainer-code flow for unlinked
members. Determine legal retention periods. Implement the actual cleanup worker, Storage
cleanup, cross-account snapshot cleanup, incident/recovery-copy treatment and
restoration protection. Implement completion receipt display after logout/app
restart; current profile refresh can track a request while its account is active.
Complete operational retries, stuck-job alerts, rate/load testing and a real
staging walkthrough. Do not report a request as completed merely because queued.

See docs/account-deletion-scope.md and docs/ios-v1-release-gates.md.
