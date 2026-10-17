import { display, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { DeviceText } from '../common/DeviceText';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { LoginDeviceView } from '../api/Models';
import { DeviceRenameDialog } from './DeviceRenameDialog';

/**
 * 设备分组列表页 + 设备详情页（对应 iOS `DevicesSettingsView` 的 deviceList / deviceDetail）。
 *
 * 主页（SettingsSectionPage 的设备分区）只列四个固定分组行；点分组进列表页
 * （搜索 + 在线/离线两段，行内保留改名/注销按钮），点设备进详情页
 * （基本 / 活动 / 通知 / 访问权限 / 改名注销）。
 */

/** 复制到系统剪贴板（模块级：`@Builder` / 静态上下文里不能用 `this`） */
function copyPlainText(text: string): void {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  pasteboard.getSystemPasteboard().setDataSync(data);
}

/** 一类设备（对应 iOS `DeviceGroup`）：固定四组，空组也占一行 */
export class DeviceGroupDef {
  readonly id: string;
  readonly title: string;
  readonly symbol: Resource;
  readonly items: LoginDeviceView[];

  constructor(id: string, title: string, symbol: Resource, items: LoginDeviceView[]) {
    this.id = id;
    this.title = title;
    this.symbol = symbol;
    this.items = items;
  }

  /** 固定四组：浏览器 / App / 命令行与转码器（其余未列出的类型都归这里）/ 播放器 */
  static make(devices: LoginDeviceView[]): DeviceGroupDef[] {
    const browser: LoginDeviceView[] = [];
    const app: LoginDeviceView[] = [];
    const paired: LoginDeviceView[] = [];
    const player: LoginDeviceView[] = [];
    for (const device of devices) {
      if (device.kind === 'web') {
        browser.push(device);
      } else if (device.kind === 'ios' || device.kind === 'tvos' || device.kind === 'macos'
        || device.kind === 'android' || device.kind === 'androidtv') {
        app.push(device);
      } else if (device.kind === 'jellyfin') {
        player.push(device);
      } else {
        paired.push(device);
      }
    }
    return [
      new DeviceGroupDef('browser', '浏览器', $r('sys.symbol.website'), browser),
      new DeviceGroupDef('app', 'App', $r('sys.symbol.pad_and_iphone'), app),
      new DeviceGroupDef('paired', '命令行与转码器', $r('sys.symbol.code'), paired),
      new DeviceGroupDef('player', '播放器', $r('sys.symbol.video'), player)
    ];
  }

  /** 搜索：按名称 / 所属成员 / 系统说明过滤（同 iOS `matching`） */
  matching(query: string): LoginDeviceView[] {
    const q: string = query.trim().toLowerCase();
    if (q.length === 0) {
      return this.items;
    }
    const matched: LoginDeviceView[] = [];
    for (const device of this.items) {
      const platform: string = device.platform ?? '';
      if (device.name.toLowerCase().indexOf(q) >= 0
        || device.owner_nickname.toLowerCase().indexOf(q) >= 0
        || platform.toLowerCase().indexOf(q) >= 0) {
        matched.push(device);
      }
    }
    return matched;
  }
}

/** 分组列表页路由参数（路由参数会序列化，不要用 instanceof） */
export class GroupListParams {
  readonly groupId: string;
  readonly showAll: boolean;

  constructor(groupId: string, showAll: boolean) {
    this.groupId = groupId;
    this.showAll = showAll;
  }

  static of(param: Object | undefined | null): GroupListParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: GroupListParams = param as GroupListParams;
    const id: string = raw.groupId;
    if (id === undefined || id === null || id.length === 0) {
      return null;
    }
    return new GroupListParams(id, raw.showAll === true);
  }
}

/** 设备详情页路由参数 */
export class DetailParams {
  readonly deviceId: string;
  readonly showAll: boolean;

  constructor(deviceId: string, showAll: boolean) {
    this.deviceId = deviceId;
    this.showAll = showAll;
  }

