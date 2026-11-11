import { PlaybackSessionView } from '../api/Models';

/**
 * PGS 旁挂后台下载的完成判定（纯逻辑，主机侧可测）。
 *
 * 起点记下当时的世界：这是第几次预备请求（宿主每次起跑单调 +1，同会话里快切
 * PGS 轨会产生多个并发下载）、第几轮会话（epoch 在 negotiate / dispose 里都会
 * +1）、哪个会话对象、选的是哪条轨。完成时对照现在的世界，分三种结局：
 *
 * - **作废**（退出 / 换集 / 重协商 / 已有更新的预备请求起跑）：连缓存都不进，
 *   文件直接删——旧集的旁挂挂到新集的会话上就是「换集瞬间画面被旧流重开一次」
 *   的事故；旧请求晚完成也一样：只删自己那份，绝不驱逐新请求刚挂上的缓存，更
 *   不能删掉对方正要打开的文件；
 * - **只入缓存**（中途切走了这条轨）：不当场重挂，切回来命中缓存再挂；
 * - **重挂**（什么都没变）：带着旁挂把播放器重挂一次，mpv sub-add 补上字幕。
 */
export class PgsPrepareGuard {
  static readonly outcomeDiscard: string = 'discard';
  static readonly outcomeCache: string = 'cache';
  static readonly outcomeRemount: string = 'remount';

  private readonly seq: number;
  private readonly epoch: number;
  private readonly session: PlaybackSessionView;
  private readonly ref: string;

  constructor(seq: number, epoch: number, session: PlaybackSessionView, ref: string) {
    this.seq = seq;
    this.epoch = epoch;
    this.session = session;
    this.ref = ref;
  }

  /** 下载完成后对照当前状态，给出三种结局之一 */
  outcome(currentSeq: number, currentEpoch: number, disposed: boolean,
    currentSession: PlaybackSessionView | null, subtitleIndex: number): string {
    if (disposed || currentSeq !== this.seq || currentEpoch !== this.epoch
      || currentSession !== this.session) {
      return PgsPrepareGuard.outcomeDiscard;
    }
    if (!PgsPrepareGuard.stillSelected(subtitleIndex, this.ref, this.session)) {
      return PgsPrepareGuard.outcomeCache;
    }
    return PgsPrepareGuard.outcomeRemount;
  }

  /** 这条在途请求是否仍属于当前会话世界（epoch 与会话对象都没换）。防重入登记
   *  簿（PgsPrepareTracker）用它区分「同请求重入（拦住）」与「重协商后旧请求
   *  占位（放行新代次重跑）」——只按 key 防重入时，同文件重开（越出转码窗口、
   *  档位失败重试、重开音画设置）后的再预备会被旧会话的登记拦掉，而旧请求完成
   *  时又因世界已换而作废，从此没人再试，字幕一直缺失。 */
  aliveIn(currentEpoch: number, currentSession: PlaybackSessionView | null): boolean {
    return this.epoch === currentEpoch && currentSession === this.session;
  }

  /** 这条 PGS 还是不是当前选中的轨（下标越界 = 切走 / 关了） */
  static stillSelected(subtitleIndex: number, ref: string, view: PlaybackSessionView): boolean {
    if (subtitleIndex < 0 || subtitleIndex >= view.decision.subtitles.length) {
      return false;
    }
    return view.decision.subtitles[subtitleIndex].track_ref === ref;
  }
}

/**
 * PGS 旁挂预备的在途登记簿（PhonePlaybackHost 的防重入簿记抽成纯类：宿主是
 * struct，进不了测试转译管线，抽出来 node / 真机两侧都能做宿主级测试）。
 *
 * 只按 key（fileId:ref）登记时有两个洞：
 * - **重协商被旧请求占位**：同文件重开（越出转码窗口、档位失败重试、重开音画
 *   设置）后再预备同一条轨，被旧会话留下的在途 key 拦住；旧请求完成时又因
 *   epoch / 会话已换而作废，谁都不会再试——字幕从此缺失。起跑前多对一次账：
 *   在途请求已不属当前世界就放行新代次重跑，旧请求完成自会按自己的代次作废、
 *   只删自己那份文件；
 * - **晚完成误清后来者的登记**：A1→B→A2 时 A1 的收尾只比 key，会把 A2 的登记
 *   清掉，下一次同 key 的预备不再被拦，白重复下载几十 MB。登记以请求为单位：
 *   起跑时登记、收尾时只清自己那笔。
 */
export class PgsPrepareTracker {
  private key: string = '';
  private guard: PgsPrepareGuard | null = null;

  /** 同 key 的在途请求仍属当前会话世界时返回 false（拦住重入）；key 不同、或在
   *  途请求已属旧世界（重协商后注定作废）时放行新代次起跑 */
  canStart(key: string, epoch: number, session: PlaybackSessionView | null): boolean {
    const inFlight: PgsPrepareGuard | null = this.guard;
    if (inFlight !== null && this.key === key && inFlight.aliveIn(epoch, session)) {
      return false;
    }
    return true;
  }

  /** 起跑时登记（新请求覆盖旧请求：换轨 / 换集时旧请求让位） */
  begin(key: string, guard: PgsPrepareGuard): void {
    this.key = key;
    this.guard = guard;
  }

  /** 收尾时只清自己的登记：晚完成的旧请求（A1→B→A2 里的 A1）碰不到后来者 */
  end(guard: PgsPrepareGuard): void {
    if (this.guard === guard) {
      this.key = '';
      this.guard = null;
    }
  }

  /** 退出播放页时整体作废 */
  reset(): void {
    this.key = '';
    this.guard = null;
  }
}
