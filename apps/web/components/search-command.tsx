"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";

import { useConfirm, useToast } from "@/components/feedback";
import {
  BookmarkIcon,
  ChevronRightIcon,
  FilmIcon,
  FolderIcon,
  HistoryIcon,
  LayersIcon,
  SearchIcon,
  TvIcon,
  UserIcon,
  XIcon,
} from "@/components/icons";
import {
  clearSearchHistory,
  deleteSearchHistoryEntry,
  listSearchHistory,
  searchLibrary,
  type LibrarySearchSuggestion,
  type SearchHistoryItem,
} from "@/lib/api/search";
import {
  presetSummary,
  SCOPE_ALL,
  scopeEquals,
  scopeOfTab,
  tabKeyOf,
  tabLabel,
  type SearchScope,
  type SearchTab,
  type SearchVertical,
} from "@/lib/categories";
import { useSearchAccess } from "@/lib/search-access";
import { useSearchPrefs } from "@/lib/search-prefs";
import { formatRelativeTime } from "@/lib/time";
import { useTheme } from "@/lib/ui-prefs";
import { useIsMobile } from "@/lib/use-media-query";

/**
 * 侧栏搜索入口 + 命令面板（Command Palette）。
 *
 * 全站唯一搜索入口，三模式（媒体优先）：触发器是品牌行右侧的放大镜图标按钮，
 * 点击（或 ⌘K）弹出面板。视觉对齐 Raycast/Spotlight 的**实心深色浮层**——
 * 纯 CSS 面板（不再用 WebGL 液态玻璃：弹窗是高频工具，要的是安静、快、可读，
 * 折射效果在这里只会增加视觉噪音），结构自上而下三段：
 *   输入行   放大镜 + 关键词输入 + 「影视 | 资源 | 媒体库」分段（右侧，Tab 键可切）
 *   主体     资源模式先出一行分类 chips；下方是当前模式的最近搜索（媒体库不展示，
 *            图标 + 类型徽标区分，↑↓ 可选、输入即过滤、hover 可删）
 *   页脚     左侧当前模式说明，右侧快捷键提示
 *
 * 提交与回放都走 onSearch：关键词 + 范围 + { vertical, snapshotId }，由上层
 * 编码进 /search 的 URL。历史点击按记录自身的垂直回放（媒体历史带快照 id
 * 进快照预览，资源历史沿用原有快照/重搜逻辑）。
 *
 * 银玻璃主题向原生 App 对齐（apps/apple/.../SearchHomeView.swift）：
 *   - 最近搜索改成 iOS 式分组（SilverHistoryGroup）：永远展开、无折叠箭头，主行时钟 + 关键词，
 *     同组其余记录用「↳」缩进列出；
 *   - 手机上面板变成全屏搜索页：顶部输入行 + 取消，模式分段撑满一行；没输关键词的资源模式给
 *     「浏览最新资源」列表，输了关键词顶上一行「搜索“xx”」、资源模式再给「在其他范围搜索」；
 *   - 结果页顶栏的关键词胶囊经 openSearchPalette 带着草稿（关键词 / 模式 / 范围）重新打开面板。
 * Netflix 主题的浮层与可折叠分组保持原样。
 */

/** 提交搜索的附加选项：目标垂直 + 历史快照回放。 */
export interface SearchSubmitOptions {
  /** 落地垂直；缺省 = 站点资源（torrent），与老调用方行为一致 */
  vertical?: SearchVertical;
  /** 非空 = 预览该条历史的结果快照（点历史记录进入），而非发起实时搜索 */
  snapshotId?: number;
}

export interface SearchCommandProps {
  /** 提交搜索的回调：关键词 + 搜索范围（标签换算而来）。由上层负责落地展示。 */
  onSearch: (keyword: string, scope: SearchScope, options?: SearchSubmitOptions) => void;
  /**
   * 触发键的样式覆盖。缺省是侧栏/顶栏那副玻璃行图标键；放进别处的控件行时
   * （如详情页顶栏与 ⋯ 并排，见 components/page-nav.tsx）传入该行自己的按钮
   * 类名，否则一颗方玻璃挨着一颗圆键，会像两套控件凑在一起。
   */
  triggerClassName?: string;
  /**
   * 本次打开预选的模式（银玻璃手机顶栏按所在标签传：发现 / 订阅 → 影视，媒体库 → 媒体库，
   * 活动 → 资源，同原生 App）。只决定打开时停在哪，不改写面板记住的上次模式；
   * 该模式当前账号不可用时照常回落。缺省 = 上次停留的模式。
   */
  preferredMode?: SearchVertical;
}

/**
 * 打开面板时的初值草稿：结果页顶栏的关键词胶囊「改词重搜」用（对应 iOS
 * `Router.editSearch(SearchDraft)`，见 apps/apple/.../SearchResultsView.swift 的 keywordCapsule）。
 * 关键词填回输入框、模式切回当时的垂直；scope 只在资源垂直给，能对上某个可见分类就选中它，
 * 对不上（历史回放的已隐藏分类）保留面板记住的分类，同 iOS takeDraft。
 */
export interface SearchPaletteDraft {
  keyword: string;
  mode: SearchVertical;
  scope?: SearchScope;
}

/** 请求打开面板的全局事件名（见 openSearchPalette） */
const OPEN_PALETTE_EVENT = "movieclaw:search-palette-open";

/**
 * 让当前挂着的那份 SearchCommand 带着草稿打开面板。
 *
 * 为什么是全局事件而不是 context：SearchCommand 自带全局 ⌘K 监听，全站同一时刻只挂一份
 * （手机在外壳顶栏、桌面在侧栏、详情页在 PageNav），挂在哪由外壳决定；结果页只需要
 * 「让那一份打开」，用一个窗口事件即可，不必为此改外壳或在各挂载点之间传 ref。
 */
export function openSearchPalette(draft: SearchPaletteDraft): void {
  window.dispatchEvent(new CustomEvent<SearchPaletteDraft>(OPEN_PALETTE_EVENT, { detail: draft }));
}

/** 搜索面板上次停留位置的浏览器级记忆，不随账号同步。 */
const SEARCH_PALETTE_STATE_KEY = "movieclaw.search-palette-state";

interface SearchPaletteState {
  mode: SearchVertical;
  tabKey: string;
}

/**
 * 从 localStorage 恢复搜索模式和资源分类。
 * 存储内容可能来自旧版本或被手动修改，因此只接受当前认识的字段和值。
 */
function readSearchPaletteState(): SearchPaletteState {
  const fallback: SearchPaletteState = { mode: "media", tabKey: "all" };
  try {
    const value = JSON.parse(localStorage.getItem(SEARCH_PALETTE_STATE_KEY) ?? "null") as
      | Partial<SearchPaletteState>
      | null;
    return {
      mode:
        value?.mode === "torrent" || value?.mode === "media" || value?.mode === "library"
          ? value.mode
          : fallback.mode,
      tabKey:
        typeof value?.tabKey === "string" && value.tabKey.length > 0
          ? value.tabKey
          : fallback.tabKey,
    };
  } catch {
    return fallback;
  }
}

/** localStorage 不可用时仅失去记忆能力，不影响搜索本身。 */
function writeSearchPaletteState(state: SearchPaletteState): void {
  try {
    localStorage.setItem(SEARCH_PALETTE_STATE_KEY, JSON.stringify(state));
  } catch {
    // 隐私模式或存储空间不足时静默降级
  }
}

