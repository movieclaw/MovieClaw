import { display, promptAction } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { MemberCredentialDialog } from './MemberCredentialDialog';
import { SettingsSegmentChip, SettingsSwitchRow, SettingsTwoStateSegment } from '../common/SettingsControls';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import {
  LibraryView,
  MemberCreateRequest,
  MemberPasswordResetView,
  MemberStatusRequest,
  MemberUpdateRequest,
  MemberView, CatalogItem } from '../api/Models';

/**
 * `MemberUpdateRequest` **全是可选字段**，对象字面量会被 ArkTS 拒绝
 * （`arkts-no-untyped-obj-literals`），用类实现绕开。
 */
class MemberUpdateBody implements MemberUpdateRequest {
  nickname?: string | null;
  allow_subscribe?: boolean | null;
  allow_search?: boolean | null;
  allow_direct_download?: boolean | null;
  all_libraries?: boolean | null;
  library_ids?: number[] | null;
  all_sites?: boolean | null;
  site_ids?: string[] | null;
  /// 内容年龄上限；-1 = 取消上限，null = 不改动
  content_age_limit?: number | null;
  allow_unrated?: boolean | null;
}

/** 编辑面板里的一个多选 chip */
class ChipOption {
  readonly label: string;
  readonly key: string;
  readonly selected: boolean;

  constructor(label: string, key: string, selected: boolean) {
    this.label = label;
    this.key = key;
    this.selected = selected;
  }
}

/** 成员编辑弹层的模式 */
class MemberMode {
  static readonly create: string = 'create';
  static readonly edit: string = 'edit';
}

/**
 * 设置 → 成员（对应 iOS `MembersSettingsView` / Web `members-section`）：
 * 成员账号、能力与资源范围的唯一管理入口。
 *
 * iOS 的组织方式照抄：
 * - **列表只负责扫描状态**（头像、启用点、功能权限徽标、媒体库范围、最近活动），
 *   创建 / 编辑用**独立弹层**，避免在列表里展开长表单；
 * - **创建与重置产生的明文密码只在一次性结果弹层里出现**，关掉后前端不再保留
 *   ——与后端「仅返回一次」的凭据语义一致。
 *
 * **本轮先不做**：站点范围（`all_sites` / `site_ids`，要拉站点目录）、
 * 头像上传、内容年龄上限的细调。能力开关与媒体库范围做了。
 */
@ComponentV2
export struct MembersSection {
  @Local private members: MemberView[] = [];
  @Local private libraries: LibraryView[] = [];
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private busyId: number = 0;

  // 创建 / 编辑弹层
  @Local private sheetKind: string = '';
  @Local private showSheet: boolean = false;
  @Local private mode: string = MemberMode.create;
  @Local private formId: number = 0;
  @Local private formUsername: string = '';
  @Local private formPassword: string = '';
  @Local private formNickname: string = '';
  @Local private formSubscribe: boolean = true;
  @Local private formSearch: boolean = true;
  @Local private formDirectDownload: boolean = false;
  @Local private formAllLibraries: boolean = true;
  @Local private formLibraryIds: number[] = [];
  /** 可搜索站点（`siteCatalog`）与「全部 / 指定」两态 */
  @Local private catalog: CatalogItem[] = [];
  @Local private formAllSites: boolean = true;
  @Local private formSiteIds: string[] = [];
  /** 内容年龄上限；-1 = 不限（协议里 -1 = 取消上限，null = 不改动） */
  @Local private formAgeLimit: number = -1;
  /** 编辑态的身份卡要显示头像/状态：保存一下被编辑的成员 */
  private editTarget: MemberView | null = null;
  @Local private formAllowUnrated: boolean = false;
  /** 一次性凭据弹窗（新成员密码 / 重置后的新密码）：与批准登录同一套原生弹窗 */
  @Local private credentialDialogId: number = -1;
  @Local private credentialTitle: string = '';
  @Local private credentialUsername: string = '';
  @Local private credentialPassword: string = '';
  @Local private formSaving: boolean = false;
  @Local private formError: string = '';

  /** 一次性明文密码（关掉即丢，前端不再保留） */


