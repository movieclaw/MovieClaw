import { http } from '@kit.NetworkKit';

/**
 * 网络测速（对齐 iOS `NetBench.swift`）：
 * 1. RTT：对 `GET /api/v1/health` 连测 3 次取最小往返毫秒；
 * 2. 吞吐：对当前播放流地址限时拉流，按窗口收包字节折算 Mbit/s。
 */
export class NetBenchResult {
  rttMs: number = -1;
  bytes: number = 0;
  seconds: number = 0;
  error: string = '';

  lines(): string[] {
    const out: string[] = [];
    out.push(this.rttMs >= 0 ? `往返延迟：${this.rttMs} ms` : '往返延迟：测不通');
    if (this.bytes > 0 && this.seconds > 0) {
      out.push(`下载：${this.seconds.toFixed(1)} 秒收到 ${Math.round(this.bytes / 1048576)} MB · ${NetBench.mbpsOf(this.bytes, this.seconds * 1000)} Mbit/s`);
    } else if (this.error.length > 0) {
      out.push(this.error);
    }
    return out;
  }

  get failed(): boolean {
    return this.bytes <= 0;
  }
}

export class NetBench {
  /** 纯计算：bytes 字节耗时 ms 毫秒 → Mbit/s（保留 1 位小数） */
  static mbpsOf(bytes: number, ms: number): number {
    if (bytes <= 0 || ms <= 0) {
      return 0;
    }
    return Math.round(bytes * 8 / (ms / 1000) / 1000000 * 10) / 10;
  }

  static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  static async rttOf(origin: string, token: string): Promise<number> {
    let best: number = -1;
    for (let i = 0; i < 3; i++) {
      const client = http.createHttp();
      try {
        const header: Record<string, string> = { 'Accept': 'application/json' };
        if (token.length > 0) {
          header['Authorization'] = `Bearer ${token}`;
        }
        const started: number = Date.now();
        await client.request(`${origin}/api/v1/health`, {
          method: http.RequestMethod.GET,
          header: header,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 5000,
          readTimeout: 5000
        });
        const cost: number = Date.now() - started;
        if (best < 0 || cost < best) {
          best = cost;
        }
      } catch (_error) {
        // 单次失败继续下一轮
      } finally {
        client.destroy();
      }
    }
    return best;
  }

  static async throughputOf(url: string, token: string, windowMs: number): Promise<NetBenchResult> {
    const result: NetBenchResult = new NetBenchResult();
    if (url.length === 0) {
      result.error = '本机副本播放不经过服务器，无需测速';
      return result;
    }
    const client = http.createHttp();
    let totalBytes: number = 0;
    let streamFailed: boolean = false;
    try {
      const header: Record<string, string> = { 'Range': 'bytes=0-' };
      if (token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      client.on('dataReceiveProgress', (data: http.DataReceiveProgressInfo) => {
        totalBytes = data.receiveSize;
      });
      const started: number = Date.now();
      const streamDone: Promise<void> = client.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 5000,
        readTimeout: windowMs + 2000
      }).then((): void => {
      }).catch((): void => {
        streamFailed = true;
      });
      await Promise.race([NetBench.sleep(windowMs), streamDone]);
      result.bytes = Math.max(0, totalBytes);
      result.seconds = Math.max(0.1, (Date.now() - started) / 1000);
      if (result.bytes <= 0) {
        result.error = streamFailed ? '下载测速失败（网络或服务器不可达）' : '服务器没有返回数据，测不出吞吐';
      }
    } catch (_error) {
      result.error = '下载测速失败（网络或服务器不可达）';
    } finally {
      client.off('dataReceiveProgress');
      client.destroy();
    }
    return result;
  }

  static async run(origin: string, token: string, streamUrl: string, windowMs: number): Promise<NetBenchResult> {
    const result: NetBenchResult = await NetBench.throughputOf(streamUrl, token, windowMs);
    result.rttMs = origin.length > 0 ? await NetBench.rttOf(origin, token) : -1;
    return result;
  }
}