/** 同关键词下的媒体搜索与各资源范围记录，默认在历史列表里折叠成一行。 */
interface HistoryGroup {
  /** 忽略首尾空格和英文大小写后的分组键。 */
  key: string;
  /** 使用组内最近一条记录的原文展示关键词。 */
  keyword: string;
  /** 组内按最近搜索时间倒序，首条即主行回车时打开的记录。 */
  items: SearchHistoryItem[];
}

/** 把接口返回的有序记录折叠为关键词组，保持后端给出的组顺序与组内顺序。 */
function groupHistory(items: SearchHistoryItem[]): HistoryGroup[] {
  const groups = new Map<string, HistoryGroup>();
  for (const item of items) {
    const key = item.keyword.trim().toLocaleLowerCase();
    const group = groups.get(key);
    if (group) group.items.push(item);
    else groups.set(key, { key, keyword: item.keyword, items: [item] });
  }
  return [...groups.values()];
}

export function SearchCommand({
  onSearch,
  // 移动端 44px：iOS HIG 最小可点目标（触屏），桌面保持 32px 紧凑图标键
  triggerClassName = "glass-row !size-8 shrink-0 justify-center !p-0 max-md:!size-11",
  preferredMode,
}: SearchCommandProps) {
  const searchAccess = useSearchAccess();
  const [open, setOpen] = useState(false);
  // 本次打开带的草稿（openSearchPalette 唤起时）；触发键 / ⌘K 打开时为 null
  const [draft, setDraft] = useState<SearchPaletteDraft | null>(null);
  // 面板是全屏浮层，Portal 到 body：避免被 sidebar 玻璃面板的 isolation:isolate
  // 层叠上下文困住。portalReady 规避 SSR。
  const [portalReady, setPortalReady] = useState(false);
  useEffect(() => setPortalReady(true), []);

  // 面板打开时给 body 挂 cmdk-open 类，驱动 .app-shell 轻微缩放后推（Spotlight 式纵深）
  useEffect(() => {
    document.body.classList.toggle("cmdk-open", open);
    return () => document.body.classList.remove("cmdk-open");
  }, [open]);

  // ⌘K / Ctrl+K 全局唤起；已打开时再次按下则关闭
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setDraft(null);
        setOpen((prev) => !prev);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  // 结果页的关键词胶囊请求带草稿打开（见 openSearchPalette）
  useEffect(() => {
    const onOpen = (event: Event) => {
      setDraft((event as CustomEvent<SearchPaletteDraft>).detail);
      setOpen(true);
    };
    window.addEventListener(OPEN_PALETTE_EVENT, onOpen);
    return () => window.removeEventListener(OPEN_PALETTE_EVENT, onOpen);
  }, []);

  if (searchAccess.ready && searchAccess.available.length === 0) return null;

  return (
    <>
      {/* 触发器保持紧凑；打开后的输入提示会告诉用户下次可直接用快捷键唤起。 */}
      <button
        type="button"
        onClick={() => {
          setDraft(null);
          setOpen(true);
        }}
        aria-label="搜索（⌘K 或 Ctrl+K）"
        aria-haspopup="dialog"
        title="搜索（⌘K 或 Ctrl+K）"
        className={triggerClassName}
      >
        <SearchIcon className="size-[18px] max-md:size-[22px]" />
      </button>

      {/* 面板按需挂载：每次打开都是全新实例，状态（模式/分类/输入）自然重置，
          不需要「打开时逐项复位」的清理逻辑；关闭即时卸载（对齐 Raycast 的干脆手感） */}
      {portalReady &&
        open &&
        createPortal(
          <SearchPalette
            preferredMode={preferredMode}
            draft={draft}
            onClose={() => setOpen(false)}
            onSearch={(keyword, scope, options) => {
              onSearch(keyword, scope, options);
              setOpen(false);
            }}
          />,
          document.body,
        )}
    </>
  );
}

/* —— 面板本体 —— */

/** 草稿里的范围对应面板的哪个分类 key；对不上任何可见分类时返回 null（保留记住的分类）。 */
function draftTabKey(draft: SearchPaletteDraft | null, tabs: SearchTab[]): string | null {
  const scope = draft?.scope;
  if (!scope) return null;
  if (scopeEquals(scope, SCOPE_ALL)) return "all";
  const tab = tabs.find((t) => scopeEquals(scopeOfTab(t), scope));
  return tab ? tabKeyOf(tab) : null;
}

/** 各模式的一句话说明（桌面页脚 / 手机全屏页列表末尾）。 */
const MODE_HINT: Record<SearchVertical, string> = {
  media: "在豆瓣与 TMDB 中搜索影视条目",
  torrent: "跨全部已配置站点搜索种子",
  library: "在媒体库中搜索已入库的影片",
};

