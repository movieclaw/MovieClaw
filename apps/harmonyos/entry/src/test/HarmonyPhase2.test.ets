import { describe, expect, it } from '@ohos/hypium';
import { PlayRequest, restorableSubtitleIndex, selectedSubtitleTrack, subtitleIndexForRef } from '../main/ets/playback/PlayRequest';
import {
  DownloadLiveSnapshot,
  LiveViewThrottle,
  formatLiveBytes,
  formatLiveCapsuleTitle,
  formatLiveEta,
  formatLivePrimarySubtitle,
  formatLivePrimaryTitle,
  formatLiveSpeed
} from '../main/ets/common/LiveViewModel';
import {
  SmartCachePrefs,
  WatchedEpisodeRecord,
  pickSmartOfflineProfile,
  selectEvictableWatchedFileIds,
  shouldTriggerSmartPrefetch
} from '../main/ets/offline/OfflineSmartCacheModel';
import { LanguageCode, lookupString } from '../main/ets/common/AppLanguage';
import { LocaleEn } from '../main/ets/locales/LocaleEn';
import { LocaleZhHans } from '../main/ets/locales/LocaleZhHans';
import { LocaleZhHant } from '../main/ets/locales/LocaleZhHant';
import { DeviceCapability } from '../main/ets/playback/DeviceCapability';
import { OfflineProfileView, SubtitlePlanView } from '../main/ets/api/Models';

function makeProfile(name: string, bytes: number): OfflineProfileView {
  return { profile: name, label: name, expected_bytes: bytes };
}

function makeSub(ref: string, kind: string): SubtitlePlanView {
  return { track_ref: ref, kind: kind, is_default: false, is_ai: false };
}

