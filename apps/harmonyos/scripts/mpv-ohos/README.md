# MovieClaw libmpv（dex2oat/mpv OHOS 移植）交叉编译与集成

把 https://github.com/dex2oat/mpv （mpv 的 OpenHarmony 移植，被 HosPlayer 使用）编译成
单文件 `libmpv.so` 并内嵌进 MovieClaw 鸿蒙端，替代/并列系统 `AVPlayer`。

## 架构

```
ArkTS PlayerPage (几乎不动)
   └─ PlayerEngine = media.AVPlayer | MpvPlayer   ← 鸭子类型，签名逐一对齐
        └─ MpvPlayer.ets                           ← 状态机/事件映射（本目录 ../player/）
             └─ libmovieclaw_mpv.so (player_engine/src/main/cpp/mpv_napi.cpp, NAPI 桥)
                  └─ libmpv.so (player_engine/libs/arm64-v8a/, 本脚本产物)
                       ├─ vo_gpu + --gpu-context=ohos (EGL/GLES3, fork 的 video/out/context_ohos.c)
                       ├─ hwdec=ohcodec (硬解, fork hwdec_ohcodec.c + ffmpeg hwcontext_oh)
                       ├─ ao_ohaudio (OHAudio, 打了焦点中断补丁)
                       └─ 静态链入: ffmpeg(ohcodec+mbedtls) / libass / libplacebo / freetype
                                   / fribidi / harfbuzz / mbedtls / zlib
```

- surfaceId 从 XComponentController 拿到后经 mpv 的 **`--wid`** 选项传入
  （fork 的 ohos 输出层用它 `OH_NativeWindow_CreateNativeWindowFromSurfaceId`）。
- 引擎选择在 `PlayerPrefs`（`player.engine` = `'mpv'`（默认）| `'avplayer'`）。
- 能力申报：mpv 引擎下放宽 containers/音视频格式（PlayerPage.capability()）。

## 构建

依赖：DevEco Studio 的 OHOS NDK（脚本自动找 `/Applications/DevEco-Studio.app/...`）、
Homebrew 的 `meson ninja cmake pkg-config`、Python `jinja2` `jsonschema`（mbedtls 代码生成用）：

```bash
brew install meson ninja cmake pkg-config
pip3 install jinja2 jsonschema
./build-all.sh
```

产物（自动导出）：
- `player_engine/libs/arm64-v8a/libmpv.so` —— 播放引擎（单 .so，依赖全部静态链入；
  运行时只需要系统库 libEGL/libGLESv3/libohaudio/libnative_*/libz）
- `player_engine/src/main/cpp/include/mpv/*.h` —— NAPI 封装用的头文件

增量构建：每个组件有 `build/locks/<name>.stamp`，存在即跳过。
强制重建某组件：删对应 stamp + `build/out/<name>`。
`build/` 整目录不入库（.gitignore），可随时删掉重来。

## 组件与版本（BUILT-VERSIONS.txt 有实际构建记录）

| 组件 | 来源 | 说明 |
|---|---|---|
| mpv | dex2oat/mpv @ d974ee33 | OHOS vo/ao/hwdec 适配 |
| ffmpeg | dex2oat/FFmpeg @ dd2976b9 | 含 ohcodec 硬解/hwcontext_oh；`--enable-ohcodec --enable-mbedtls --enable-version3`（LGPLv3） |
| libplacebo | v7.351.0 | fork 把它设为硬依赖；最小化构建（无 vulkan/glslang/dovi） |
| libass | 0.17.4 | `--disable-require-system-font-provider`（字体走 --sub-fonts-dir=/system/fonts + 内嵌字体） |
| mbedtls | 2.28.9 | ffmpeg 的 TLS 后端（3.6 把头文件私有化，与 ffmpeg 不兼容，必须 2.x） |
| freetype / fribidi / harfbuzz / zlib | master/tag | libass 依赖链 |

## 对 fork 打的补丁（patches/，全部幂等）

1. **apply-mpv-patch.py → meson.build**：meson 引用了仓库里不存在的
   `video/out/vo_ohcodec.c`、`vo_ohcodec_osd.c`（作者漏提交）—— 移除引用。
