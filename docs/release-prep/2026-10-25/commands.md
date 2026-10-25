# 验证与后续发布命令

本页是操作草稿。发布命令本次均未执行。先解决 validation.md 的失败/未验项目，并合入准备分支；不要用未提交的本地版本号直接在 origin/main 上打 tag。

## 建议顺序

1. 完成服务器升级/备份恢复、GPU 与客户端兼容验证，完成发布准备 PR 的 CI。
2. 先发服务器 `v0.43.0`（包含 Web、CLI、runtime 24 镜像与随带插件），验证正式镜像和旧客户端。当前旧服务器兼容尚未全部验证，因此采用服务器先行的保守顺序，不代表已证实客户端无法降级。
3. 发 Apple 三端、Android 两端；Windows 播放器 0.1.2 优先级较低，可随后发。只有 Apple 客户端实际签名分发后，才能宣称用户已能安装；tvOS 的 GitHub Release 不等于 TestFlight 已上线。
4. Windows 转码器先补独立渠道和 Windows 实机证据，再首发；必须与服务器说明中的“可安装”状态协调。Mac 转码器、NER、HarmonyOS 本次不发。
5. 检查每个客户端 Release 不是 latest，服务器仍是 latest；如服务器正文需要更新刚发布的客户端列表，再重建正文（不要把未上线的 App 写成已可用）。

若后续完整验证了新 App 对旧服务器的回退，可按仓库常规改为 App → 服务器，以便服务器说明自动包含这批客户端。两种顺序都需先通过验证，不凭版本常量推断兼容。

## 本地检查（不会发布）

```bash
python3 scripts/release-status.py --ref HEAD --offline
# 上述脚本读 git 提交，不读未提交的版本改动；本地提交后才反映新版本。
PYTHON=.venv/bin/python scripts/export-spec.sh
.venv/bin/ruff check .
.venv/bin/python scripts/i18n/check.py
.venv/bin/python -m pytest -m 'not integration' tests/api tests/i18n tests/windows_transcoder tests/windows_transcoder_app tests/playback scripts/tests -n 4 --dist loadfile --timeout=180
.venv/bin/python -m pytest -m integration tests/e2e/test_i18n_browser.py tests/e2e/test_hevc_transcode_browser.py tests/api/test_playback_hevc_e2e.py --timeout=240
pnpm install --frozen-lockfile
pnpm web:lint
pnpm web:typecheck
TZ=Asia/Shanghai pnpm --filter web test
pnpm web:build
PYTHON_BIN=.venv/bin/python VERSION=0.43.0 bash scripts/build-release-artifacts.sh /tmp/movieclaw-release-artifacts
(cd cli && go vet ./... && go test ./...)
(cd apps/desktop && npm ci && npm test)
apps/apple/scripts/ci-build.sh MovieClaw iOS Release
apps/apple/scripts/ci-build.sh MovieClawTV tvOS Release
apps/apple/scripts/ci-build.sh MovieClawMac macOS Release
(cd apps/android && bash gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug)
(cd apps/android-tv && bash gradlew :core:network:test :core:session:testDebugUnitTest :core:playback:testDebugUnitTest :core:update:testDebugUnitTest :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease)
```

本地完整镜像（需要正确的 TMDB 配置，不推送镜像）：

```bash
# 构建脚本从环境或本机 .env 取 Key；不要把 Key 写入报告或提交。
bash scripts/build-image.sh
```

Android 正式签名打包（仅在已配置原签名环境的机器）：

```bash
bash apps/android/scripts/package-release.sh
bash apps/android-tv/scripts/package-release.sh
```

Windows 转码器安装包与真正的硬件端到端（Windows 10/11 + NVENC + jellyfin-ffmpeg）：

```powershell
powershell -ExecutionPolicy Bypass -File windows\MovieClawTranscoder\scripts\build-app.ps1 -Makensis 'C:\Program Files (x86)\NSIS\makensis.exe' -OutDir "$env:TEMP\MovieClawTranscoder-release-prep-0.1.0"
# OutDir 应是本次新建的输出目录；脚本会清空指定目录。
$env:MOVIECLAW_TEST_FFMPEG = 'C:\jellyfin-ffmpeg\ffmpeg.exe'
python -m pytest -m integration tests/playback/test_windows_transcoder_e2e.py tests/playback/test_windows_transcoder_matrix.py tests/playback/test_windows_transcoder_app_e2e.py tests/playback/test_windows_transcoder_browser.py
```

