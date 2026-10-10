import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { request } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { AppFooter } from '../common/AppFooter';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { AccountSwitcherSheet } from '../common/AccountSwitcherSheet';
import { display, promptAction } from '@kit.ArkUI';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { ChangePasswordRequest, LoginDeviceView, SessionView, UpdateProfileRequest } from '../api/Models';

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function ProfileBuilder() {
  ProfilePage()
}

/** 头像压到 512px 长边再传（同 iOS `compressedJPEG(maxEdge: 512)`） */
const AVATAR_MAX_EDGE: number = 512;

/**
 * 个人信息页（对应 iOS `Features/Settings/Sections/ProfileSettingsView.swift`）。
 *
 * 内容与功能逐块对齐 iOS（四块 + 底部两个入口）：
 * 1. **账号总览**：大头像（点一下从系统图库选图 → 压到 512px JPEG → `POST /auth/avatar`）、昵称、身份徽章、@用户名；
 * 2. **账号信息**：昵称原地编辑（≤32 字，`PUT /auth/profile`）、用户名只读；
 * 3. **安全**：当前 / 新（≥8 位）/ 确认三格 → `PUT /auth/password`；有配对的命令行与转码器时可勾「一并注销」；
 * 4. **观看历史**：清空自己的全部观看记录（二次确认 → `DELETE /playback/history?scope=all`）；
 * 5. **切换账号**（打开切换弹窗；长按底栏头像是快捷路径）与**退出登录**（底部居中红字）。
 *
 * 交互控件一律用**华为原生组件**：`List` / `ListItem`、`TextInput`（`InputType.Password` 走系统安全键盘）、
 * `Toggle`、`Button`（胶囊）、`LoadingProgress`、系统图库 `PhotoViewPicker`；
 * 卡片容器沿用本 App 既有的圆角卡（与「我的」「设置」同款），不另造一套壳。
 */
@ComponentV2
export struct ProfilePage {
  private navStack: NavPathStack = new NavPathStack();
  @Local private model: AppModel = AppModel.shared;

  // 头像
  @Local private avatarBusy: boolean = false;
  @Local private avatarError: string = '';
  // 昵称
  @Local private editingNickname: boolean = false;
  @Local private nicknameDraft: string = '';
  @Local private nicknameBusy: boolean = false;
  @Local private nicknameError: string = '';
  // 密码
  @Local private oldPassword: string = '';
  @Local private newPassword: string = '';
  @Local private confirmPassword: string = '';
  @Local private passwordBusy: boolean = false;
  @Local private passwordError: string = '';
  @Local private passwordDone: string = '';
  /** 本机配对的命令行 / 转码器 / 手工令牌台数：>0 才给「一并注销」勾选（同 iOS `pairedCount`） */
  @Local private pairedCount: number = 0;
  @Local private signOutPaired: boolean = false;
  // 观看记录
  @Local private clearing: boolean = false;

  // 切换账号弹窗
  @Local private switcherDialogId: number = -1;