  private started: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 取数

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    try {
      this.members = await api.membersList();
      this.libraries = await api.libraryList();
      this.catalog = await api.siteCatalog();
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

  // MARK: 派生

  private isEnabled(member: MemberView): boolean {
    return member.status === 'active' || member.status === 'enabled';
  }

  /** 能力徽标（对应 iOS 的功能权限徽标） */
  private badges(member: MemberView): string[] {
    const out: string[] = [];
    if (member.allow_subscribe) {
      out.push('订阅');
    }
    if (member.allow_search) {
      out.push('搜索');
    }
    if (member.allow_direct_download) {
      out.push('直接下载');
    }
    return out;
  }

  /** 媒体库范围（对应 iOS 的媒体库范围小字） */
  private scopeText(member: MemberView): string {
    if (member.all_libraries) {
      return '全部媒体库';
    }
    const count: number = member.library_ids.length;
    return count === 0 ? '未分配媒体库' : `${count} 个媒体库`;
  }

  private activityText(member: MemberView): string {
    const last: string | null = member.last_login_at ?? null;
    const seen: string = last === null || last.length === 0
      ? '从未登录' : `最近 ${Formatters.relative(last)}`;
    return member.device_count > 0 ? `${seen}  ·  ${member.device_count} 台设备` : seen;
  }

  private initials(member: MemberView): string {
    const name: string = member.nickname.length > 0 ? member.nickname : member.username;
    return name.length > 0 ? name.substring(0, 1).toUpperCase() : '?';
  }

  /**
   * 成员的头像（对应 iOS 成员行 `AvatarBadge(session: nil, avatarUrl: member.avatarUrl, size: 38)`）。
   * 成员不是本机登录的账号，但头像同样走服务器的图片接口，一样要用 `ImageUrls.resolve` 拼 origin。
   */
  private avatarUrlOf(member: MemberView): string {
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), member.avatar_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  // MARK: 弹层

  private openCreate(): void {
    this.mode = MemberMode.create;
    this.formId = 0;
    this.formUsername = '';
    this.formPassword = '';
    this.formNickname = '';
    this.formSubscribe = true;
    this.formSearch = true;
    this.formDirectDownload = false;
    this.formAllLibraries = true;
    this.formLibraryIds = [];
    this.formAllSites = true;
    this.formSiteIds = [];
    this.formAgeLimit = -1;
    this.formAllowUnrated = false;
    this.formError = '';
    this.sheetKind = 'editor';
    this.showSheet = true;
  }

  private openEdit(member: MemberView): void {
    this.mode = MemberMode.edit;
    this.editTarget = member;
    this.formId = member.id;
    this.formUsername = member.username;
    this.formPassword = '';
    this.formNickname = member.nickname;
    this.formSubscribe = member.allow_subscribe;
    this.formSearch = member.allow_search;
    this.formDirectDownload = member.allow_direct_download;
    this.formAllLibraries = member.all_libraries;
    this.formLibraryIds = member.library_ids.slice();
    this.formAllSites = member.all_sites;
    this.formSiteIds = member.site_ids.slice();
    this.formAgeLimit = member.content_age_limit ?? -1;
    this.formAllowUnrated = member.allow_unrated;
    this.formError = '';
    this.sheetKind = 'editor';
    this.showSheet = true;
  }

  private async saveForm(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.formSaving) {
      return;
    }
    if (this.mode === MemberMode.create) {
      if (this.formUsername.trim().length === 0 || this.formPassword.length === 0) {
        this.formError = '用户名与密码都要填';
        return;
      }
    }
    this.formSaving = true;
    this.formError = '';
    try {
      if (this.mode === MemberMode.create) {
        // `MemberCreateRequest` 只收用户名 / 密码 / 昵称——能力与范围是**建完再改**的，
        // 所以创建是两步：建账号 → 用 Update 设能力。别指望一次建到位。
        const body: MemberCreateRequest = {
          username: this.formUsername.trim(),
          password: this.formPassword,
          nickname: this.formNickname.trim().length > 0 ? this.formNickname.trim() : null
        };
        const created: MemberView = await api.membersCreate(body);
        await api.membersUpdate(created.id, this.updateBody());
        this.showSheet = false;
        // 明文密码只在这里出现一次（后端也是「仅返回一次」的语义）→ 用原生弹窗给
        const createdPassword: string = this.formPassword;
        const createdUsername: string = created.username;
        const createdName: string = created.nickname.length > 0 ? created.nickname : created.username;
        await this.load();
        this.openCredentialDialog(`「${createdName}」的密码`, createdUsername, createdPassword);
      } else {
        await api.membersUpdate(this.formId, this.updateBody());
        this.showSheet = false;
        this.toast('已保存');
        await this.load();
      }
    } catch (error) {
      this.formError = this.messageOf(error);
    } finally {
      this.formSaving = false;
    }
  }