function SearchPalette({
  preferredMode,
  draft,
  onClose,
  onSearch,
}: {
  preferredMode?: SearchVertical;
  draft: SearchPaletteDraft | null;
  onClose: () => void;
  onSearch: (keyword: string, scope: SearchScope, options?: SearchSubmitOptions) => void;
}) {
  const { visibleTabs, loading: tabsLoading } = useSearchPrefs();
  const searchAccess = useSearchAccess();
  const confirm = useConfirm();
  const toast = useToast();
  // 银玻璃：最近搜索用 iOS 式分组行；手机上面板改成全屏搜索页（SearchHomeView 的版式）。
  // Netflix 主题沿用原来的浮层与可折叠分组，展示不动。
  const silver = !useTheme().structural;
  const isMobile = useIsMobile();
  const fullPage = silver && isMobile;
  const [keyword, setKeyword] = useState(draft?.keyword ?? "");
  // 面板每次重新挂载，但模式与资源分类从浏览器级记忆恢复；带草稿打开时以草稿为准。
  const [rememberedState] = useState(readSearchPaletteState);
  const [mode, setMode] = useState<SearchVertical>(
    draft?.mode ?? preferredMode ?? rememberedState.mode,
  );
  // 搜资源模式选中的分类 key；"all" = 全部。
  const [tabKey, setTabKey] = useState(
    () => draftTabKey(draft, visibleTabs) ?? rememberedState.tabKey,
  );
  // null = 加载中；[] = 无历史
  const [items, setItems] = useState<SearchHistoryItem[] | null>(null);
  // 删除完成后重读当前类型，同时让旧的读取请求作废；失败时也恢复后端真实状态。
  const [historyRefresh, setHistoryRefresh] = useState(0);
  // （Netflix 主题的可折叠分组）关键词组默认全部展开；这里只记录用户在本次弹窗里主动收起的组。
  // 输入过滤时匹配组会临时强制展开，但不会抹掉用户的收起选择。
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(() => new Set());
  // 键盘高亮的关键词组下标；-1 = 未选中（此时回车提交输入的关键词）
  const [sel, setSel] = useState(-1);
  const inputRef = useRef<HTMLInputElement>(null);
  const availableModes = searchAccess.available;
  const historyVertical = mode === "media" ? "titles" : mode === "torrent" ? "torrents" : undefined;

  // 挂载即聚焦输入框：effect 执行时 DOM 已提交，直接同步 focus（不要用 rAF，
  // 后台标签页里 rAF 会被挂起导致聚焦丢失）。草稿预填了关键词时光标放到末尾，接着改词。
  useEffect(() => {
    const input = inputRef.current;
    if (!input) return;
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  }, []);

  useEffect(() => {
    if (!searchAccess.ready) return;
    if (availableModes.length === 0) {
      onClose();
      return;
    }
    if (!availableModes.includes(mode)) {
      const nextMode = searchAccess.firstAvailable ?? availableModes[0];
      setMode(nextMode);
      writeSearchPaletteState({ mode: nextMode, tabKey });
    }
  }, [availableModes, mode, onClose, searchAccess.firstAvailable, searchAccess.ready, tabKey]);

  // 等服务端搜索偏好加载完成后再校验。若上次分类已隐藏或删除，回退到「全部」，
  // 避免界面没有选中项但提交时悄悄按全部搜索。
  useEffect(() => {
    if (
      !tabsLoading &&
      tabKey !== "all" &&
      !visibleTabs.some((tab) => tabKeyOf(tab) === tabKey)
    ) {
      setTabKey("all");
      writeSearchPaletteState({ mode, tabKey: "all" });
    }
  }, [mode, tabKey, tabsLoading, visibleTabs]);

  const changeMode = (nextMode: SearchVertical) => {
    if (!availableModes.includes(nextMode)) return;
    setMode(nextMode);
    writeSearchPaletteState({ mode: nextMode, tabKey });
  };

  const changeTab = (nextTabKey: string) => {
    setTabKey(nextTabKey);
    writeSearchPaletteState({ mode, tabKey: nextTabKey });
  };

  // 先在后端按类型筛选再取最近 8 组；切换模式时丢弃旧响应，媒体库不请求历史。
  useEffect(() => {
    let cancelled = false;
    setItems(null);
    setSel(-1);
    if (!historyVertical) {
      setItems([]);
      return;
    }
    listSearchHistory(8, historyVertical)
      .then((list) => !cancelled && setItems(list))
      .catch(() => !cancelled && setItems([]));
    return () => {
      cancelled = true;
    };
  }, [historyVertical, historyRefresh]);

  const groups = useMemo(
    () =>
      groupHistory(
        (items ?? []).filter((item) =>
          item.vertical === historyVertical &&
          (item.vertical === "titles" ? searchAccess.canMedia : searchAccess.canTorrent),
        ),
      ),
    [items, historyVertical, searchAccess.canMedia, searchAccess.canTorrent],
  );

  // 输入即过滤关键词组（子串匹配）；匹配后 UI 自动展开该组的所有具体范围。
  const filteredGroups = useMemo(() => {
    const needle = keyword.trim().toLowerCase();
    if (!needle) return groups;
    return groups.filter((group) => group.key.includes(needle));
  }, [groups, keyword]);

  // 过滤结果变化后旧下标可能越界，收敛到组列表末尾；空列表回到 -1。
  useEffect(() => {
    setSel((prev) => Math.min(prev, filteredGroups.length - 1));
  }, [filteredGroups.length]);

  const trimmed = keyword.trim();
  const currentTab = visibleTabs.find((t) => tabKeyOf(t) === tabKey) ?? null;

  // 媒体库模式的搜索联想（同 Apple TV 的系统联想）：输入停顿 200ms 请求一次相关度搜索，
  // 取它从结果里提取的片名与人名；只是「按已搜出的结果补全」，不纠错、不按热度。
  // 选中即按这个词搜索。与当前输入完全相同的词不列。
  const [suggestions, setSuggestions] = useState<LibrarySearchSuggestion[]>([]);
  const suggestKeyword = mode === "library" && availableModes.includes("library") ? trimmed : "";
  useEffect(() => {
    if (!suggestKeyword) {
      setSuggestions([]);
      return;
    }
    let cancelled = false;
    const timer = window.setTimeout(() => {
      searchLibrary({ q: suggestKeyword })
        .then((page) => {
          if (cancelled) return;
          setSel(-1); // 换了一批联想词：旧高亮作废
          const seen = new Set([suggestKeyword.toLowerCase()]);
          setSuggestions(
            page.suggestions.filter((suggestion) => {
              const key = suggestion.text.trim().toLowerCase();
              if (!key || seen.has(key)) return false;
              seen.add(key);
              return true;
            }),
          );
        })
        // 联想失败不打扰：回车照常搜索，结果页会给出真正的错误
        .catch(() => !cancelled && setSuggestions([]));
    }, 200);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [suggestKeyword]);
  // ↑↓ 在当前列表里移动：媒体库模式是联想词，其他模式是历史分组
  const navCount = mode === "library" ? suggestions.length : filteredGroups.length;
  const pickSuggestion = (suggestion: LibrarySearchSuggestion) =>
    onSearch(suggestion.text, SCOPE_ALL, { vertical: "library" });
  const torrentActive = mode === "torrent" && availableModes.includes("torrent");

  /** 按指定分类搜资源；空关键词 = 浏览该分类最新资源（Web 的「留空提交」）。 */
  const submitTorrent = (key: string) => {
    const tab = visibleTabs.find((t) => tabKeyOf(t) === key);
    onSearch(trimmed, tab ? scopeOfTab(tab) : SCOPE_ALL, { vertical: "torrent" });
  };

  const submit = () => {
    if (!availableModes.includes(mode)) return;
    if (mode === "torrent") {
      // 资源模式允许空关键词 = 浏览：直接逛选中分类的站点种子列表页，
      // 对应"我不想搜某一部，就想看看这个分类最近出了什么"
      submitTorrent(tabKey);
      return;
    }
    // 影视/媒体库没有「浏览」语义（无分类维度），空词不提交，范围恒为「全部」
    if (!trimmed) return;
    onSearch(trimmed, SCOPE_ALL, { vertical: mode });
  };

  /** 点开一条历史：按记录自身的垂直回放，有快照进快照预览，没有发起实时搜索。 */
  const pick = (item: SearchHistoryItem) => {
    const snapshotId = item.has_snapshot ? item.id : undefined;
    if (item.vertical === "titles") {
      onSearch(item.keyword, SCOPE_ALL, { vertical: "media", snapshotId });
      return;
    }
    onSearch(
      item.keyword,
      {
        label: item.label,
        categories: item.categories,
        siteIds: item.site_ids,
        // 还原发起搜索时的图览模式；skipHistory 恒 false——能出现在历史里的
        // 搜索本来就不是无痕的，点它重搜也照常记录
        posterMode: item.poster_mode,
        skipHistory: false,
      },
      { vertical: "torrent", snapshotId },
    );
  };

  const handleKeyDown = (event: React.KeyboardEvent) => {
    switch (event.key) {
      case "Escape":
        event.preventDefault();
        onClose();
        break;
      // Tab 在三种模式间轮换：面板是模态浮层，焦点常驻输入框，Tab 的原生
      // 焦点移动在这里没有意义，挪用作模式切换（与页脚提示文案呼应）
      case "Tab":
        event.preventDefault();
        if (availableModes.length > 1) {
          const index = availableModes.indexOf(mode);
          changeMode(availableModes[(index + 1) % availableModes.length]);
        }
        break;
      case "ArrowDown":
        event.preventDefault();
        setSel((prev) => Math.min(prev + 1, navCount - 1));
        break;
      case "ArrowUp":
        event.preventDefault();
        setSel((prev) => Math.max(prev - 1, -1));
        break;
      // ←→ 收起 / 展开分组只属于 Netflix 主题的可折叠分组；银玻璃的分组永远展开
      case "ArrowRight": {
        const group = filteredGroups[sel];
        if (silver || !group || group.items.length === 1) break;
        event.preventDefault();
        setCollapsedGroups((prev) => {
          const next = new Set(prev);
          next.delete(group.key);
          return next;
        });
        break;
      }
      case "ArrowLeft": {
        const group = filteredGroups[sel];
        if (silver || !group || group.items.length === 1) break;
        event.preventDefault();
        setCollapsedGroups((prev) => new Set(prev).add(group.key));
        break;
      }
      case "Enter":
        event.preventDefault();
        if (mode === "library" && sel >= 0 && suggestions[sel]) pickSuggestion(suggestions[sel]);
        else if (mode !== "library" && sel >= 0 && filteredGroups[sel]) pick(filteredGroups[sel].items[0]);
        else submit();
        break;
    }
  };

  const removeOne = (id: number) => {
    setItems((prev) => (prev ? prev.filter((i) => i.id !== id) : prev));
    deleteSearchHistoryEntry(id)
      .catch(() => toast.error("删除搜索历史失败，请重试"))
      .finally(() => setHistoryRefresh((prev) => prev + 1));
  };

  const removeGroup = async (group: HistoryGroup) => {
    if (group.items.length === 1) {
      removeOne(group.items[0].id);
      return;
    }
    if (
      group.items.length > 1 &&
      !(await confirm({
        title: `删除「${group.keyword}」的 ${group.items.length} 条搜索记录？`,
        confirmLabel: "删除",
        tone: "danger",
      }))
    ) {
      return;
    }
    const ids = new Set(group.items.map((item) => item.id));
    setItems((prev) => (prev ? prev.filter((item) => !ids.has(item.id)) : prev));
    // 等组内所有删除落定后再刷新，避免首个失败提前触发读取，剩余删除还在进行。
    Promise.allSettled(group.items.map((item) => deleteSearchHistoryEntry(item.id)))
      .then((results) => {
        if (results.some((result) => result.status === "rejected")) {
          toast.error("部分搜索历史删除失败，请重试");
        }
      })
      .finally(() => setHistoryRefresh((prev) => prev + 1));
  };

  const toggleGroup = (groupKey: string) => {
    setCollapsedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(groupKey)) next.delete(groupKey);
      else next.add(groupKey);
      return next;
    });
  };

  const removeAll = () => {
    if (!historyVertical) return;
    setItems([]);
    clearSearchHistory(historyVertical)
      .catch(() => toast.error("清空搜索历史失败，请重试"))
      .finally(() => setHistoryRefresh((prev) => prev + 1));
  };

  const input = (
    <input
      ref={inputRef}
      value={keyword}
      onChange={(event) => {
        setKeyword(event.target.value);
        setSel(-1); // 输入变化 = 用户意图回到「搜新词」，清掉历史高亮
      }}
      // 手机全屏页没有实体键盘，不提 ⌘K；资源模式把当前分类写进占位文字（同 iOS 收起态）
      placeholder={
        mode === "media"
          ? `搜索电影、剧集…${fullPage ? "" : " · 下次按 ⌘K / Ctrl+K 唤醒"}`
          : mode === "torrent"
            ? `搜索资源或 IMDb ID…${fullPage ? "" : " · 下次按 ⌘K / Ctrl+K 唤醒"}`
            : `搜索已入库的影片…${fullPage ? "" : " · 下次按 ⌘K / Ctrl+K 唤醒"}`
      }
      aria-label={
        mode === "media" ? "搜索影视条目" : mode === "torrent" ? "搜索站点资源" : "搜索媒体库"
      }
      // 手机键盘的回车键显示为「搜索」
      enterKeyHint="search"
      // 搜索词是片名/IMDb ID，不是英文句子：iOS 的首字母大写和自动纠错
      // 会把 "tt0111161"、"Dune" 这类输入改得面目全非，全部关掉
      autoCapitalize="off"
      autoCorrect="off"
      spellCheck={false}
      className={`min-w-0 flex-1 bg-transparent text-body-lg text-[var(--text)] outline-none placeholder:text-[var(--text-faint)] ${
        fullPage ? "h-full" : "h-[52px]"
      }`}
    />
  );

  /* —— 最近搜索 —— */
  const historyList = filteredGroups.length > 0 && (
    <ul aria-label="最近搜索">
      {filteredGroups.map((group, index) =>
        silver ? (
          <SilverHistoryGroup
            key={group.key}
            group={group}
            active={index === sel}
            onHover={() => setSel(index)}
            onPickItem={pick}
            onRemoveItem={removeOne}
            onRemoveGroup={() => void removeGroup(group)}
          />
        ) : (
          <HistoryGroupRow
            key={group.key}
            group={group}
            active={index === sel}
            onHover={() => setSel(index)}
            onPick={() => pick(group.items[0])}
            expanded={trimmed.length > 0 || !collapsedGroups.has(group.key)}
            onToggle={() => toggleGroup(group.key)}
            onPickItem={pick}
            onRemoveItem={removeOne}
            onRemoveGroup={() => void removeGroup(group)}
          />
        ),
      )}
    </ul>
  );
  const clearHistoryButton = (
    <button
      type="button"
      onClick={removeAll}
      aria-label={`清空${mode === "media" ? "影视" : "资源"}搜索历史`}
      className="touch-target rounded-md px-1.5 py-0.5 text-caption text-[var(--text-faint)] transition-colors hover:bg-white/[0.08] hover:text-[var(--text-muted)]"
    >
      清空
    </button>
  );

  const suggestionList = suggestions.length > 0 && (
    <ul aria-label="搜索联想">
      {suggestions.map((suggestion, index) => (
        <SuggestionRow
          key={`${suggestion.type}:${suggestion.text}`}
          suggestion={suggestion}
          active={index === sel}
          onHover={() => setSel(index)}
          onPick={() => pickSuggestion(suggestion)}
        />
      ))}
    </ul>
  );

  /* —— 手机全屏搜索页（银玻璃）：对齐 iOS SearchHomeView —— */
  if (fullPage) {
    return (
      <div className="search-palette-overlay viewport-app-height fixed inset-x-0 top-0 z-[80] flex">
        <div
          role="dialog"
          aria-modal="true"
          aria-label="搜索"
          className="search-palette-panel flex h-full w-full flex-col bg-[rgba(15,17,23,0.94)] pt-[var(--safe-top)]"
          onKeyDown={handleKeyDown}
        >
          {/* 输入行：圆角搜索框（资源模式带分类标记）+ 取消，同 iOS 系统搜索栏 */}
          <div className="flex shrink-0 items-center gap-3 px-4 pb-2 pt-2">
            <div className="flex h-10 min-w-0 flex-1 items-center gap-2 rounded-full bg-white/[0.09] pl-3 pr-1.5">
              <SearchIcon className="size-[17px] shrink-0 text-[var(--text-faint)]" />
              {/* 分类标记（同 iOS 搜索栏里的 token）：回车就在这个分类里搜，✕ 掉 = 全部分类 */}
              {torrentActive && currentTab && (
                <button
                  type="button"
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => changeTab("all")}
                  aria-label={`搜索范围：${tabLabel(currentTab)}，点按改为全部分类`}
                  className="flex h-7 max-w-[40%] shrink-0 items-center gap-1 rounded-full bg-[#56637a] pl-2.5 pr-1.5 text-sub font-medium text-white"
                >
                  <span className="truncate">{tabLabel(currentTab)}</span>
                  <XIcon className="size-3 shrink-0 opacity-80" />
                </button>
              )}
              {input}
              {keyword && (
                <button
                  type="button"
                  aria-label="清除关键词"
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => {
                    setKeyword("");
                    inputRef.current?.focus();
                  }}
                  className="touch-target grid size-6 shrink-0 place-items-center rounded-full bg-white/[0.18] text-[var(--text)]"
                >
                  <XIcon className="size-3" />
                </button>
              )}
            </div>
            <button
              type="button"
              onClick={onClose}
              className="shrink-0 text-body-lg text-[var(--text)] active:opacity-60"
            >
              取消
            </button>
          </div>
          {availableModes.length > 1 && (
            <div className="shrink-0 px-4 pb-2">
              <ModeSwitch mode={mode} modes={availableModes} onChange={changeMode} stretch />
            </div>
          )}

          <div className="scroll-thin min-h-0 flex-1 overflow-y-auto overscroll-contain px-2 pb-[calc(var(--safe-bottom)+24px)]">
            {/* 输入了关键词：顶上一行直接搜索，下注在哪儿搜（收起键盘后也能一点就搜） */}
            {trimmed && availableModes.includes(mode) && (
              <ul className="pt-1">
                <ScopeRow
                  icon={<SearchIcon className="size-[18px]" />}
                  title={`搜索“${trimmed}”`}
                  subtitle={
                    mode === "media"
                      ? "豆瓣与 TMDB 影视条目"
                      : mode === "torrent"
                        ? currentTab
                          ? `在「${tabLabel(currentTab)}」中搜索`
                          : "在全部分类中搜索"
                        : "已入库的影片"
                  }
                  onClick={submit}
                />
              </ul>
            )}
            {suggestionList && (
              <section>
                <SectionTitle title="搜索联想" />
                {suggestionList}
              </section>
            )}

            {/* 最近搜索：资源模式下面还有浏览列表，不需要空态占位 */}
            {historyVertical && items !== null && items.length === 0 && !torrentActive && (
              <p className="px-2.5 py-10 text-center text-sub text-[var(--text-faint)]">
                还没有搜索记录。{MODE_HINT[mode]}。
              </p>
            )}
            {filteredGroups.length > 0 && (
              <section>
                <SectionTitle title="最近搜索" action={clearHistoryButton} />
                {historyList}
              </section>
            )}

            {/* 资源分类的两种用法（同 iOS）：没输关键词 = 浏览各分类最新资源；
                输了关键词 = 换个范围搜（点一行即按该范围搜索并记住） */}
            {torrentActive && !trimmed && (
              <section>
                <SectionTitle title="浏览最新资源" />
                <ul>
                  <ScopeRow
                    icon={<LayersIcon className="size-[18px]" />}
                    title="全部分类"
                    chevron
                    onClick={() => onSearch("", SCOPE_ALL, { vertical: "torrent" })}
                  />
                  {visibleTabs.map((tab) => (
                    <ScopeRow
                      key={tabKeyOf(tab)}
                      icon={<TabIcon tab={tab} />}
                      title={tabLabel(tab)}
                      subtitle={presetSummary(tab)}
                      chevron
                      onClick={() => onSearch("", scopeOfTab(tab), { vertical: "torrent" })}
                    />
                  ))}
                </ul>
              </section>
            )}
            {torrentActive && trimmed && (
              <section>
                <SectionTitle title="在其他范围搜索" />
                <ul>
                  {tabKey !== "all" && (
                    <ScopeRow
                      icon={<LayersIcon className="size-[18px]" />}
                      title="全部分类"
                      onClick={() => {
                        changeTab("all");
                        submitTorrent("all");
                      }}
                    />
                  )}
                  {visibleTabs
                    .filter((tab) => tabKeyOf(tab) !== tabKey)
                    .map((tab) => (
                      <ScopeRow
                        key={tabKeyOf(tab)}
                        icon={<TabIcon tab={tab} />}
                        title={tabLabel(tab)}
                        subtitle={presetSummary(tab)}
                        onClick={() => {
                          changeTab(tabKeyOf(tab));
                          submitTorrent(tabKeyOf(tab));
                        }}
                      />
                    ))}
                </ul>
              </section>
            )}
            {torrentActive && (
              <p className="px-2.5 pt-3 text-caption text-[var(--text-faint)]">
                {MODE_HINT.torrent}。搜索框里的分类标记就是搜索范围，✕ 掉即搜全部分类。
              </p>
            )}
          </div>
        </div>
      </div>
    );
  }

  return (
    // 遮罩：mousedown 落在遮罩本身（而非面板内）即关闭
    <div
      // bottom 超出视口 --vp-overshoot：遮罩铺到屏幕物理底边（见 globals.css 的说明）。
      // 面板 items-start 顶部对齐，加高遮罩不会挪动它。
      className="search-palette-overlay fixed inset-0 z-[80] flex items-start justify-center px-4 pt-[13vh] [bottom:calc(-1*var(--vp-overshoot))] max-md:px-2 max-md:pt-[calc(var(--safe-top)+10px)]"
      onMouseDown={(event) => event.target === event.currentTarget && onClose()}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-label="搜索"
        className="search-palette-panel flex w-full max-w-[600px] flex-col overflow-hidden rounded-2xl border border-white/[0.09] bg-[rgba(21,23,29,0.96)] shadow-[0_24px_80px_rgba(0,0,0,0.55),0_2px_8px_rgba(0,0,0,0.4)] backdrop-blur-2xl max-md:max-h-[calc(100dvh-var(--safe-top)-var(--keyboard-inset)-20px)]"
        onKeyDown={handleKeyDown}
      >
        {/* —— 输入行 —— */}
        <div className="flex items-center gap-3 pl-4 pr-3">
          <SearchIcon className="size-[17px] shrink-0 text-[var(--text-faint)]" />
          {input}
          <ModeSwitch mode={mode} modes={availableModes} onChange={changeMode} />
        </div>

        {/* —— 分类 chips（仅资源模式；影视/媒体库搜索没有分类维度）—— */}
        {mode === "torrent" && (
          <div className="flex flex-wrap gap-1.5 px-4 pb-3">
            <CategoryChip
              label="全部"
              active={tabKey === "all"}
              onClick={() => changeTab("all")}
            />
            {visibleTabs.map((tab) => (
              <CategoryChip
                key={tabKeyOf(tab)}
                label={tabLabel(tab)}
                active={tabKey === tabKeyOf(tab)}
                onClick={() => changeTab(tabKeyOf(tab))}
              />
            ))}
          </div>
        )}

        <div className="h-px bg-white/[0.06]" />

        {/* —— 主体：当前类型的最近搜索；媒体库只展示搜索引导 —— */}
        <div className="scroll-thin max-h-[336px] min-h-[96px] overflow-y-auto p-2 max-md:max-h-none max-md:min-h-0 max-md:flex-1">
          {historyVertical && items !== null && items.length > 0 && (
            <div className="flex items-center justify-between px-2.5 pb-1 pt-1">
              <span className="text-caption font-medium tracking-wide text-[var(--text-faint)]">
                最近搜索
              </span>
              {clearHistoryButton}
            </div>
          )}
          {historyVertical && items !== null && items.length === 0 && (
            <p className="px-2.5 py-6 text-center text-sub text-[var(--text-faint)]">
              还没有搜索记录，输入关键词回车开始搜索
            </p>
          )}
          {historyVertical && items !== null && items.length > 0 && filteredGroups.length === 0 && (
            <p className="px-2.5 py-6 text-center text-sub text-[var(--text-faint)]">
              没有匹配「{trimmed}」的搜索记录，回车直接搜索
            </p>
          )}
          {historyList}
          {mode === "library" &&
            (suggestionList || (
              <p className="px-2.5 py-6 text-center text-sub text-[var(--text-faint)]">
                {MODE_HINT.library}，输入关键词回车开始搜索
              </p>
            ))}
        </div>

        {/* —— 页脚：左侧模式说明，右侧快捷键 —— */}
        <div className="flex h-10 shrink-0 items-center justify-between border-t border-white/[0.06] px-4">
          <span className="text-caption text-[var(--text-faint)]">
            {mode === "torrent"
              ? `${MODE_HINT.torrent}，留空回车 = 浏览该分类最新资源`
              : MODE_HINT[mode]}
          </span>
          <span className="flex items-center gap-3 text-caption text-[var(--text-faint)] max-md:hidden">
            <span className="flex items-center gap-1">
              <Kbd>⏎</Kbd> {mode === "torrent" && !trimmed ? "浏览" : "搜索"}
            </span>
            <span className="flex items-center gap-1">
              <Kbd>Tab</Kbd> 切换范围
            </span>
            <span className="flex items-center gap-1">
              <Kbd>↑↓</Kbd> {mode === "library" ? "联想" : "历史"}
            </span>
            <span className="flex items-center gap-1">
              <Kbd>esc</Kbd> 关闭
            </span>
          </span>
        </div>
      </div>
    </div>
  );
}