  aboutToAppear(): void {
    this.loadPairedCount();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private session(): SessionView | null {
    return this.model.session;
  }

  /** 当前账号的头像（与「我的」页、底栏页签同一套解析） */
  private avatarUrl(): string {
    const session: SessionView | null = this.session();
    if (session === null) {
      return '';
    }
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), session.avatar_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  private roleLabel(): string {
    const session: SessionView | null = this.session();
    return session === null ? '' : Permissions.roleLabel(session);
  }

  private nickname(): string {
    const session: SessionView | null = this.session();
    return session === null ? '' : session.nickname;
  }

  private username(): string {
    const session: SessionView | null = this.session();
    return session === null ? '' : session.username;
  }

  // MARK: 头像上传

  /**
   * 点头像：系统图库选图 → 压到 512px JPEG → 写进应用缓存 → 系统上传代理 POST `/auth/avatar`
   * （`request.uploadFile` 走的是系统的 multipart 上传，不用自己拼 body）→ 再拉一次 `authMe()` 刷新会话。
   *
   * 图库与压图都是**华为原生能力**（`PhotoViewPicker` + `ImagePacker`）。
   */
  private async pickAndUploadAvatar(): Promise<void> {
    if (this.avatarBusy) {
      return;
    }
    this.avatarError = '';
    let uri: string = '';
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const picked: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      uri = picked.photoUris.length > 0 ? picked.photoUris[0] : '';
    } catch (error) {
      this.avatarError = '打开图库失败，请重试';
      return;
    }
    if (uri.length === 0) {
      return;
    }
    const api: MovieClawApi | null = this.api();
    const client = AppModel.shared.client;
    const context = getContext() as common.UIAbilityContext;
    if (api === null || client === null) {
      return;
    }
    this.avatarBusy = true;
    try {
      // 压到 512px 长边（头像不需要大图）
      const source: image.ImageSource = image.createImageSource(uri);
      const info: image.ImageInfo = await source.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      const longest: number = width >= height ? width : height;
      const scale: number = longest > AVATAR_MAX_EDGE ? AVATAR_MAX_EDGE / longest : 1;
      const target: image.Size = {
        width: Math.max(1, Math.round(width * scale)),
        height: Math.max(1, Math.round(height * scale))
      };
      const pixelMap: image.PixelMap = await source.createPixelMap({ desiredSize: target });
      const packer: image.ImagePacker = image.createImagePacker();
      const jpeg: ArrayBuffer = await packer.packing(pixelMap, { format: 'image/jpeg', quality: 90 });
      packer.release();
      source.release();

      // 写进应用缓存目录，交给系统上传代理（内部 URI 形如 internal://cache/avatar.jpg）
      const filePath: string = `${context.cacheDir}/avatar.jpg`;
      const file = fileIo.openSync(filePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, jpeg);
      fileIo.closeSync(file);

      const token: string = this.model.token !== null ? this.model.token : '';
      const task: request.UploadTask = await request.uploadFile(context, {
        url: `${client.origin}/api/v1/auth/avatar`,
        header: { 'Authorization': `Bearer ${token}` },
        method: 'POST',
        files: [{ filename: 'avatar.jpg', name: 'file', uri: 'internal://cache/avatar.jpg', type: 'jpg' }],
        data: []
      });
      await this.awaitUpload(task);

      // 上传代理不把响应体给出来，重拉一次会话拿新的 avatar_url（同 iOS 的 `model.update(session:)`）
      const refreshed: SessionView = await api.authMe();
      this.model.update(refreshed);
    } catch (error) {
      this.avatarError = this.messageOf(error);
    } finally {
      this.avatarBusy = false;
    }
  }

