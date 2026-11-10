import { describe, it, expect } from '@ohos/hypium';
import { PlaybackSessionView, SubtitlePlanView } from '../main/ets/api/Models';
import { PgsPrepareGuard } from '../main/ets/playback/PgsPrepareGuard';

/**
 * PGS 旁挂后台下载的完成判定矩阵（含同会话快切 PGS 轨的并发预载）。
 *
 * 下载完成只查「epoch + 会话对象 + 选中轨」还不够——同会话里快速连切 PGS 轨
 * 会有多个下载并发在飞：起跑时记下自己的请求代次（宿主每次起跑单调 +1），
 * 完成时对照当前代次。旧代次无论先完成还是后完成一律作废、只删自己那份文
 * 件，绝不驱逐新请求刚挂上的缓存；「中途切走这条轨」（没有更新的请求起跑）
 * 才只入缓存，切回来命中缓存再挂。
 */

function makeSubtitle(ref: string, kind: string): SubtitlePlanView {
  return { track_ref: ref, kind: kind, is_default: false, is_ai: false };
}

function makeSession(refs: string[]): PlaybackSessionView {
  const subtitles: SubtitlePlanView[] =
    refs.map((ref: string): SubtitlePlanView => makeSubtitle(ref, 'pgs'));
  return {
    decision: { outcome: 'plan', audio_tracks: [], subtitles: subtitles, reason: '' },
    progressive_segments: false,
    start_ms: 0,
    timeline: 'source',
    subtitle_urls: [],
    chapters: []
  };
}

export default function pgsPrepareGuardTest() {
  describe('PgsPrepareGuard', () => {
    it('remount_什么都没变_带着旁挂重挂播放器', 0, () => {
      const session: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2']);
      const guard: PgsPrepareGuard = new PgsPrepareGuard(5, 7, session, 'pgs:2');
      expect(guard.outcome(5, 7, false, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeRemount);
    });

    it('discard_退出_换集_重协商_连缓存都不进', 0, () => {
      const session: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2']);
      const guard: PgsPrepareGuard = new PgsPrepareGuard(5, 7, session, 'pgs:2');
      // 退出播放页
      expect(guard.outcome(5, 7, true, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
      // negotiate / dispose 把 epoch +1（换集、重新协商）
      expect(guard.outcome(5, 8, false, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
      // 换集后拿到的是另一份会话对象（内容可能一样，身份必须不同）
      const reopened: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2']);
      expect(guard.outcome(5, 7, false, reopened, 1))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
    });

    it('cache_中途切轨_关字幕_只入缓存不当场重挂', 0, () => {
      const session: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2']);
      const guard: PgsPrepareGuard = new PgsPrepareGuard(5, 7, session, 'pgs:2');
      // 中途切到内封轨（没有更新的预备请求，代次没变）
      expect(guard.outcome(5, 7, false, session, 0))
        .assertEqual(PgsPrepareGuard.outcomeCache);
      // 关掉字幕
      expect(guard.outcome(5, 7, false, session, -1))
        .assertEqual(PgsPrepareGuard.outcomeCache);
      // 下标越界（旧下标已无意义）
      expect(guard.outcome(5, 7, false, session, 2))
        .assertEqual(PgsPrepareGuard.outcomeCache);
    });

    it('discard_更新的预备请求已起跑_旧请求无论何时完成_只删自己那份', 0, () => {
      const session: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2', 'pgs:3']);
      // A（pgs:2，代次 1）还在下载，用户快切到 B（pgs:3，代次 2）：B 起跑那一刻起
      // A 就注定作废——先完成、后完成都一样，不许驱逐 B 的缓存文件
      const guardA: PgsPrepareGuard = new PgsPrepareGuard(1, 7, session, 'pgs:2');
      const guardB: PgsPrepareGuard = new PgsPrepareGuard(2, 7, session, 'pgs:3');
      expect(guardA.outcome(2, 7, false, session, 2))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
      // B 自己完成：是最新代次且还选中 → 重挂
      expect(guardB.outcome(2, 7, false, session, 2))
        .assertEqual(PgsPrepareGuard.outcomeRemount);
    });

    it('discard_A到B再到A_旧代次全作废_只有最新代次能重挂', 0, () => {
      const session: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2', 'pgs:3']);
      const guardA1: PgsPrepareGuard = new PgsPrepareGuard(1, 7, session, 'pgs:2');
      const guardB: PgsPrepareGuard = new PgsPrepareGuard(2, 7, session, 'pgs:3');
      const guardA2: PgsPrepareGuard = new PgsPrepareGuard(3, 7, session, 'pgs:2');
      // 用户切回 A：当前代次 3，前两轮请求无论何时完成都是旧代次 → 作废
      expect(guardA1.outcome(3, 7, false, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
      expect(guardB.outcome(3, 7, false, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
      // 最新一轮 A 完成：还选中 → 重挂
      expect(guardA2.outcome(3, 7, false, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeRemount);
    });

    it('stillSelected_下标在界内且轨引用一致才算还选中', 0, () => {
      const session: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2']);
      expect(PgsPrepareGuard.stillSelected(1, 'pgs:2', session)).assertTrue();
      expect(PgsPrepareGuard.stillSelected(0, 'embedded:1', session)).assertTrue();
      // 同一下标但轨不匹配（服务端新决策换了轨序）
      expect(PgsPrepareGuard.stillSelected(0, 'pgs:2', session)).assertFalse();
      expect(PgsPrepareGuard.stillSelected(-1, 'pgs:2', session)).assertFalse();
      expect(PgsPrepareGuard.stillSelected(2, 'pgs:2', session)).assertFalse();
    });
  });
}
