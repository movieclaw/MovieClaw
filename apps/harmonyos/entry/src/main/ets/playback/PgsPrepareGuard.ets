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

  /** 这条 PGS 还是不是当前选中的轨（下标越界 = 切走 / 关了） */
  static stillSelected(subtitleIndex: number, ref: string, view: PlaybackSessionView): boolean {
    if (subtitleIndex < 0 || subtitleIndex >= view.decision.subtitles.length) {
      return false;
    }
    return view.decision.subtitles[subtitleIndex].track_ref === ref;
  }
}
