# Apple / TestFlight 0.14.1 preparation

## Scope and baseline evidence

- Server prerequisite verified: v0.51.0, SHA `395373eb3c79058ee8ce1b2077850b3c4c84ea5c`, release run `44211125388` success, published release `449383201`.
- ASC queried on 2026-11-18 through the existing local Python helper and official API, selecting bundle ID `io.movieclaw.app`, app `6816792312`.
- Latest uploaded builds (complete 50-record result, no next page):

| Platform | Version / build | ASC build ID | Processing / internal state |
|---|---|---|---|
| iOS | 0.13.0 / 202611111752 | 489a5a8b-4348-49bd-8000-1ca8d86a57dd | VALID / IN_BETA_TESTING |
| tvOS | 0.13.0 / 202611111752 | 6aa999d6-71ba-4678-aa94-c472f10b6d1b | VALID / IN_BETA_TESTING |
| macOS | 0.13.0 / 202611111752 | 69b0944a-7747-4640-bcca-fb449a441e19 | VALID / IN_BETA_TESTING |

These builds uploaded on 2026-11-11 at 18:07–18:20 UTC. The actor-wall feature `3e4aacae16084627bb7b39314bec7d636af17682` was committed on 2026-11-12 at 02:26 UTC. Thus all three platforms have real changes relative to their latest TF build. iOS additionally includes the session-deletion crash fix `9dd11c106`.

Exact old TF source SHA is not provided by ASC; no previous archive was found at the documented local build path or Xcode Archives path. The 0.13.0 GitHub tag is `4afc18515964c89de8e38f71cdc77c40515710ed`, a comparison reference, **not verified TF provenance**. Coordinator asked for historical build evidence. Existing TF test notes match the 0.13.0 episode-picker scope.

## Product inventory

| Source | User effect | Release notes |
|---|---|---|
| 3e4aacae1 | Local/NFO actor card opens same-library actor wall; platform-specific navigation/removal | All three platforms, relative to latest TF 0.13.0 |
| 9dd11c106 | iPhone/iPad AI session deletion no longer prematurely removes the row and crashes | iOS only; swipe/cancel, long-press, conversation menu, last row in date group |
| 43eacf65d | Optional generated playback-policy fields; no new client interaction or consumer | Omitted as internal model compatibility |
| release-surface-diff | No removed UI strings and no changed client defaults or minimum-version gates | No extra notes needed |

Version 0.14.1 avoids reusing the already published 0.14.0 product versions. Shared marketing version only; each uploaded build must exceed the latest existing platform build. Release preparation changes no client behavior. No App Store/Beta review or group changes are authorized. Build-specific test notes must match each platform.

## Validation / delivery

Completed locally on source commit `4a559e7bc` (Apple tree `6388e539bbc326e8735c93c05adc6cddad81c6c0`):

- Dedicated iPhone 17 and iPad Pro 13-inch simulators: `PersonalSpaceUITests/testDeletingSessionsKeepsListConsistent`, each 1 passed / 0 failed / 0 skipped, complete xcresult and TEST SUCCEEDED. Includes cancel, swipe, long-press, conversation menu, emptying date section and exactly four server deletions.
- `LibraryActorFilterTests`: 8 passed / 0 failed / 0 skipped, complete xcresult and TEST EXECUTE SUCCEEDED. Covers actor routing, deep links, filter persistence and request query parameters.
- Xcode 27.2 (27B52), fixed dependency lock, all three Release archives and App Store Connect exports succeeded.
- Exported IPA/PKG contents: strict deep signature verification; expected bundle/platform/version/build; App Store provisioning with no device list or debug entitlement. iOS includes both device families and two correctly signed notification extensions; tvOS device family 3; Mac universal arm64/x86_64, sandboxed store app without Sparkle, installer signature verified. No package installed.
- Sanitized artifact hashes and validation summary: `apple-build-validation.json`.
- Existing test.sh prematurely ended a combined unit/UI run after unit summary; that incomplete result was discarded. Direct xcodebuild runs above completed with valid result bundles. No unrelated script change.

Completed after PR #1298 was rebase-merged into `fa23d2369d0c5db6de88397479116d0cbe0c462e`: root tree `69e8a838aa8cc661dedc1f6dd476fc378cd096f9` and Apple input tree matched the reviewed preparation. Original signed IPA/PKG hashes matched the committed preflight evidence; no rebuild/re-export. Archive manifests were hashed before upload and rechecked afterward; executable/dSYM UUIDs match.

All three original packages were uploaded through Xcode's official altool using the existing authorized local ASC key. Final official ASC readback confirms all three are **VALID / IN_BETA_TESTING**, unexpired and without encryption-compliance blockers. Each platform's en-US/zh-Hans test notes were written and read back. External state remains READY_FOR_BETA_SUBMISSION; no review or group changes. No user-installed app was installed or restarted; UI tests used only newly created dedicated simulators.

Final build IDs, delivery receipts, immutable artifact/archive hashes, notes, UTC verification time and bounded diagnostics are recorded in `apple-testflight-results.json`. The optional group-relationship query returned 403 and was stopped without requesting permissions; internal availability is independently established by each official buildBetaDetail record. **No remaining Apple blocker.**
