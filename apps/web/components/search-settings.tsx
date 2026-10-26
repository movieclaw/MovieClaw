"use client";

import { useLocale, useTranslations } from "next-intl";

import { useEffect, useRef, useState } from "react";

import { ErrorBanner, Toggle } from "@/components/cloud-push-ui";
import { useConfirm } from "@/components/feedback";
import { GripIcon, PlusIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsCard,
  SettingsMoreMenu,
  SettingsSection,
} from "@/components/settings-ui";
import { listConfiguredSites, listSiteCatalog } from "@/lib/api/sites";
import {
  categoryLabel,
  presetSummary,
  tabLabel,
  CATEGORY_OPTIONS,
  type PresetTab,
  type SearchTab,
  type TorrentCategory,
} from "@/lib/categories";
import type { AppMessageKey } from "@/lib/i18n/translate";
import { HttpError } from "@/lib/http";
import { useSearchPrefs } from "@/lib/search-prefs";
import { nanoid } from "nanoid";

/**
 * 拖拽排序的进行时状态。列表行数有限（7 个内置分类 + 至多 20 个预设），
 * 指针移动时整组重渲染的开销可忽略，直接放 useState 里换取
 * 「其余行实时让位」的动画简洁性。
 *
 * 坐标算法（行高不等也成立——预设行/带说明的分类行有第二行文字）：
 * - 按下时记录每一行的**原始中心 Y**（centers）与被拖行的高度；
 * - 拖动中，被拖行中心 = 原中心 + dy；目标下标 to = 中心在其上方的「其他行」数
 *   ——即把被拖行抽出后应插入的位置；
 * - 其余行按 from/to 的区间关系整体平移 ±被拖行高度（CSS transform 过渡），
 *   实时腾出落点。
 */
interface DragState {
  /** 被拖行的原始下标 */
  from: number;
  /** 当前应落入的目标下标（等于 from 表示位置未变） */
  to: number;
  /** 指针相对按下点的纵向位移 */
  dy: number;
  /** 按下时的指针 Y（视口坐标） */
  startY: number;
  /** 被拖行高度：其余行让位的平移距离 */
  height: number;
  /** 按下时每一行的中心 Y（视口坐标） */
  centers: number[];
}

/**
 * 内置分类的补充说明（展示在分类行名称下方）：只给语义不自明的分类写，
 * 电影/剧集这类一望即知的不加，避免整列说明文字变成噪音。
 */
const CATEGORY_HINT: Partial<Record<TorrentCategory, AppMessageKey>> = {
  other: "search.preferences.otherHint",
};

/** 预设编辑器的会话状态：新建（editingId=null）或编辑某个预设。 */
interface EditorState {
  /** 正在编辑的预设 id；null = 新建 */
  editingId: string | null;
  name: string;
  categories: TorrentCategory[];
  siteIds: string[];
  /** 图览模式：用该分类搜索时，结果页默认以图墙展示 */
  posterMode: boolean;
  /** 无痕搜索：用该分类搜索时不写入搜索历史 */
  skipHistory: boolean;
}

/** 站点勾选器的选项：已配置站点 + 展示名 + 当前是否可用。 */
interface SiteOption {
  siteId: string;
  displayName: string;
  usable: boolean;
}

/**
 * 搜索分类配置：搜索面板分类栏的完整设置，作为「资源站点」分区的
 * 「搜索分类」标签页（分类筛的就是同分区接入的那些站点，不单设分区）。
 *
 * 一个统一混排的标签列表：内置分类（不可删只可隐藏）与自定义分类（可增删改）
 * 同列拖拽排序、同款显隐开关；「全部」固定在搜索面板首位，不在此列表中。
 *
 * 自定义分类 = 命名的「分类组合 × 站点组合」预设：新建入口在小节标题行右侧，
 * 打开编辑器（名称 + 分类勾选 + 站点勾选），分类/站点都不勾选表示「不限」；
 * 编辑 / 删除收在每行的 ⋯ 菜单里。
 * 站点勾选器只列**已配置**站点；暂时不可用（禁用/验证未通过）的照样可勾选，
 * 搜索时会自动跳过。
 *
 * 所有改动即时保存到服务端（乐观更新，失败回滚并显示错误），无需保存按钮；
 * 编辑器内的「保存」也是同一条链路，失败时编辑器保持打开。
 *
 * 拖拽用原生 Pointer Events 手写（约 60 行），不为此引入 dnd 库：
 * 场景是单列定长小列表，库的能力（多容器、虚拟滚动、传感器抽象）全用不上。
 */
