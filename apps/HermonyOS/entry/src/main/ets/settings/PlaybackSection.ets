import { Theme } from '../theme/AppTheme';
import { SettingsSwitchRow } from '../common/SettingsControls';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { PlaybackPolicyPayload, PlaybackPolicyView } from '../api/Models';
import { AppFooter } from '../common/AppFooter';

/** `PlaybackPolicyPayload` 全可选，用类绕开 `arkts-no-untyped-obj-literals` */
class PolicyBody implements PlaybackPolicyPayload {
  software_transcode_enabled?: boolean | null;
  trickplay_enabled?: boolean | null;
  transcode_cache_enabled?: boolean | null;
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

  aboutToAppear(): void {
    this.load();
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
