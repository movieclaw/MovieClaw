import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { GlassSwitchModifier } from '../common/GlassControls';
import { AppNavBar } from '../common/AppNavBar';
import { Permissions } from '../common/Permissions';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { TabBarStyle } from '../common/TabBarStyle';

/** 一个设置分区（对应 iOS `SettingsSection`） */
export class SettingsSection {
  readonly id: string;
  readonly title: string;
  readonly subtitle: string;
  readonly symbol: string;
  /** 仅超级管理员可见（iOS 的 `memberVisible`：只有「个人信息」与「设备」成员可见） */
  readonly adminOnly: boolean;
  /** 鸿蒙端还没做，去网页端管理 */
  readonly webOnly: boolean;

  constructor(id: string, title: string, subtitle: string, symbol: string,
    adminOnly: boolean = true, webOnly: boolean = false) {
    this.id = id;
    this.title = title;
    this.subtitle = subtitle;
    this.symbol = symbol;
    this.adminOnly = adminOnly;
    this.webOnly = webOnly;
  }
}

/** 一组分区（空标题的组不渲染组头） */
export class SettingsGroup {
  readonly title: string;
  readonly items: SettingsSection[];

  constructor(title: string, items: SettingsSection[]) {
    this.title = title;
    this.items = items;
  }
}

/**
 * 设置分区注册表，文案**逐条照抄** iOS `AppRoute.swift` 的 `SettingsSection`
 * （title / subtitle / systemImage），因为那些小字讲的是「这一区能解决什么」。
 *
 * `webOnly` 的几项对应 iOS 的 `availableInApp == false`：
 * **资源与下载的配置（订阅规则、资源站点、下载器、自动入库）与概览只在网页端管理**
 * （iOS 2026-09-29 的决定，为了降低审核按「便利文件共享」条款拒审的风险）。
 * iOS 的做法是设置首页**不列出**它们；这里也照做，所以下面看不到那几项。
 */
export class SettingsCatalog {
  static groups(): SettingsGroup[] {
    return [
      new SettingsGroup('账号', [
        new SettingsSection('devices', '设备',
          '登录着你的账号的浏览器、App、命令行与转码器', 'sys.symbol.display', false),
        new SettingsSection('members', '成员',
          '家庭成员账号、能力开关与可见范围', 'sys.symbol.person')
      ]),
      new SettingsGroup('媒体库', [
        new SettingsSection('scrape', '刮削与整理',
          '海报、简介、命名与目录整理的全局默认', 'sys.symbol.picture'),
        new SettingsSection('playback', '播放',
          '远程转码与播放体验', 'sys.symbol.play_circle')
      ]),
      new SettingsGroup('通知与集成', [
        new SettingsSection('im-push', '消息推送',
          '微信 / Telegram / Discord / 飞书 推送与 AI 对话', 'sys.symbol.bell'),
        new SettingsSection('webhook', 'Webhook',
          '向外部服务推送播放、收藏等事件', 'sys.symbol.paperplane'),
        new SettingsSection('llm', '模型接入',
          '接入 OpenAI、百炼等模型供应商，可同时接入多家', 'sys.symbol.star_fill'),
        new SettingsSection('mcp', 'MCP 服务',
          '把 MovieClaw 的能力开放给 Claude Code、Cursor 等 AI 客户端', 'sys.symbol.externaldrive'),
        new SettingsSection('ai', 'AI 设定',
          '智能体与字幕处理使用的默认模型', 'sys.symbol.wand_and_stars')
      ]),
      new SettingsGroup('系统', [
        new SettingsSection('app', '更新与维护',
          '版本更新与应用重启', 'sys.symbol.gearshape'),
        new SettingsSection('network', '网络',
          '代理、镜像与外部访问地址，解决 TMDB 等不可达', 'sys.symbol.house'),
        new SettingsSection('logs', '系统日志',
          '后端运行日志，按天存档', 'sys.symbol.rectangle_stack')
      ])
    ];
  }

  static find(id: string): SettingsSection | null {
    for (const group of SettingsCatalog.groups()) {
      for (const item of group.items) {
        if (item.id === id) {
          return item;
        }
      }
    }
    return null;
  }

