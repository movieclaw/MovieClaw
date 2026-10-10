import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import {
  EgressServiceOption,
  NetworkConfigPayload,
  NetworkConfigView,
  NetworkTestPayload,
  NetworkTestResult
} from '../api/Models';

/** 代理方式（对应后端的 proxy_mode） */
class ProxyMode {
  readonly value: string;
  readonly label: string;
  readonly hint: string;

  constructor(value: string, label: string, hint: string) {
    this.value = value;
    this.label = label;
    this.hint = hint;
  }
}

const MODES: ProxyMode[] = [
  new ProxyMode('off', '不走代理', '直连'),
  new ProxyMode('manual', '手动指定', '自己填代理地址'),
  new ProxyMode('env', '跟随环境变量', '用部署环境里的 HTTP_PROXY 等')
];

/** `NetworkConfigPayload` 全可选，用类绕开 `arkts-no-untyped-obj-literals` */
class NetPayload implements NetworkConfigPayload {
  proxy_mode?: string | null;
  proxy_url?: string | null;
  proxy_services?: string[] | null;
  tmdb_api_base_url?: string | null;
  tmdb_image_base_url?: string | null;
  douban_api_base_url?: string | null;
}

/** `NetworkTestPayload` 同理 */
class TestPayload implements NetworkTestPayload {
  service: string = '';
}

/**
 * 设置 → 网络（对应 iOS `NetworkSettingsView` / Web `network-config-section`）。
 *
 * **iOS 的交互模型是「自动保存，立即生效」**——代理方式 / 服务开关**点按即落库**，
 * 地址输入框**提交或失焦落库**；**没有「保存」按钮**，「测试」随时可点。
 * 而且**保存请求要串行化**：快速连点开关时按顺序落库，避免旧请求覆盖新配置
 * （这条是 iOS 注释里点名的，我用一个 Promise 链实现）。
 *
 * 分组：代理（方式三选一 + 手动地址 + 环境变量探测结果）→ 走代理的服务（开关 + 逐项测试）
 * → TMDB / 豆瓣镜像地址（高级，默认折叠）。
 *
 * **没做**：PT 站点分区、外部访问（对外端口要全量重启，得单独二次确认）、
 * 说明文字的 ⓘ 气泡（这里直接写在字段下面）。
 */
@ComponentV2
export struct NetworkSection {
  @Local private config: NetworkConfigView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private saveState: string = '';
  @Local private showAdvanced: boolean = false;

  /** 正在测试的服务 id → 结果 */
  @Local private testingService: string = '';
  @Local private testOk: boolean = false;
  @Local private testMessage: string = '';

  // 输入框草稿（失焦 / 提交才落库）
  @Local private draftProxyUrl: string = '';
  @Local private draftTmdbApi: string = '';
  @Local private draftTmdbImage: string = '';
  @Local private draftDouban: string = '';

  /** 串行化保存：新请求接在上一个之后，避免旧请求覆盖新配置 */
  private saveChain: Promise<void> = Promise.resolve();

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const view: NetworkConfigView = await api.netShow();
      this.config = view;
      this.draftProxyUrl = view.proxy_url;
      this.draftTmdbApi = view.tmdb_api_base_url;
      this.draftTmdbImage = view.tmdb_image_base_url;
      this.draftDouban = view.douban_api_base_url;
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

  /** 立即生效的保存（自动保存模型）：串行入队，完成后刷新视图 */
  private save(patch: (body: NetPayload) => void): void {
    this.saveChain = this.saveChain.then((): Promise<void> => {
      return this.doSave(patch);
    });
  }

