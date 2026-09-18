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

Run `node tests/demo-messaging.cjs` with jsdom installed (or set PITI_JSDOM_PATH).
The test assigns a task as PT, completes it as the member, checks the measurement,
converts an existing message to a task, verifies customer isolation and rejects
any production database access by the demo flow.
