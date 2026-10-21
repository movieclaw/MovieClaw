import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

/**
 * 主题 SDK 的出口快照（docs/design/theme-plugins.md §4.1）：SDK 就是主题契约 ui.theme 的代码面，
 * 出口变动必须是有意的——加出口 = 契约次版本，删 / 改名 = 主版本。改了 theme-sdk/index.ts
 * 就同步改这份清单，并在提交说明里写清契约版本怎么变。
 */
const EXPECTED = [
  "accessiblePathFor",
  "AccountSwitcherDialog",
  "ActivityIcon",
  "AppUpdateDot",
  "AppUpdateEntry",
  "AvatarBadge",
  "BookmarkFillIcon",
  "BrandLoader",
  "checkSubscriptionAutomationReadiness",
  "ChevronDownIcon",
  "ChevronLeftIcon",
  "ChevronRightIcon",
  "ContentEmptyState",
  "DesktopTopNavProps",
  "DetailNavProps",
  "formatRelativeTime",
  "GearIcon",
  "HScroller",
  "IMAGE_ASPECT",
  "imageUrl",
  "InfoIcon",
  "LibraryItem",
  "LibraryStackIcon",
  "listLibraries",
  "listLibraryItems",
  "listUpNext",
  "LogoutIcon",
  "MediaTypeSwitcher",
  "MobileSettingsNavProps",
  "MovieclawMark",
  "MovieclawWordmark",
  "NoticeCenter",
  "PAGE_NAV_BUTTON_SIZE_CLASS",
  "PageActionsProps",
  "PageNav",
  "PlayIcon",
  "PlusIcon",
  "PosterImage",
  "responsiveImage",
  "SearchCommand",
  "SearchScope",
  "SearchSubmitOptions",
  "settingsSectionGroupsFor",
  "SettingsSidebarProps",
  "signOut",
  "SparkIcon",
  "SparklesIcon",
  "Subscription",
  "SubscriptionCell",
  "SubscriptionFilter",
  "subscriptionFullyCollected",
  "taskActivityBadge",
  "TaskActivityBadge",
  "ThemeDefinition",
  "ThemePages",
  "ThemeSlots",
  "tmdbImageForWidth",
  "TodayArrivalGroup",
  "UpNextItem",
  "useAgentConversations",
  "useAppNavLinks",
  "useDownloadTasks",
  "useElementCoverWidth",
  "useIsMobile",
  "usePageChrome",
  "usePendingUpdate",
  "usePermissions",
  "usePluginNavItems",
  "UserCircleIcon",
  "UsersIcon",
  "useScrollRestoration",
  "useSearchAccess",
  "useSession",
  "useSubscribeEntry",
  "useTaskActivity",
  "useThemeState",
  "useTodayArrivalGroups",
  "useTodaySubscriptionArrivals",
  "useUiPrefs",
  "withImageWidth",
];

function exportedNames(src) {
  const code = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  const names = [];
  for (const m of code.matchAll(/export\s+(?:type\s+)?\{([^}]*)\}/g)) {
    for (const raw of m[1].split(",")) {
      const name = raw.replace(/^\s*type\s+/, "").trim();
      if (name) names.push(name);
    }
  }
  return [...new Set(names)].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
}

test("主题 SDK 出口与快照一致", () => {
  const src = fs.readFileSync(path.resolve(import.meta.dirname, "../theme-sdk/index.ts"), "utf8");
  assert.deepEqual(exportedNames(src), EXPECTED);
});

test("SDK 只做转出口：不写实现", () => {
  const src = fs.readFileSync(path.resolve(import.meta.dirname, "../theme-sdk/index.ts"), "utf8");
  const code = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  const statements = code.split(";").map((s) => s.trim()).filter(Boolean);
  for (const statement of statements) assert.match(statement, /^export\s+(type\s+)?\{[\s\S]*\}\s+from\s+"[^"]+"$/);
});
