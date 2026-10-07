## torrent-ner v1: Structured extraction from torrent titles

A multitask torrent-title recognition model extracts titles, years, seasons and episodes, alongside separate media-type and content-type classifications. It is trained on lert-small and exported as an int8-quantized ONNX model that runs on CPU, for structured search results and enrichment.

### Installation

Download these three files into `data/models/torrent-ner/` under your deployment directory, then restart the service. Override the directory with `MOVIECLAW_NER_DIR` if needed.

| File | Description | SHA-256 |
| --- | --- | --- |
| `model.int8.onnx` | int8 model weights (15MB) | `ba39675e50b52d8eb641d7bce34b9b6fed63499657d50baeec03cdae8478c1a8` |
| `tokenizer.json` | Tokenizer | `a34543f1ac37c19b829db3674d5af635d1d72a5b4b3801d0ba208911df5860a2` |
| `labels.json` | Label definitions | `847224d5630ab44c42e1219f95060fcb3b10ad8747c4a70c0e2ca3df27426886` |

The service can start without the model. Only structured torrent-title extraction is unavailable, with an explicit log message.

---

## 简体中文

种子标题多任务抽取模型（NER：片名/年份/季集 + 媒体类型/内容类型双轴分类），基于 lert-small 训练后导出的 int8 量化 ONNX，CPU 即可推理，供「搜索结果实体化 / enrich」功能使用。

## 安装

下载以下三个文件，放入部署目录的 `data/models/torrent-ner/` 后重启服务（目录可用环境变量 `MOVIECLAW_NER_DIR` 覆盖）：

| 文件 | 说明 | SHA-256 |
| --- | --- | --- |
| `model.int8.onnx` | int8 量化模型权重（15MB） | `ba39675e50b52d8eb641d7bce34b9b6fed63499657d50baeec03cdae8478c1a8` |
| `tokenizer.json` | 分词器 | `a34543f1ac37c19b829db3674d5af635d1d72a5b4b3801d0ba208911df5860a2` |
| `labels.json` | 标签定义 | `847224d5630ab44c42e1219f95060fcb3b10ad8747c4a70c0e2ca3df27426886` |

未放置模型时服务可正常启动，仅种子名结构化抽取功能不可用，日志中会有明确提示。
