/** Shift textual sidecar timestamps from file time to a session's stream time. */
export function shiftSubtitleTimeline(text: string, originMs: number): string {
  const shift = (value: string): string => {
    const parts = value.replace(',', '.').split(':');
    const seconds = Number(parts.pop());
    const minutes = Number(parts.pop());
    const hours = parts.length > 0 ? Number(parts.pop()) : 0;
    const ms = Math.max(0, Math.round((hours * 3600 + minutes * 60 + seconds) * 1000) - originMs);
    const h = `${Math.floor(ms / 3600000)}`.padStart(value.split(':').length === 3 ? 2 : 1, '0');
    const m = `${Math.floor(ms / 60000) % 60}`.padStart(2, '0');
    const s = `${Math.floor(ms / 1000) % 60}`.padStart(2, '0');
    const fraction = value.includes(',') ? ',' : '.';
    const digits = value.split(/[.,]/)[1]?.length ?? 3;
    const decimal = `${ms % 1000}`.padStart(3, '0').substring(0, digits);
    return `${h}:${m}:${s}${fraction}${decimal}`;
  };
  return text.split('\n').map((line: string): string => {
    if (line.includes('-->')) {
      return line.replace(/(?:\d+:)?\d{2}:\d{2}[.,]\d{2,3}/g, (time: string): string => shift(time));
    }
    if (line.startsWith('Dialogue:')) {
      const fields = line.split(',');
      if (fields.length >= 3) { fields[1] = shift(fields[1]); fields[2] = shift(fields[2]); }
      return fields.join(',');
    }
    return line;
  }).join('\n');
}

class SrtCue {
  public startMs: number;
  public endMs: number;
  public text: string;
  constructor(startMs: number, endMs: number, text: string) {
    this.startMs = startMs;
    this.endMs = endMs;
    this.text = text;
  }
}

/** `H:MM:SS.cc`（ASS 百分秒时间轴）→ 毫秒；解析失败返回 -1。 */
function parseAssTimeMs(raw: string): number {
  const parts = raw.trim().split(':');
  if (parts.length < 2 || parts.length > 3) { return -1; }
  let seconds = 0;
  for (let i = 0; i < parts.length; i++) {
    const piece = parts[i].trim();
    if (piece.length === 0) { return -1; }
    const value = Number(piece);
    if (isNaN(value)) { return -1; }
    seconds = seconds * 60 + value;
  }
  return Math.round(seconds * 1000);
}

/**
 * 按逗号切成至多 limit 段：前 limit-1 个逗号各切一段，剩余整段（可含逗号）留尾。
 * JS 的 split(sep, limit) 是「截断」而非「留尾」，与 Kotlin split(limit=) 语义不同，故手写。
 */
function splitCsvPrefix(line: string, limit: number): string[] {
  const parts: string[] = [];
  let rest = line;
  while (parts.length < limit - 1) {
    const comma = rest.indexOf(',');
    if (comma < 0) { return parts; }
    parts.push(rest.substring(0, comma));
    rest = rest.substring(comma + 1);
  }
  parts.push(rest);
  return parts;
}

/** 与 Web `plainCueText`、Android SubtitleCues 同口径：剥富文本/ASS 覆盖块，还原实体与换行。 */
function plainAssDialogue(raw: string): string {
  return raw.replace(/\{[^}]*\}/g, '')
    .replace(/<[^>]*>/g, '')
    .replace(/\\N/g, '\n')
    .replace(/\\n/g, '\n')
    .replace(/\\h/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .trim();
}

function srtTime(ms: number): string {
  const h = `${Math.floor(ms / 3600000)}`.padStart(2, '0');
  const m = `${Math.floor(ms / 60000) % 60}`.padStart(2, '0');
  const s = `${Math.floor(ms / 1000) % 60}`.padStart(2, '0');
  const milli = `${ms % 1000}`.padStart(3, '0');
  return `${h}:${m}:${s},${milli}`;
}

/**
 * ASS/SSA [Events] → 纯文本 SRT，样式一律丢弃（iOS/Android 既定口径：字幕文件
 * 自带的样式不要，位置由播放器统一控制）。解析不出 cue 返回空串（调用方按无字幕处理）。
 */
export function assToSrt(text: string): string {
  const cues: SrtCue[] = [];
  let section = '';
  let fields: string[] = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line;
      continue;
    }
    if (section !== '[Events]') { continue; }
    if (line.startsWith('Format:')) {
      fields = line.substring('Format:'.length).split(',').map((field: string): string => field.trim());
      continue;
    }
    if (!line.startsWith('Dialogue:')) { continue; }
    const textIndex = fields.indexOf('Text');
    const startIndex = fields.indexOf('Start');
    const endIndex = fields.indexOf('End');
    if (textIndex < 0 || startIndex < 0 || endIndex < 0) { continue; }
    // 正文里可能有逗号：按 Format 的 Text 列切，只切前 textIndex 个逗号。
    const parts = splitCsvPrefix(line.substring('Dialogue:'.length).trim(), textIndex + 1);
    if (parts.length < textIndex + 1) { continue; }
    const startMs = parseAssTimeMs(parts[startIndex]);
    const endMs = parseAssTimeMs(parts[endIndex]);
    if (startMs < 0 || endMs < 0) { continue; }
    const body = plainAssDialogue(parts[textIndex]);
    if (body.length === 0) { continue; }
    cues.push(new SrtCue(startMs, endMs, body));
  }
  cues.sort((a: SrtCue, b: SrtCue): number => a.startMs - b.startMs);
  return cues.map((cue: SrtCue, index: number): string =>
    `${index + 1}\n${srtTime(cue.startMs)} --> ${srtTime(cue.endMs)}\n${cue.text}`).join('\n\n');
}
