import { Theme } from '../theme/AppTheme';
import { SettingsSwitchRow } from '../common/SettingsControls';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { PlaybackPolicyPayload, PlaybackPolicyView, ReelClipProgressView, ReelClipStatsView } from '../api/Models';
import { Formatters } from '../common/Formatters';
import { AppFooter } from '../common/AppFooter';

/** `PlaybackPolicyPayload` 全可选，用类绕开 `arkts-no-untyped-obj-literals` */
class PolicyBody implements PlaybackPolicyPayload {
  software_transcode_enabled?: boolean | null;
  trickplay_enabled?: boolean | null;
  transcode_cache_enabled?: boolean | null;
  reel_clips_enabled?: boolean | null;
}

/**
 * 设置 → 播放（对应 iOS `PlaybackSettingsView` / Web `settings-view` 的 `PlaybackSection`）。
 *
 * iOS 这一页有三块：进度条预览、转码缓存（两颗开关**改即存**、失败回滚）、远程转码。
 * 本轮做前两块（它们共用一个策略接口），并把硬件转码的**探测结论**一并显示出来：
 *
 * - **软件转码**：没有硬件加速时兜底用 CPU 转（很吃 CPU，默认建议关）；
 * - **进度条预览**：拖动时显示缩略图预览，要预先生成，占磁盘；
 * - **转码缓存**：把转好的片段缓存下来，回看同一段不用重转，占磁盘；
 * - **硬件加速**：显示服务端探测到的结论与可用后端（这是**事实**，不是开关）。
 *
 * **三颗开关都是「改即存」**（乐观更新、失败回滚），没有保存按钮——同 iOS。
 *
 * **没做**：远程转码 worker。它的端点是 `/transcode-worker/config` 与 `/transcode-worker/status`，
 * **这两个端点没有被生成进鸿蒙的 API 客户端**（`Endpoints.ets` 里只有 9 处 `transcode`，
 * 都是别的东西），所以不是「没来得及做」，而是**要先补生成器或手写端点**才能做。
 * 另外「意图（开关）与现实（Worker 是否在线）要分开说」这条 iOS 的设计要点，也一并留到那时。
 */
@ComponentV2
export struct PlaybackSection {
  @Local private policy: PlaybackPolicyView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private busy: boolean = false;
  /** 保存失败只显示在出错的那张卡上（Web 两张卡各管各的错误） */
  @Local private saveError: string = '';
  /** 开着且还在切时的进度轮询（同 iOS 15 秒一拉） */
  private clipTick: number = -1;

  aboutToAppear(): void {
    this.load();
    this.clipTick = setInterval((): void => {
      this.refreshClipProgress();
    }, 15000);
  }