  static of(param: Object | undefined | null): DetailParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: DetailParams = param as DetailParams;
    const id: string = raw.deviceId;
    if (id === undefined || id === null || id.length === 0) {
      return null;
    }
    return new DetailParams(id, raw.showAll === true);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function DeviceGroupListBuilder() {
  DeviceGroupListPage()
}

@Builder
export function DeviceDetailBuilder() {
  DeviceDetailPage()
}

/**
 * 分组列表页：一个分组里的全部设备，在线 / 离线两段 + 搜索。
 * 行内保留改名 / 注销按钮；点行的文字区进详情页。
 */
@ComponentV2
export struct DeviceGroupListPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  /** 首次 onShown 不刷（onReady 已加载）；之后每次重新可见（从详情页返回）静默刷新 */
  private shownOnce: boolean = false;

  @Local private groupId: string = 'browser';
  @Local private showAll: boolean = false;
  @Local private model: AppModel = AppModel.shared;

  @Local private devices: LoginDeviceView[] = [];
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private refreshing: boolean = false;
  @Local private search: string = '';
  @Local private busyId: string = '';

  /** 改名用华为原生自定义弹窗（openCustomDialog，底部卡片） */
  @Local private renameTarget: LoginDeviceView | null = null;
  @Local private renameDialogId: number = -1;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private isAdmin(): boolean {
    return Permissions.fromSession(this.model.session).isAdmin;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  private deviceName(device: LoginDeviceView): string {
    return device.name.length > 0 ? device.name : device.kind_label;
  }

  private currentGroup(): DeviceGroupDef {
    const groups: DeviceGroupDef[] = DeviceGroupDef.make(this.devices);
    for (const group of groups) {
      if (group.id === this.groupId) {
        return group;
      }
    }
    return groups[0];
  }

  private filtered(): LoginDeviceView[] {
    return this.currentGroup().matching(this.search);
  }

  private onlineDevices(): LoginDeviceView[] {
    const online: LoginDeviceView[] = [];
    for (const device of this.filtered()) {
      if (DeviceText.isLive(device)) {
        online.push(device);
      }
    }
    return online;
  }

  private offlineDevices(): LoginDeviceView[] {
    const offline: LoginDeviceView[] = [];
    for (const device of this.filtered()) {
      if (!DeviceText.isLive(device)) {
        offline.push(device);
      }
    }
    return offline;
  }

  private async load(silent: boolean = false): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    if (!silent) {
      this.loading = true;
    }
    try {
      this.devices = await api.authDevicesList(this.showAll && this.isAdmin() ? true : undefined);
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  // MARK: 改名 / 注销

  private revokeMessage(device: LoginDeviceView): string {
    if (device.kind === 'worker' || device.scope === 'transcode') {
      return '这台转码器会立即断开，正在进行的转码会中止，需要重新配对才能再次接入。';
    }
    return '这台设备会立即失去访问权限，正在播放的也会停止；要再用需要重新登录或重新配对。其他设备不受影响。';
  }

  private confirmRevoke(device: LoginDeviceView): void {
    this.getUIContext().showAlertDialog({
      title: `注销「${this.deviceName(device)}」？`,
      message: this.revokeMessage(device),
      primaryButton: {
        value: '不注销',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '注销',
        fontColor: Theme.danger,
        action: (): void => {
          this.revoke(device);
        }
      }
    });
  }

  private async revoke(device: LoginDeviceView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busyId.length > 0) {
      return;
    }
    this.busyId = device.id;
    try {
      await api.authDevicesRevoke(device.id);
      this.toast('已注销');
      await this.load(true);
    } catch (error) {
      this.toast('注销失败，请稍后再试');
    } finally {
      this.busyId = '';
    }
  }

  /** 注销本机 = 退出当前登录（交给 AppModel：服务端注销 + 删本机令牌 + 切账号或回欢迎页） */
  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: '退出登录？',
      message: '这台设备上的登录会被注销，再回来需要重新输入密码。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: Theme.danger,
        action: (): void => {
          this.model.logout();
        }
      }
    });
  }

  private promptRename(device: LoginDeviceView): void {
    this.renameTarget = device;
    this.openRenameDialog();
  }

  // MARK: 弹窗

  /** 拉起改名弹窗（底部对齐、宽度随屏、遮罩、输入法避让） */
  private openRenameDialog(): void {
    const screenWidthVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    const options: promptAction.CustomDialogOptions = {
      builder: (): void => {
        this.RenameCard();
      },
      width: Math.round(screenWidthVp - 32),
      alignment: DialogAlignment.Bottom,
      keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
      autoCancel: true,
      maskColor: 'rgba(0,0,0,0.6)',
      backgroundColor: Theme.surfaceRaised,
      cornerRadius: Theme.cardRadius
    };
    this.getUIContext().getPromptAction().openCustomDialog(options)
      .then((id: number): void => {
        this.renameDialogId = id;
      })
      .catch((): void => {
        this.renameDialogId = -1;
      });
  }

  private closeRenameDialog(): void {
    if (this.renameDialogId < 0) {
      return;
    }
    this.getUIContext().getPromptAction().closeCustomDialog(this.renameDialogId);
    this.renameDialogId = -1;
  }

  /** 改名弹窗内容 */
  @Builder
  RenameCard() {
    DeviceRenameDialog({
      deviceId: this.renameTarget !== null ? this.renameTarget.id : '',
      deviceName: this.renameTarget !== null ? this.deviceName(this.renameTarget) : '',
      onClose: (): void => {
        this.closeRenameDialog();
      },
      onRenamed: (): void => {
        this.load(true);
      }
    })
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        PageTopBar({ title: this.currentGroup().title, onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress().width(26).height(26).color(Theme.textMuted)
            Text('正在加载设备…').fontSize(14).fontColor(Theme.textMuted)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
            Scroll() {
              Column({ space: 16 }) {
                if (this.errorMessage.length > 0) {
                  Text(this.errorMessage)
                    .fontSize(13)
                    .fontColor(Theme.danger)
                    .width('100%')
                }

                // 搜索（同 iOS .searchable：按名称 / 成员 / 系统说明过滤）
                TextInput({ text: this.search, placeholder: this.showAll ? '搜索设备或成员' : '搜索设备' })
                  .width('100%')
                  .height(42)
                  .fontSize(14)
                  .fontColor(Theme.text)
                  .backgroundColor(Theme.surface)
                  .borderRadius(Theme.cardRadius)
                  .border({ width: 1, color: Theme.line })
                  .onChange((value: string): void => {
                    this.search = value;
                  })

                if (this.filtered().length === 0) {
                  this.EmptyState()
                } else {
                  if (this.onlineDevices().length > 0) {
                    this.DeviceSection(`在线 · ${this.onlineDevices().length}`, this.onlineDevices())
                  }
                  if (this.offlineDevices().length > 0) {
                    this.DeviceSection(`离线 · ${this.offlineDevices().length}`, this.offlineDevices())
                  }
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: Theme.tabBarInset })
            }
            .width('100%')
            .layoutWeight(1)
            .align(Alignment.TopStart)
            .scrollBar(BarState.Off)
          }
          .width('100%')
          .layoutWeight(1)
          .onRefreshing((): void => {
            this.load(true).then((): void => {
              this.refreshing = false;
            }).catch((): void => {
              this.refreshing = false;
            });
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: GroupListParams | null = GroupListParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.groupId = params.groupId;
        this.showAll = params.showAll;
        this.load();
      }
    })
    .onShown((): void => {
      if (!this.started) {
        return;
      }
      if (this.shownOnce) {
        // 从详情页返回：静默刷新（详情页里可能已改名/注销）
        this.load(true);
      } else {
        this.shownOnce = true;
      }
    })
  }

  /** 空态：整组没有设备 / 搜索没有命中（同 iOS ContentUnavailableView） */
  @Builder
  EmptyState() {
    Column({ space: 10 }) {
      SymbolGlyph(this.currentGroup().symbol)
        .fontSize(30)
        .fontColor([Theme.textFaint])
      if (this.search.trim().length === 0) {
        Text(`暂无${this.currentGroup().title}设备`)
          .fontSize(15)
          .fontColor(Theme.textMuted)
        Text('登录或配对后，设备会出现在这里。')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      } else {
        Text('没有匹配的设备')
          .fontSize(15)
          .fontColor(Theme.textMuted)
        Text('换个关键词试试。')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
    }
    .width('100%')
    .padding({ top: 48, bottom: 48 })
    .justifyContent(FlexAlign.Center)
  }

  /** 一段设备：小标题 + 卡片（在线 · N / 离线 · N） */
  @Builder
  DeviceSection(title: string, devices: LoginDeviceView[]) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 4 })
      Column() {
        ForEach(devices, (device: LoginDeviceView, index: number) => {
          this.DeviceListRow(device, index < devices.length - 1)
        }, (device: LoginDeviceView): string => device.id)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 一行设备：图标（在线亮绿点）+ 名字 + 两行说明 + 休眠提示；文字区点击进详情，尾部改名/注销 */
  @Builder
  DeviceListRow(device: LoginDeviceView, separator: boolean) {
    Column() {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          SymbolGlyph(DeviceText.symbolOf(device.kind, device.scope))
            .fontSize(22)
            .fontColor([device.current ? Theme.accent : Theme.textMuted])
          if (DeviceText.isLive(device)) {
            Circle()
              .width(7)
              .height(7)
              .fill(Theme.ok)
              .border({ width: 1.5, color: Theme.surface })
          }
        }
        .width(28)
        .alignSelf(ItemAlign.Center)

        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(this.deviceName(device))
              .fontSize(16)
              .fontColor(Theme.text)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .wordBreak(WordBreak.BREAK_ALL)
            if (device.current) {
              Text('本机')
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.accent)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .backgroundColor(Theme.accentSoft)
                .borderRadius(8)
            }
          }
          .width('100%')

          Text(DeviceText.metaLine(DeviceText.identityParts(device, this.showAll)))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
          Text(DeviceText.metaLine(DeviceText.activityParts(device)))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')

          if (DeviceText.isDormant(device)) {
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.clock'))
                .fontSize(11)
                .fontColor([Theme.warning])
              Text('超过 90 天没有用过，不认识或不再用的设备可以注销')
                .fontSize(12)
                .fontColor(Theme.warning)
            }
            .padding({ top: 2 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => {
          this.navStack.pushPathByName('deviceDetail', new DetailParams(device.id, this.showAll));
        })

        // 尾部两个竖排按钮（右对齐）：改名 / 注销
        Column({ space: 6 }) {
          if (device.renamable) {
            Text('改名')
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .textAlign(TextAlign.Center)
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .backgroundColor(Theme.glassFill)
              .borderRadius(10)
              .onClick((): void => {
                this.promptRename(device);
              })
          }
          Text(this.busyId === device.id ? '…' : '注销')
            .fontSize(13)
            .fontColor(Theme.danger)
            .textAlign(TextAlign.Center)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(10)
            .onClick((): void => {
              if (this.busyId === device.id) {
                return;
              }
              if (device.current) {
                this.confirmLogout();
              } else {
                this.confirmRevoke(device);
              }
            })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 16, right: 12, top: 12, bottom: 12 })

      if (separator) {
        Divider().color(Theme.line).margin({ left: 56, right: 16 })
      }
    }
    .width('100%')
  }
}

