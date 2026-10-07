## torrent-ner v3: Correct season and episode extraction in individual filenames

Fixes v2's blind spot for dot-separated episode filenames with higher season numbers, such as `Thirteen.Talks.S06E01.…`. Episode numbers could be missed or labeled as seasons, causing cascading quality-upgrade failures.

### Training data

Real labeled examples increased from 26,432 to 28,024: 1,592 newly mined, stratified dot-separated episode examples with full quotas for S04–S08. Another 1,236 examples use season renumbering, with at least 85 examples per bucket across S02–S12.

### Validation compared with v2

- New deterministic season-scan matrix, 4 templates × 12 seasons × 8 episodes: **384/384**, up from 359/384.
- Test set: EPISODE F1 **+1.5 points** to 0.960; TITLE_ZH +0.8, SEASON +0.3.
- 130 regression examples: TITLE_ZH +1.4, TITLE_EN +0.5, YEAR +1.0.
- Held-out tracker: EPISODE +0.7, SEASON +0.1; other field differences remain within seed noise, at most 0.6 points.

### Updating

Install through the settings page's model update action, then restart to apply. Pair it with application enrichment v16, which removes subtitle-negation guards. Training details and ablation records are in `docs/design/subtitle-audio-ner.md` and `ml/torrent_ner/augment_filenames.py`.

---

## 简体中文

## torrent-ner v3（单集文件名季集修复）

修复 v2 的「点分隔单集文件名 × 中高季号」盲区（`Thirteen.Talks.S06E01.…`
式文件名漏抽集号、集号数字被错标成季号，曾导致洗版链路连锁故障）。

**语料**：26,432 → 28,024 条真实标注（新增 1,592 条分层重挖的点分隔单集，
S04–S08 满配额）+ 1,236 条季号重编号增强（S02–S12 每桶 ≥85）。

**门禁成绩（vs v2，同口径）**：
- 扫季确定性矩阵（新增门禁，4 模板 × 12 季 × 8 集）：**384/384**（v2: 359/384）
- test：EPISODE F1 **+1.5pt**（0.960），TITLE_ZH +0.8，SEASON +0.3
- 回归 130 例：TITLE_ZH +1.4、TITLE_EN +0.5、YEAR +1.0
- holdout 站：EPISODE +0.7、SEASON +0.1，其余场差均在 seed 噪声内（≤0.6pt）

**升级方式**：设置页 → 模型更新一键安装（需重启生效）。应用侧建议配合
enrich v16（字幕否定护栏退役）一同更新。训练细节与消融记录见
`docs/design/subtitle-audio-ner.md` 及 `ml/torrent_ner/augment_filenames.py`。
