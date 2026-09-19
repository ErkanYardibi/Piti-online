# Shared demo and production UI

Demo uses the same page router, chat renderer, composer, task forms, validation,
completion flow, task widgets and progress calculations as signed-in accounts.
Do not add a separate demo screen or a demo-only copy of a feature.

`chatData()` selects the data adapter. `cloudChatData` reads/writes Supabase;
`demoChatData` uses `state.demoChat` with the same message/task field names.
Keep storage-specific branching in this layer. Demo identity and customer keys
are resolved by `chatActorId()` and `chatClientId()`.

Demo starts from the shared cloud demo snapshot. A visitor's changes belong to
that test session; only the existing admin demo-save action publishes a new
shared snapshot. Demo operations must never write real messages, tasks or clients.
Authentication, authorization and multi-device persistence still require live
account tests; demo is not a substitute for those checks.

As of 2026-09-19 the shared fixture and its new version history are hosted in
the separate Free-plan `piti-demo` project (`ldufxzwgwbaogpmwqhlw`), under
Erkan Yardibi Organization. Production remains `objwhegswugyeibcnjfr`.
`demoDb` has no persistent auth session. A local static fixture is only the
fallback if the free DEMO project is unavailable. Visitor edits remain in memory.

Admin demo operations use `demo-admin` in the DEMO project. Its custom
authentication validates the production JWT through `admin_console('overview')`,
which enforces a current admin session and AAL2. Gateway JWT verification is off
because the token belongs to the other project; the handler fails closed before
any DEMO database access. Only a publishable production key exists there.
The built-in DEMO service credential never reaches the browser or production.
Versioned publication/restoration is atomic, with writes restricted to service_role.
Old production demo snapshots remain historical; the new UI no longer uses them.

Run `node --test tests/demo-admin.test.mjs` and execute `tests/demo-storage.sql`
against DEMO only. The latter rehearses exact restoration inside a transaction
and rolls it back. This is a DEMO version-recovery test, not production backup
or disaster-recovery validation. No production daily backup has been enabled.

Run `node tests/demo-messaging.cjs` with jsdom installed (or set PITI_JSDOM_PATH).
The test assigns a task as PT, completes it as the member, checks the measurement,
converts an existing message to a task, verifies customer isolation and rejects
any production database access by the demo flow.
