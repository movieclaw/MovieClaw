/**
 * 主题 SDK（`@movieclaw/theme-sdk`）——主题能碰到的全部内核能力，就是这一个文件
 * （docs/design/theme-plugins.md §4.1、§5.2）。
 *
 * 纪律：
 * - 主题代码只许 import react / react-dom / next/link / next/navigation / 本 SDK
 *   （主题构建器 theme-sdk/build.mjs 守着：引了别的直接构建失败）；内核其余模块对主题不可见；
 * - 这里只做转出口，不写实现：实现留在内核原处，内核自己也照常用；
 * - 加出口 = 契约次版本；删 / 改签名 = 主版本。出口按「主题外框真用到的」收，不预先铺开；
 * - 出口清单由导出快照测试守着（test/theme-sdk-surface.test.mjs），改这里要一并更新快照。
 */

// —— 主题定义与坑位 props ——
export type {
  DesktopTopNavProps,
  DetailNavProps,
  MobileSettingsNavProps,
  PageActionsProps,
  ThemeDefinition,
  ThemePages,
  ThemeSlots,
} from "@/themes/types";
export type { SettingsSidebarProps } from "@/components/settings-view";

// —— 外壳 ——
export { PAGE_NAV_BUTTON_SIZE_CLASS, PageNav } from "@/components/page-nav";
export { usePageChrome } from "@/lib/page-chrome";
export { useIsMobile } from "@/lib/use-media-query";
export { useScrollRestoration } from "@/lib/use-scroll-restoration";
export { useThemeState, useUiPrefs } from "@/lib/ui-prefs";
export { settingsSectionGroupsFor } from "@/lib/mock-data";

// —— 导航 ——
export { usePluginNavItems } from "@/components/sidebar";
export { useAppNavLinks } from "@/lib/plugin-apps-context";

// —— 账户与权限 ——
export { signOut } from "@/lib/account-reload";
export { useSession } from "@/lib/session";
export { accessiblePathFor, usePermissions } from "@/lib/permissions";
export { AccountSwitcherDialog } from "@/components/account-switcher-dialog";
export { AvatarBadge } from "@/components/avatar-badge";

// —— 搜索 ——
export { SearchCommand, type SearchSubmitOptions } from "@/components/search-command";
export type { SearchScope } from "@/lib/categories";
export { useSearchAccess } from "@/lib/search-access";

// —— 通知、任务与更新 ——
export { NoticeCenter } from "@/components/notice-center";
export { AppUpdateDot, AppUpdateEntry, usePendingUpdate } from "@/components/app-update-entry";
export { taskActivityBadge, useTaskActivity, type TaskActivityBadge } from "@/lib/task-activity";
export { useAgentConversations } from "@/lib/agent-conversations";

// —— 媒体与图片 ——
export { PosterImage } from "@/components/poster-image";
export {
  IMAGE_ASPECT,
  imageUrl,
  responsiveImage,
  tmdbImageForWidth,
  withImageWidth,
} from "@/lib/image-proxy";
export { useElementCoverWidth } from "@/lib/image-resolution";

// —— 媒体库与续播 ——
export { listLibraries, listLibraryItems, type LibraryItem } from "@/lib/api/libraries";
export { listUpNext, type UpNextItem } from "@/lib/api/playback";

// —— 订阅与下载 ——
export { checkSubscriptionAutomationReadiness, type Subscription } from "@/lib/api/subscriptions";
export type { SubscriptionFilter } from "@/lib/subscription-overview";
export { subscriptionFullyCollected, type TodayArrivalGroup } from "@/lib/subscription-ui";
export { useTodayArrivalGroups, useTodaySubscriptionArrivals } from "@/lib/use-today-arrivals";
export { MediaTypeSwitcher, SubscriptionCell } from "@/components/subscriptions-view";
export { useSubscribeEntry } from "@/components/subscribe-entry";
export { useDownloadTasks } from "@/lib/download-tasks";

// —— 原件 ——
export {
  ActivityIcon,
  BookmarkFillIcon,
  ChevronDownIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  GearIcon,
  InfoIcon,
  LibraryStackIcon,
  LogoutIcon,
  PlayIcon,
  PlusIcon,
  SparkIcon,
  SparklesIcon,
  UserCircleIcon,
  UsersIcon,
} from "@/components/icons";
export { MovieclawMark, MovieclawWordmark } from "@/components/brand";
export { BrandLoader } from "@/components/brand-loader";
export { ContentEmptyState } from "@/components/content-empty-state";
export { HScroller } from "@/components/h-scroller";
export { formatRelativeTime } from "@/lib/time";
