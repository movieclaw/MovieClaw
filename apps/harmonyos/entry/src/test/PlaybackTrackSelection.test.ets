import { describe, it, expect } from '@ohos/hypium';
import { SubtitlePlanView } from '../main/ets/api/Models';
import {
  restorableSubtitleIndex,
  selectedSubtitleTrack,
  subtitleIndexForRef
} from '../main/ets/common/AvPlayerEngine';

function subtitle(ref: string, kind: string): SubtitlePlanView {
  return { track_ref: ref, kind: kind, is_default: false, is_ai: false };
}

export default function playbackTrackSelectionTest() {
  describe('PlaybackTrackSelection', () => {
    it('only_sends_an_explicit_subtitle_choice', 0, () => {
      expect(selectedSubtitleTrack(false, 'embedded:2') === null).assertTrue();
      expect(selectedSubtitleTrack(true, 'embedded:2')).assertEqual('embedded:2');
      expect(selectedSubtitleTrack(true, 'off')).assertEqual('off');
    });
    it('audio_switch_restores_text_subtitle_by_ref_on_the_new_player', 0, () => {
      const plans: SubtitlePlanView[] = [subtitle('external:other', 'vtt'), subtitle('embedded:2', 'ass')];
      expect(restorableSubtitleIndex(plans, ['/other', '/audio-sub'], 'embedded:2', '')).assertEqual(1);
    });
    it('quality_switch_restores_text_subtitle_after_decision_reorders_tracks', 0, () => {
      const plans: SubtitlePlanView[] = [subtitle('embedded:2', 'vtt'), subtitle('external:other', 'vtt')];
      expect(restorableSubtitleIndex(plans, ['/quality-sub', '/other'], 'embedded:2', '')).assertEqual(0);
    });
    it('session_404_reconnect_restores_text_subtitle_on_the_replacement_player', 0, () => {
      const plans: SubtitlePlanView[] = [subtitle('embedded:0', 'vtt'), subtitle('embedded:2', 'ass')];
      expect(restorableSubtitleIndex(plans, ['/first', '/reconnected-sub'], 'embedded:2', '')).assertEqual(1);
    });
    it('tier_fallback_restores_text_subtitle_from_the_downgraded_decision', 0, () => {
      const plans: SubtitlePlanView[] = [subtitle('embedded:2', 'vtt')];
      expect(restorableSubtitleIndex(plans, ['/fallback-sub'], 'embedded:2', '')).assertEqual(0);
    });
    it('burned_pgs_keeps_the_selected_ref_but_is_not_attached_as_a_sidecar', 0, () => {
      const plans: SubtitlePlanView[] = [subtitle('external:text', 'vtt'), subtitle('embedded:5', 'pgs')];
      expect(subtitleIndexForRef(plans, 'embedded:5')).assertEqual(1);
      expect(restorableSubtitleIndex(plans, ['/text', '/pgs'], 'embedded:5', 'embedded:5')).assertEqual(-1);
    });
  });
}
