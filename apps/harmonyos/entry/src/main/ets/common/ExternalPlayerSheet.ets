import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from './GlassControls';
import { Haptics } from './Haptics';
import { AppModel } from './AppModel';
import { MovieClawApi } from '../api/Endpoints';
import {
  PlaybackExternalLinkView,
  PlaybackExternalSubtitleView
} from '../api/Models';

/**
 * 外部播放器签名直链面板（领先 iOS 端首发上线）：
 *
 * 调用 `POST /playback/external-link` 签出 12 小时有效的单文件原画直链及文本字幕地址，支持：
 * 1. **系统视频应用拉起（HarmonyOS Want `ohos.want.action.viewData` `video/*`）**——直接唤起本机安装的第三方全能播放器；
 * 2. **VLC / MPV / Infuse / PotPlayer 协议拉起**（2in1 / 平板 / 跨端复制）；
 * 3. **一键复制 12 小时原文件直链与外挂字幕直链**。
 */
@Component
export struct ExternalPlayerSheet {
  mediaItemId: number = 0;
  seasonNumber: number = 0;
  episodeNumber: number = 0;
  fileId: number | null = null;
  onClose: () => void = (): void => {};

  @State private loading: boolean = true;
  @State private errorText: string = '';
  @State private link: PlaybackExternalLinkView | null = null;

  aboutToAppear(): void {
    this.fetchLink();
  }

  private async fetchLink(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.mediaItemId <= 0) {
      this.loading = false;
      this.errorText = '当前未连接服务器';
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const view: PlaybackExternalLinkView = await api.playbackExternalLink({
        media_item_id: this.mediaItemId,
        season_number: this.seasonNumber,
        episode_number: this.episodeNumber,
        file_id: this.fileId !== null && this.fileId > 0 ? this.fileId : null
      });
      this.link = view;
    } catch (error) {
      this.errorText = `${error}`;
    } finally {
      this.loading = false;
    }
  }

  private copyText(text: string, label: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data);
      Haptics.notifySuccess();
      this.getUIContext().getPromptAction().showToast({ message: `已复制${label}（12小时内有效）` });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    }
  }

  private launchSystemVideo(view: PlaybackExternalLinkView): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: view.stream_url,
      type: 'video/*',
      parameters: {
        title: view.title,
        position: view.start_ms
      }
    };
    ctx.startAbility(want).then((): void => {
      Haptics.click();
    }).catch((): void => {
      this.copyText(view.stream_url, '视频直链（未检测到外部播放器，已复制链接）');
    });
  }

  private launchScheme(uri: string, fallbackStreamUrl: string, name: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri
    };
    ctx.startAbility(want).then((): void => {
      Haptics.click();
    }).catch((): void => {
      this.copyText(fallbackStreamUrl, `直链（本机未安装 ${name}，已复制原画地址）`);
    });
  }

  private vlcUri(view: PlaybackExternalLinkView): string {
    const sub: string = view.subtitles.length > 0 ? `&sub=${encodeURIComponent(view.subtitles[0].url)}` : '';
    return `vlc-x-callback://x-callback-url/stream?url=${encodeURIComponent(view.stream_url)}${sub}`;
  }

  build() {
    Column({ space: 16 }) {
      Row() {
        Column({ space: 3 }) {
          Text('用外部播放器打开')
            .fontSize(18)
            .fontWeight(700)
            .fontColor(Theme.text)
          Text('签发 12 小时单文件原画直链 · 不耗转码算力')
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(15)
            .fontColor([Theme.text])
        }
        .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
        .width(34)
        .height(34)
        .borderRadius(17)
        .onClick((): void => {
          this.onClose();
        })
      }
      .width('100%')

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(Theme.textMuted)
          Text('正在签发原文件直链…')
            .fontSize(14)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .padding({ top: 28, bottom: 28 })
        .justifyContent(FlexAlign.Center)
      } else if (this.errorText.length > 0 || this.link === null) {
        Column({ space: 10 }) {
          Text(this.errorText.length > 0 ? this.errorText : '无法生成外部播放链接')
            .fontSize(14)
            .fontColor(Theme.danger)
            .textAlign(TextAlign.Center)
          Button('重试')
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .height(38)
            .padding({ left: 20, right: 20 })
            .borderRadius(19)
            .onClick((): void => {
              this.fetchLink();
            })
        }
        .width('100%')
        .padding({ top: 20, bottom: 20 })
      } else {
        this.ReadyBody(this.link as PlaybackExternalLinkView)
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 28 })
  }

  @Builder
  private ReadyBody(view: PlaybackExternalLinkView) {
    Column({ space: 12 }) {
      Column({ space: 4 }) {
        Text(view.title)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(view.file_name)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(12)
      .backgroundColor('rgba(255,255,255,0.05)')
      .borderRadius(12)

      Button('拉起本机外部视频播放器')
        .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
        .fontColor('#0b0d12')
        .fontWeight(600)
        .fontSize(15)
        .width('100%')
        .height(44)
        .borderRadius(14)
        .onClick((): void => {
          this.launchSystemVideo(view);
        })

      Row({ space: 10 }) {
        Button('VLC 打开')
          .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
          .fontColor(Theme.text)
          .fontSize(14)
          .layoutWeight(1)
          .height(40)
          .borderRadius(12)
          .onClick((): void => {
            this.launchScheme(this.vlcUri(view), view.stream_url, 'VLC');
          })
        Button('PotPlayer / PC')
          .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
          .fontColor(Theme.text)
          .fontSize(14)
          .layoutWeight(1)
          .height(40)
          .borderRadius(12)
          .onClick((): void => {
            this.launchScheme(`potplayer://${view.stream_url}`, view.stream_url, 'PotPlayer');
          })
        Button('复制原片直链')
          .attributeModifier(new GlassButtonModifier(GlassTone.Strong))
          .fontColor(Theme.text)
          .fontSize(14)
          .layoutWeight(1)
          .height(40)
          .borderRadius(12)
          .onClick((): void => {
            this.copyText(view.stream_url, '原片直链');
          })
      }
      .width('100%')

      if (view.subtitles.length > 0) {
        Column({ space: 8 }) {
          Text('可用外挂文本字幕（点击复制直链）')
            .fontSize(12)
            .fontColor(Theme.textMuted)
          ForEach(view.subtitles.slice(0, 4), (sub: PlaybackExternalSubtitleView) => {
            Row({ space: 8 }) {
              Text(`${sub.label ?? sub.language ?? sub.track} · ${sub.format.toUpperCase()}`)
                .fontSize(13)
                .fontColor(Theme.text)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('复制')
                .fontSize(12)
                .fontWeight(600)
                .fontColor(Theme.accent)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .backgroundColor('rgba(255,255,255,0.04)')
            .borderRadius(10)
            .onClick((): void => {
              this.copyText(sub.url, '字幕链接');
            })
          }, (sub: PlaybackExternalSubtitleView) => sub.track)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      Text('注：外部播放器不自动回传观看进度，看完后可在详情页点「标为已看」。链接 12 小时内有效，请勿公开转发。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .lineHeight(16)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
