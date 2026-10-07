## torrent-ner v2: Subtitle and audio recognition

### Changes

- Retrained on 26,432 production examples from 17 trackers, replacing v1's six-field model.
- Added SUBTITLE and AUDIO spans to recognize subtitle declarations, subtitle formats and audio declarations in torrent titles.
- Retains title, year, season/episode, media-type and content-type extraction; all six existing fields improve over v1.
- With a newer MovieClaw application, these fields support subtitle and audio-language filters and automatic torrent-selection rules.

### Quality

- Frozen test set of 2,405 examples: SUBTITLE F1 0.973, AUDIO F1 0.963.
- Exact language-set accuracy in the business layer: subtitles 99.6%, audio 99.8%.
- Chinese subtitle-rule precision 0.997; Mandarin audio-rule precision 1.000.
- CPU int8 inference per item: p50 5.3ms, p95 8.8ms.

### Updating

Check and install model updates in MovieClaw's Settings → Application. For a manual deployment, download `model.int8.onnx`, `tokenizer.json` and `labels.json` into `data/models/torrent-ner/`, then restart the service. `manifest.json` verifies in-app downloads.

---

## 简体中文

## 变更

- 基于 26,432 条、17 个站点的正式语料重新训练，替换 v1 的六字段模型。
- 新增 SUBTITLE 与 AUDIO 两类 span，可识别种子标题中的字幕声明、字幕载体和音轨声明。
- 继续支持片名、年份、季集、媒体类型与内容类型抽取，旧六字段相对 v1 全部提升。
- 配合 MovieClaw 新版可用于字幕语言、音轨语言筛选和自动选种规则。

## 质量

- 冻结 test 2,405 条：SUBTITLE F1 0.973，AUDIO F1 0.963。
- 业务层语言集合精确一致率：字幕 99.6%，音轨 99.8%。
- 中文字幕规则 precision 0.997，国语音轨规则 precision 1.000。
- CPU int8 单条推理：p50 5.3ms，p95 8.8ms。

## 更新方式

推荐在 MovieClaw 的 设置 → 应用 中检查并安装模型更新。手工部署时下载 model.int8.onnx、tokenizer.json、labels.json 到 data/models/torrent-ner/ 后重启服务；manifest.json 用于应用内下载校验。