  /** 能力与范围（创建第二步与编辑共用） */
  private updateBody(): MemberUpdateRequest {
    const body: MemberUpdateBody = new MemberUpdateBody();
    body.nickname = this.formNickname.trim().length > 0 ? this.formNickname.trim() : null;
    body.allow_subscribe = this.formSubscribe;
    body.allow_search = this.formSearch;
    // 一键下载依赖资源搜索（iOS 同口径：没开搜索就不能下载）
    body.allow_direct_download = this.formSearch && this.formDirectDownload;
    // 「全部库」时只保留「指定成员」库的显式授权，不能当白名单一起清掉；
    // 库清单里没有的 id（刚建的库）一律原样保留，宁可多留不误删授权
    const selectedModeIds: number[] = [];
    for (const library of this.libraries) {
      if (library.access_mode === 'selected') {
        selectedModeIds.push(library.id);
      }
    }
    if (this.formAllLibraries) {
      const kept: number[] = [];
      for (const id of this.formLibraryIds) {
        if (selectedModeIds.indexOf(id) >= 0) {
          kept.push(id);
          continue;
        }
        let known: boolean = false;
        for (const library of this.libraries) {
          if (library.id === id) {
            known = true;
            break;
          }
        }
        if (!known) {
          kept.push(id);
        }
      }
      body.library_ids = kept;
    } else {
      body.library_ids = this.formLibraryIds;
    }
    body.all_sites = this.formAllSites;
    body.site_ids = this.formAllSites ? [] : this.formSiteIds;
    // -1 = 取消上限；null 是「不改动」，两者在协议上必须分开
    body.content_age_limit = this.formAgeLimit;
    body.allow_unrated = this.formAllowUnrated;
    return body;
  }

