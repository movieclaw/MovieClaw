import { appTranslator } from "../i18n/translate.ts";
import { requestLocale, type AppLocale } from "../i18n/negotiate.ts";

/**
 * 开播提示「已沿用上次的选择」（与 iOS App 的 `RememberedChoices` 同一口径，
 * apps/apple/MovieClaw/Features/Player/PlayerPreferences.swift；设计见 docs/design/player-engine.md §3.2）。
 *
 * 画质按片记、音轨与字幕由服务端按单元记（剧集新一集沿用最近看的一集，换算成本集的轨）。下次打开
 * 这部片时，只有**不是默认**的选择才在出画那一刻提示几秒——免得对着 720p 的画面、日语音轨纳闷
 * 「怎么是这样」，默认的就不打扰。哪些项算「沿用了非默认」由播放器判（它知道默认挑的是哪条），
 * 这里只负责拼句子。
 */

/** 各项传 null = 这一项是默认（或这次没沿用记忆），不提 */
export function rememberedChoicesNotice(input: {
  quality: number | null;
  audio: string | null;
  subtitle: string | null;
}, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const t = appTranslator(locale);
  const parts: string[] = [];
  if (input.quality !== null) parts.push(t("player.memory.quality", { height: input.quality }));
  if (input.audio !== null) parts.push(t("player.memory.audio", { label: input.audio }));
  if (input.subtitle !== null) parts.push(t("player.memory.subtitles", { label: input.subtitle }));
  return parts.length ? t("player.memory.restored", { choices: parts.join(t("player.memory.separator")) }) : null;
}

/**
 * 菜单标签（「日语 · AC3 · 5.1」「简体中文 · 文本」）在提示里只留语言；
 * 同语言有好几条时留全称才分得清。
 */
export function shortTrackLabel(label: string, labels: readonly string[]): string {
  const name = (text: string) => text.split(" · ")[0] ?? text;
  const short = name(label);
  return labels.filter((other) => name(other) === short).length > 1 ? label : short;
}