  /**
   * 按身份过滤：成员只看得到「设备」（iOS 的 `memberVisible`）。
   * 顺带滤掉空组，免得留下一个只有标题的空壳。
   */
  static visibleGroups(isAdmin: boolean): SettingsGroup[] {
    const out: SettingsGroup[] = [];
    for (const group of SettingsCatalog.groups()) {
      const items: SettingsSection[] = [];
      for (const item of group.items) {
        if (isAdmin || !item.adminOnly) {
          items.push(item);
        }
      }
      if (items.length > 0) {
        out.push(new SettingsGroup(group.title, items));
      }
    }
    return out;
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function SettingsBuilder() {
  SettingsIndexPage()
}

/**
 * 设置首页（对应 iOS `SettingsIndexView`）。
 *
 * iOS 的组织方式照抄：**分组列表**，组头是「账号 / 媒体库 / 通知与集成 / 系统」，
 * 每行是「图标 + 标题 + 一行小字说这区能解决什么」。
 *
 * **「个人信息」不列在这里**——iOS 明确去掉了这个重复入口（2026-09-27 用户要求），
 * 入口是「我的」页顶部的头像卡。这一点已经在上一轮接好了。
 */
@ComponentV2
export struct SettingsIndexPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  /** 列表滚动器：标题栏的渐变模糊 / 滑动显隐靠它驱动（同根页签） */
  private scroller: Scroller = new Scroller();
  @Local private model: AppModel = AppModel.shared;
  /** 底栏样式单例：开关读写它，MainTabsPage 持有同一个例、底栏跟着重建 */
  @Local private tabBarStyle: TabBarStyle = TabBarStyle.shared();

  build() {
    HdsNavDestination() {
      Column() {
        // iOS「服务器设置」是 List + Section 的 insetGrouped 分组列表：每组一个圆角容器、
        // 组内多行、行间分隔线、组头 caption 小字。这里用华为 ArkUI 原生 List + ListItemGroup 还原同一观感。
        List({ space: 14, scroller: this.scroller }) {
          ForEach(SettingsCatalog.visibleGroups(this.isAdmin()), (group: SettingsGroup) => {
            ListItemGroup({
              header: group.title.length > 0 ? this.GroupHeader(group.title) : undefined,
              style: ListItemGroupStyle.NONE
            }) {
              ForEach(group.items, (item: SettingsSection) => {
                ListItem() {
                  this.SettingsRow(item)
                }
              }, (item: SettingsSection) => item.id)
            }
            // 行间分隔线，缩进到图标列（iOS 分割线默认对齐行内容）
            .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 54, endMargin: 16 })
            .borderRadius(Theme.cardRadius)
            // 朴素原生卡片：实色 surface + 细边框（第一步地基，不叠加毛玻璃/手工配色）
            .backgroundColor(Theme.surface)
            .border({ width: 1, color: Theme.line })
          }, (group: SettingsGroup) => group.title)
          // 「底栏样式」：悬浮胶囊 / 经典贴底栏两套并存，开关即时切换（本机偏好，重启保留）
          ListItemGroup({ style: ListItemGroupStyle.NONE }) {
            ListItem() {
              this.TabBarStyleRow()
            }
          }
          .borderRadius(Theme.cardRadius)
          .backgroundColor(Theme.surface)
          .border({ width: 1, color: Theme.line })
          // 「图标更换」：应用内图标选择（桌面图标鸿蒙不允许运行时更换，页内有说明）
          ListItemGroup({ style: ListItemGroupStyle.NONE }) {
            ListItem() {
              this.IconRow()
            }
          }
          .borderRadius(Theme.cardRadius)
          .backgroundColor(Theme.surface)
          .border({ width: 1, color: Theme.line })
          // 「关于 MovieClaw」：从「我的」页整体挪到本页最底部（用户要求），仍是设置里的一项
          ListItemGroup({ style: ListItemGroupStyle.NONE }) {
            ListItem() {
              this.AboutRow()
            }
          }
          .borderRadius(Theme.cardRadius)
          .backgroundColor(Theme.surface)
          .border({ width: 1, color: Theme.line })
          // 页脚：品牌联合声明，复用全局 AppFooter（包在 ListItem 里跟随滚动）
          ListItem() {
            AppFooter({ topSpace: 0 })
          }
        }
        .width('100%')
        .layoutWeight(1)
        // 内容从 y=0 铺到标题栏下面：首屏用 contentStartOffset 让开标题栏，滚动时产生渐变
        .contentStartOffset(AppNavBar.contentTop)
        .padding({ left: 16, right: 16, top: 8 })
        .contentEndOffset(Theme.tabBarInset)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      // 与全 App 一致的深色主题（Theme.*）：此前误用了 app.color.* 的浅色资源，整页和外面两个世界
      .backgroundColor(Theme.bg)
    }
    /*
     * 二级页标题栏：与根页签同一套「沉浸光感渐变模糊 + 自适应材质」（见 common/AppNavBar）。
     * 返回键与标题由官方 HdsNavDestination 渲染，滚动时标题栏从透明渐显磨砂。
     */
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(AppNavBar.subPageTitleBar('设置'))
    .bindToScrollable([this.scroller])
    .dynamicHideTitleBar(AppNavBar.dynamicHide())
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      this.started = true;

    })
  }

  /**
   * 组头：普通小字标题。
   *
   * **不用官方 `SubHeaderV2`**：它是列表小节头组件，自身带固定行高和内边距，
   * 再叠我们的上下留白后，两张分组卡之间会多出一大段空白（用户反馈「卡片中间间距有点大」）。
   * 这里用一行 13vp 的淡色标题 + 可控留白，间距与 App 其它小节头一致。
   */
  @Builder
  GroupHeader(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(Theme.textFaint)
      .width('100%')
      .padding({ left: 6, right: 6, top: 8, bottom: 6 })
  }

  /** 分组行：图标列 + 主标题 + 副标题（caption）+ 右箭头，与 iOS Label{ VStack } 一致。 */
  @Builder
  SettingsRow(item: SettingsSection) {
    Row({ space: 12 }) {
      SymbolGlyph(this.iconFor(item.symbol))
        .fontSize(18)
        .fontColor([Theme.accent2])
        .width(26)
      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(15)
          .fontColor(Theme.text)
        Text(item.subtitle)
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      this.navStack.pushPathByName('settingsSection', new SectionParams(item.id));
    })
  }

  /** 「底栏样式」行：开关即时切换（开 = 经典贴底栏，关 = 悬浮胶囊），改的是 TabBarStyle 单例 */
  @Builder
  TabBarStyleRow() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.rectangle_grid_2x1'))
        .fontSize(18)
        .fontColor([Theme.accent2])
        .width(26)
      Column({ space: 2 }) {
        Text('经典底栏')
          .fontSize(15)
          .fontColor(Theme.text)
        Text('开 = 通用的整宽贴底栏；关 = 悬浮胶囊（默认）')
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: !this.tabBarStyle.floating })
      .attributeModifier(new GlassSwitchModifier())
      .onChange((on: boolean): void => {
        TabBarStyle.shared().setFloating(!on);
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
  }

  /** 「图标更换」行：与「关于」行同一套排布（图标列 + 标题 + 副标题 + 箭头） */
  @Builder
  IconRow() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.picture'))
        .fontSize(18)
        .fontColor([Theme.accent2])
        .width(26)
      Column({ space: 2 }) {
        Text('图标')
          .fontSize(15)
          .fontColor(Theme.text)
        Text('选择应用内展示的图标（26 款设计）')
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      this.navStack.pushPathByName('iconPicker', null);
    })
  }

  /** 「关于 MovieClaw」行：与上面各分区同一套排布（图标列 + 标题 + 副标题 + 箭头） */
  @Builder
  AboutRow() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.film'))
        .fontSize(18)
        .fontColor([Theme.accent2])
        .width(26)
      Column({ space: 2 }) {
        Text('关于 MovieClaw')
          .fontSize(15)
          .fontColor(Theme.text)
        Text('版本与开源许可')
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      this.navStack.pushPathByName('about', null);
    })
  }

  /**
   * 图标按名字分派成**直接的 `$r(...)`**。
   *
   * 不能写成 `SymbolGlyph($r(item.symbol))`——那样传的是变量，**编译期不校验资源是否存在**，
   * 名字错了要到运行时才发现（图标位置空白，不报错）。
   */
  private iconFor(symbol: string): Resource {
    if (symbol === 'sys.symbol.bell') {
      return $r('sys.symbol.bell');
    }
    if (symbol === 'sys.symbol.chevron_left') {
      return $r('sys.symbol.chevron_left');
    }
    if (symbol === 'sys.symbol.chevron_right') {
      return $r('sys.symbol.chevron_right');
    }
    if (symbol === 'sys.symbol.display') {
      return $r('sys.symbol.display');
    }
    if (symbol === 'sys.symbol.gearshape') {
      return $r('sys.symbol.gearshape');
    }
    if (symbol === 'sys.symbol.house') {
      return $r('sys.symbol.house');
    }
    if (symbol === 'sys.symbol.paperplane') {
      return $r('sys.symbol.paperplane');
    }
    if (symbol === 'sys.symbol.person') {
      return $r('sys.symbol.person');
    }
    if (symbol === 'sys.symbol.picture') {
      return $r('sys.symbol.picture');
    }
    if (symbol === 'sys.symbol.play_circle') {
      return $r('sys.symbol.play_circle');
    }
    if (symbol === 'sys.symbol.externaldrive') {
      return $r('sys.symbol.externaldrive');
    }
    if (symbol === 'sys.symbol.star_fill') {
      return $r('sys.symbol.star_fill');
    }
    if (symbol === 'sys.symbol.rectangle_stack') {
      return $r('sys.symbol.rectangle_stack');
    }
    if (symbol === 'sys.symbol.wand_and_stars') {
      return $r('sys.symbol.wand_and_stars');
    }
    return $r('sys.symbol.gearshape');
  }

  private isAdmin(): boolean {
    return Permissions.fromSession(this.model.session).isAdmin;
  }
}

/** 分区页的路由参数（路由参数会序列化，不要用 instanceof） */export class SectionParams {
  readonly sectionId: string;

  constructor(sectionId: string) {
    this.sectionId = sectionId;
  }

  static of(param: Object | undefined | null): SectionParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: SectionParams = param as SectionParams;
    const id: string = raw.sectionId;
    if (id === undefined || id === null || id.length === 0) {
      return null;
    }
    return new SectionParams(id);
  }
}