  private confirmResetPassword(member: MemberView): void {
    this.getUIContext().showAlertDialog({
      title: '重置密码',
      message: `给「${member.nickname.length > 0 ? member.nickname : member.username}」生成一个新密码？`
        + '新密码只显示一次，关掉就看不到了；旧密码立即失效。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '重置',
        action: (): void => {
          this.resetPassword(member);
        }
      }
    });
  }

  private async resetPassword(member: MemberView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = member.id;
    try {
      const result: MemberPasswordResetView = await api.membersPasswordReset(member.id);
      this.openCredentialDialog(`「${member.nickname.length > 0 ? member.nickname : member.username}」的新密码`,
        member.username, result.password);
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = 0;
    }
  }

  private confirmToggleStatus(member: MemberView): void {
    const enabled: boolean = this.isEnabled(member);
    const name: string = member.nickname.length > 0 ? member.nickname : member.username;
    this.getUIContext().showAlertDialog({
      title: enabled ? '停用成员' : '启用成员',
      message: enabled
        ? `停用「${name}」后它立刻登不上，已登录的设备也会被断开。`
        : `启用「${name}」，它就可以重新登录了。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: enabled ? '停用' : '启用',
        fontColor: enabled ? Theme.danger : Theme.accent,
        action: (): void => {
          this.setStatus(member, !enabled);
        }
      }
    });
  }

  private async setStatus(member: MemberView, enabled: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = member.id;
    try {
      const body: MemberStatusRequest = { enabled: enabled };
      await api.membersStatusSet(member.id, body);
      this.toast(enabled ? '已启用' : '已停用');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = 0;
    }
  }

  /** 让某成员的所有设备下线（对应后端 `membersSignOut`） */
  private confirmSignOut(member: MemberView): void {
    this.getUIContext().showAlertDialog({
      title: '让它的设备下线',
      message: '这个成员登录着的浏览器、App、命令行会全部退出，需要重新登录。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '全部下线',
        action: (): void => {
          this.signOut(member);
        }
      }
    });
  }

  private async signOut(member: MemberView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = member.id;
    try {
      await api.membersSignOut(member.id);
      this.toast('已全部下线');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = 0;
    }
  }

  private confirmDelete(member: MemberView): void {
    const name: string = member.nickname.length > 0 ? member.nickname : member.username;
    this.getUIContext().showAlertDialog({
      title: '删除成员',
      message: `删除「${name}」？这个账号会消失，它登录的设备一并断开。`
        + '它看过的记录与播放进度不受影响。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: (): void => {
          this.remove(member);
        }
      }
    });
  }

  private async remove(member: MemberView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = member.id;
    try {
      await api.membersDelete(member.id);
      this.toast('已删除');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = 0;
    }
  }

  // MARK: 视图

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载成员…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            this.Header()
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage).fontSize(13).fontColor(Theme.danger).width('100%')
            }
            if (this.members.length === 0) {
              this.EmptyState()
            } else {
              this.MemberList()
            }
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
    /*
       * **一个组件只能绑一个 `bindSheet`**（后绑的覆盖前面的）。这里原本绑了两个，
       * 所以其中一个弹层一直打不开——合成单槽位 + 内容切换。
       */
      .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 页头：一句说明 + 「添加成员」（对应 iOS 的那一行） */
  @Builder
  Header() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('成员账号')
          .fontSize(15)
          .fontColor(Theme.text)
        Text('管理登录状态、功能权限和可见媒体库')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('添加成员')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0b0d12')
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor(Theme.accent)
        .borderRadius(16)
        .onClick(() => {
          this.openCreate();
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  EmptyState() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.person'))
        .fontSize(30)
        .fontColor([Theme.textFaint])
      Text('还没有成员')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('添加成员后，可以单独控制它能看到哪些媒体库、能不能订阅与搜索。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 50 })
    .justifyContent(FlexAlign.Center)
  }

  /** 列表：卡片上半是身份信息（右上是最近活动），下半是操作条（横线隔开、竖线分格） */
  @Builder
  MemberList() {
    Column() {
      ForEach(this.members, (member: MemberView, index: number) => {
        Column() {
          Row({ space: 12 }) {
            Stack() {
              // 底层：首字（iOS `AvatarBadge` 同款，没设头像或图还没下来时就是这一版）
              Text(this.initials(member))
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('rgba(0, 0, 0, 0.75)')
              // 上层：有头像就盖上去（iOS `AvatarBadge` 的 `if url != nil { RemoteImage(...) }`）
              if (this.avatarUrlOf(member).length > 0) {
                RemoteImage({
                  url: this.avatarUrlOf(member),
                  placeholderSymbol: $r('sys.symbol.person_crop_circle_fill')
                })
                  .width(38)
                  .height(38)
                  .borderRadius(19)
                  .clip(true)
              }
            }
            .width(38)
            .height(38)
            .borderRadius(19)
            .backgroundColor(this.isEnabled(member) ? Theme.accent2 : Theme.textFaint)
            .alignContent(Alignment.Center)

            Column({ space: 3 }) {
              Row({ space: 6 }) {
                Text(member.nickname.length > 0 ? member.nickname : member.username)
                  .fontSize(16)
                  .fontColor(this.isEnabled(member) ? Theme.text : Theme.textFaint)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.isEnabled(member)) {
                  Circle().width(6).height(6).fill(Theme.ok)
                } else {
                  Text('已停用')
                    .fontSize(10)
                    .fontColor(Theme.textFaint)
                    .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                    .backgroundColor(Theme.glassFill)
                    .borderRadius(5)
                }
              }
              Text(`@${member.username}`)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              // 能力徽标 + 媒体库范围
              Row({ space: 5 }) {
                ForEach(this.badges(member), (badge: string) => {
                  Text(badge)
                    .fontSize(10)
                    .fontColor(Theme.accent2)
                    .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                    .backgroundColor(Theme.glassFill)
                    .borderRadius(5)
                }, (badge: string) => badge)
                Text(this.scopeText(member))
                  .fontSize(10)
                  .fontColor(Theme.textFaint)
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 右上角原来是 ⋯ 按钮：现在显示最近活动（用户要求），忙碌时就地转圈
            if (this.busyId === member.id) {
              LoadingProgress().width(16).height(16).color(Theme.textMuted)
            } else {
              Text(this.activityText(member))
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .textAlign(TextAlign.End)
                .maxLines(1)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 14, right: 14, top: 12, bottom: 10 })

          // 横线：身份信息与操作条之间
          Divider().color(Theme.line)

          // 操作条：原来 ⋯ 菜单里的五项平铺在卡片底部，竖线分格
          Row() {
            this.MemberAction('编辑', this.isEnabled(member) ? Theme.text : Theme.textMuted, (): void => {
              this.openEdit(member);
            })
            this.ActionDivider()
            this.MemberAction('重置密码', Theme.text, (): void => {
              this.confirmResetPassword(member);
            })
            this.ActionDivider()
            this.MemberAction(this.isEnabled(member) ? '停用' : '启用', Theme.text, (): void => {
              this.confirmToggleStatus(member);
            })
            this.ActionDivider()
            this.MemberAction('让设备下线', Theme.text, (): void => {
              this.confirmSignOut(member);
            })
            this.ActionDivider()
            this.MemberAction('删除', Theme.danger, (): void => {
              this.confirmDelete(member);
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (index < this.members.length - 1) {
            Divider().color(Theme.line).margin({ left: 14, right: 14 })
          }
        }
        .width('100%')
      }, (member: MemberView) => `${member.id}`)
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 操作条里的一项（等分占满整行） */
  @Builder
  MemberAction(label: string, color: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(color)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .layoutWeight(1)
      .padding({ top: 11, bottom: 11 })
      .onClick((): void => {
        action();
      })
  }

  /** 操作项之间的竖线 */
  @Builder
  ActionDivider() {
    Divider()
      .vertical(true)
      .strokeWidth(0.5)
      .color(Theme.line)
      .height(16)
  }

  // MARK: 创建 / 编辑弹层

  /** 唯一的弹层内容：按 sheetKind 切换 */
  @Builder
  SheetContent() {
    this.EditorSheet()
  }

  /** 编辑 / 添加成员（**逐节照 iOS `EditMemberSheet`**）：身份信息 → 基本信息 → 功能权限 → 内容分级 → 媒体库范围 →（开了搜索才有的）可搜索站点 */
  @Builder
  EditorSheet() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick(() => {
            this.showSheet = false;
          })
        Blank()
        Text(this.mode === MemberMode.create ? '添加成员' : '编辑成员')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Blank()
        Text(this.formSaving ? '保存中…' : '保存设置')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.formSaving ? Theme.textFaint : Theme.accentStrong)
          .height(40)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (!this.formSaving) {
              this.saveForm();
            }
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })

      Scroll() {
        Column({ space: 14 }) {
          if (this.formError.length > 0) {
            Text(this.formError).fontSize(13).fontColor(Theme.danger).width('100%')
          }

          // ① 身份卡（编辑态）：头像 + 昵称 + @用户名 + 状态
          if (this.mode === MemberMode.edit && this.editTarget !== null) {
            Row({ space: 12 }) {
              Stack() {
                Text(this.initials(this.editTarget))
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('rgba(0, 0, 0, 0.75)')
                if (this.avatarUrlOf(this.editTarget).length > 0) {
                  RemoteImage({
                    url: this.avatarUrlOf(this.editTarget),
                    placeholderSymbol: $r('sys.symbol.person_crop_circle_fill')
                  })
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .clip(true)
                }
              }
              .width(44)
              .height(44)
              .borderRadius(22)
              .backgroundColor(this.isEnabled(this.editTarget) ? Theme.accent2 : Theme.textFaint)
              .alignContent(Alignment.Center)

              Column({ space: 2 }) {
                Text(this.editTarget.nickname.length > 0 ? this.editTarget.nickname : this.editTarget.username)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text)
                Text(`@${this.editTarget.username}`)
                  .fontSize(12)
                  .fontColor(Theme.textMuted)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text(this.isEnabled(this.editTarget) ? '已启用' : '已停用')
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isEnabled(this.editTarget) ? Theme.ok : Theme.textFaint)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(this.isEnabled(this.editTarget)
                  ? 'rgba(74, 222, 128, 0.1)' : Theme.glassFill)
                .borderRadius(12)
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }

          // ② 基本信息
          Column({ space: 6 }) {
            Text('基本信息')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4 })
            Column({ space: 10 }) {
              if (this.mode === MemberMode.create) {
                this.Field('用户名', this.formUsername, '小写字母、数字', true, (v: string): void => {
                  this.formUsername = v;
                })
                this.Field('初始密码', this.formPassword, '创建后只显示这一次', true, (v: string): void => {
                  this.formPassword = v;
                })
              } else {
                this.Field('用户名', this.formUsername, '', false, (v: string): void => {
                })
              }
              this.Field('昵称', this.formNickname, '留空就用用户名', true, (v: string): void => {
                this.formNickname = v;
              })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // ③ 功能权限（一键下载依赖资源搜索）
          Column({ space: 6 }) {
            Text('功能权限')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4 })
            Column({ space: 0 }) {
              SettingsSwitchRow({
                title: '订阅追踪', hint: '发起订阅并管理自己的订阅', value: this.formSubscribe,
                onToggle: (v: boolean): void => {
                  this.formSubscribe = v;
                }
              })
              Divider().color(Theme.line).margin({ left: 16, right: 16 })
              SettingsSwitchRow({
                title: '资源搜索', hint: '搜索被分配的 PT 站点上的种子资源', value: this.formSearch,
                onToggle: (v: boolean): void => {
                  this.formSearch = v;
                  // 关掉搜索就一并关掉一键下载（iOS 同口径）
                  if (!v) {
                    this.formDirectDownload = false;
                  }
                }
              })
              Divider().color(Theme.line).margin({ left: 16, right: 16 })
              SettingsSwitchRow({
                title: '一键下载',
                hint: '从搜索结果直接提交下载、给自己的订阅手动选种',
                value: this.formDirectDownload,
                disabled: !this.formSearch,
                onToggle: (v: boolean): void => {
                  this.formDirectDownload = v;
                }
              })
            }
            .width('100%')
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
            Text('关闭后相关入口会从成员页面隐藏，后端同时拒绝调用。')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4, right: 4 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // ④ 内容分级
          Column({ space: 6 }) {
            Text('内容分级')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4 })
            Column({ space: 10 }) {
              this.Chips(this.ageOptions(), (key: string): void => {
                this.formAgeLimit = key === 'any' ? -1 : Number(key);
                if (this.formAgeLimit < 0) {
                  this.formAllowUnrated = false;
                }
              })
              if (this.formAgeLimit >= 0) {
                Divider().color(Theme.line)
                SettingsSwitchRow({
                  title: '未分级的作品也给看',
                  hint: '默认一并隐藏——「不确定的一律不给看」更稳妥',
                  value: this.formAllowUnrated,
                  onToggle: (v: boolean): void => {
                    this.formAllowUnrated = v;
                  }
                })
              }
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
            Text('给孩子用的档案设一个年龄上限：超过这个分级的作品在海报墙、搜索、合集、播放器和详情页都看不到，直接改地址栏也进不去。')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4, right: 4 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // ⑤ 媒体库范围
          Column({ space: 6 }) {
            Text('媒体库范围')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4 })
            Column({ space: 10 }) {
              SettingsTwoStateSegment({
                leftLabel: '全部媒体库', rightLabel: '指定媒体库', leftSelected: this.formAllLibraries,
                onPick: (left: boolean): void => {
                  this.formAllLibraries = left;
                }
              })
              if (!this.formAllLibraries) {
                this.Chips(this.libraryOptions(), (key: string): void => {
                  this.toggleLibrary(Number(key));
                })
              }
              // 「全部库」时，「指定成员」的库仍要单独勾选
              if (this.formAllLibraries && this.selectedModeLibraries().length > 0) {
                Text('指定成员的库（需单独勾选）')
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
                  .width('100%')
                this.Chips(this.selectedModeLibraryOptions(), (key: string): void => {
                  this.toggleLibrary(Number(key));
                })
              }
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
            Text('「全部媒体库」自动包含对所有成员开放的库，含以后新建的；「指定成员」的库需要单独勾选。')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 4, right: 4 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // ⑥ 可搜索站点（只有开了资源搜索才有意义）
          if (this.formSearch) {
            Column({ space: 6 }) {
              Text('可搜索站点')
                .fontSize(13)
                .fontColor(Theme.textFaint)
                .width('100%')
                .padding({ left: 4 })
              Column({ space: 10 }) {
                SettingsTwoStateSegment({
                  leftLabel: '全部启用站点', rightLabel: '指定站点', leftSelected: this.formAllSites,
                  onPick: (left: boolean): void => {
                    this.formAllSites = left;
                  }
                })
                if (!this.formAllSites) {
                  if (this.catalog.length === 0) {
                    Text('暂无可选项')
                      .fontSize(12)
                      .fontColor(Theme.textFaint)
                      .width('100%')
                  } else {
                    this.Chips(this.siteOptions(), (key: string): void => {
                      this.toggleSite(key);
                    })
                  }
                }
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Theme.surface)
              .borderRadius(Theme.cardRadius)
              .border({ width: 1, color: Theme.line })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 28 })
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  // MARK: 编辑面板的小控件

  /** 年龄上限候选（对应 iOS `ageLimits`） */
  private ageOptions(): ChipOption[] {
    const out: ChipOption[] = [];
    out.push(new ChipOption('不限', 'any', this.formAgeLimit < 0));
    const values: number[] = [6, 12, 16, 18];
    for (const value of values) {
      out.push(new ChipOption(`${value} 岁以下`, `${value}`, this.formAgeLimit === value));
    }
    return out;
  }

  private libraryOptions(): ChipOption[] {
    const out: ChipOption[] = [];
    for (const library of this.libraries) {
      out.push(new ChipOption(library.name, `${library.id}`,
        this.formLibraryIds.indexOf(library.id) >= 0));
    }
    return out;
  }

  /** 「指定成员」可见的库（即使是「全部库」也要单独勾选） */
  private selectedModeLibraries(): LibraryView[] {
    const out: LibraryView[] = [];
    for (const library of this.libraries) {
      if (library.access_mode === 'selected') {
        out.push(library);
      }
    }
    return out;
  }

  private selectedModeLibraryOptions(): ChipOption[] {
    const out: ChipOption[] = [];
    for (const library of this.selectedModeLibraries()) {
      out.push(new ChipOption(`${library.name} · 指定成员`, `${library.id}`,
        this.formLibraryIds.indexOf(library.id) >= 0));
    }
    return out;
  }

  private siteOptions(): ChipOption[] {
    const out: ChipOption[] = [];
    for (const site of this.catalog) {
      out.push(new ChipOption(site.display_name, site.site_id,
        this.formSiteIds.indexOf(site.site_id) >= 0));
    }
    return out;
  }

  private toggleSite(siteId: string): void {
    const at: number = this.formSiteIds.indexOf(siteId);
    if (at >= 0) {
      this.formSiteIds.splice(at, 1);
    } else {
      this.formSiteIds.push(siteId);
    }
  }

  /** 多选 chips（选中 = 强调底 + 描边，同 iOS `MemberChip`） */
  @Builder
  Chips(options: ChipOption[], onPick: (key: string) => void) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(options, (option: ChipOption) => {
        Text(option.label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(option.selected ? Theme.accent : Theme.textMuted)
          .maxLines(1)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(option.selected ? Theme.accentSoft : 'rgba(255, 255, 255, 0.035)')
          .borderRadius(9)
          .border({
            width: 1,
            color: option.selected ? 'rgba(205, 214, 230, 0.5)' : Theme.line
          })
          .margin({ right: 8, bottom: 8 })
          .onClick((): void => {
            onPick(option.key);
          })
      }, (option: ChipOption): string => `chip-${option.key}-${option.selected}`)
    }
    .width('100%')
  }

  // MARK: 一次性凭据弹窗（与批准登录同一套原生弹窗）

  private openCredentialDialog(title: string, username: string, password: string): void {
    this.credentialTitle = title;
    this.credentialUsername = username;
    this.credentialPassword = password;
    const screenWidthVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    const options: promptAction.CustomDialogOptions = {
      builder: (): void => {
        this.CredentialCard();
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
        this.credentialDialogId = id;
      })
      .catch((): void => {
        this.credentialDialogId = -1;
      });
  }

  @Builder
  CredentialCard() {
    MemberCredentialDialog({
      title: this.credentialTitle,
      username: this.credentialUsername,
      password: this.credentialPassword,
      onClose: (): void => {
        if (this.credentialDialogId >= 0) {
          this.getUIContext().getPromptAction().closeCustomDialog(this.credentialDialogId);
          this.credentialDialogId = -1;
        }
      }
    })
  }

  private toggleLibrary(id: number): void {
    const at: number = this.formLibraryIds.indexOf(id);
    if (at >= 0) {
      this.formLibraryIds.splice(at, 1);
    } else {
      this.formLibraryIds.push(id);
    }
  }

  @Builder
  Field(label: string, value: string, hint: string, editable: boolean, onChange: (v: string) => void) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
      if (editable) {
        TextInput({ text: value, placeholder: hint })
          .width('100%')
          .height(42)
          .fontSize(15)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((v: string): void => {
            onChange(v);
          })
      } else {
        Text(value.length > 0 ? value : '—')
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .width('100%')
          .padding({ top: 10, bottom: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
