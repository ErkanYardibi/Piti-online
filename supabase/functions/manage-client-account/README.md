# Managed customer accounts

PT-created accounts are confirmed by the server and linked to the existing client ID; no email is sent. Existing email identities are never overwritten. A 24-hour, single-use token is shared in the URL fragment. Only its SHA-256 hash is stored. Initial passwords are shown in the PT modal and are not persisted in browser storage.

The Edge Function uses the built-in `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` environment variables. It has no external dependencies. Deploy `index.ts` with `deno.json` and `handler.mjs`. Gateway `verify_jwt` is disabled only because the entry-token exchange has no session. Every other action validates the bearer with Auth and checks the database session, immutable account role, and client ownership.

Apply `supabase/migrations` in order. `profiles.role` is assigned once on Auth account creation; changing user metadata or the login form cannot change it. Business-table policies require a live `auth.sessions` row and a completed password change. PT resets revoke prior sessions and entry links. Password completion also revokes temporary sessions; the UI signs in again with the customer's new password.

Messages use `public.messages`, keyed by `client_id`, with database-assigned sender roles. RLS limits each conversation to its owner PT and linked member. The browser cannot supply an arbitrary recipient or modify sender/body fields. Existing JSON chat history remains readable and immutable.

Validation:

- `node --test tests/*.test.cjs tests/*.test.mjs`
- `PITI_JSDOM_PATH=/path/to/jsdom node tests/managed-ui-smoke.cjs` (tested with jsdom 26.1.0)
- Execute `tests/managed-accounts.sql` and `tests/client-invitations.sql` in an administrative SQL connection. Both roll back their fixtures.
- Live endpoint smoke: GET returns 405; unauthenticated account management returns 401; approved-origin OPTIONS returns 204.

Persistent test users were not created in production. Live Auth account-creation/password-change integration still needs an authorized real-account acceptance test. Database behavior and the UI/Edge integration were verified with rollback fixtures and mocked Auth responses.
