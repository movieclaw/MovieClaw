/**
 * 骨架阶段的占位数据。
 * 后续接入 FastAPI 后端时，这里的静态数组会替换为接口返回（见 lib/api/）。
 * 现在只为把布局与交互跑通，字段尽量贴近真实产品形态。
 */
import type { ComponentType, SVGProps } from "react";
import { appTranslator, type AppMessageKey } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import {
  GaugeIcon,
  BellBadgeIcon,
  BookmarkIcon,
  ChatBubblesIcon,
  CloudIcon,
  CloudDriveIcon,
  SparklesIcon,
  LaptopPhoneIcon,
  DownloadCircleIcon,
  FolderGearIcon,
  GearsIcon,
  GlobeIcon,
  PaletteIcon,
  AppBadgeIcon,
  PhotosStackIcon,
  PlayRectangleIcon,
  PaperplaneIcon,
  ServerIcon,
  MembersKeyIcon,
  TerminalIcon,
  WandIcon,
  UserCircleIcon,
  PlugIcon,
  PuzzleIcon,
} from "@/components/icons";

type Icon = ComponentType<SVGProps<SVGSVGElement>>;

/** 「探索」分组里的操作按钮 */
export interface ExploreItem {
  id: string;
  label: string;
  icon: Icon;
}

export const exploreItems = [
  { id: "discover", label: "nav.main.discover", icon: SparklesIcon },
] as const;

/** 最近会话（类 Codex / ChatGPT 的会话列表） */
export type RunStatus = "running" | "done" | "failed";

export interface RecentRun {
  id: string;
  title: string;
  preview: string;
  status: RunStatus;
  time: string;
}

export const recentRuns: RecentRun[] = [
  {
    id: "run-1",
    title: "追踪《沙丘 2》4K 资源",
    preview: "已在 3 个站点命中，正在校验做种健康度…",
    status: "running",
    time: "刚刚",
  },
  {
    id: "run-2",
    title: "订阅《幕府将军》全季",
    preview: "第 10 集已入库，等待字幕匹配。",
    status: "done",
    time: "12 分钟前",
  },
  {
    id: "run-3",
    title: "补齐《绝命毒师》缺失剧集",
    preview: "S02E07 未找到合适资源。",
    status: "failed",
    time: "1 小时前",
  },
  {
    id: "run-4",
    title: "每周热门电影自动巡检",
    preview: "已生成 8 条候选，全部确认入库。",
    status: "done",
    time: "昨天",
  },
  {
    id: "run-5",
    title: "订阅《怪奇物语》最终季",
    preview: "全季 8 集已入库，字幕匹配完成。",
    status: "done",
    time: "2 天前",
  },
  {
    id: "run-6",
    title: "清理低做种历史种子",
    preview: "已归档 23 个种子，释放 180GB。",
    status: "done",
    time: "3 天前",
  },
];

export const runStatusMeta: Record<RunStatus, { label: string; color: string }> = {
  running: { label: "运行中", color: "#6aa7ff" },
  done: { label: "已完成", color: "#4ade80" },
  failed: { label: "失败", color: "#ff6b6b" },
};

/** 设置页的分区（进入设置后替换左侧菜单） */
export interface SettingsSection {
  id: string;
  label: string;
  description: string;
  icon: Icon;
  /**
   * 依赖的扩展点：只有这个扩展点有插件登记（或已有它的数据）时才在侧栏出现
   * （docs/design/cloud-storage.md §11.7）。插件驱动的分区都用这个条件，网盘是第一个。
   */
  requires?: ExtensionPoint;
}

/** 设置分区可以依赖的扩展点（值与后端注册表名一致） */
export type ExtensionPoint = "drive-backends";

/** 设置分区的分组：侧栏按组渲染小节标题，组内顺序即展示顺序 */
export interface SettingsSectionGroup {
  label: string;
  items: SettingsSection[];
}