  aboutToDisappear(): void {
    if (this.clipTick >= 0) {
      clearInterval(this.clipTick);
      this.clipTick = -1;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.policy = await api.playbackPolicyShow();
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  /** 改即存：乐观更新本地视图，失败回滚并给出提示（同 iOS） */
  private async setPolicy(kind: string, on: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: PlaybackPolicyView | null = this.policy;
    if (api === null || view === null || this.busy) {
      return;
    }
    const previous: PlaybackPolicyView = view;
    if (kind === 'software') {
      view.software_transcode_enabled = on;
    } else if (kind === 'trickplay') {
      view.trickplay_enabled = on;
    } else {
      view.transcode_cache_enabled = on;
    }
    this.busy = true;
    this.saveError = '';
    try {
      const body: PolicyBody = new PolicyBody();
      if (kind === 'software') {
        body.software_transcode_enabled = on;
      } else if (kind === 'trickplay') {
        body.trickplay_enabled = on;
      } else {
        body.transcode_cache_enabled = on;
      }
      this.policy = await api.playbackPolicySet(body);
    } catch (error) {
      this.policy = previous;
      this.saveError = this.messageOf(error);
    } finally {
      this.busy = false;
    }
  }

  private backendLabel(id: string): string {
    if (id === 'videotoolbox') {
      return 'VideoToolbox（Apple）';
    }
    if (id === 'nvenc') {
      return 'NVENC（NVIDIA）';
    }
    if (id === 'qsv') {
      return 'Quick Sync（Intel）';
    }
    if (id === 'vaapi') {
      return 'VAAPI（Linux）';
    }
    if (id === 'amf') {
      return 'AMF（AMD）';
    }
    return id;
  }

  /** 片段预切开关：开启直接存；关闭先查已切数量，非空先问要不要一并删除（同 iOS toggleClips） */
  private async onClipsToggle(on: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    if (on) {
      this.saveClips(true, false);
      return;
    }
    try {
      const stats: ReelClipStatsView = await api.reelsClipsStats();
      if (stats.count > 0) {
        this.confirmDropClips(stats);
      } else {
        this.saveClips(false, false);
      }
    } catch (error) {
      this.saveError = this.messageOf(error);
    }
  }

  /** 关「片段预切」前查到的已切片段；非空时弹「要不要一并删除」（同 iOS clipsToDrop） */
  private confirmDropClips(stats: ReelClipStatsView): void {
    this.getUIContext().showAlertDialog({
      title: '关闭片段预切？',
      message: '关闭后预告和刷片改回直接播放原片，后台不再切新的片段。保留的片段在重新打开后可直接使用。',
      primaryButton: {
        value: '关闭，保留片段',
        action: (): void => {
          this.saveClips(false, false);
        }
      },
      secondaryButton: {
        value: `关闭并删除 ${stats.count} 个片段（${Formatters.bytes(stats.bytes)}）`,
        fontColor: Theme.danger,
        action: (): void => {
          this.saveClips(false, true);
        }
      }
    });
  }

  /** 片段预切的保存（同 iOS savePolicy(clips:purgeClips:)）：purge=true 时关掉后把已切片段删掉 */
  private async saveClips(on: boolean, purge: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: PlaybackPolicyView | null = this.policy;
    if (api === null || view === null || this.busy) {
      return;
    }
    const previous: PlaybackPolicyView = view;
    view.reel_clips_enabled = on;
    this.busy = true;
    this.saveError = '';
    try {
      const body: PolicyBody = new PolicyBody();
      body.reel_clips_enabled = on;
      this.policy = await api.playbackPolicySet(body);
      if (purge) {
        await api.reelsClipsClear();
      }
    } catch (error) {
      this.policy = previous;
      this.saveError = this.messageOf(error);
    } finally {
      this.busy = false;
    }
  }

  /** 开着且还在切时刷新进度（同 iOS refreshClipProgress） */
  private async refreshClipProgress(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const current: PlaybackPolicyView | null = this.policy;
    if (api === null || this.busy || current === null || current.reel_clips_enabled !== true) {
      return;
    }
    const progress: ReelClipProgressView | null = current.reel_clips_progress ?? null;
    if (progress !== null && progress.state === 'done') {
      return;
    }
    try {
      this.policy = await api.playbackPolicyShow();
    } catch (error) {
      // 静默：下次轮询再试
    }
  }

  /** 片段预切的说明：关着讲开启的好处，开着写进度（文案同 iOS clipsFooter / Web） */
  private clipsFooter(view: PlaybackPolicyView): string {
    if (view.reel_clips_enabled !== true) {
      return '后台把每部影片的精彩片段提前转成 1080p 小文件。开启后，电视首页和详情页的大图预告起播快、不卡顿，'
        + '刷片更流畅，外网刷片也不用实时转码。首次开启要在后台处理一段时间（有人观看时自动暂停），每部约占 20 MB。';
    }
    const progress: ReelClipProgressView | null = view.reel_clips_progress ?? null;
    if (progress === null) {
      return '正在准备……';
    }
    if (progress.state === 'done') {
      const skipped: number = progress.total - progress.ready;
      return skipped > 0
        ? `已切好 ${progress.ready} 部，其余 ${skipped} 部无法预切（网盘文件或片子太短）；新入库的会自动补切`
        : `已切好全部 ${progress.ready} 部；新入库的会自动补切`;
    }
    if (progress.state === 'paused') {
      return `已切好 ${progress.ready} / ${progress.total} 部，有人在观看，暂停中`;
    }
    return `已切好 ${progress.ready} / ${progress.total} 部，正在后台处理；没切好的预告先显示剧照`;
  }

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载播放设置…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.policy === null) {
        Column({ space: 10 }) {
          Text('播放设置加载失败').fontSize(15).fontColor(Theme.text)
          Text(this.errorMessage).fontSize(13).fontColor(Theme.textMuted)
          Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
            this.load();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            if (this.saveError.length > 0) {
              Text(this.saveError)
                .fontSize(13)
                .fontColor(Theme.danger)
                .width('100%')
                .padding(12)
                .backgroundColor(Theme.surface)
                .borderRadius(Theme.cardRadius)
                .border({ width: 1, color: Theme.line })
            }
            this.HardwareCard(this.policy as PlaybackPolicyView)
            this.TogglesCard(this.policy as PlaybackPolicyView)
            Text('开关都是改一下就保存，没有「保存」按钮。')
              .fontSize(11)
              .fontColor(Theme.textFaint)
              .width('100%')
            AppFooter()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: Theme.tabBarInset })
        }
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 硬件加速：这是**事实**（服务端探测到的），不是开关 */
  @Builder
  HardwareCard(view: PlaybackPolicyView) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Circle()
          .width(8)
          .height(8)
          .fill(view.hardware_available ? Theme.ok : Theme.warn)
        Text(view.hardware_available ? '有硬件加速可用' : '没有硬件加速')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
      }
      .width('100%')
      if (view.hw_backends.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(view.hw_backends, (backend: string) => {
            Text(this.backendLabel(backend))
              .fontSize(11)
              .fontColor(Theme.accent2)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .backgroundColor(Theme.glassFill)
              .borderRadius(6)
              .margin({ right: 6, bottom: 4 })
          }, (backend: string) => backend)
        }
        .width('100%')
      }
      Text(view.hardware_available
        ? '转码会优先用显卡，CPU 占用低得多。'
        : '这台机器没探测到能用的显卡编码器，转码只能靠 CPU（很吃性能）。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  TogglesCard(view: PlaybackPolicyView) {
    Column({ space: 0 }) {
      SettingsSwitchRow({
        title: '进度条预览', hint: '拖动时显示缩略图预览；要预先生成，占磁盘', value: view.trickplay_enabled,
        onToggle: (on: boolean): void => {
          this.setPolicy('trickplay', on);
        }
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      SettingsSwitchRow({
        title: '转码缓存', hint: '把转好的片段存下来，回看同一段不用重转；占磁盘', value: view.transcode_cache_enabled,
        onToggle: (on: boolean): void => {
          this.setPolicy('cache', on);
        }
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      SettingsSwitchRow({
        title: '片段预切', hint: this.clipsFooter(view), value: view.reel_clips_enabled ?? false,
        onToggle: (on: boolean): void => {
          this.onClipsToggle(on);
        }
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      SettingsSwitchRow({
        title: '允许软件转码', hint: '没有硬件加速时用 CPU 兜底转码；很吃 CPU，机器弱就别开', value: view.software_transcode_enabled,
        onToggle: (on: boolean): void => {
          this.setPolicy('software', on);
        }
      })
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }
}
