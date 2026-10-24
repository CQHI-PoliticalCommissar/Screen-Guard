import { TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
import { localUnitTest } from '../test/LocalUnit.test';

export default class LocalUnitTestRunner extends TestRunner {
  public onCreate() {
    Hypium.hypiumTest(this.abilityDelegator, this.arguments, localUnitTest);
  }
}