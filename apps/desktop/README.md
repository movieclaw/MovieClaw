# MovieClaw Desktop for Windows

A Windows x64 client built with Tauri, Rust and WebView2, with bundled mpv playback. It connects to a separately deployed MovieClaw server. The interface is embedded in the executable; the desktop application has an independent version (currently 1.0.4).

## Features

Library browsing, search, favorites, movie and episode details, resume/progress synchronization, audio and subtitle tracks, keyboard controls, fullscreen with original-ratio or cropped-fill modes, playback diagnostics and read speed. Windows integration includes media keys/SMTC, picture in picture, window restoration and sleep inhibition during playback. Playback controls hide after three idle seconds and reappear on mouse movement.

Movie and episode details support selecting a file version, audio track and subtitle before playback. Administrators can preview and generate single-language or bilingual AI subtitles through the existing server APIs, restore task progress, cancel or retry jobs, and select completed subtitles. Generation uses reference subtitles and a configured server AI model; PGS OCR requires server support. Audio transcription without reference subtitles is not included. Arrow keys seek and adjust volume, with the current volume synchronized in the playback controls.

Server discovery, cookie login and account switching work with existing servers. Native device login and QR pairing require the server to advertise `windows` in `/auth/bootstrap.native_device_kinds`; compatible server support is outside this client contribution. QR entry points are temporarily hidden while deployed servers lack Windows pairing support. Native tokens use Windows Credential Manager and persisted cookies use Windows-user DPAPI encryption.

Version 1.0.2 adds opt-in Discovery and My Subscriptions. Enable each entry in Settings → Navigation; preferences are scoped to this computer, server and account. Browse TMDB/Douban, title details and people; subscribe with smart preferences or server rules. Monitor download/import stages, weekly arrivals, tracking, season selection and safe cleanup. Features depend on the deployed server APIs and account permissions. Site/downloader configuration opens the server Web settings.

## Build and test

Version 1.0.3 adds an optional [watch-presence server plugin](../../plugins/watch-presence/README.md) and a desktop friends panel accessible from Home and playback. Viewing friends and publishing watch activity default off. Sharing is limited to selected non-hidden, non-adult libraries; current sessions remain separate per device, while recent history is grouped per account and viewing unit. The plugin runs inside the existing server process and supplies a settings page for other clients. Native HLS playback rewrites manifest resource URLs through the authenticated local gateway, including nested playlists, keys and initialization segments. Capped playback failures offer explicit original-quality recovery.

Development requires Windows x64, PowerShell 7, Node.js 22, Python 3.12, Rust with the `x86_64-pc-windows-msvc` target, Visual Studio C++ Build Tools and 7-Zip. Desktop CI pins exact tool/runtime versions.

```powershell
cd apps/desktop
npm ci
./scripts/build.ps1 -Tests
npm run test:unit
npx playwright install chromium
npm run test:e2e
./scripts/dev.ps1
```

Tests use isolated fixtures. `MOVIECLAW_DATA_DIR` selects a separate data directory for native smoke tests. `MOVIECLAW_MPV` can select a development player; packaged builds use the verified bundled runtime.

## Packaging and requirements

```powershell
./scripts/package.ps1 -InstallSmoke -BuildNumber 61.1
```

Supported distribution target: Windows 10/11 x64. The installer includes mpv, its required runtime DLLs/licenses and the full Microsoft-signed offline WebView2 installer. It installs WebView2 when missing. The application statically links the Visual C++ runtime. Users do not need Node.js, Rust or a separately installed player. The portable ZIP needs WebView2 already installed.

Packaging verifies pinned archive/binary hashes, DLL imports, runtime startup and mpv IPC. Desktop CI exercises the packaged application, silent installation/startup/uninstallation, and uploads the installer, portable ZIP, `SHA256SUMS.txt` and `release-manifest.json`. The manifest records source revision, dependency sources/licenses, hashes and actual Authenticode status. Unsigned builds are identified as unsigned.

## Update channel

Official builds default to `movieclaw/MovieClaw`. A community distributor can set `MOVIECLAW_RELEASE_REPOSITORY=owner/repository` before building. The channel is fixed at build time; API responses cannot redirect it to a different repository.

Build numbers use the Desktop CI run number and attempt (`run_number.run_attempt`); CI supplies this automatically. GitHub sanitizes parentheses in resource filenames. The build-labeled installer ZIP preserves a filename such as `MovieClaw-Desktop-1.0.3(61.1)-Setup-x64.exe` inside, while GitHub resource labels show the same build number. Legacy installer/portable filenames and checksum entries remain available for installed clients' verified updates. `release-manifest.json` records `buildNumber` and the exact derived artifacts; their installer bytes must match the tested original. Use `label-packages.py --directory dist --build-number 61.1` to label an existing verified build without recompiling it.

The updater accepts exact Windows x64 assets from formal GitHub releases in that channel. Downloads validate HTTPS hosts, size and published SHA-256 hashes; installation rechecks the cached package and Authenticode. Invalid signatures are rejected, and unsigned installers require explicit confirmation. Releases without verifiable hashes offer a manual release-page path. Portable updates use manual replacement. Same-version rebuilds are distinguished using the manifest source revision and timestamp.

This contribution adds CI packaging, without enabling official release publication. Release ownership, signing and publication policy remain maintainer decisions.

## Validation boundaries

Browser E2E exercises the shipped DOM and HTTP contracts with a native bridge fixture. Hosted Windows native smoke exercises WebView2 startup, bundled mpv decoding/IPC and installation lifecycle; performance artifacts identify their fixture and software-decoding measurements.

Physical GPU/HDR output, audio passthrough, multi-monitor DPI, optical-disc playback and a physical clean Windows installation without WebView2 require further testing. Hosted CI does not establish full Windows/macOS hardware equivalence. Dependency license notices are included in the application/package.

## Source layout

- `ui/desktop/`: embedded UI, player controls, icons and styles.
- `src-tauri/`: native Windows integration, credentials, media gateway and verified updates.
- `tests/`: JavaScript contracts and browser E2E; native unit tests live beside Rust code.
- `scripts/`: build, packaging, native smoke and performance tools.
- `release/`: acceptance template, not a completed physical acceptance report.

Generated `dist/`, `src-tauri/target/`, `test-results/` and dependency directories are ignored.
