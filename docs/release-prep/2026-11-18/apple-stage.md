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

Pending: isolated simulator iPhone/iPad deletion regression, actor-filter tests, three Release archives and exports, signature/entitlement/identity verification, then upload and ASC VALID/internal availability verification. Never install or restart the user's installed apps. Use only dedicated test simulators.
