# PiTi — first internal TestFlight beta

The first internal device test does not wait for all planned features or public
App Store release gates. It does require a working signed build and isolated test
data. No TestFlight build has been uploaded yet.

## First test scope

- Install/launch, PT and member login, logout and switching accounts.
- Dashboard, calendar and session requests, messages and keyboard behavior.
- Safe-area layout, background/resume, network loss/retry and photo/file selection.
- Real push delivery only after staging APNs and its queue are configured; until
  then, record push as unavailable, not passed.
- Account deletion stays unavailable until the permanent cleanup path is complete.

Use synthetic accounts. An internal beta does not authorize production deployment.

## Requirements before upload

1. Active Apple Developer Program membership and App Store Connect access.
2. Register/verify staging Bundle ID `online.mypiti.app.staging`, create its app
   record and configure signing with the actual Team ID. Enable Push Notifications.
3. Publish a verified separate staging frontend/backend with synthetic data.
   Neither mypiti.online nor its workers.dev alias is a staging backend. A different
   hostname alone does not prove isolation. Do not copy live customer data.
4. On a Mac/Xcode build host, generate the project and resolve Staging settings.
   A personal Mac is not mandatory if an authorized macOS CI signing setup is used.
5. Archive/sign the device build, validate it and upload to App Store Connect.
   Set an unused build number, complete export compliance and wait for processing.
6. Add the build to an internal testing group and the account holder as a tester.
   External testers are a separate step; the first external build requires beta
   review. Do not promise an Apple processing/review completion time.

## Configuration preflight

Create ignored `ios/Config/Local.xcconfig` with the real team and verified staging
URL, as described in ios/README.md. No Apple keys/passwords go in Git or chat.

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/PiTi.xcodeproj -scheme PiTi-Staging -configuration Staging -sdk iphoneos -showBuildSettings -json > /tmp/piti-staging-settings.json
python3 ios/check-testflight.py /tmp/piti-staging-settings.json
```

The preflight checks resolved configuration, device platform, Team ID format,
signing enabled, staging Bundle ID, production APNs transport and an HTTPS URL
that is not a known live host. It does not validate certificates, Apple permissions,
the remote frontend/backend, or whether the build number was already uploaded.
An unsigned simulator build is useful evidence, but is not an installable IPA.

## Current blockers

Apple membership/Team ID and signing access are unconfirmed. Staging URL is blank
by design. No isolated staging backend or signed archive is verified. These are
the next delivery gates; there is no credible installation date until resolved.

Sources checked 21 September 2026:
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
- https://developer.apple.com/programs/