export function SearchSection() {
  const t = useTranslations();
  const locale = useLocale();
  const confirm = useConfirm();
  const { tabs, loading, saveTabs } = useSearchPrefs();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [drag, setDrag] = useState<DragState | null>(null);
  const [editor, setEditor] = useState<EditorState | null>(null);
  const rowRefs = useRef<(HTMLDivElement | null)[]>([]);

  /** 统一的保存包装：清错误 + busy 防抖 + 中文错误回显；返回是否成功。 */
  const apply = async (next: SearchTab[]): Promise<boolean> => {
    setError(null);
    setBusy(true);
    try {
      await saveTabs(next);
      return true;
    } catch (err) {
      setError(err instanceof HttpError ? err.message : t("search.preferences.saveFailed"));
      return false;
    } finally {
      setBusy(false);
    }
  };

  const toggle = (index: number, visible: boolean) =>
    void apply(tabs.map((t, i) => (i === index ? { ...t, visible } : t)));

  /** 把 from 行抽出并插入 to 位置，返回新数组。 */
  const reorder = (from: number, to: number) => {
    const next = [...tabs];
    const [moved] = next.splice(from, 1);
    next.splice(to, 0, moved);
    return next;
  };

  /** 键盘微调：手柄聚焦时 ↑/↓ 与相邻行交换（拖拽的无障碍兜底）。 */
  const nudge = (index: number, delta: -1 | 1) => {
    const target = index + delta;
    if (target < 0 || target >= tabs.length) return;
    void apply(reorder(index, target));
  };

  // ---- 拖拽三事件：都挂在手柄上，setPointerCapture 后移动/抬起始终回到手柄 ----

  const onDragStart = (index: number) => (e: React.PointerEvent<HTMLButtonElement>) => {
    if (busy || loading) return;
    e.preventDefault();
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      // 无活动指针（合成事件等）时 capture 会抛错；丢失捕获只影响
      // 指针移出手柄后的跟踪，不应让拖拽直接失效
    }
    const rects = rowRefs.current.slice(0, tabs.length).map((el) => el?.getBoundingClientRect());
    if (rects.some((r) => !r)) return;
    setDrag({
      from: index,
      to: index,
      dy: 0,
      startY: e.clientY,
      height: rects[index]!.height,
      centers: rects.map((r) => r!.top + r!.height / 2),
    });
  };

  const onDragMove = (e: React.PointerEvent<HTMLButtonElement>) => {
    setDrag((d) => {
      if (!d) return d;
      const dy = e.clientY - d.startY;
      const center = d.centers[d.from] + dy;
      // 目标下标 = 中心仍在被拖行中心之上的「其他行」数
      let to = 0;
      for (let i = 0; i < d.centers.length; i++) {
        if (i !== d.from && d.centers[i] < center) to++;
      }
      return { ...d, dy, to };
    });
  };

  const onDragEnd = () => {
    if (!drag) return;
    const { from, to } = drag;
    setDrag(null);
    if (from !== to) void apply(reorder(from, to));
  };

  /** 拖动中每一行的内联样式：被拖行跟随指针并抬起，其余行让位平移。 */
  const rowStyle = (index: number): React.CSSProperties => {
    if (!drag) return {};
    if (index === drag.from) {
      return { transform: `translateY(${drag.dy}px) scale(1.02)`, zIndex: 10 };
    }
    const { from, to, height } = drag;
    let shift = 0;
    if (from < to && index > from && index <= to) shift = -height;
    if (to < from && index >= to && index < from) shift = height;
    return { transform: `translateY(${shift}px)`, transition: "transform 200ms ease" };
  };

  /** 打开编辑器：新建（空草稿）或载入某个预设的当前值。 */
  const openEditor = (preset: PresetTab | null) => {
    setError(null);
    setEditor(
      preset
        ? {
            editingId: preset.id,
            name: preset.name,
            categories: preset.categories,
            siteIds: preset.site_ids,
            posterMode: preset.poster_mode,
            skipHistory: preset.skip_history,
          }
        : {
            editingId: null,
            name: "",
            categories: [],
            siteIds: [],
            posterMode: false,
            skipHistory: false,
          },
    );
  };

  /** 编辑器保存：新建追加到列表末尾（默认可见），编辑则原位替换（保留显隐）。 */
  const savePreset = async (draft: EditorState) => {
    const next: SearchTab[] = draft.editingId
      ? tabs.map((t) =>
          t.type === "preset" && t.id === draft.editingId
            ? {
                ...t,
                name: draft.name,
                categories: draft.categories,
                site_ids: draft.siteIds,
                poster_mode: draft.posterMode,
                skip_history: draft.skipHistory,
              }
            : t,
        )
      : [
          ...tabs,
          {
            type: "preset",
            // 前端生成短随机 id：偏好是整体覆盖式保存，后端无法区分新旧行
            id: `p-${nanoid(8)}`,
            name: draft.name,
            visible: true,
            categories: draft.categories,
            site_ids: draft.siteIds,
            poster_mode: draft.posterMode,
            skip_history: draft.skipHistory,
          },
        ];
    if (await apply(next)) setEditor(null);
  };

  const deletePreset = async (preset: PresetTab) => {
    const ok = await confirm({
      title: t("search.preferences.deleteTitle", { name: preset.name }),
      description: t("search.preferences.deleteHint"),
      confirmLabel: t("common.delete"),
      tone: "danger",
    });
    if (!ok) return;
    if (editor?.editingId === preset.id) setEditor(null);
    void apply(tabs.filter((t) => !(t.type === "preset" && t.id === preset.id)));
  };

  return (
    <div className="space-y-6">
      <SettingsSection
        title={t("search.preferences.title")}
        action={
          <button
            type="button"
            onClick={() => openEditor(null)}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
          >
            <PlusIcon className="size-4" />
            {t("search.preferences.new")}
          </button>
        }
        footnote={
          t("search.preferences.footnote")
        }
      >
        {/* divide-y 常驻：拖动中若移除分隔线会让整列高度跳 1px×行数，按下瞬间坐标漂移 */}
        <div className="css-glass select-none divide-y divide-[var(--line)] !rounded-xl">
          {tabs.map((tab, index) => (
            <div
              key={`${tab.type}:${tab.id}`}
              ref={(el) => {
                rowRefs.current[index] = el;
              }}
              style={rowStyle(index)}
              className={`relative flex min-h-[56px] items-center gap-3 px-4 py-3 ${
                loading ? "opacity-50" : ""
              } ${
                drag?.from === index
                  ? "rounded-xl bg-[#1d222d]/95 shadow-[0_16px_40px_-12px_rgba(0,0,0,0.75)] ring-1 ring-white/[0.16] backdrop-blur-md"
                  : ""
              }`}
            >
              {/* 拖拽手柄：按住拖动排序；聚焦后 ↑/↓ 微调。touch-none 禁掉触屏滚动手势 */}
              <button
                type="button"
                aria-label={t("search.preferences.reorder", { name: tabLabel(tab, locale) })}
                disabled={busy || loading}
                onPointerDown={onDragStart(index)}
                onPointerMove={onDragMove}
                onPointerUp={onDragEnd}
                onPointerCancel={onDragEnd}
                onKeyDown={(e) => {
                  if (e.key === "ArrowUp" || e.key === "ArrowDown") {
                    e.preventDefault();
                    nudge(index, e.key === "ArrowUp" ? -1 : 1);
                  }
                }}
                className={`-ml-1.5 touch-none rounded-md p-1 text-[var(--text-faint)] transition-colors hover:bg-white/[0.08] hover:text-[var(--text)] focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)] disabled:pointer-events-none disabled:opacity-30 ${
                  drag?.from === index ? "cursor-grabbing text-[var(--text)]" : "cursor-grab"
                }`}
              >
                <GripIcon className="size-4" />
              </button>

              {tab.type === "category" ? (
                <div className="min-w-0 flex-1">
                  <p className="text-body font-medium text-[var(--text)]">
                    {categoryLabel(tab.id, locale)}
                  </p>
                  {CATEGORY_HINT[tab.id] && (
                    <p className="mt-0.5 text-caption text-[var(--text-faint)]">
                      {t(CATEGORY_HINT[tab.id]!)}
                    </p>
                  )}
                </div>
              ) : (
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <p className="truncate text-body font-medium text-[var(--text)]">{tab.name}</p>
                    <span className="shrink-0 rounded-full bg-[var(--accent-soft)] px-2 py-0.5 text-micro font-semibold text-[var(--accent)]">
                      {t("search.preferences.custom")}
                    </span>
                  </div>
                  <p className="mt-0.5 truncate text-caption text-[var(--text-faint)]">
                    {presetSummary(tab, locale)}
                  </p>
                </div>
              )}

              {tab.type === "preset" && (
                <SettingsMoreMenu
                  label={t("search.preferences.actions", { name: tab.name })}
                  disabled={busy || loading}
                  items={[
                    { label: t("search.preferences.edit"), onSelect: () => openEditor(tab) },
                    { label: t("common.delete"), onSelect: () => void deletePreset(tab), danger: true },
                  ]}
                />
              )}

              {/* 显隐开关：改完即存 */}
              <Toggle
                checked={tab.visible}
                disabled={busy || loading}
                label={t("search.preferences.visibility", { visible: tab.visible ? "yes" : "no", name: tabLabel(tab, locale) })}
                onChange={(checked) => toggle(index, checked)}
              />
            </div>
          ))}
        </div>
      </SettingsSection>

      {editor && (
        <PresetEditor
          draft={editor}
          busy={busy}
          onChange={setEditor}
          onSave={() => void savePreset(editor)}
          onCancel={() => {
            setEditor(null);
            setError(null);
          }}
        />
      )}

      {error && <ErrorBanner>{error}</ErrorBanner>}
    </div>
  );
}

