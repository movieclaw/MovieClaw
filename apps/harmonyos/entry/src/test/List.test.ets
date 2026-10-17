import localUnitTest from './LocalUnit.test';
import savedServersTest from './SavedServers.test';
import pairingCodeTest from './PairingCode.test';

export default function testsuite() {
  localUnitTest();
  savedServersTest();
  pairingCodeTest();
}
