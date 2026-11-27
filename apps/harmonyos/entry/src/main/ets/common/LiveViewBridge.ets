import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { liveViewManager } from '@kit.LiveViewKit';
import {
  DownloadLiveSnapshot,
  LiveViewThrottle,
  formatLiveCapsuleTitle,
  formatLivePrimarySubtitle,
  formatLivePrimaryTitle
} from './LiveViewModel';

const DOWNLOAD_LIVE_ID: number = 1001;

/**
 * 鸿蒙 NEXT 实况窗桥接（`@kit.LiveViewKit`）：
 * 离线缓存下载期间把片名、实时进度条、网速与剩余时间推送到锁屏、通知栏与灵动胶囊，
 * 点按直达「离线存储」页；在未开通实况窗或模拟器环境自动静默降级、零崩溃。
 */
export class LiveViewBridge {
  static readonly shared: LiveViewBridge = new LiveViewBridge();

  private active: boolean = false;
  private sequence: number = 0;
  private enabledChecked: boolean = false;
  private liveEnabled: boolean = false;
  private readonly throttle: LiveViewThrottle = new LiveViewThrottle(1200, 2);

  private constructor() {
  }

  async syncDownload(context: common.UIAbilityContext | null, snap: DownloadLiveSnapshot,
    force: boolean = false): Promise<void> {
    if (context === null) {
      return;
    }
    const pct: number = snap.progressPercent();
    if (!this.throttle.shouldEmit(Date.now(), pct, this.active, force || snap.done)) {
      return;
    }
    if (!(await this.ensureEnabled())) {
      return;
    }
    try {
      const clickAction: WantAgent = await this.buildOfflineWantAgent(context);
      const view: liveViewManager.LiveView = this.buildDownloadView(snap, clickAction);
      if (!this.active) {
        await liveViewManager.startLiveView(view);
        this.active = true;
      } else {
        await liveViewManager.updateLiveView(view);
      }
    } catch (_err) {
      // 未签发实况窗权益或模拟器不支持时静默跳过
      this.active = false;
    }
  }

  async stopDownload(context: common.UIAbilityContext | null, finalSnap?: DownloadLiveSnapshot): Promise<void> {
    if (!this.active) {
      this.throttle.reset();
      return;
    }
    this.active = false;
    this.throttle.reset();
    if (context === null) {
      return;
    }
    try {
      const clickAction: WantAgent = await this.buildOfflineWantAgent(context);
      const snap: DownloadLiveSnapshot = finalSnap ?? new DownloadLiveSnapshot('MovieClaw', '', 1, 1, 0, 0, true);
      const view: liveViewManager.LiveView = this.buildDownloadView(snap, clickAction);
      await liveViewManager.stopLiveView(view);
    } catch (_err) {
    }
  }

  private async ensureEnabled(): Promise<boolean> {
    if (this.enabledChecked) {
      return this.liveEnabled;
    }
    this.enabledChecked = true;
    try {
      this.liveEnabled = await liveViewManager.isLiveViewEnabled();
    } catch (_err) {
      this.liveEnabled = false;
    }
    return this.liveEnabled;
  }

  private async buildOfflineWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    return wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
        parameters: {
          'mcContinueKind': 'offline_storage'
        }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: DOWNLOAD_LIVE_ID,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  private buildDownloadView(snap: DownloadLiveSnapshot, clickAction: WantAgent): liveViewManager.LiveView {
    this.sequence += 1;
    const progress: number = snap.progressPercent();
    const layoutData: liveViewManager.ProgressLayout = {
      layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
      progress: progress,
      color: '#FFF5C451',
      backgroundColor: '#FF2B3345',
      indicatorType: liveViewManager.IndicatorType.INDICATOR_TYPE_UP,
      indicatorIcon: 'live_icon.png',
      lineType: liveViewManager.LineType.LINE_TYPE_NORMAL_SOLID_LINE,
      nodeIcons: ['live_icon.png', 'live_icon.png']
    };
    const capsule: liveViewManager.TextCapsule = {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
      status: 1,
      icon: 'live_icon.png',
      backgroundColor: '#FF1B2436',
      title: formatLiveCapsuleTitle(snap)
    };
    const view: liveViewManager.LiveView = {
      id: DOWNLOAD_LIVE_ID,
      event: 'DELIVERY',
      sequence: this.sequence,
      liveViewData: {
        primary: {
          title: formatLivePrimaryTitle(snap),
          content: [{
            text: formatLivePrimarySubtitle(snap),
            textColor: '#FFD6DCE8'
          }],
          keepTime: snap.done ? 60 : 900,
          clickAction: clickAction,
          layoutData: layoutData
        },
        capsule: capsule
      }
    };
    return view;
  }
}