Windows 播放器的发布验证由 `.github/workflows/desktop-ci.yml` 实施。产物齐备后复核：

```bash
python3 apps/desktop/scripts/check-release-evidence.py --policy ci-verified \
  --directory dist --revision "$RELEASE_SHA" --version 0.1.2 --notes notes-with-ci-scope.md
# notes-with-ci-scope.md 须合并 changelog 和 apps/desktop/release/ci-verified-scope.md。
```

## 合入后才执行：远程发布

以下命令会真正发布，必须由维护者在本次准备完成、阻塞项关闭并决定发布后执行。

```bash
git fetch origin main --tags
# 填准备 PR 实际合入且通过检查的提交，不能填本报告旧的 a4559c65d。
RELEASE_SHA='<填入已合入并通过发布检查的完整提交 SHA>'
git merge-base --is-ancestor "$RELEASE_SHA" origin/main
# 在该 SHA 上核对版本、runtime、changelog 与依赖锁文件；只看工作区不够。
python3 scripts/release-status.py --ref "$RELEASE_SHA" --offline
```

每次只发布一个组件；每一条 push 都会触发对应工作流。不要一次批量推全部 tag。

```bash
git tag v0.43.0 "$RELEASE_SHA"
git push origin v0.43.0
# 等 release / docker-image 成功，并验证镜像和升级后，再继续。
git tag ios-v0.11.0 "$RELEASE_SHA"
git push origin ios-v0.11.0
git tag macos-v0.11.0 "$RELEASE_SHA"
git push origin macos-v0.11.0
git tag tvos-v0.11.0 "$RELEASE_SHA"
git push origin tvos-v0.11.0
git tag android-v0.8.0 "$RELEASE_SHA"
git push origin android-v0.8.0
git tag androidtv-v0.7.0 "$RELEASE_SHA"
git push origin androidtv-v0.7.0
git tag windows-v0.1.2 "$RELEASE_SHA"
git push origin windows-v0.1.2
```

确认包版本、build number、签名和 TestFlight 测试内容后，在配置好账号的打包 Mac 上上传（本次不执行，也没有读取凭据）：

```bash
apps/apple/scripts/release.sh --upload
apps/apple/scripts/release.sh --tv --upload
apps/apple/scripts/release.sh --mac --upload
```

`--mac` 是 Apple 商店/TestFlight 构建；官网 DMG/Sparkle 直装版由 `macos-v*` 流水线构建签名，两条渠道不能混为一谈。

Windows 转码器暂时没有可直接触发的现成发布工作流。建议独立前缀 `windows-transcoder-v0.1.0`；前缀/下载清单识别落地、Windows 产物通过安装和硬件验收后，可选择独立流水线，或以下手动首发方案（仍是未来命令，不能现在照跑）：

```bash
# 准备含英文和中文的最终 notes，并确认 dist 是通过测试的同一份 Windows 产物。
gh release create windows-transcoder-v0.1.0 --repo movieclaw/MovieClaw \
  --target "$RELEASE_SHA" --draft --latest=false \
  --title 'MovieClaw Transcoder for Windows 0.1.0' --notes-file windows-transcoder-notes.md
gh release upload windows-transcoder-v0.1.0 --repo movieclaw/MovieClaw \
  dist/MovieClawTranscoder-0.1.0-setup-x64.exe \
  dist/MovieClawTranscoder-0.1.0-portable-x64.zip dist/SHA256SUMS.txt
# 核验下载、校验和、签名声明和版本后才转正。
gh release edit windows-transcoder-v0.1.0 --repo movieclaw/MovieClaw --draft=false --latest=false
```

发布后只读检查：

```bash
gh release view v0.43.0 --repo movieclaw/MovieClaw --json tagName,isDraft,isPrerelease,assets
# 对每个客户端 tag 同样检查附件和正文。
gh api repos/movieclaw/MovieClaw/releases/latest --jq .tag_name
# 预期 v0.43.0，避免 CLI 安装脚本下载到客户端 Release 后 404。
```
