# PiTi iOS V1 — development source

Not yet a signed app or App Store-ready release. See ../docs/ios-v1-release-gates.md.
First internal beta scope and upload preparation: ../docs/testflight-first-beta.md.

## Mac / Xcode

Install Xcode and XcodeGen, then run:
    xcodegen generate --spec ios/project.yml

Open ios/PiTi.xcodeproj. PiTi-Staging archives with Staging configuration.
Debug and Staging require a VERIFIED, isolated staging web URL; no live fallback.
Do not use piti-online.erkan-yardibi.workers.dev as staging: it shares production data.
The approved staging backend now shares the separate DEMO project. See
../docs/staging-shared-demo.md for its dedicated frontend deployment and verification.

Create the ignored ios/Config/Local.xcconfig locally with a real developer team
and the verified staging URL. For xcconfig HTTPS values use https:/$()/HOST.
Use bundle ID online.mypiti.app.staging for testing and online.mypiti.app for
production only after verifying availability in your Apple account.

Debug uses development APNs. TestFlight staging uses production APNs with the
staging bundle ID. APNs environment is not inferred from DEBUG.
Enable the Push Notifications capability in the Apple developer account.
Universal Links are deliberately not entitled until the domain AASA file and
Team ID are verified; only safe piti://calendar / messages etc. routes exist now.

The WKWebView preserves its own technical session. No business-data offline
database is added. Secure-storage/session review remains a release gate.
Default WebKit file inputs handle native photo/file selection; device testing
must verify camera, gallery, PDF receipt and audio capture before release.

## Push backend

See ../supabase/functions/send-push/README.md. SQL migration is OFF by default.
Apple .p8 keys, service-role keys and dispatcher secrets stay server-side.
No paid database, extra production project or production rollout was created.

## Local tests

node --test tests/ios-push.test.mjs
PITI_PGLITE_PATH=/ABS/PATH/TO/@electric-sql/pglite node tests/ios-push-db.cjs

PGlite 0.5.8 is the tested disposable database engine. Existing UI tests use
jsdom 26.1.0 via PITI_JSDOM_PATH. The GitHub macOS verification workflow compiles
without signing, does not upload to TestFlight and does not deploy the website.
