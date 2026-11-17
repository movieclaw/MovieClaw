/**
 * 宿主自绘字幕（AVP 文本旁挂）的 cue 模型、SRT/WebVTT 解析与时刻检索。
 *
 * 背景：histreamer（AVPlayer）挂上 fd/URL 字幕源后，主解码流高概率楔死——时钟
 * 停走、状态机仍报 playing、无 error 回调（2026-11-17 NAS 直连真机取证，4/4
 * 复现）。文本旁挂因此不再进内核，由宿主下载解析成 cue，按播放位置自绘。
 */

export class SubtitleCue {
  public startMs: number;
  public endMs: number;
  public text: string;
  constructor(startMs: number, endMs: number, text: string) {
    this.startMs = startMs;
    this.endMs = endMs;
    this.text = text;
  }
}

/** `H:MM:SS,mmm` / `MM:SS.mmm` 一类时间戳 → 毫秒；解析失败返回 -1。 */
function parseTimestampMs(raw: string): number {
  const match = raw.trim().match(/^(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})$/);
  if (match === null) { return -1; }
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3]);
  const fraction = Number(match[4].padEnd(3, '0'));
  if (isNaN(hours) || isNaN(minutes) || isNaN(seconds) || isNaN(fraction)) { return -1; }
  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fraction;
}

/**
 * SRT / WebVTT → cue 列表：按空行分块，找 `-->` 计时行取起止（VTT 结束时间戳后
 * 的行内 cue 设置先按空白截断再解析），正文剥 HTML 标签；序号行 / WEBVTT 头 /
 * NOTE 块没有计时行自然跳过。按 start 升序，空正文丢弃。
 */
export function parseSubtitleCues(raw: string): SubtitleCue[] {
  const cues: SubtitleCue[] = [];
  const text = raw.replace(/^\uFEFF/, '').replace(/\r/g, '');
  const blocks = text.split(/\n{2,}/);
  for (const block of blocks) {
    const lines = block.split('\n');
    let startMs = -1;
    let endMs = -1;
    let timingIndex = -1;
    for (let i = 0; i < lines.length; i++) {
      const arrow = lines[i].indexOf('-->');
      if (arrow < 0) { continue; }
      const parts = lines[i].split('-->');
      if (parts.length < 2) { continue; }
      startMs = parseTimestampMs(parts[0]);
      endMs = parseTimestampMs(parts[1].trim().split(/\s/)[0]);
      if (startMs >= 0 && endMs > startMs) { timingIndex = i; break; }
    }
    if (timingIndex < 0) { continue; }
    const body = lines.slice(timingIndex + 1).join('\n').replace(/<[^>]*>/g, '').trim();
    if (body.length === 0) { continue; }
    cues.push(new SubtitleCue(startMs, endMs, body));
  }
  cues.sort((a: SubtitleCue, b: SubtitleCue): number => a.startMs - b.startMs);
  return cues;
}

/**
 * atMs 时刻的 cue 文本：二分定位最后一条 start <= atMs 的 cue，向后回溯收集所有
 * 仍在档的（重叠轨按开始序以换行拼接）；回溯用「已见最大 endMs」做终止——只要
 * 前面任何 cue 的 endMs 都追不上 atMs，更早的绝无可能命中，常规无重叠文件一两
 * 步即断。无命中返回空串。
 */
export function subtitleCueTextAt(cues: SubtitleCue[], atMs: number): string {
  let low = 0;
  let high = cues.length;
  while (low < high) {
    const mid = Math.floor((low + high) / 2);
    if (cues[mid].startMs <= atMs) { low = mid + 1; } else { high = mid; }
  }
  const parts: string[] = [];
  let beyondMs = -1;
  for (let i = low - 1; i >= 0; i--) {
    if (cues[i].endMs > beyondMs) { beyondMs = cues[i].endMs; }
    if (beyondMs <= atMs) { break; }
    if (cues[i].startMs <= atMs && cues[i].endMs > atMs) { parts.unshift(cues[i].text); }
  }
  return parts.join('\n');
}