/**
 * 预设编辑器：名称 + 分类勾选 + 站点勾选。
 *
 * 站点选项在打开时向后端拉取（已配置站点 ∩ 站点目录，取展示名与可用状态）；
 * 分类/站点都不勾选表示「不限」，用 chips 的空选态自然表达，不设「全选」按钮。
 */
function PresetEditor({
  draft,
  busy,
  onChange,
  onSave,
  onCancel,
}: {
  draft: EditorState;
  busy: boolean;
  onChange: (next: EditorState) => void;
  onSave: () => void;
  onCancel: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  // null = 加载中；[] = 没有任何已配置站点
  const [siteOptions, setSiteOptions] = useState<SiteOption[] | null>(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([listConfiguredSites(), listSiteCatalog()])
      .then(([configured, catalog]) => {
        if (cancelled) return;
        const nameOf = new Map(catalog.map((c) => [c.site_id, c.display_name]));
        setSiteOptions(
          configured.map((s) => ({
            siteId: s.site_id,
            displayName: nameOf.get(s.site_id) ?? s.site_id,
            usable: s.usable,
          })),
        );
      })
      .catch(() => !cancelled && setSiteOptions([]));
    return () => {
      cancelled = true;
    };
  }, []);

  const toggleCategory = (id: TorrentCategory) =>
    onChange({
      ...draft,
      categories: draft.categories.includes(id)
        ? draft.categories.filter((c) => c !== id)
        : [...draft.categories, id],
    });

  const toggleSite = (id: string) =>
    onChange({
      ...draft,
      siteIds: draft.siteIds.includes(id)
        ? draft.siteIds.filter((s) => s !== id)
        : [...draft.siteIds, id],
    });

  const chipCls = (active: boolean) =>
    `rounded-full border px-3 py-1 text-sub transition-colors ${
      active
        ? "border-[var(--accent)]/60 bg-[var(--accent)]/15 text-[var(--accent)]"
        : "border-white/[0.09] bg-white/[0.04] text-[var(--text-muted)] hover:border-white/[0.18] hover:text-[var(--text)]"
    }`;

  return (
    <SettingsCard
      title={draft.editingId ? t("search.preferences.editorEdit") : t("search.preferences.new")}
      action={
        <div className="flex gap-2">
          <button type="button" onClick={onCancel} disabled={busy} className={SETTINGS_BUTTON_CLASS}>
            {t("common.cancel")}
          </button>
          <button
            type="button"
            onClick={onSave}
            disabled={busy || !draft.name.trim()}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? t("search.preferences.saving") : t("common.save")}
          </button>
        </div>
      }
    >
      <div className="space-y-5">
        <div>
          <label className="mb-1.5 block text-sub font-medium text-[var(--text-muted)]">
            {t("search.preferences.name")}
          </label>
          <input
            type="text"
            value={draft.name}
            onChange={(e) => onChange({ ...draft, name: e.target.value })}
            maxLength={16}
            placeholder={t("search.preferences.namePlaceholder")}
            autoFocus
            className={`${SETTINGS_INPUT_CLASS} w-full`}
          />
        </div>

        <div>
          <p className="mb-1.5 text-sub font-medium text-[var(--text-muted)]">
            {t("search.preferences.categories")} <span className="text-[var(--text-faint)]">{t("search.preferences.categoriesHint")}</span>
          </p>
          <div className="flex flex-wrap gap-1.5">
            {CATEGORY_OPTIONS.map((opt) => (
              <button
                key={opt.value}
                type="button"
                onClick={() => toggleCategory(opt.value)}
                className={chipCls(draft.categories.includes(opt.value))}
              >
                {categoryLabel(opt.value, locale)}
              </button>
            ))}
          </div>
        </div>

        <div>
          <p className="mb-1.5 text-sub font-medium text-[var(--text-muted)]">
            {t("search.preferences.sites")} <span className="text-[var(--text-faint)]">{t("search.preferences.sitesHint")}</span>
          </p>
          {siteOptions === null ? (
            <p className="text-sub text-[var(--text-faint)]">{t("search.preferences.loadingSites")}</p>
          ) : siteOptions.length === 0 ? (
            <p className="text-sub text-[var(--text-faint)]">
              {t("search.preferences.noSites")}
            </p>
          ) : (
            <div className="flex flex-wrap gap-1.5">
              {siteOptions.map((site) => (
                <button
                  key={site.siteId}
                  type="button"
                  onClick={() => toggleSite(site.siteId)}
                  title={site.usable ? undefined : t("search.preferences.unavailableHint")}
                  className={`${chipCls(draft.siteIds.includes(site.siteId))} ${
                    site.usable ? "" : "opacity-55"
                  }`}
                >
                  {site.displayName}
                  {!site.usable && <span className="ml-1 text-micro">{t("search.preferences.unavailable")}</span>}
                </button>
              ))}
            </div>
          )}
        </div>

        <div className="flex items-center gap-3">
          <div className="min-w-0 flex-1">
            <p className="text-sub font-medium text-[var(--text-muted)]">{t("search.preferences.poster")}</p>
            <p className="mt-0.5 text-caption leading-4 text-[var(--text-faint)]">
              {t("search.preferences.posterHint")}
            </p>
          </div>
          <Toggle
            checked={draft.posterMode}
            label={t("search.preferences.posterToggle", { enabled: draft.posterMode ? "yes" : "no" })}
            onChange={(checked) => onChange({ ...draft, posterMode: checked })}
          />
        </div>

        <div className="flex items-center gap-3">
          <div className="min-w-0 flex-1">
            <p className="text-sub font-medium text-[var(--text-muted)]">{t("search.preferences.private")}</p>
            <p className="mt-0.5 text-caption leading-4 text-[var(--text-faint)]">
              {t("search.preferences.privateHint")}
            </p>
          </div>
          <Toggle
            checked={draft.skipHistory}
            label={t("search.preferences.privateToggle", { enabled: draft.skipHistory ? "yes" : "no" })}
            onChange={(checked) => onChange({ ...draft, skipHistory: checked })}
          />
        </div>
      </div>
    </SettingsCard>
  );
}
