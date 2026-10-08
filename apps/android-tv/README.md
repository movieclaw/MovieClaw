# MovieClaw Android TV

独立的 Android TV 客户端，设计见 [docs/design/androidtv-app.md](../../docs/design/androidtv-app.md)。
与 `apps/android`（手机版）不共享代码。

## 构建

需要 JDK 17+（Android Studio 自带的 JBR 即可）与 Android SDK（`local.properties` 里写 `sdk.dir`）。

```bash
cd apps/android-tv
./gradlew :core:network:test :core:session:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

## 接口层

`core/model`、`core/network` 下的 `generated/` 由后端生成，勿手改。后端改了 TV 用到的接口后：

```bash
.venv/bin/python apps/android-tv/scripts/gen_api.py          # 重新生成
.venv/bin/python apps/android-tv/scripts/gen_api.py --check  # CI 用：校验一致
```

要用新接口，把它加进脚本里的 `ENDPOINTS` 白名单。

## 端到端验收

隔离测试服务器（/tmp 下全新数据库 + 生成的测试片，后端跑当前工作区代码）：

```bash
.venv/bin/python apps/android-tv/tests/fixture/fixture.py start   # 端口 8810，账号 admin / mclaw-atv-2026
```

模拟器（`Android_TV_API_34`）里用调试参数直达登录、播放（只认 debug 包）：

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n io.movieclaw.androidtv/.MainActivity \
  --es mc_server http://10.0.2.2:8810 --es mc_user admin --es mc_pass mclaw-atv-2026 --el mc_play 1
adb shell input keyevent KEYCODE_DPAD_CENTER   # 遥控器按键
adb exec-out screencap -p > shot.png
```

播放页日志 `adb logcat | grep " Playback"` 会打出每次起播的档位与路径（原文件直连 / 服务端 HLS）。
