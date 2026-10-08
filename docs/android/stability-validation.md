# Android stability fixes

Base: android / 55a68bea41e1c2cec27678abcd470aec08bd10fa.

## Priority and behavior

| Priority | Trigger | Fix / expected behavior |
| --- | --- | --- |
| P0 | Queued requests while switching accounts; lookalike origin | Capture atomic request identity; compare scheme, host, port; ignore stale account responses. |
| P1 | MKV with server Cues | Read upstream outside index, bound local reads, propagate tail failure and support retry. |
| P1 | HLS session or absent MPV library | Preserve HLS type; advertise universal decoding only with MPV and no quality cap. |
| P1 | Rapid open, quality changes, consent, or exit while negotiating | Cancel old work; bind results to controller/generation; stop obsolete sessions. |
| P1 | Heartbeat 404 | Recover in a separate job so cancelling the old heartbeat cannot cancel recovery. |
| P1 | Native Surface teardown or ISO close with blocked clients | Own MPV Surface/event thread per instance; interrupt and join workers before destroying shared resources. |
| P1 | Leave Reels during settle, negotiation, or delayed release | Cancel pending work, prevent direct fallback after cancellation, close sessions, flush deferred release. |
| P1 | Player proxy/service released | Stop polling, detach players, cancel scopes, snapshot stop progress before release. |
| P1 | Password-protected guest share | Separate origin/path-scoped cookies; guest requests/images carry no member token. |
| P2 | Prefetch cache unused or IDs collide across servers | Share custom playback/prefetch keys scoped by origin; preserve bandwidth sampling; cancel prefetch between ranges. |

## Automated scenarios

From `apps/android`, with JDK and Android SDK:

```sh
bash gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug -PskipNativeLibsDownload=true
bash tests/native/run.sh
```

Production Kotlin entry points run under Robolectric. MockWebServer exercises actual Retrofit/OkHttp HTTP requests for account switching, guest cookies, pending playback opens and MKV header/index/tail reads. Coroutine scenarios cover recovery, exit, Reels replay/release and proxy teardown. These are JVM integration scenarios, not physical-device E2E playback results.

The native harness includes production C++ with stub JVM/mpv/UDF dependencies and real sockets/threads. ASan/UBSan checks 200 MPV cycles, 60 ISO blocked receive/header cycles, 30 blocked-send cycles, reopen, repeated close and descriptor lifetime. This validates resource lifetime, not media decoding or UDF correctness.

Validated locally: all 38 Android tests passed, with zero failures/errors/skips. Android Lint passed with zero errors (existing warning/deprecation cleanup remains separate). Both the Exo-only debug APK and the full arm64 APK (including the checksum-pinned release native libraries) built successfully. Source inputs were copied unchanged to a local SSD for verification; the shared workspace uses a slower network filesystem.

CI runs scenarios, native sanitizers, Android Lint and the Exo-only debug APK build.

## Device acceptance before release

Still requires an arm64 device and a real server:

1. Progressive MKV with/without Cues, repeated seeks, HLS remux/transcode and seeks across segments. Confirm playback, timeline and tracks.
2. Rapid title/quality switching, exit during negotiation and server-session expiry. Verify no stale title/sound/session and correct recovery position.
3. MPV HDR/ASS, ISO, background/foreground, Surface recreation, notification control and 100 open/exit cycles. Check crash, ANR, threads and file descriptors.
4. Rapid Reels swiping, exit before settle, completed-clip replay and fullscreen handoff. Only visible clips play; replay stops at clip boundary.
5. Account/server switch with pending HTTP/SSE and password share while logged in. Guest cookies work; no member token reaches guest endpoints.
6. Offline/slow network, HTTP 503, low storage and Exo-only package.

## Remaining boundaries

- ISO supports HTTP only. HTTPS is explicitly rejected, never sent as plaintext. Mature TLS transport is a separate change.
- ISO still selects the largest M2TS; playlist-aware branching/libbluray support remains separate.
- Socket shutdown cannot interrupt `getaddrinfo`. ISO open/cleanup run off main; stalled DNS can delay shutdown.
- This patch does not redesign device codec probing or add Dolby Vision/BD-J guarantees.

- Clearing the byte cache while Exo/Reels/prefetch still holds readers needs a separate cache lease/lifetime change. The current clear/release API has not been redesigned in this patch.