/**
 * 分组标准统一为「回答用户什么问题」：账号（我是谁、我在哪些设备上登录着）→
 * 成员（谁能进来）→ 资源与下载（内容怎么来）→ 媒体库（内容长什么样、怎么看）→
 * 通知与集成（系统怎么告诉外界）→ 系统（运维）。文件到手之前的事归「资源与下载」，
 * 到手之后归「媒体库」，这条边界决定了刮削、播放的归属。
 */
type SettingsSectionSpec = Omit<SettingsSection, "label" | "description"> & { label: AppMessageKey; description: AppMessageKey };
type SettingsGroupSpec = { label: AppMessageKey | ""; items: SettingsSectionSpec[] };

export const settingsSectionGroups: SettingsGroupSpec[] = [
  {
    // 概览不属于任何分组、不设组标题（侧栏对空标题不渲染小节头）：
    // 它是管理员进设置的落地页——未配齐必要件时是开局清单（哪些必须配、
    // 下一步做什么），配齐后是链路体检与更新提示，让问题主动找人，
    // 而不是让新手在十几个分区里翻。
    label: "",
    items: [
      {
        id: "overview",
        label: "settings.overview.title",
        description: "settings.overview.description",
        icon: GaugeIcon,
      },
    ],
  },
  {
    // 「设备」是每个人自己的登录设备（浏览器、App、命令行、转码器），属于
    // 「我在哪些地方登录着」，所以跟个人信息放在一起、对成员同样开放
    // （docs/design/login-devices.md §8）。「通知」同理：每个人自己选收哪些
    // 手机通知，成员只需要这一个入口，不用知道云和中继（docs/design/cloud-push.md §1）。
    label: "settings.groups.account",
    items: [
      { id: "profile", label: "settings.profile.title", description: "settings.profile.description", icon: UserCircleIcon },
      {
        id: "devices",
        label: "settings.devices.title",
        description: "settings.devices.description",
        icon: LaptopPhoneIcon,
      },
      {
        id: "notifications",
        label: "settings.notifications.title",
        description: "settings.notifications.description",
        icon: BellBadgeIcon,
      },
      { id: "appearance", label: "settings.appearance.title", description: "settings.appearance.description", icon: PaletteIcon },
    ],
  },
  {
    // 成员权限（能力开关 + 库/站点白名单）的写入口唯一在这里，库页面零改动
    // （docs/design/member-management.md §3.9.1）。
    label: "settings.groups.members",
    items: [
      { id: "members", label: "settings.members.title", description: "settings.members.description", icon: MembersKeyIcon },
    ],
  },
  {
    // 组内按资源接入链路排序：订阅规则（消费整条链路）→ 站点（含浏览器扩展
    // Cookie 同步）→ 下载器 → 自动入库（下载完成的收尾）。
    label: "settings.groups.downloads",
    items: [
      { id: "subscription", label: "settings.subscription.title", description: "settings.subscription.description", icon: BookmarkIcon },
      { id: "sites", label: "settings.sites.title", description: "settings.sites.description", icon: ServerIcon },
      { id: "downloaders", label: "settings.downloaders.title", description: "settings.downloaders.description", icon: DownloadCircleIcon },
      { id: "import-watch", label: "settings.importWatch.title", description: "settings.importWatch.description", icon: FolderGearIcon },
    ],
  },
  {
    // 刮削的每库级覆盖在「编辑库 → 刮削设置」里，这里是全局默认口味；
    // 「播放」按功能命名而非按当前唯一的实现叫「远程转码」——给未来的
    // 转码策略、字幕偏好等播放域设置留好家。
    label: "settings.groups.library",
    items: [
      { id: "scrape", label: "settings.scrape.title", description: "settings.scrape.description", icon: PhotosStackIcon },
      { id: "playback", label: "settings.playback.title", description: "settings.playback.description", icon: PlayRectangleIcon },
      {
        id: "drives",
        label: "settings.drives.title",
        description: "settings.drives.description",
        icon: CloudDriveIcon,
        requires: "drive-backends",
      },
    ],
  },
  {
    // 推人（App 推送、IM 推送）、推服务（Webhook）、AI 供应商接入，都是对外集成；
    // AI 紧挨着它最大的消费方（推送里的 AI 对话）。接入与设定是两件事：
    // 「模型接入」回答怎么连上，「AI 设定」回答什么场景用哪个模型。
    // App 推送管通道与设备覆盖，连接 MovieClaw Cloud 在「系统」组（cloud-push.md §0.1）。
    label: "settings.groups.integrations",
    items: [
      {
        id: "app-push",
        label: "settings.appPush.title",
        description: "settings.appPush.description",
        icon: AppBadgeIcon,
      },
      { id: "im-push", label: "settings.imPush.title", description: "settings.imPush.description", icon: ChatBubblesIcon },
      { id: "webhook", label: "settings.webhook.title", description: "settings.webhook.description", icon: PaperplaneIcon },
      { id: "llm", label: "settings.llm.title", description: "settings.llm.description", icon: SparklesIcon },
      { id: "mcp", label: "settings.mcp.title", description: "settings.mcp.description", icon: PlugIcon },
      { id: "ai", label: "settings.ai.title", description: "settings.ai.description", icon: WandIcon },
    ],
  },
  {
    // 装完配一次/出问题才碰的低频运维项，沉底。MovieClaw Cloud 是整台服务器的一次性
    // 连接，以后云端的能力（远程访问等）都挂在它下面，所以放这里而不是推送旁边。
    // 「插件」独立成分区：第三方插件的安装管理与内置插件的运行状态都在这里，
    // 不再藏在「更新与维护」的页签里（概念见 lib/plugins-display.ts 文件头）
    label: "settings.groups.system",
    items: [
      {
        id: "cloud",
        label: "settings.cloud.title",
        description: "settings.cloud.description",
        icon: CloudIcon,
      },
      { id: "app", label: "settings.app.title", description: "settings.app.description", icon: GearsIcon },
      {
        id: "plugins",
        label: "settings.plugins.title",
        description: "settings.plugins.description",
        icon: PuzzleIcon,
      },
      { id: "network", label: "settings.network.title", description: "settings.network.description", icon: GlobeIcon },
      { id: "logs", label: "settings.logs.title", description: "settings.logs.description", icon: TerminalIcon },
    ],
  },
];

