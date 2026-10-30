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
