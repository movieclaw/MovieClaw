import tabBarCollapseTest from './TabBarCollapse.test';
import playerInteractionTest from './PlayerInteraction.test';
import playbackGatewayTest from './PlaybackGateway.test';
import playbackSessionTest from './PlaybackSession.test';
import playbackControllerTest from './PlaybackController.test';
import localUnitTest from './LocalUnit.test';
import savedServersTest from './SavedServers.test';
import pairingCodeTest from './PairingCode.test';
import homeRowsTest from './HomeRows.test';
import staleLoadGuardTest from './StaleLoadGuard.test';
import pgsPrepareGuardTest from './PgsPrepareGuard.test';
import playbackTrackSelectionTest from './PlaybackTrackSelection.test';
import appLanguageTest from './AppLanguage.test';
import chaptersTest from './Chapters.test';
import playerDiagnosticsTest from './PlayerDiagnostics.test';
import harmonyUpgradesTest from './HarmonyUpgrades.test';

export default function testsuite() {
  playerInteractionTest();
  tabBarCollapseTest();
  playbackControllerTest();
  playbackGatewayTest();
  playbackSessionTest();
  localUnitTest();
  savedServersTest();
  pairingCodeTest();
  homeRowsTest();
  staleLoadGuardTest();
  pgsPrepareGuardTest();
  playbackTrackSelectionTest();
  appLanguageTest();
  chaptersTest();
  playerDiagnosticsTest();
  harmonyUpgradesTest();
}
