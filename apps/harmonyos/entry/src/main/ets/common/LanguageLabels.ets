/**
 * 轨道语言码（ISO 639-2/B 与常见私有码）→ 中文名。
 *
 * 详情页的字幕/音轨徽章与播放器的轨选择菜单共用同一份：同一条轨在两处显示
 * 成不同的名字（一处「简体中文」一处 chs），用户会以为是两条不同的轨。
 * 对齐 Web `apps/web/lib/language-labels.ts` 与 iOS `TrackModel.languageLabels`。
 */
const LANGUAGE_LABELS: Record<string, string> = {
  'chs': '简体中文', 'cht': '繁体中文', 'chi': '中文', 'zho': '中文', 'cmn': '中文',
  'yue': '粤语', 'eng': '英语', 'jpn': '日语', 'kor': '韩语', 'fre': '法语', 'fra': '法语',
  'ger': '德语', 'deu': '德语', 'spa': '西班牙语', 'rus': '俄语', 'ita': '意大利语',
  'por': '葡萄牙语', 'tha': '泰语', 'hin': '印地语'
};

/** 语言码 → 中文名；未收录的码原样返回，未标/und 返回 null（调用方自行兜底）。 */
export function trackLanguageLabel(code: string | null | undefined): string | null {
  if (code === null || code === undefined || code.length === 0 || code === 'und') {
    return null;
  }
  const label: string | undefined = LANGUAGE_LABELS[code.toLowerCase()];
  return label !== undefined ? label : code;
}
