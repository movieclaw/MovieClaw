# Harmony phone playback E2E

Use an ARM64 HarmonyOS emulator/device with the real MPV libraries. x86 stub builds cannot validate fallback. Install a debug HAP, sign in to the test NAS, and open the app before running fixtures. `PlaybackTestProbe` ignores all requests in release builds. Fixtures contain file/item IDs, never authentication or signed media URLs.

Host regressions can run without a device. They transpile the production ArkTS with the
DevEco SDK compiler, run the shared Hypium controller/session/gateway suites, and exercise
HTTP subtitle failures, queued episode reports, startup deadlines and platform cleanup
with mocked platform boundaries:

```sh
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  node --test apps/harmonyos/scripts/tests/playback.test.cjs
```

Run from the repository root with Node 20 or newer. For another SDK layout, set
`HARMONY_TYPESCRIPT_PATH` to its `ets-loader/node_modules/typescript` directory.
These tests do not establish decoder, rendered-frame or system-service behavior on a device.

Build the app and `entry@ohosTest` separately from `apps/harmonyos`, using the DevEco SDK/JBR. Install both HAPs. Run the shared controller/session/gateway tests:

```sh
hdc shell aa test -b io.movieclaw.HUAWEI -m entry_test \
  -s unittest OpenHarmonyTestRunner \
  -s class PlayerInteraction,PlaybackController,PlaybackSessionCoordinator,PlaybackGateway -w 80
```

The `HarmonyPhonePlaybackE2E` suite runs seven real UI scenarios: repeated play/pause glyph checks for AVPlayer/MPV, AVPlayer/MPV menu highlighting, submenu scroll reset, pause, rotation, lock, display and auto-hide interactions, plus AVPlayer/MPV/automatic-fallback playback, seeking, diagnostics and exit. Pass JSON strings through `-s avplayerFixture`, `-s mpvFixture`, and `-s fallbackFixture`, with `-s timeout 180000` and `-w 600`. Each fixture uses the matrix shape below. The forced MPV fixture sets `engine: "mpv"`; the fallback fixture must actually be rejected by the target device's AVPlayer.

Screenshots are saved to the app cache as `mc-style-*.png` and `mc-toggle-*.png`; on the emulator, retrieve them from `/data/app/el2/100/base/io.movieclaw.HUAWEI/cache/`. Unlock the emulator before starting. Wait for menu transitions before clicking controls underneath.

## NAS format matrix

Install Pillow in a Python virtual environment. A matrix is an array of:

```json
[{"caseId":"example","itemId":1,"fileId":2,"season":0,"episode":0,"startMs":1,"engine":"auto"}]
```

Optional `trackRef: "embedded:1"` explicitly selects the second audio track. `subtitleRef: "off"` disables subtitles for an original-bitrate measurement; an explicit embedded subtitle reference can reproduce a server burn-in path. Without it, normal account subtitle preferences apply. Extra `format`, `audioFormat`, `title` fields annotate the report. Build the matrix from the NAS's actual file metadata, choosing each distinct container/video codec/HDR/bit-depth/audio combination. Add codec/profile/channel audio cases separately. This is representative format coverage, not watching every file to completion.

```sh
python playback_matrix.py --hdc /path/to/hdc --matrix fixtures.json --output /path/to/evidence
python summarize_playback.py /path/to/evidence
```

Run one device-driving suite at a time; UiTest and command-line layout/screenshot drivers share the emulator automation service. Stop the runner before reinstalling an app, then relaunch the app before resuming. Do not pause a live case across installation: its timestamps and player lifetime are no longer valid. Interrupted cases without a request/session must be excluded and rerun in a preserved evidence directory.

The runner opens the real phone page, waits for native clock advancement, captures video and audio-service evidence, pauses, seeks 30 seconds, resumes, and exits. Completed cases are skipped on reruns; use a new directory for a changed app build. Preserve the HAP checksum with the evidence. Inspect contact sheets and every flagged dark/still frame; a moving clock alone does not prove visible video. Audio-service RUNNING verifies an output stream, not subjective listening quality or surround passthrough. `firstFrameMs` is the AVPlayer render callback; MPV only reports playback state and must not be labeled first-frame latency. `clockAdvanceMs` confirms at least 1.5 seconds of actual progress (including that observation interval); `startupClockWaitMs` exposes delay between playing state and the first advancing clock sample. Steady clock ratio excludes that initial wait and is not a frame-rate measurement.

## Buffer recovery

Start the local proxy and forward a device port:

```sh
python media_proxy.py --upstream http://your-nas:3000
hdc rport tcp:53123 tcp:53123
python playback_network.py --hdc /path/to/hdc --fixture single-fixture.json --output /path/to/network-evidence
```

Use a high bitrate direct-play MP4. The runner limits initial throughput, stalls the media transport, observes buffering and frozen time, restores transport, and checks recovery without switching engines. It also stalls a far seek for 10 seconds and verifies recovery after uncached data becomes available. The proxy binds loopback, forwards Range requests, and does not log signed URLs. Remove the forwarding task shown by `hdc fport ls` and stop the proxy after testing.

Playback tests update the test account's viewing state through the same application paths as normal playback. Emulator results do not establish real-phone thermal behavior, HDR output fidelity, audio quality, cellular recovery, or background/telephony behavior.

## EOF and replay

`playback_lifecycle.py` uses a single-movie fixture, seeks near its end, waits for the real ended state, then checks replay from the beginning for both engines. Use a movie instead of a series to avoid auto-next changing the playback target.