2. **apply-mpv-patch.py → options/options.h**：补上漏提交的
   `mp_vo_opts.ohos_surface_size` 成员（options.c/ohos_common.c 在用）。
3. **apply-mpv-patch.py → video/out/ohos_common.c**：`vo_ohos_ohcodec_discard()`
   调用的 `ff_ohcodec_discard_buffer` 在配套 FFmpeg fork 里不存在（两 fork 版本错位，
   2026-01 的 FFmpeg vs 2026-04 的 mpv），加载即 relocation 失败 —— 改安全 no-op
   （该函数只服务 vo_ohcodec surface 模式的高倍速丢帧，GL 路径用不到）。
4. **apply-mpv-patch.py → video/out/vo.c**：驱动表挂着 `video_out_ohcodec`
   （定义文件没提交）—— 移除注册，否则 libmpv.so 加载即 `symbol not found`。
5. **apply-ao-patch.py → audio/out/ao_ohaudio.c**：注册 OHAudio 焦点中断回调
   （来电/抢占），经导出的函数指针 `mpv_ohos_interrupt_hook` 转发给嵌入方
   （mpv_napi.cpp → ArkTS `audioInterrupt` 事件 → PlaybackGuard）。

## 产物后处理（export_lib 内，缺一不可）

- **SONAME 改写** `libmpv.so.2 → libmpv.so`：meson 版本化命名与 HAP 打包名不符，
  NEEDED 解析不到 → 整个 NAPI 模块加载失败（症状：`does not provide an export name`）。
- **zlib 改挂私有名**：应用 ndk namespace 里没有 libz.so.1 →
  `patchelf --replace-needed libz.so.1 libmovieclaw_z.so` + 把 zlib 一起打包
  （症状：`MUSL-LDSO: load libz.so failed`）。
- needs `brew install patchelf`。

## 模拟器/真机验收记录（2026-10-27，Pura X View 模拟器，HarmonyOS 7.0）

| 项 | 结果 |
|---|---|
| 安装/启动/快捷登录 | ✅ |
| 直出档播放（mpv 读原始 mp4/mkv 流） | ✅ 电影全程直出 |
| 硬件转码档播放（服务端 VAAPI HLS） | ✅ 剧集 S01E195 |
| 视频/音频（OHAudio 6 声道渲染） | ✅ |
| libass 字幕（内封轨，中文，/system/fonts） | ✅ |
| 进度/时长/控制条唤出 | ✅（修了 PlayerPage 手势层丢失，见下） |
| 双击 ±10s / 暂停恢复 / 横竖屏往返 | ✅ |
| 画中画（surface 迁移后 mpv 继续渲染 + 字幕） | ✅（此前评估的头号风险，实测没问题） |
| 字幕面板 / 音轨面板 | ✅（修了 overlay 吃点击，见下） |
| 退出保存进度 + 媒体库迷你续播条 | ✅ |
| 服务端进度上报 / 会话心跳 | ✅（10s/15s POST 正常） |

### 顺带修掉的 PlayerPage 既有 bug（与引擎无关，重构遗留）

1. **手势层绑定丢失**（2f91836f）：`onGesture` 状态机成了死代码——单击唤不出
   控制条、双击/横滑/长按倍速全失效。作者注释里已写明正确方案（根 Stack 收得到
   触摸，全屏子层收不到），本次把 `.onTouch` 绑回根 Stack。
2. **`.overlay(UpNextOverlay)` 吞点击**：overlay 宿主空内容也全尺寸 + Default 命中
   + zIndex 置顶，整个播放页所有按钮点不动。改为 Stack 内条件子节点 + 容器穿透。
3. **Controls 空白轻点层**与根手势层会双 toggle —— 移除，统一由 handleTap 处理。

### 已知取舍（上架前要看的）

- libmpv.so 是 LGPLv3 组合（静态链入 ffmpeg/libass/libplacebo 等）；自用无碍，
  上架建议改动态链接或提供重链产物。
- `tls-verify=no`：自签证书服务器场景。
- av1/vp9 软解，能力申报封顶 1080。
- 长稳播放与自动连播（播完→即将播放卡）：见 VERIFIED.md 的实测记录。
