import { describe, it, expect } from '@ohos/hypium';
import { PlaybackController } from '@movieclaw/playback';
import { PhonePlaybackHost, PlayerPhase } from '../main/ets/playback/PhonePlaybackHost';

class RateController extends PlaybackController {
  rates: number[] = [];
  async setRate(rate: number): Promise<void> { this.rates.push(rate); }
}
export default function playerInteractionTest() {
  describe('PlayerInteraction', () => {
    it('single_tap_keeps_paused_controls_visible_without_resuming', 0, () => {
      const host = new PhonePlaybackHost(); host.phase = PlayerPhase.ready;
      host.playing = false; host.chromeVisible = true; host.pausedIntent = true;
      host.handleTap(0.5);
      expect(host.chromeVisible).assertTrue(); expect(host.pausedIntent).assertTrue();
      expect(host.playing).assertFalse();
    });
    it('outside_tap_only_dismisses_menu', 0, () => {
      const host = new PhonePlaybackHost(); host.phase = PlayerPhase.ready;
      host.toggleMenu('audio'); host.handleTap(0.5);
      expect(host.showSheet).assertFalse(); expect(host.chromeVisible).assertTrue();
      expect(host.playing).assertFalse();
    });
    it('same_menu_toggles_and_another_menu_replaces_it', 0, () => {
      const host = new PhonePlaybackHost(); host.toggleMenu('audio'); host.toggleMenu('subtitle');
      expect(host.showSheet).assertTrue(); expect(host.sheetKind).assertEqual('subtitle');
      host.toggleMenu('subtitle'); expect(host.showSheet).assertFalse();
    });
    it('more_button_closes_its_open_submenu', 0, () => {
      const host = new PhonePlaybackHost(); host.toggleMenu('settings'); host.sheetKind = 'speed';
      host.toggleMenu('settings'); expect(host.showSheet).assertFalse();
      host.toggleMenu('audio'); host.toggleMenu('settings');
      expect(host.showSheet).assertTrue(); expect(host.sheetKind).assertEqual('settings');
    });
    it('menu_uses_measured_space_between_top_bar_and_buttons', 0, () => {
      const host = new PhonePlaybackHost(); host.layerHeight = 400; host.layerOriginY = 20;
      host.chromeTopY = [20, 92]; host.menuAnchorTop = 280;
      expect(host.menuHeight()).assertEqual(188); expect(host.menuAnchorY()).assertEqual(280);
      host.menuAnchorTop = 800; expect(host.menuHeight()).assertEqual(460);
    });
    it('locked_surface_does_not_reveal_transport_and_back_unlocks', 0, () => {
      const host = new PhonePlaybackHost(); host.toggleControlLock(); host.handleTap(0.5);
      expect(host.chromeVisible).assertFalse(); expect(host.controlsLocked).assertTrue();
      expect(host.handleBack()).assertTrue(); expect(host.controlsLocked).assertFalse();
      expect(host.chromeVisible).assertTrue();
    });
    it('back_dismisses_menu_before_leaving_player', 0, () => {
      const host = new PhonePlaybackHost(); host.toggleMenu('settings');
      expect(host.handleBack()).assertTrue(); expect(host.showSheet).assertFalse();
      expect(host.handleBack()).assertFalse();
    });
    it('display_modes_preserve_ratio_except_explicit_stretch', 0, () => {
      const host = new PhonePlaybackHost(); host.layerWidth = 800; host.layerHeight = 400; host.videoAspect = 16 / 9;
      expect(host.surfaceHeight()).assertEqual(400);
      expect(Math.round(host.surfaceWidth())).assertEqual(711);
      host.displayMode = 'fill'; expect(host.surfaceWidth()).assertEqual(800);
      expect(host.surfaceHeight()).assertEqual(450);
      host.displayMode = 'stretch'; expect(host.surfaceHeight()).assertEqual(400);
      expect(host.surfaceWidth()).assertEqual(800);
    });
    it('hold_restores_user_selected_rate', 0, () => {
      const host = new PhonePlaybackHost(); const controller = new RateController(); host.controller = controller;
      host.selectRate(1.5); host.phase = PlayerPhase.ready; host.playing = true;
      expect(host.beginHoldSpeed()).assertTrue(); host.endHoldSpeed();
      expect(controller.rates.join(',')).assertEqual('1.5,2,1.5');
      host.playing = false; expect(host.beginHoldSpeed()).assertFalse();
    });
  });
}