/* —— 小件 —— */

/** 「影视 | 资源 | 媒体库」分段：输入行右侧的紧凑三段开关（Raycast 的 scope 选择位）。
 *  命名按内容来源走（不带「搜」前缀，弹窗本身就是搜索场景）：影视 = 世界上有什么
 *  （豆瓣条目），资源 = 去哪儿下（跨站点种子），媒体库 = 我有没有（本地已入库）。 */
function ModeSwitch({
  mode,
  modes,
  onChange,
  stretch = false,
}: {
  mode: SearchVertical;
  modes: SearchVertical[];
  onChange: (mode: SearchVertical) => void;
  /** 撑满一行、各段等分（手机全屏搜索页，同 iOS 搜索栏下的范围分段） */
  stretch?: boolean;
}) {
  const options: { id: SearchVertical; label: string; hint: string }[] = [
    { id: "media", label: "影视", hint: "影视条目（豆瓣与 TMDB）" },
    { id: "torrent", label: "资源", hint: "跨站点种子搜索" },
    { id: "library", label: "媒体库", hint: "已入库的本地影片" },
  ] satisfies { id: SearchVertical; label: string; hint: string }[];
  const visibleOptions = options.filter((option) => modes.includes(option.id));
  if (visibleOptions.length <= 1) return null;
  return (
    <div
      role="radiogroup"
      aria-label="搜索范围"
      className={`flex shrink-0 gap-0.5 rounded-lg bg-white/[0.06] p-0.5 ${stretch ? "w-full" : ""}`}
    >
      {visibleOptions.map((opt) => {
        const active = opt.id === mode;
        return (
          <button
            key={opt.id}
            type="button"
            role="radio"
            aria-checked={active}
            title={opt.hint}
            // mousedown 抢焦点会让输入框失焦，preventDefault 保持焦点常驻输入框
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => onChange(opt.id)}
            className={`rounded-md px-2.5 text-sub font-medium transition-colors ${
              stretch ? "flex-1 py-1.5" : "py-1"
            } ${
              active
                ? "bg-white/[0.13] text-[var(--text)]"
                : "text-[var(--text-muted)] hover:text-[var(--text)]"
            }`}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}

/** 分类 chip（资源模式）：展示哪些标签、什么顺序由「设置 → 搜索」的偏好决定。 */
function CategoryChip({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onMouseDown={(event) => event.preventDefault()}
      onClick={onClick}
      className={`rounded-full px-2.5 py-[3px] text-sub transition-colors ${
        active
          ? "bg-white/[0.14] font-medium text-[var(--text)]"
          : "text-[var(--text-muted)] hover:bg-white/[0.06] hover:text-[var(--text)]"
      }`}
    >
      {label}
    </button>
  );
}

/**
 * （Netflix 主题）关键词组主行：默认只占一行，点击/回车打开最近一次搜索；右侧箭头按需展开
 * 媒体及各资源范围。组内只有一条时仍沿用相同结构，保持列表节奏稳定。
 */
function HistoryGroupRow({
  group,
  active,
  onHover,
  onPick,
  expanded,
  onToggle,
  onPickItem,
  onRemoveItem,
  onRemoveGroup,
}: {
  group: HistoryGroup;
  active: boolean;
  onHover: () => void;
  onPick: () => void;
  expanded: boolean;
  onToggle: () => void;
  onPickItem: (item: SearchHistoryItem) => void;
  onRemoveItem: (id: number) => void;
  onRemoveGroup: () => void;
}) {
  const latest = group.items[0];
  const mediaCount = group.items.filter((item) => item.vertical === "titles").length;
  const torrentCount = group.items.length - mediaCount;

  // 单条记录不制造「只有一个孩子的分组」：沿用旧版扁平行，点击即进入该记录。
  if (group.items.length === 1) {
    return (
      <HistorySingleRow
        item={latest}
        active={active}
        onHover={onHover}
        onPick={onPick}
        onRemove={onRemoveGroup}
      />
    );
  }

  return (
    <li className="group/history">
      <div
        className={`flex items-center rounded-[10px] transition-colors ${
          active ? "bg-white/[0.07]" : ""
        }`}
        onMouseEnter={onHover}
      >
        <button
          type="button"
          onClick={onPick}
          className="flex min-w-0 flex-1 items-center gap-2.5 py-2 pl-2.5 text-left"
        >
          <span className="min-w-0 flex-1 truncate text-ui leading-5 text-[var(--text)]/90">
            {group.keyword}
          </span>
          {group.items.length > 1 ? (
            <>
              <span className="shrink-0 rounded-md bg-white/[0.07] px-1.5 py-0.5 text-micro text-[var(--text-muted)]">
                {group.items.length} 种范围
              </span>
              <span className="hidden shrink-0 text-micro text-[var(--text-faint)] sm:inline">
                {mediaCount > 0 && `影视 ${mediaCount}`}
                {mediaCount > 0 && torrentCount > 0 && " · "}
                {torrentCount > 0 && `资源 ${torrentCount}`}
              </span>
            </>
          ) : (
            <HistoryTypeBadges item={latest} />
          )}
          {latest.has_snapshot && (
            <span
              title="最近一次搜索已有结果快照，点击秒开预览"
              className="shrink-0 rounded-md bg-[var(--info-soft)]/15 px-1.5 py-0.5 text-micro text-[var(--info-text-2)]"
            >
              快照
            </span>
          )}
          <span className="shrink-0 text-caption text-[var(--text-faint)]">
            {formatRelativeTime(latest.last_searched_at)}
          </span>
        </button>
        <button
          type="button"
          aria-label={expanded ? `收起 ${group.keyword} 的搜索范围` : `展开 ${group.keyword} 的搜索范围`}
          aria-expanded={expanded}
          onMouseDown={(event) => event.preventDefault()}
          onClick={onToggle}
          className="touch-target mx-0.5 rounded-md p-1.5 text-[var(--text-faint)] transition-colors hover:bg-white/[0.08] hover:text-[var(--text-muted)]"
        >
          <svg
            viewBox="0 0 20 20"
            className={`size-3.5 transition-transform ${expanded ? "rotate-90" : ""}`}
            fill="none"
            stroke="currentColor"
            strokeWidth={1.8}
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d="m7.5 4.5 5 5-5 5" />
          </svg>
        </button>
        <DeleteHistoryButton
          label={`删除搜索历史组：${group.keyword}`}
          onClick={onRemoveGroup}
          className="touch-reveal mr-1 opacity-0 group-hover/history:opacity-100"
        />
      </div>

      {expanded && (
        <ul className="ml-[18px] border-l border-white/[0.07] py-0.5 pl-3">
          {group.items.map((item) => (
            <HistoryVariantRow
              key={item.id}
              item={item}
              onPick={() => onPickItem(item)}
              onRemove={() => onRemoveItem(item.id)}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

/**
 * 只有一条记录的关键词保持旧版扁平展示：类型、资源分类、快照和时间同层呈现，
 * 没有摘要、展开箭头或重复的子行，与多记录分组自然混排。
 */
function HistorySingleRow({
  item,
  active,
  onHover,
  onPick,
  onRemove,
}: {
  item: SearchHistoryItem;
  active: boolean;
  onHover: () => void;
  onPick: () => void;
  onRemove: () => void;
}) {
  return (
    <li className="group/single relative">
      <button
        type="button"
        onMouseEnter={onHover}
        onClick={onPick}
        className={`flex w-full items-center gap-2.5 rounded-[10px] px-2.5 py-2 text-left transition-colors ${
          active ? "bg-white/[0.07]" : ""
        }`}
      >
        <span className="min-w-0 flex-1 truncate text-ui leading-5 text-[var(--text)]/90">
          {item.keyword}
        </span>
        <HistoryTypeBadges item={item} />
        {item.has_snapshot && (
          <span
            title="已留存结果快照，点击秒开预览"
            className="shrink-0 rounded-md bg-[var(--info-soft)]/15 px-1.5 py-0.5 text-micro text-[var(--info-text-2)]"
          >
            快照
          </span>
        )}
        <span className="shrink-0 text-caption text-[var(--text-faint)] transition-opacity group-hover/single:opacity-0">
          {formatRelativeTime(item.last_searched_at)}
        </span>
      </button>
      <DeleteHistoryButton
        label={`删除搜索历史：${item.keyword}`}
        onClick={onRemove}
        // !absolute 是必需的：.touch-target 在移动端的无层 position:relative
        // 会顶掉普通 absolute（同 media-track-rows / sidebar 的既有处理）
        className="touch-reveal !absolute right-2 top-1/2 -translate-y-1/2 opacity-0 group-hover/single:opacity-100"
      />
    </li>
  );
}

/** 展开态中的具体搜索范围：不重复关键词，只显示垂直、分类、快照和时间。 */
function HistoryVariantRow({
  item,
  onPick,
  onRemove,
}: {
  item: SearchHistoryItem;
  onPick: () => void;
  onRemove: () => void;
}) {
  return (
    <li className="group/variant flex items-center rounded-lg transition-colors hover:bg-white/[0.05]">
      <button
        type="button"
        onClick={onPick}
        className="flex min-w-0 flex-1 items-center gap-2 py-1.5 pl-2 text-left"
      >
        <span className="min-w-0 flex-1 truncate text-sub text-[var(--text-muted)]">
          {item.vertical === "titles" ? "影视" : `资源 · ${item.label ?? "全部"}`}
        </span>
        {item.has_snapshot && (
          <span className="shrink-0 rounded-md bg-[var(--info-soft)]/15 px-1.5 py-0.5 text-micro text-[var(--info-text-2)]">
            快照
          </span>
        )}
        <span className="shrink-0 text-micro text-[var(--text-faint)]">
          {formatRelativeTime(item.last_searched_at)}
        </span>
      </button>
      <DeleteHistoryButton
        label={`删除搜索历史：${item.keyword}（${item.vertical === "titles" ? "影视" : item.label ?? "资源全部"}）`}
        onClick={onRemove}
        className="touch-reveal mr-1 opacity-0 group-hover/variant:opacity-100"
      />
    </li>
  );
}

/** 单记录组在主行直接显示垂直与资源分类，不必展开才能辨认。 */
function HistoryTypeBadges({ item }: { item: SearchHistoryItem }) {
  const isMedia = item.vertical === "titles";
  return (
    <>
      <span
        className={`shrink-0 rounded-md px-1.5 py-0.5 text-micro ${
          isMedia
            ? "bg-[var(--accent-soft)] text-[var(--accent-2)]"
            : "bg-white/[0.07] text-[var(--text-muted)]"
        }`}
      >
        {isMedia ? "影视" : "资源"}
      </span>
      {!isMedia && item.label && (
        <span className="shrink-0 rounded-md bg-white/[0.07] px-1.5 py-0.5 text-micro text-[var(--text-muted)]">
          {item.label}
        </span>
      )}
    </>
  );
}

/** 记录的范围：「影视」「资源」「资源 · 电影」（同 iOS SearchHomeView.scopeLabel）。 */
function historyScopeLabel(item: SearchHistoryItem): string {
  if (item.vertical === "titles") return "影视";
  return item.label ? `资源 · ${item.label}` : "资源";
}

/** 记录的时间与快照：「4 小时前 · 快照」（同 iOS SearchHomeView.detailLine）。 */
function historyDetailLine(item: SearchHistoryItem): string {
  const time = formatRelativeTime(item.last_searched_at);
  return item.has_snapshot ? `${time} · 快照` : time;
}

/**
 * 银玻璃的最近搜索分组（对齐 iOS SearchHomeView.groupRow）：同关键词的记录归成一组、永远展开，
 * 没有折叠箭头——箭头（展开）和整行（打开）挤在同一行会误触（原生 App 真机反馈），
 * 每行只做一件事：点哪行就回放哪条记录。
 *   主行   时钟图标 + 关键词，副行「范围 · 时间 · 快照」（组内最近一条）；✕ 删整组（多条时先确认）
 *   子行   图标列换成「↳」连接符，写该条的范围与「时间 · 快照」；✕ 删这一条
 * 组内不画分隔线、只在组与组之间画，一眼看出哪几行是一组。✕ 在触屏上常显（touch-reveal），
 * 桌面悬停才出；iOS 的左滑删除网页暂不做。
 */
function SilverHistoryGroup({
  group,
  active,
  onHover,
  onPickItem,
  onRemoveItem,
  onRemoveGroup,
}: {
  group: HistoryGroup;
  active: boolean;
  onHover: () => void;
  onPickItem: (item: SearchHistoryItem) => void;
  onRemoveItem: (id: number) => void;
  onRemoveGroup: () => void;
}) {
  const [latest, ...rest] = group.items;
  return (
    <li className="border-b border-white/[0.06] py-0.5 last:border-b-0">
      <div
        className={`group/history flex items-center rounded-[10px] transition-colors ${
          active ? "bg-white/[0.07]" : "hover:bg-white/[0.04]"
        }`}
        onMouseEnter={onHover}
      >
        <button
          type="button"
          onClick={() => onPickItem(latest)}
          className="flex min-w-0 flex-1 items-center gap-3 py-2 pl-2.5 pr-1 text-left"
        >
          <HistoryIcon className="size-[18px] shrink-0 text-[var(--text-faint)]" />
          <span className="min-w-0 flex-1">
            <span className="block truncate text-ui leading-5 text-[var(--text)]">
              {group.keyword}
            </span>
            <span className="block truncate text-caption text-[var(--text-muted)]">
              {historyScopeLabel(latest)} · {historyDetailLine(latest)}
            </span>
          </span>
        </button>
        <DeleteHistoryButton
          label={
            rest.length > 0 ? `删除搜索历史组：${group.keyword}` : `删除搜索历史：${group.keyword}`
          }
          onClick={onRemoveGroup}
          className="touch-reveal mr-1.5 opacity-0 group-hover/history:opacity-100"
        />
      </div>
      {rest.map((item) => (
        <div
          key={item.id}
          className="group/variant flex items-center rounded-[10px] transition-colors hover:bg-white/[0.04]"
        >
          <button
            type="button"
            onClick={() => onPickItem(item)}
            className="flex min-w-0 flex-1 items-center gap-3 py-1.5 pl-2.5 pr-1 text-left"
          >
            <span aria-hidden="true" className="w-[18px] shrink-0 text-center text-sub text-[var(--text-faint)]">
              ↳
            </span>
            <span className="min-w-0 flex-1 truncate text-sub text-[var(--text-muted)]">
              {historyScopeLabel(item)}
              <span className="text-[var(--text-faint)]"> · {historyDetailLine(item)}</span>
            </span>
          </button>
          <DeleteHistoryButton
            label={`删除搜索历史：${item.keyword}（${item.vertical === "titles" ? "影视" : item.label ?? "资源全部"}）`}
            onClick={() => onRemoveItem(item.id)}
            className="touch-reveal mr-1.5 opacity-0 group-hover/variant:opacity-100"
          />
        </div>
      ))}
    </li>
  );
}

/** 全屏搜索页的大号段头（同 iOS 系统搜索页的「最近搜索」），右侧可挂一个动作。 */
function SectionTitle({ title, action }: { title: string; action?: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between px-2.5 pb-1 pt-4">
      <h3 className="text-body-lg font-semibold text-[var(--text)]">{title}</h3>
      {action}
    </div>
  );
}

/**
 * 全屏搜索页的范围 / 动作行（同 iOS SearchHomeView.scopeRow）：图标 + 标题（+ 一行说明）
 * （+ 进入箭头），整行可点。「搜索“xx”」「浏览最新资源」「在其他范围搜索」共用。
 */
/** 一条搜索联想：片名用胶片图标、人名用人像图标；键盘高亮与历史行同一套样式。 */
function SuggestionRow({
  suggestion,
  active,
  onHover,
  onPick,
}: {
  suggestion: LibrarySearchSuggestion;
  active: boolean;
  onHover: () => void;
  onPick: () => void;
}) {
  return (
    <li>
      <button
        type="button"
        onMouseDown={(event) => event.preventDefault()}
        onMouseEnter={onHover}
        onClick={onPick}
        aria-label={`搜索「${suggestion.text}」`}
        className={`flex w-full items-center gap-3 rounded-[10px] px-2.5 py-2 text-left transition-colors hover:bg-white/[0.04] active:bg-white/[0.07] ${
          active ? "bg-white/[0.06]" : ""
        }`}
      >
        <span className="grid w-[18px] shrink-0 place-items-center text-[var(--text-faint)]">
          {suggestion.type === "person" ? (
            <UserIcon className="size-[17px]" />
          ) : (
            <FilmIcon className="size-[17px]" />
          )}
        </span>
        <span className="min-w-0 flex-1 truncate text-ui leading-5 text-[var(--text)]">
          {suggestion.text}
        </span>
        <span className="shrink-0 text-caption text-[var(--text-faint)]">
          {suggestion.type === "person" ? "人物" : "影片"}
        </span>
      </button>
    </li>
  );
}

function ScopeRow({
  icon,
  title,
  subtitle,
  chevron = false,
  onClick,
}: {
  icon: React.ReactNode;
  title: string;
  subtitle?: string | null;
  chevron?: boolean;
  onClick: () => void;
}) {
  return (
    <li>
      <button
        type="button"
        onMouseDown={(event) => event.preventDefault()}
        onClick={onClick}
        className="flex w-full items-center gap-3 rounded-[10px] px-2.5 py-2 text-left transition-colors hover:bg-white/[0.04] active:bg-white/[0.07]"
      >
        <span className="grid w-[18px] shrink-0 place-items-center text-[var(--accent)]">{icon}</span>
        <span className="min-w-0 flex-1">
          <span className="block truncate text-ui leading-5 text-[var(--text)]">{title}</span>
          {subtitle && (
            <span className="block truncate text-caption text-[var(--text-muted)]">{subtitle}</span>
          )}
        </span>
        {chevron && <ChevronRightIcon className="size-4 shrink-0 text-[var(--text-faint)]" />}
      </button>
    </li>
  );
}

/** 分类行的图标：电影 / 剧集有专属图标，其余内置分类用文件夹，自定义分类用书签。 */
function TabIcon({ tab }: { tab: SearchTab }) {
  const cls = "size-[18px]";
  if (tab.type === "preset") return <BookmarkIcon className={cls} />;
  if (tab.id === "movie") return <FilmIcon className={cls} />;
  if (tab.id === "tv") return <TvIcon className={cls} />;
  return <FolderIcon className={cls} />;
}

/** 组与子记录共用的删除按钮；mousedown 不抢走搜索输入框焦点。 */
function DeleteHistoryButton({
  label,
  onClick,
  className,
}: {
  label: string;
  onClick: () => void;
  className?: string;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      onMouseDown={(event) => event.preventDefault()}
      onClick={onClick}
      // touch-target：21px 的裸 X 键是移动端删除历史的唯一入口，命中区
      // 撑到 44px（伪元素方案，外观不变）——紧贴相邻可点行，太小必误触
      className={`touch-target rounded-md p-1 text-[var(--text-faint)] transition-opacity hover:bg-white/[0.1] hover:text-[var(--text-muted)] ${className ?? ""}`}
    >
      <svg
        viewBox="0 0 24 24"
        className="size-[13px]"
        fill="none"
        stroke="currentColor"
        strokeWidth={2}
        strokeLinecap="round"
        aria-hidden="true"
      >
        <path d="m6 6 12 12M18 6 6 18" />
      </svg>
    </button>
  );
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="rounded bg-white/[0.07] px-1 py-px font-sans text-micro text-[var(--text-muted)]">
      {children}
    </kbd>
  );
}