/** 扁平分区列表：路由校验、默认分区等按 id 消费的场景继续用它 */
export const settingsSections = settingsSectionGroups.flatMap(
  (group) => group.items,
);

/** 成员可见的设置分区（其余分区后端一律 403，前端不给入口）。 */
const MEMBER_SECTION_IDS = new Set(["profile", "devices", "notifications", "appearance"]);

/**
 * 按角色过滤设置分区分组：管理员全量；成员只剩「账号」组的个人分区
 * （个人信息、自己的设备、通知、外观；概览呈现的是全局配置健康，属管理员视角，成员不可见）。
 * 这只是界面裁剪——安全边界在后端的 require_admin / 守护测试。
 *
 * ``active`` 是当前有登记的扩展点：依赖扩展点的分区只在扩展点有登记时出现；传 ``"all"`` 不按扩展点
 * 过滤（直接打开分区地址时照常进得去，不因为还没查完扩展点就跳走）。
 */
export function settingsSectionGroupsFor(
  role: "admin" | "member",
  active: ReadonlySet<ExtensionPoint> | "all" = new Set(),
  locale: AppLocale = "zh-Hans",
): SettingsSectionGroup[] {
  const t = appTranslator(locale);
  const groups = settingsSectionGroups.map((group) => ({
    label: group.label ? t(group.label) : "",
    items: group.items.map((section) => ({ ...section, label: t(section.label), description: t(section.description) })),
  }));
  if (role === "admin") {
    if (active === "all") return groups;
    return groups
      .map((group) => ({
        ...group,
        items: group.items.filter((s) => s.requires == null || active.has(s.requires)),
      }))
      .filter((group) => group.items.length > 0);
  }
  return groups
    .map((group) => ({
      ...group,
      items: group.items.filter((s) => MEMBER_SECTION_IDS.has(s.id)),
    }))
    .filter((group) => group.items.length > 0);
}