  /** 等系统上传代理跑完（成功 resolve，失败 reject） */
  private awaitUpload(task: request.UploadTask): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      task.on('complete', (): void => {
        resolve();
      });
      task.on('fail', (): void => {
        reject(new Error('上传失败，请重试'));
      });
    });
  }

  // MARK: 昵称

  private startEditNickname(): void {
    this.nicknameDraft = this.nickname();
    this.nicknameError = '';
    this.editingNickname = true;
  }

  private async saveNickname(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.nicknameBusy) {
      return;
    }
    const nickname: string = this.nicknameDraft.trim();
    if (nickname.length === 0) {
      this.nicknameError = '昵称不能为空';
      return;
    }
    this.nicknameBusy = true;
    this.nicknameError = '';
    try {
      const payload: UpdateProfileRequest = { nickname: nickname };
      this.model.update(await api.authProfileUpdate(payload));
      this.editingNickname = false;
    } catch (error) {
      this.nicknameError = this.messageOf(error);
    } finally {
      this.nicknameBusy = false;
    }
  }

  // MARK: 密码

  private async changePassword(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.passwordBusy) {
      return;
    }
    if (this.newPassword.length < 8) {
      this.passwordError = '新密码至少 8 位';
      return;
    }
    if (this.newPassword !== this.confirmPassword) {
      this.passwordError = '两次输入的新密码不一致';
      return;
    }
    this.passwordBusy = true;
    this.passwordError = '';
    this.passwordDone = '';
    try {
      const revokePaired: boolean = this.signOutPaired && this.pairedCount > 0;
      const payload: ChangePasswordRequest = {
        old_password: this.oldPassword,
        new_password: this.newPassword,
        sign_out_paired: revokePaired
      };
      this.model.update(await api.authPasswordUpdate(payload));
      this.oldPassword = '';
      this.newPassword = '';
      this.confirmPassword = '';
      this.signOutPaired = false;
      this.passwordDone = revokePaired
        ? '密码已修改，其他设备的登录已全部失效，命令行与转码器也已注销；本机保持登录。'
        : '密码已修改，用密码登录的其他设备已全部下线；本机保持登录。';
      await this.loadPairedCount();
    } catch (error) {
      this.passwordError = this.messageOf(error);
    } finally {
      this.passwordBusy = false;
    }
  }

  /** 有配对的命令行 / 转码器才显示「一并注销」（同 iOS `loadPairedCount`） */
  private async loadPairedCount(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const devices: LoginDeviceView[] = await api.authDevicesList();
      let count: number = 0;
      for (const device of devices) {
        if (device.family === 'paired') {
          count += 1;
        }
      }
      this.pairedCount = count;
    } catch (error) {
      // 拿不到就不显示那个勾选项，不影响别的
    }
  }

  // MARK: 观看记录

  private confirmClearHistory(): void {
    this.getUIContext().showAlertDialog({
      title: '清空全部观看记录？',
      message: '所有作品的续播进度、已看标记和播放次数都会清除，首页「最近观看」与播放器的'
        + '「继续观看」随即清空，无法恢复。只影响你自己的记录。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.danger,
        action: (): void => {
          this.clearHistory();
        }
      }
    });
  }

  private async clearHistory(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.clearing) {
      return;
    }
    this.clearing = true;
    try {
      await api.playbackHistoryClear('all');
      this.toast('观看记录已清空');
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.clearing = false;
    }
  }

  // MARK: 切换账号 / 退出

  /** 打开切换账号弹窗（与长按底栏头像同一个弹窗、同一套样式） */
  private openSwitcher(): void {
    const screenWidthVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    const options: promptAction.CustomDialogOptions = {
      builder: (): void => {
        this.SwitcherCard();
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
        this.switcherDialogId = id;
      })
      .catch((): void => {
        this.switcherDialogId = -1;
      });
  }

  private closeSwitcher(): void {
    if (this.switcherDialogId < 0) {
      return;
    }
    this.getUIContext().getPromptAction().closeCustomDialog(this.switcherDialogId);
    this.switcherDialogId = -1;
  }

  @Builder
  SwitcherCard() {
    AccountSwitcherSheet({
      onClose: (): void => {
        this.closeSwitcher();
      }
    })
  }

  private confirmSignOut(): void {
    this.getUIContext().showAlertDialog({
      title: '退出登录',
      message: '退出后需要重新输入密码才能连回这台服务器。',
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

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        PageTopBar({ title: '个人信息', onBack: (): void => {
          this.navStack.pop();
        }})
        List() {
          ListItem() {
            this.OverviewCard()
          }
          ListItem() {
            this.AccountCard()
          }
          ListItem() {
            this.SecurityCard()
          }
          ListItem() {
            this.HistoryCard()
          }
          ListItem() {
            this.SwitchCard()
          }
          ListItem() {
            this.SignOutCard()
          }
          ListItem() {
            AppFooter()
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .padding({ left: 16, right: 16, bottom: Theme.tabBarInset })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
    })
  }

  /** 分组标题（同 iOS `Section("账号信息")` 那行小标题） */
  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(Theme.textFaint)
      .width('100%')
      .padding({ left: 4, top: 14, bottom: 6 })
  }

  // MARK: 账号总览

  @Builder
  OverviewCard() {
    Row({ space: 18 }) {
      Stack() {
        Text(Permissions.initialsOf(this.nickname()))
          .fontSize(27)
          .fontWeight(FontWeight.Bold)
          .fontColor('rgba(0, 0, 0, 0.75)')
        if (this.avatarUrl().length > 0) {
          RemoteImage({
            url: this.avatarUrl(),
            placeholderSymbol: $r('sys.symbol.person_crop_circle_fill')
          })
            .width(72)
            .height(72)
            .borderRadius(36)
            .clip(true)
        }
        if (this.avatarBusy) {
          Column()
            .width(72)
            .height(72)
            .borderRadius(36)
            .backgroundColor('rgba(0,0,0,0.55)')
          LoadingProgress()
            .width(24)
            .height(24)
            .color('#ffffff')
        }
      }
      .width(72)
      .height(72)
      .borderRadius(36)
      .linearGradient({
        angle: 180,
        colors: [[Theme.accentStrong, 0], [Theme.accent2, 1]]
      })
      .alignContent(Alignment.Center)
      .onClick(() => {
        this.pickAndUploadAvatar();
      })

      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.nickname())
            .fontSize(19)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.roleLabel())
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.accent)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(9)
        }
        Text(`@${this.username()}`)
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('点头像可从系统图库换一张')
          .fontSize(12)
          .fontColor(Theme.textFaint)
        if (this.avatarError.length > 0) {
          Text(this.avatarError)
            .fontSize(12)
            .fontColor(Theme.danger)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .alignItems(VerticalAlign.Center)
  }

  // MARK: 账号信息（昵称可改、用户名只读）

  @Builder
  AccountCard() {
    Column({ space: 12 }) {
      this.SectionTitle('账号信息')
      Column({ space: 12 }) {
        // 昵称：原地编辑（≤32 字）
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Text('昵称')
              .fontSize(15)
              .fontColor(Theme.text)
            Blank()
            if (this.editingNickname) {
              TextInput({ text: this.nicknameDraft, placeholder: '昵称' })
                .type(InputType.Normal)
                .textAlign(TextAlign.End)
                .maxLength(32)
                .layoutWeight(1)
                .height(38)
                .fontSize(15)
                .fontColor(Theme.text)
                .backgroundColor(Theme.surfaceRaised)
                .borderRadius(10)
                .padding({ left: 12, right: 12 })
                .onChange((value: string): void => {
                  this.nicknameDraft = value.length > 32 ? value.substring(0, 32) : value;
                })
                .onSubmit(() => {
                  this.saveNickname();
                })
            } else {
              Text(this.nickname())
                .fontSize(15)
                .fontColor(Theme.textMuted)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Button('编辑')
                .type(ButtonType.Capsule)
                .buttonStyle(ButtonStyleMode.NORMAL)
                .controlSize(ControlSize.SMALL)
                .fontSize(13)
                .backgroundColor(Theme.glassFill)
                .fontColor(Theme.text)
                .onClick(() => {
                  this.startEditNickname();
                })
            }
          }
          .width('100%')

          if (this.editingNickname) {
            Row({ space: 10 }) {
              Blank()
              Button('取消')
                .type(ButtonType.Capsule)
                .buttonStyle(ButtonStyleMode.NORMAL)
                .controlSize(ControlSize.SMALL)
                .fontSize(13)
                .backgroundColor(Theme.glassFill)
                .fontColor(Theme.text)
                .onClick(() => {
                  this.editingNickname = false;
                })
              Button(this.nicknameBusy ? '保存中…' : '保存')
                .type(ButtonType.Capsule)
                .buttonStyle(ButtonStyleMode.EMPHASIZED)
                .controlSize(ControlSize.SMALL)
                .fontSize(13)
                .backgroundColor(Theme.accent)
                .fontColor('#0b0d12')
                .enabled(!this.nicknameBusy)
                .onClick(() => {
                  this.saveNickname();
                })
            }
            .width('100%')
          }
          if (this.nicknameError.length > 0) {
            Text(this.nicknameError)
              .fontSize(12)
              .fontColor(Theme.danger)
              .width('100%')
              .textAlign(TextAlign.End)
          }
        }
        .width('100%')

        Divider().color(Theme.line)

        // 用户名：只读
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text('用户名')
              .fontSize(15)
              .fontColor(Theme.text)
            Text('登录凭证，不可修改')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.username())
            .fontSize(15)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
  }

  // MARK: 安全（改密码）

  @Builder
  SecurityCard() {
    Column({ space: 12 }) {
      this.SectionTitle('安全')
      Column({ space: 10 }) {
        TextInput({ text: this.oldPassword, placeholder: '当前密码' })
          .type(InputType.Password)
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string): void => {
            this.oldPassword = value;
            this.passwordError = '';
            this.passwordDone = '';
          })
        TextInput({ text: this.newPassword, placeholder: '新密码（至少 8 位）' })
          .type(InputType.Password)
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string): void => {
            this.newPassword = value;
            this.passwordError = '';
            this.passwordDone = '';
          })
        TextInput({ text: this.confirmPassword, placeholder: '确认新密码' })
          .type(InputType.Password)
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string): void => {
            this.confirmPassword = value;
            this.passwordError = '';
            this.passwordDone = '';
          })

        // 有配对的命令行 / 转码器才给这个勾选（原生开关）
        if (this.pairedCount > 0) {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(`同时注销命令行和转码器（${this.pairedCount} 台）`)
                .fontSize(15)
                .fontColor(Theme.text)
              Text('转码器常年无人值守，改密码一般不需要停掉它；怀疑密码泄露时请勾上')
                .fontSize(12)
                .fontColor(Theme.textFaint)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.signOutPaired })
              .selectedColor(Theme.accent)
              .onChange((isOn: boolean): void => {
                this.signOutPaired = isOn;
              })
          }
          .width('100%')
        }

        if (this.passwordError.length > 0) {
          Text(this.passwordError)
            .fontSize(12)
            .fontColor(Theme.danger)
            .width('100%')
        }
        if (this.passwordDone.length > 0) {
          Text(this.passwordDone)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .width('100%')
        }

        Row() {
          Blank()
          Button(this.passwordBusy ? '提交中…' : '修改密码')
            .type(ButtonType.Capsule)
            .buttonStyle(ButtonStyleMode.EMPHASIZED)
            .controlSize(ControlSize.NORMAL)
            .fontSize(15)
            .backgroundColor(Theme.accent)
            .fontColor('#0b0d12')
            .enabled(!this.passwordBusy && this.oldPassword.length > 0
              && this.newPassword.length > 0 && this.confirmPassword.length > 0)
            .onClick(() => {
              this.changePassword();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
  }

  // MARK: 观看历史

  @Builder
  HistoryCard() {
    Column({ space: 12 }) {
      this.SectionTitle('观看历史')
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('清空全部观看记录')
            .fontSize(15)
            .fontColor(Theme.text)
          Text('续播进度、已看标记与播放次数一并清除；单部作品或单个库的记录可在对应页面的 ⋯ 菜单里清')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button(this.clearing ? '清空中…' : '清空')
          .type(ButtonType.Capsule)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .controlSize(ControlSize.SMALL)
          .fontSize(13)
          .backgroundColor(Theme.glassFill)
          .fontColor(Theme.danger)
          .enabled(!this.clearing)
          .onClick(() => {
            this.confirmClearHistory();
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  // MARK: 切换账号 / 退出登录

  @Builder
  SwitchCard() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(18)
          .fontColor([Theme.text])
          .width(24)
        Text('切换账号')
          .fontSize(15)
          .fontColor(Theme.text)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .padding(16)
      // 上面那张卡的小标题给了 14 的顶部留白，这张卡没有小标题——补上同样的节奏，
      // 否则「观看历史」与「切换账号」两张卡会贴在一起（用户反馈「留的太窄」）
      .margin({ top: 18 })
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
      .onClick(() => {
        this.openSwitcher();
      })
      Text('长按底部的头像也能切换账号，双击头像切回上一个账号。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 4 })
    }
    .width('100%')
  }

  @Builder
  SignOutCard() {
    Text('退出登录')
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.danger)
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 15, bottom: 15 })
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
      .margin({ top: 14 })
      .onClick(() => {
        this.confirmSignOut();
      })
  }
}
