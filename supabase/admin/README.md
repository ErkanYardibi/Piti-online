# PiTi admin console

Admin membership is kept in `piti_private.admin_users`, not editable user metadata or a public role dropdown. The ADMIN login alias resolves to the appointed owner's existing Auth account; no default password is generated or committed. Before assigning the first admin, confirm the owner's account identity. Do not infer ownership from a display name.

Only a valid, non-suspended session with AAL2 can call `admin_console`. Initial TOTP enrollment is performed by the owner at first admin login. Existing PT/member role remains intact. Admin mode does not load or save the ordinary PT/member application state.

Implemented: separate login/registration, exact DEMO/DEMO button visibility, TOTP enrollment/challenge, paginated user and PT/client listings, last login/registration dates, heartbeat presence, Auth event history, business change field audit (no passwords or message bodies), password reset with forced replacement, session revocation, suspension/archive/restore, registration and maintenance controls, announcements, shared demo editing and demo version restore.

Presence means activity during the last 90 seconds, refreshed every 30 seconds while the page is visible. Revocation is enforced by server session checks on gated business data, not only by hiding UI. Historical events cannot be reconstructed; Auth events are limited to the provider's retained logs. User/client relationship editing and recovery of previously hard-deleted business records are not implemented. No admin identity has been assigned by the migration.

Validation:
- `node --test tests/admin-account.test.mjs`
- `PITI_JSDOM_PATH=/path/to/jsdom node tests/admin-dom.cjs`
- `tests/admin-access.sql` runs inside a rollback-only transaction on the database.
- Optional real browser smoke: `node tests/admin-ui.cjs` (Playwright + Chromium required).

`admin-account` deliberately handles JWT verification in its body via Auth get-user plus database session checks. All reset operations require the caller's admin RPC gate before any service-role password update. Service keys stay in Edge Function secrets.
