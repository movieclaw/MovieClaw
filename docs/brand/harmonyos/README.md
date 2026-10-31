# 鸿蒙应用市场图标

沿用 MovieClaw **A9 极光、尺寸 B** 定稿。以下文件按上架后台提供的要求导出：
直角正方形、背景完全不透明、不预制圆角；圆角由平台 Mask 生成。

| 文件 | 用途 |
|---|---|
| [app-icon-1024.png](app-icon-1024.png) | **上架提交首选**：1024×1024，RGB PNG，约 445 KiB，低于 3 MB |
| [app-icon.svg](app-icon.svg) | 可编辑矢量源文件，1024×1024，保留路径、渐变、光晕滤镜，无嵌入位图、无字体依赖 |
| [app-icon-216.png](app-icon-216.png) | 216×216 备用 PNG，约 29 KiB |

![1024×1024 图标](app-icon-1024.png)

## 上架与 HAP 一致性

手机、平板、大屏、PC 的后台图标素材均使用 `app-icon-1024.png`，不要自行加圆角、
裁切、改色或转成透明背景。216 版本只在后台明确需要该尺寸时使用。

鸿蒙工程继续通过 `app.json5` 和 `module.json5` 中的 `$media:layered_image`
引用前景、背景两层。生成脚本同时更新以下两个公共资源目录，供各设备类型使用：

- `apps/harmonyos/AppScope/resources/base/media/`
- `apps/harmonyos/entry/src/main/resources/base/media/`

两处的 `background.png` / `foreground.png` 分别相同；**上架 1024 PNG 是这两层以原尺寸
合成的结果，逐像素一致**。因此后台使用本目录文件，HAP 使用同一提交中的分层资源。
应重新构建 HAP 后提交；已经发布或之前打出的 HAP 不会随仓库素材自动更新。

SVG 是品牌设计源稿。分层导出存在少量 8-bit 量化误差，不同 SVG 渲染器也可能产生不同的
抗锯齿结果；上架使用随附 PNG，不要单独重渲染 SVG 后与旧 HAP 混用。

## 重新生成

在仓库根目录执行（依赖 `Pillow`、`numpy`）：

```sh
python3 apps/harmonyos/tools/gen_brand_icon.py
```

脚本从 `docs/brand/masters/app-icon-1024.png` 生成两处 HAP 分层资源、启动图和两个市场 PNG；
从 `docs/brand/app-icon-dark.svg` 导出本目录的 1024 SVG。
修改设计时先同步更新品牌 SVG 和对应的 PNG 母版，再执行此命令，并将所有产物一起提交。
