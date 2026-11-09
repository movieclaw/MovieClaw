import { describe, it, expect } from '@ohos/hypium';
import { selectedSubtitleTrack } from '../main/ets/common/AvPlayerEngine';

export default function playbackTrackSelectionTest() {
  describe('PlaybackTrackSelection', () => {
    it('only_sends_an_explicit_subtitle_choice', 0, () => {
      expect(selectedSubtitleTrack(false, 'embedded:2') === null).assertTrue();
      expect(selectedSubtitleTrack(true, 'embedded:2')).assertEqual('embedded:2');
      expect(selectedSubtitleTrack(true, 'off')).assertEqual('off');
    });
  });
}
