/**
 * 系统通知的差分基线（照 Android `NotifySnapshot`）。
 *
 * 服务器没有面向成员的通用事件流（只有 agent / jobs / search 三条 SSE，也没有 APNs
 * 那样的推送通道），系统通知走「本机轮询 → 与上一次快照差分」：只在状态真的翻转时
 * 发本地通知；首次运行只落基线、不轰炸。
 *
 * 基线四段用 `|` 分隔、段内用 `,`：
 * `下载 id:状态,…|作业 id:状态,…|今日 订阅:季:集,…|入库 订阅:季:集,…`
 * （四段固定顺序：下载任务 / 后台作业 / 今日有可看的 / 最近入库；空段允许）
 */
export class NotifySnapshotState {
  /** 下载任务：前端键 → state（completed / error / missing / …） */
  downloads: Map<string, string> = new Map<string, string>();
  /** 后台作业：作业 id → status（failed / blocked / …） */
  jobs: Map<string, string> = new Map<string, string>();
  /** 今日有可看的：`订阅id:季:集` */
  arrivals: Set<string> = new Set<string>();
  /** 最近入库：`订阅id:季:集` */
  recent: Set<string> = new Set<string>();
}

export class NotifySnapshot {
  /** 四段编码（顺序与 decode 对齐：下载 | 作业 | 今日 | 入库） */
  static encode(state: NotifySnapshotState): string {
    const parts: string[] = [
      NotifySnapshot.joinPairs(state.downloads),
      NotifySnapshot.joinPairs(state.jobs),
      NotifySnapshot.joinSet(state.arrivals),
      NotifySnapshot.joinSet(state.recent)
    ];
    return parts.join('|');
  }

  static decode(raw: string): NotifySnapshotState {
    const state: NotifySnapshotState = new NotifySnapshotState();
    if (raw.length === 0) {
      return state;
    }
    const parts: string[] = raw.split('|');
    state.downloads = NotifySnapshot.splitPairs(parts.length > 0 ? parts[0] : '');
    state.jobs = NotifySnapshot.splitPairs(parts.length > 1 ? parts[1] : '');
    state.arrivals = NotifySnapshot.splitSet(parts.length > 2 ? parts[2] : '');
    state.recent = NotifySnapshot.splitSet(parts.length > 3 ? parts[3] : '');
    return state;
  }

  private static joinPairs(map: Map<string, string>): string {
    const out: string[] = [];
    map.forEach((value: string, key: string): void => {
      out.push(`${key}:${value}`);
    });
    return out.join(',');
  }

  private static joinSet(set: Set<string>): string {
    const out: string[] = [];
    set.forEach((key: string): void => {
      out.push(key);
    });
    return out.join(',');
  }

  private static splitPairs(raw: string): Map<string, string> {
    const map: Map<string, string> = new Map<string, string>();
    if (raw.length === 0) {
      return map;
    }
    const items: string[] = raw.split(',');
    for (const item of items) {
      if (item.length === 0) {
        continue;
      }
      const index: number = item.lastIndexOf(':');
      if (index <= 0) {
        continue;
      }
      map.set(item.substring(0, index), item.substring(index + 1));
    }
    return map;
  }

  private static splitSet(raw: string): Set<string> {
    const set: Set<string> = new Set<string>();
    if (raw.length === 0) {
      return set;
    }
    const items: string[] = raw.split(',');
    for (const item of items) {
      if (item.length > 0) {
        set.add(item);
      }
    }
    return set;
  }
}