/**
 * 设备详情页：基本 / 活动 / 通知 / 访问权限 + 改名注销（对应 iOS `deviceDetail`）。
 * 注销本机走「退出登录」，其余设备注销后返回列表。
 */
@ComponentV2
export struct DeviceDetailPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;

  @Local private deviceId: string = '';
  @Local private showAll: boolean = false;
  @Local private model: AppModel = AppModel.shared;

  @Local private device: LoginDeviceView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private busy: boolean = false;
  @Local private renameDialogId: number = -1;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private isAdmin(): boolean {
    return Permissions.fromSession(this.model.session).isAdmin;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  private deviceName(device: LoginDeviceView): string {
    return device.name.length > 0 ? device.name : device.kind_label;
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const devices: LoginDeviceView[] =
        await api.authDevicesList(this.showAll && this.isAdmin() ? true : undefined);
      let found: LoginDeviceView | null = null;
      for (const item of devices) {
        if (item.id === this.deviceId) {
          found = item;
          break;
        }
      }
      if (found === null) {
        this.errorMessage = '这台设备已注销，或不在当前查看范围内。';
        this.device = null;
      } else {
        this.device = found;
        this.errorMessage = '';
      }
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  // MARK: 字段可见性 / 文案

  private statusText(device: LoginDeviceView): string {
    if (device.current) {
      return '本机 · 正在使用';
    }
    return DeviceText.isLive(device) ? '在线' : '离线';
  }

  private statusColor(device: LoginDeviceView): ResourceColor {
    return DeviceText.isLive(device) ? Theme.ok : Theme.textMuted;
  }

  private hasPlatform(device: LoginDeviceView): boolean {
    return (device.platform ?? '').length > 0;
  }

  private hasVersion(device: LoginDeviceView): boolean {
    return (device.client_version ?? '').length > 0;
  }

  /** 「状态」行之后还有没有别的行（所属成员 / 系统 / 版本） */
  private hasBasicTail(device: LoginDeviceView): boolean {
    return this.hasPlatform(device) || this.hasVersion(device);
  }

  private hasIp(device: LoginDeviceView): boolean {
    return (device.last_seen_ip ?? '').length > 0;
  }

  private hasPush(device: LoginDeviceView): boolean {
    return device.push !== null && device.push !== undefined;
  }

  private pushText(device: LoginDeviceView): string {
    const push = device.push;
    return push !== null && push !== undefined ? push.status_text : '';
  }

  private pushSymbol(device: LoginDeviceView): Resource {
    const push = device.push;
    return push !== null && push !== undefined && push.status === 'ok'
      ? $r('sys.symbol.bell') : $r('sys.symbol.bell_slash');
  }

  private revokeMessage(device: LoginDeviceView): string {
    if (device.kind === 'worker' || device.scope === 'transcode') {
      return '注销会断开转码器并中止正在进行的转码，再次使用需要重新配对。';
    }
    return '注销会终止这台设备的访问和播放，再次使用需要重新登录。';
  }

  // MARK: 改名 / 注销

  private confirmRevoke(device: LoginDeviceView): void {
    this.getUIContext().showAlertDialog({
      title: `注销「${this.deviceName(device)}」？`,
      message: this.revokeMessage(device),
      primaryButton: {
        value: '不注销',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '注销',
        fontColor: Theme.danger,
        action: (): void => {
          this.revoke();
        }
      }
    });
  }

  private async revoke(): Promise<void> {
    const device: LoginDeviceView | null = this.device;
    const api: MovieClawApi | null = this.api();
    if (device === null || api === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      await api.authDevicesRevoke(device.id);
      this.toast('已注销');
      this.navStack.pop();
    } catch (error) {
      this.toast('注销失败，请稍后再试');
    } finally {
      this.busy = false;
    }
  }

  /** 注销本机 = 退出当前登录（交给 AppModel） */
  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: '退出登录？',
      message: '这台设备上的登录会被注销，再回来需要重新输入密码。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: Theme.danger,
        action: (): void => {
          this.model.logout();
        }
      }
    });
  }

  // MARK: 弹窗

  private openRenameDialog(): void {
    const screenWidthVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    const options: promptAction.CustomDialogOptions = {
      builder: (): void => {
        this.RenameCard();
      },
      width: Math.round(screenWidthVp - 32),
      alignment: DialogAlignment.Bottom,
      keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
      autoCancel: true,
      maskColor: 'rgba(0,0,0,0.6)',
      backgroundColor: Theme.surfaceRaised,
      cornerRadius: Theme.cardRadius
    };
    this.getUIContext().getPromptAction().openCustomDialog(options)
      .then((id: number): void => {
        this.renameDialogId = id;
      })
      .catch((): void => {
        this.renameDialogId = -1;
      });
  }

  private closeRenameDialog(): void {
    if (this.renameDialogId < 0) {
      return;
    }
    this.getUIContext().getPromptAction().closeCustomDialog(this.renameDialogId);
    this.renameDialogId = -1;
  }

  /** 改名弹窗内容 */
  @Builder
  RenameCard() {
    DeviceRenameDialog({
      deviceId: this.device !== null ? this.device.id : '',
      deviceName: this.device !== null ? this.deviceName(this.device) : '',
      onClose: (): void => {
        this.closeRenameDialog();
      },
      onRenamed: (): void => {
        this.load();
      }
    })
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        PageTopBar({ title: '设备详情', onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress().width(26).height(26).color(Theme.textMuted)
            Text('正在加载设备…').fontSize(14).fontColor(Theme.textMuted)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.device === null) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark'))
              .fontSize(28)
              .fontColor([Theme.textFaint])
            Text(this.errorMessage.length > 0 ? this.errorMessage : '找不到这台设备。')
              .fontSize(14)
              .fontColor(Theme.textMuted)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 16 }) {
              this.BasicCard(this.device)
              this.ActivityCard(this.device)
              if (this.hasPush(this.device)) {
                this.PushCard(this.device)
              }
              this.ScopeCard(this.device)
              if (DeviceText.isDormant(this.device)) {
                Text('超过 90 天没有使用。不认识或不再使用的设备可以注销。')
                  .fontSize(12)
                  .fontColor(Theme.warning)
                  .width('100%')
                  .padding({ left: 4 })
              }
              this.ActionCard(this.device)
              Text(this.revokeMessage(this.device))
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
                .padding({ left: 4 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: Theme.tabBarInset })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: DetailParams | null = DetailParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.deviceId = params.deviceId;
        this.showAll = params.showAll;
        this.load();
      }
    })
  }

  /** 标签 + 值一行（值右对齐；`separator` 控制行底分隔线） */
  @Builder
  InfoRow(label: string, value: string, separator: boolean, color: ResourceColor) {
    Column() {
      Row({ space: 12 }) {
        Text(label)
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .width(76)
        Text(value)
          .fontSize(14)
          .fontColor(color)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (separator) {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
      }
    }
    .width('100%')
  }

  /** 点按复制的值行（来源地址） */
  @Builder
  CopyRow(label: string, value: string, separator: boolean) {
    Column() {
      Row({ space: 12 }) {
        Text(label)
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .width(76)
        Text(value)
          .fontSize(14)
          .fontColor(Theme.accent)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .copyOption(CopyOptions.InApp)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .onClick((): void => {
        copyPlainText(value);
        this.toast('已复制');
      })

      if (separator) {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
      }
    }
    .width('100%')
  }

  /** 基本：名称 / 类型 / 状态 /（所属成员）/（系统）/（版本） */
  @Builder
  BasicCard(device: LoginDeviceView) {
    Column() {
      this.InfoRow('名称', this.deviceName(device), true, Theme.text)
      this.InfoRow('类型', device.kind_label, true, Theme.text)
      this.InfoRow('状态', this.statusText(device), this.showAll || this.hasBasicTail(device), this.statusColor(device))
      if (this.showAll) {
        this.InfoRow('所属成员', device.owner_nickname, this.hasBasicTail(device), Theme.text)
      }
      if (this.hasPlatform(device)) {
        this.InfoRow('系统', device.platform ?? '', this.hasVersion(device), Theme.text)
      }
      if (this.hasVersion(device)) {
        this.InfoRow('版本', device.client_version ?? '', false, Theme.text)
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 活动：最近使用 /（来源地址，点按复制）/ 首次登录 */
  @Builder
  ActivityCard(device: LoginDeviceView) {
    Column() {
      this.InfoRow('最近使用', DeviceText.activityText(device), this.hasIp(device), Theme.text)
      if (this.hasIp(device)) {
        this.CopyRow('来源地址', device.last_seen_ip ?? '', true)
      }
      this.InfoRow('首次登录', Formatters.relative(device.created_at), false, Theme.text)
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 通知：推送状态（只有 App 类设备带） */
  @Builder
  PushCard(device: LoginDeviceView) {
    Row({ space: 10 }) {
      SymbolGlyph(this.pushSymbol(device))
        .fontSize(16)
        .fontColor([Theme.textMuted])
      Text(this.pushText(device))
        .fontSize(14)
        .fontColor(Theme.text)
        .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 访问权限：完全权限 / 仅限转码 */
  @Builder
  ScopeCard(device: LoginDeviceView) {
    Column() {
      this.InfoRow('访问权限', device.scope === 'transcode' ? '仅限转码' : '与所属账号相同', false, Theme.text)
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 改名（可改名时）/ 注销设备 / 退出本机登录 */
  @Builder
  ActionCard(device: LoginDeviceView) {
    Column() {
      if (device.renamable) {
        Text('改名')
          .fontSize(15)
          .fontColor(Theme.text)
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .onClick((): void => {
            this.openRenameDialog();
          })
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
      }
      Text(this.busy ? '注销中…' : (device.current ? '退出本机登录' : '注销设备'))
        .fontSize(15)
        .fontColor(Theme.danger)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ left: 16, right: 16, top: 13, bottom: 13 })
        .onClick((): void => {
          if (this.busy) {
            return;
          }
          if (device.current) {
            this.confirmLogout();
          } else {
            this.confirmRevoke(device);
          }
        })
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }
}
