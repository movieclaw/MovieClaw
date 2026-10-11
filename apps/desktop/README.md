# MovieClaw Desktop for Windows

A Windows x64 client built with Tauri, Rust and WebView2, with bundled mpv playback. It connects to a separately deployed MovieClaw server. The interface is embedded in the executable; the desktop application has an independent version (currently 1.0.0).

## Features

Library browsing, search, favorites, movie and episode details, resume/progress synchronization, audio and subtitle tracks, keyboard controls, fullscreen with original-ratio or cropped-fill modes, playback diagnostics and read speed. Windows integration includes media keys/SMTC, picture in picture, window restoration and sleep inhibition during playback. Playback controls hide after three idle seconds and reappear on mouse movement.

Server discovery, cookie login and account switching work with existing servers. Native device login and QR pairing require the server to advertise `windows` in `/auth/bootstrap.native_device_kinds`; compatible server support is outside this client contribution. Native tokens use Windows Credential Manager and persisted cookies use Windows-user DPAPI encryption.

## Build and test

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
./scripts/package.ps1 -InstallSmoke
```

Supported distribution target: Windows 10/11 x64. The installer includes mpv, its required runtime DLLs/licenses and the full Microsoft-signed offline WebView2 installer. It installs WebView2 when missing. The application statically links the Visual C++ runtime. Users do not need Node.js, Rust or a separately installed player. The portable ZIP needs WebView2 already installed.

Packaging verifies pinned archive/binary hashes, DLL imports, runtime startup and mpv IPC. Desktop CI exercises the packaged application, silent installation/startup/uninstallation, and uploads the installer, portable ZIP, `SHA256SUMS.txt` and `release-manifest.json`. The manifest records source revision, dependency sources/licenses, hashes and actual Authenticode status. Unsigned builds are identified as unsigned.

## Update channel

Official builds default to `movieclaw/MovieClaw`. A community distributor can set `MOVIECLAW_RELEASE_REPOSITORY=owner/repository` before building. The channel is fixed at build time; API responses cannot redirect it to a different repository.

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
