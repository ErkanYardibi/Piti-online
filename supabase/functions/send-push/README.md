# APNs dispatcher — NOT deployed

Apply the migration to a verified isolated staging project only after schema review.
Its private push_settings row defaults to enabled=false. No production mutations
are made by preparing these files. Do not enable this on the shared DEMO project.

Secrets (server only): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, APNS_KEY,
APNS_KEY_ID, APPLE_TEAM_ID, APNS_BUNDLE_ID and random PUSH_DISPATCH_SECRET
(at least 32 characters). Use online.mypiti.app.staging for TestFlight staging.
Never put Apple keys, service keys or the dispatch secret into the app or repo.

Deploy with gateway JWT verification disabled ONLY for this function, because
this endpoint verifies its own dispatch secret and accepts no user-directed
recipient or message. Check current Supabase CLI --help before deploying.
Configure a server-only scheduler (e.g. Supabase Cron with Vault secrets) to POST
here every minute with x-piti-push-secret. Scheduler is NOT installed by the
migration. No browser/webhook may call it with end-user credentials.

After real APNs tests, enable the private push_settings row with the matching
bundle topic. Staging uses the staging topic, including production APNs transport
for TestFlight; debug uses sandbox APNs transport. Separate app environment from
APNs transport environment. Production requires a separately approved rollout.

The database derives recipients from actual PT/client relations, records a
per-device queue, claims at most ten jobs under a two-minute lease and retries
up to five times with exponential backoff. It checks current account/session and
relationship at claim time. Old jobs expire after 24 hours; metadata after seven
days. A scheduler run is required for retries/cleanup. Monitor failed jobs.
APNs acceptance is not guaranteed delivery or proof that the user read it.
A crash after APNs acceptance but before acknowledgement may cause re-delivery;
the stable collapse ID mitigates but does not promise exactly-once delivery.

Implemented events: messages, new tasks, changed session status/time and payment
submission/decision. Pending V1 work: scheduled session reminders, delay events,
notification preference categories, selected-client broadcast, full real-device
APNs tests and load/rate-limit hardening. Do not mark all V1 notifications complete.
