import tabBarCollapseTest from '../../../test/TabBarCollapse.test';
import appTabsE2E from './AppTabs.e2e.test';
import playerInteractionTest from '../../../test/PlayerInteraction.test';
import playbackGatewayTest from '../../../test/PlaybackGateway.test';
import playbackControllerTest from '../../../test/PlaybackController.test';
import playbackSessionTest from '../../../test/PlaybackSession.test';
import playbackE2ETest from './Playback.e2e.test';
import abilityTest from './Ability.test';

export default function testsuite() {
  playerInteractionTest();
  tabBarCollapseTest();
  abilityTest();
  playbackControllerTest();
  playbackGatewayTest();
  playbackSessionTest();
  playbackE2ETest();
  appTabsE2E();
}