export default function harmonyPhase2Test(): void {
  describe('HarmonyPhase2Test', () => {
    it('car_and_tv_share_play_request_and_subtitle_selection_helpers', 0, () => {
      const req: PlayRequest = new PlayRequest(2, 99, 1, 4, 55, 12000, '三体', 'S1E4', 'https://a/p.jpg', true);
      expect(req.libraryId).assertEqual(2);
      expect(req.itemId).assertEqual(99);
      expect(req.autoAdvance).assertTrue();
      expect(DeviceCapability.car('car-01').client).assertEqual('harmony_car');
      expect(DeviceCapability.car('car-01').isMobile).assertFalse();
      expect(selectedSubtitleTrack(false, 'embedded:1')).assertNull();
      expect(selectedSubtitleTrack(true, '')).assertEqual('off');
      const plans: SubtitlePlanView[] = [makeSub('embedded:1', 'ass'), makeSub('embedded:2', 'pgs')];
      expect(subtitleIndexForRef(plans, 'embedded:2')).assertEqual(1);
      expect(restorableSubtitleIndex(plans, ['/s1', '/s2'], 'embedded:1', '')).assertEqual(0);
      expect(restorableSubtitleIndex(plans, ['/s1', '/s2'], 'embedded:2', '')).assertEqual(-1);
    });

    it('formats_live_view_download_capsule_and_card_copy', 0, () => {
      const snap: DownloadLiveSnapshot = new DownloadLiveSnapshot(
        '沙丘2', 'S1E3', 524288000, 1048576000, 20971520, 2, false);
      expect(snap.progressPercent()).assertEqual(50);
      expect(formatLiveBytes(1536)).assertEqual('1.5 KB');
      expect(formatLiveSpeed(20971520)).assertEqual('20.0 MB/s');
      expect(formatLiveEta(524288000, 20971520)).assertEqual('剩 25 秒');
      expect(formatLiveCapsuleTitle(snap)).assertEqual('50% · 20.0 MB/s');
      expect(formatLivePrimaryTitle(snap)).assertEqual('正在缓存 · 沙丘2 · S1E3');
      const sub: string = formatLivePrimarySubtitle(snap);
      expect(sub.includes('500 MB / 1000 MB')).assertTrue();
      expect(sub.includes('队列还有 2 项')).assertTrue();

      const doneSnap: DownloadLiveSnapshot = new DownloadLiveSnapshot(
        '沙丘2', '', 1048576000, 1048576000, 0, 0, true);
      expect(doneSnap.progressPercent()).assertEqual(100);
      expect(formatLiveCapsuleTitle(doneSnap)).assertEqual('缓存完成');
      expect(formatLivePrimaryTitle(doneSnap)).assertEqual('已完成 · 沙丘2');
    });

    it('throttles_live_view_ipc_updates_by_time_and_percent_jump', 0, () => {
      const throttle: LiveViewThrottle = new LiveViewThrottle(1200, 2);
      expect(throttle.shouldEmit(1000, 1, false)).assertTrue();
      // Within 1200ms and <2% delta -> suppressed
      expect(throttle.shouldEmit(1500, 2, true)).assertFalse();
      // >=2% delta -> emitted immediately
      expect(throttle.shouldEmit(1600, 4, true)).assertTrue();
      // >=1200ms elapsed even with 0% delta -> emitted
      expect(throttle.shouldEmit(2900, 4, true)).assertTrue();
      // Force always emits
      expect(throttle.shouldEmit(2950, 4, true, true)).assertTrue();
    });

    it('triggers_wifi_smart_prefetch_only_past_40_percent_on_wifi', 0, () => {
      const prefs: SmartCachePrefs = new SmartCachePrefs();
      expect(shouldTriggerSmartPrefetch(prefs, true, 500000, 1000000, 88, false)).assertFalse();
      prefs.wifiPrefetchNext = true;
      // Cellular blocked
      expect(shouldTriggerSmartPrefetch(prefs, false, 500000, 1000000, 88, false)).assertFalse();
      // Below 40% blocked
      expect(shouldTriggerSmartPrefetch(prefs, true, 390000, 1000000, 88, false)).assertFalse();
      // Already cached blocked
      expect(shouldTriggerSmartPrefetch(prefs, true, 500000, 1000000, 88, true)).assertFalse();
      // Past 40% on Wi-Fi with uncached next file -> trigger
      expect(shouldTriggerSmartPrefetch(prefs, true, 410000, 1000000, 88, false)).assertTrue();
    });

    it('picks_smart_offline_profile_and_evicts_oldest_watched_episodes', 0, () => {
      const profiles: OfflineProfileView[] = [makeProfile('original', 5000), makeProfile('720p', 1200)];
      const picked: OfflineProfileView | null = pickSmartOfflineProfile(profiles, '1080p');
      expect(picked !== null).assertTrue();
      expect(picked?.profile).assertEqual('720p');

      const prefs: SmartCachePrefs = new SmartCachePrefs();
      prefs.autoEvictWatched = true;
      prefs.keepWatchedCount = 1;
      const records: WatchedEpisodeRecord[] = [
        new WatchedEpisodeRecord(101, 5, 1, 1000),
        new WatchedEpisodeRecord(102, 5, 2, 2000),
        new WatchedEpisodeRecord(103, 5, 3, 3000),
        // Currently playing file must never be evicted
        new WatchedEpisodeRecord(104, 5, 4, 4000)
      ];
      const evict: number[] = selectEvictableWatchedFileIds(prefs, records, 104);
      expect(evict.length).assertEqual(2);
      expect(evict[0]).assertEqual(102);
      expect(evict[1]).assertEqual(101);
    });

    it('keeps_all_three_locale_tables_key_synchronized', 0, () => {
      const zhKeys: string[] = Object.keys(LocaleZhHans.table).sort();
      const hantKeys: string[] = Object.keys(LocaleZhHant.table).sort();
      const enKeys: string[] = Object.keys(LocaleEn.table).sort();
      expect(zhKeys.length).assertEqual(hantKeys.length);
      expect(zhKeys.length).assertEqual(enKeys.length);
      for (let i: number = 0; i < zhKeys.length; i++) {
        expect(hantKeys[i]).assertEqual(zhKeys[i]);
        expect(enKeys[i]).assertEqual(zhKeys[i]);
      }
      expect(lookupString(LanguageCode.en, 'tabs.library')).assertEqual('Library');
      expect(lookupString(LanguageCode.zhHant, 'tv.tab.reels')).assertEqual('放映廳');
      expect(lookupString(LanguageCode.en, 'offline.smart_title')).assertEqual('Smart Binge Cache');
    });
  });
}