  private async doSave(patch: (body: NetPayload) => void): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.saveState = '保存中…';
    const body: NetPayload = new NetPayload();
    patch(body);
    try {
      const view: NetworkConfigView = await api.netSet(body);
      this.config = view;
      this.saveState = '已保存';
      setTimeout((): void => {
        this.saveState = '';
      }, 1500);
    } catch (error) {
      this.saveState = '保存失败';
      this.errorMessage = this.messageOf(error);
      await this.load();
    }
  }

  // MARK: 动作

  private pickMode(mode: string): void {
    const view: NetworkConfigView | null = this.config;
    if (view === null || view.proxy_mode === mode) {
      return;
    }
    this.config = this.withMode(view, mode);
    this.save((body: NetPayload): void => {
      body.proxy_mode = mode;
    });
  }

  /** 乐观改本地视图（保存回来后会被服务端视图整体替换） */
  private withMode(view: NetworkConfigView, mode: string): NetworkConfigView {
    const next: NetworkConfigView = view;
    next.proxy_mode = mode;
    return next;
  }

  private toggleService(service: EgressServiceOption, on: boolean): void {
    const view: NetworkConfigView | null = this.config;
    if (view === null) {
      return;
    }
    const next: string[] = [];
    for (const id of view.proxy_services) {
      if (id !== service.id) {
        next.push(id);
      }
    }
    if (on) {
      next.push(service.id);
    }
    view.proxy_services = next;
    this.save((body: NetPayload): void => {
      body.proxy_services = next;
    });
  }

  private isOn(service: EgressServiceOption): boolean {
    const view: NetworkConfigView | null = this.config;
    return view !== null && view.proxy_services.indexOf(service.id) >= 0;
  }

  /** 单服务连通性测试（随时可点；iOS 的「测试」就是先等在途保存落库再测） */
  private async test(service: EgressServiceOption): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    // 先等在途保存落库，测的才是此刻看到的配置
    await this.saveChain;
    this.testingService = service.id;
    this.testMessage = '';
    try {
      const body: TestPayload = new TestPayload();
      body.service = service.id;
      const result: NetworkTestResult = await api.netTest(body);
      this.testOk = result.ok;
      this.testMessage = `${service.label}：${result.message}`
        + (result.latency_ms !== null && result.latency_ms !== undefined
          ? `（${result.latency_ms}ms）` : '');
    } catch (error) {
      this.testOk = false;
      this.testMessage = this.messageOf(error);
    } finally {
      this.testingService = '';
    }
  }

  private commitProxyUrl(): void {
    const view: NetworkConfigView | null = this.config;
    if (view === null || view.proxy_url === this.draftProxyUrl) {
      return;
    }
    view.proxy_url = this.draftProxyUrl;
    const value: string = this.draftProxyUrl;
    this.save((body: NetPayload): void => {
      body.proxy_url = value;
    });
  }

  private commitMirrors(): void {
    const view: NetworkConfigView | null = this.config;
    if (view === null) {
      return;
    }
    const api: string = this.draftTmdbApi;
    const image: string = this.draftTmdbImage;
    const douban: string = this.draftDouban;
    if (view.tmdb_api_base_url === api && view.tmdb_image_base_url === image
      && view.douban_api_base_url === douban) {
      return;
    }
    this.save((body: NetPayload): void => {
      body.tmdb_api_base_url = api;
      body.tmdb_image_base_url = image;
      body.douban_api_base_url = douban;
    });
  }

  private modeLabel(mode: string): string {
    for (const item of MODES) {
      if (item.value === mode) {
        return item.label;
      }
    }
    return mode;
  }

  // MARK: 视图

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载网络配置…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.config === null) {
        Column({ space: 10 }) {
          Text('网络配置加载失败').fontSize(15).fontColor(Theme.text)
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
            // 保存状态条（没有「保存」按钮，所以要有地方告诉用户存了没）
            if (this.saveState.length > 0) {
              Text(this.saveState)
                .fontSize(12)
                .fontColor(this.saveState === '保存失败' ? Theme.danger : Theme.textFaint)
                .width('100%')
            }
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage).fontSize(13).fontColor(Theme.danger).width('100%')
            }
            this.ProxyCard()
            this.ServicesCard()
            this.TestResultBar()
            this.MirrorsCard()
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

  /** 代理：方式三选一 + 手动地址 + 环境变量探测结果 */
  @Builder
  ProxyCard() {
    Column({ space: 0 }) {
      Column({ space: 3 }) {
        Text('代理')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Text('TMDB 等站点在国内常常直连不通，走代理能解决')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Row({ space: 8 }) {
        ForEach(MODES, (mode: ProxyMode) => {
          Text(mode.label)
            .fontSize(13)
            .fontColor((this.config as NetworkConfigView).proxy_mode === mode.value
              ? '#0b0d12' : Theme.textMuted)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor((this.config as NetworkConfigView).proxy_mode === mode.value
              ? Theme.accent : Theme.glassFill)
            .borderRadius(15)
            .onClick(() => {
              this.pickMode(mode.value);
            })
        }, (mode: ProxyMode) => mode.value)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 10 })

      if ((this.config as NetworkConfigView).proxy_mode === 'manual') {
        Column({ space: 5 }) {
          Text('代理地址')
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .width('100%')
          TextInput({ text: this.draftProxyUrl, placeholder: 'http://127.0.0.1:7890' })
            .width('100%')
            .height(42)
            .fontSize(15)
            .fontColor(Theme.text)
            .backgroundColor(Theme.surfaceRaised)
            .borderRadius(10)
            .padding({ left: 12, right: 12 })
            .onChange((v: string): void => {
              this.draftProxyUrl = v;
            })
            .onSubmit(() => {
              this.commitProxyUrl();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, bottom: 14 })
      }

      if ((this.config as NetworkConfigView).env_proxy_detected.length > 0) {
        Text(`部署环境里探测到代理：${(this.config as NetworkConfigView).env_proxy_detected}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 14 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 走代理的服务：开关 + 逐项测试 */
  @Builder
  ServicesCard() {
    Column({ space: 0 }) {
      Column({ space: 3 }) {
        Text('走代理的服务')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Text('只勾选需要走代理的，其余的直连更快')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })

      ForEach((this.config as NetworkConfigView).services, (service: EgressServiceOption, index: number) => {
        Column() {
          Row({ space: 12 }) {
            Toggle({ type: ToggleType.Switch, isOn: this.isOn(service) })
              .selectedColor(Theme.accent)
              .onChange((on: boolean): void => {
                this.toggleService(service, on);
              })
            Column({ space: 2 }) {
              Text(service.label)
                .fontSize(15)
                .fontColor(Theme.text)
              Text(service.description)
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .maxLines(2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(this.testingService === service.id ? '测试中…' : '测试')
              .fontSize(12)
              .fontColor(Theme.accentStrong)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(Theme.glassFill)
              .borderRadius(12)
              .onClick(() => {
                this.test(service);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          if (index < (this.config as NetworkConfigView).services.length - 1) {
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
          }
        }
        .width('100%')
      }, (service: EgressServiceOption) => service.id)
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  TestResultBar() {
    if (this.testMessage.length > 0) {
      Row({ space: 8 }) {
        Circle()
          .width(7)
          .height(7)
          .fill(this.testOk ? Theme.ok : Theme.danger)
        Text(this.testMessage)
          .fontSize(12)
          .fontColor(this.testOk ? Theme.textMuted : Theme.danger)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(12)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  /** 镜像地址（高级，默认折叠）：失焦 / 提交才落库 */
  @Builder
  MirrorsCard() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('镜像地址')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          Text('高级：换 TMDB / 豆瓣的接口地址')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph(this.showAdvanced ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onClick(() => {
        this.showAdvanced = !this.showAdvanced;
      })

      if (this.showAdvanced) {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        Column({ space: 12 }) {
          this.MirrorField('TMDB 接口', this.draftTmdbApi, (v: string): void => {
            this.draftTmdbApi = v;
          })
          this.MirrorField('TMDB 图片', this.draftTmdbImage, (v: string): void => {
            this.draftTmdbImage = v;
          })
          this.MirrorField('豆瓣接口', this.draftDouban, (v: string): void => {
            this.draftDouban = v;
          })
          Text('留空用官方地址。改完在输入框里回车（或点开别处）即保存。')
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 14 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  MirrorField(label: string, value: string, onChange: (v: string) => void) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
      TextInput({ text: value, placeholder: '官方地址' })
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((v: string): void => {
          onChange(v);
        })
        .onSubmit(() => {
          this.commitMirrors();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
