import { describe, it, expect } from '@ohos/hypium';
import { PlaybackSessionView, SubtitlePlanView } from '../main/ets/api/Models';
import { PgsPrepareGuard } from '../main/ets/playback/PgsPrepareGuard';

/**
 * PGS 旁挂后台下载的完成判定（review #3 的核心矩阵）。
 *
 * 下载完成只查「备的键 + epoch + 会话对象 + 选中轨」还不够——逐项对照才分得清
 * 三种结局：作废（退出 / 换集 / 重协商，连缓存都不进）、只入缓存（中途切走了
 * 这条轨）、重挂（什么都没变，带着旁挂把播放器重挂一次）。
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
      const guard: PgsPrepareGuard = new PgsPrepareGuard('file-key', 7, session, 'pgs:2');
      expect(guard.outcome('file-key', 7, false, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeRemount);
    });

    it('discard_退出_换集_重协商_连缓存都不进', 0, () => {
      const session: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2']);
      const guard: PgsPrepareGuard = new PgsPrepareGuard('file-key', 7, session, 'pgs:2');
      // 退出播放页
      expect(guard.outcome('file-key', 7, true, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
      // negotiate / dispose 把 epoch +1（换集、重新协商）
      expect(guard.outcome('file-key', 8, false, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
      // 换集后拿到的是另一份会话对象（内容可能一样，身份必须不同）
      const reopened: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2']);
      expect(guard.outcome('file-key', 7, false, reopened, 1))
        .assertEqual(PgsPrepareGuard.outcomeDiscard);
    });

    it('cache_中途切轨_关字幕_换了在备的键_只入缓存不当场重挂', 0, () => {
      const session: PlaybackSessionView = makeSession(['embedded:1', 'pgs:2']);
      const guard: PgsPrepareGuard = new PgsPrepareGuard('file-key', 7, session, 'pgs:2');
      // 中途切到内封轨
      expect(guard.outcome('file-key', 7, false, session, 0))
        .assertEqual(PgsPrepareGuard.outcomeCache);
      // 关掉字幕
      expect(guard.outcome('file-key', 7, false, session, -1))
        .assertEqual(PgsPrepareGuard.outcomeCache);
      // 下标越界（旧下标已无意义）
      expect(guard.outcome('file-key', 7, false, session, 2))
        .assertEqual(PgsPrepareGuard.outcomeCache);
      // 又开始备另一条 PGS（在备的键换了）
      expect(guard.outcome('other-key', 7, false, session, 1))
        .assertEqual(PgsPrepareGuard.outcomeCache);
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
