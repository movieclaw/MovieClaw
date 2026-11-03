"use client";

import { useLocale, useTranslations } from "next-intl";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";

import { useLanguage } from "@/lib/i18n/provider";

import { useToast } from "@/components/feedback";
import {
  fetchUiPreferences,
  normalizeUiPreferences,
  updateUiPreferences,
  type UiPreferences,
} from "@/lib/api/ui";
import {
  catalogTheme,
  subscribeThemeCatalog,
  themeCatalogFresh,
  themeCatalogVersion,
} from "@/lib/theme-catalog";
import { refreshThemeCatalog } from "@/lib/theme-catalog-sync";
import {
  ensureThemeStylesheet,
  loadedDefinition,
  loadTheme,
  subscribeThemeRuntime,
  themeLoadStatus,
  themeRuntimeVersion,
  themeSlotErrors,
} from "@/lib/theme-runtime";
import {
  DEFAULT_THEME_ID,
  PHONE_THEME_QUERY,
  isKnownTheme,
  normalizeThemeId,
  themeMeta,
  type ThemeLayout,
  type ThemeMeta,
} from "@/lib/themes";
import { useMediaQuery } from "@/lib/use-media-query";
import { readUiPrefsCache, writeUiPrefsCache } from "@/lib/ui-prefs-cache";

/**
 * 界面偏好（按页面分组的样式设定）的全局状态。
 *
 * 与 backdrop / search-prefs 同款 Context 模式：应用启动时向后端拉**一次**
 * `ui.preferences` 整个配置域，之后全站（设置页、各业务页面）共享同一份状态
 * ——SPA 内切换页面不会重复请求；设置页改动即时保存并同步到所有消费者。
 *
 * 首帧不等接口：初始值取自 localStorage 缓存（上次拉到的偏好，见
 * lib/ui-prefs-cache.ts），接口返回后再以服务端值为准覆盖并回写缓存。
 * 没有这层缓存，自定义过导航顺序的用户每次刷新都会先看到默认排序、
 * 接口回来后再重排一次——这一跳是肉眼可见的（玻璃透明度、蒙版同理）。
 *
 * 扩展方式：后端配置域加字段 → lib/api/ui.ts 的类型与 DEFAULT_UI_PREFS 对齐
 * → 消费页面从 useUiPrefs().prefs.<页面> 取值。本文件无需再动。
 */
interface UiPrefsContextValue {
  /** 全站界面偏好（按页面分组）。存在预览草稿时返回草稿，实现「调节即生效」 */
  prefs: UiPreferences;
  /** 已保存（后端确认）的偏好，设置页用它判断草稿是否有未保存改动 */
  savedPrefs: UiPreferences;
  /** 首次向后端拉取是否进行中 */
  loading: boolean;
  /** 整体保存偏好；失败时状态回滚并抛错，由调用方展示错误 */
  savePrefs: (next: UiPreferences) => Promise<void>;
  /**
   * 设置未保存的预览草稿：全站消费者立即按草稿渲染（实时预览），
   * 传 null 撤销草稿、回到已保存值。仅设置页在调节期间使用。
   */
  setPreview: (draft: UiPreferences | null) => void;
  /**
   * 生效主题 id（docs/design/theme-plugins.md §4.3）：偏好里存的主题认得、外框组件没加载失败
   * 才是它，否则是默认主题——偏好本身原样保留，主题回来（重装、恢复启用）即自动生效。
   */
  themeId: string;
  /** 主题还没就绪（等主题目录、或外框组件还在加载）：外壳先显示启动画面 */
  themePending: boolean;
}

const UiPrefsContext = createContext<UiPrefsContextValue | null>(null);

/**
 * 当前是不是「手机」设备类（含横过来拿）：主题按设备类分开存时取哪一份。
 * 判据见 lib/themes.ts 的 PHONE_THEME_QUERY——不能只看页面宽度，手机横屏会越过
 * 768 被当成电脑。外壳结构的分叉仍用 useIsMobile()（只看宽度），两者不是一回事。
 */
export function useIsPhone(): boolean {
  return useMediaQuery(PHONE_THEME_QUERY);
}

/**
 * 按设备类解析生效主题（2026-09-24 起手机 / 电脑可分别选主题）：
 * 当前设备类有覆盖字段（theme_mobile / theme_desktop）就用它，没有（老账号、
 * 未单独设置）回落通用 theme——老数据唯一来源，行为与升级前完全一致。
 * 覆盖值可能是老后端 / 坏缓存里的垃圾，最终由 normalizeThemeId 兜底。
 */
function resolveThemeId(prefs: UiPreferences, phone: boolean): string {
  const override = phone ? prefs.theme_mobile : prefs.theme_desktop;
  return normalizeThemeId(override ?? prefs.theme);
}

/**
 * 请求的主题能不能用：认得（内置或已装且契约兼容），且外框组件没加载失败。
 * 外框组件只按服务端目录给的地址加载：本地快照只当首帧提示，服务端目录拉不到时，
 * 带外框组件的主题按不可用处理（不执行快照里的地址）。
 */
function effectiveThemeId(requested: string, catalogSettled: boolean): string {
  if (!isKnownTheme(requested)) return DEFAULT_THEME_ID;
  const entry = catalogTheme(requested);
  if (entry?.script) {
    if (!themeCatalogFresh()) return catalogSettled ? DEFAULT_THEME_ID : requested;
    if (themeLoadStatus(requested) === "failed") return DEFAULT_THEME_ID;
  }
  return requested;
}

/** 请求的主题还在路上：主题目录没拉到（不知道装没装），或外框组件还在加载。 */
function themeIsPending(requested: string, catalogSettled: boolean): boolean {
  if (requested === DEFAULT_THEME_ID) return false;
  if (!isKnownTheme(requested)) return !catalogSettled;
  const entry = catalogTheme(requested);
  if (!entry?.script || loadedDefinition(requested)) return false;
  if (!themeCatalogFresh()) return !catalogSettled;
  const status = themeLoadStatus(requested);
  return status === "idle" || status === "loading";
}

export function UiPrefsProvider({ children }: { children: React.ReactNode }) {
  const locale = useLocale();
  const t = useTranslations();
  const { setLanguage } = useLanguage();
  // 惰性初始化读缓存：本 Provider 只在 AuthGate 确认登录后于客户端渲染
  // （见 components/app-shell.tsx），不参与 SSR，故可直接读 localStorage。
  // 缓存内容不可信，统一过一遍 normalizeUiPreferences 补齐缺项（无缓存时
  // 它补出来的就是 DEFAULT_UI_PREFS，与改动前的初始值完全一致）。
  const [prefs, setPrefs] = useState<UiPreferences>(() =>
    normalizeUiPreferences(readUiPrefsCache()),
  );
  const [preview, setPreview] = useState<UiPreferences | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    fetchUiPreferences()
      .then((data) => {
        if (cancelled) return;
        setPrefs(data);
        // 服务端值即下次启动的首帧值
        writeUiPrefsCache(data);
      })
      .catch((err) => {
        // 拉取失败不致命：静默沿用首帧缓存里的偏好（没有缓存时即内置默认样式）
        console.warn("读取界面设置失败，暂用默认样式：", err);
      })
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!loading) setLanguage(prefs.language);
  }, [loading, prefs.language, setLanguage]);

  // 主题目录（docs/design/theme-plugins.md §4.3）：首帧先用上次的快照，这里拉服务端的
  // 整表替换。拉取失败也算「落定」：认不出的主题按默认渲染，不让外壳一直等。
  const catalogVersion = useSyncExternalStore(subscribeThemeCatalog, themeCatalogVersion, () => 0);
  const runtimeVersion = useSyncExternalStore(subscribeThemeRuntime, themeRuntimeVersion, () => 0);
  const [catalogSettled, setCatalogSettled] = useState(themeCatalogFresh);
  useEffect(() => {
    let cancelled = false;
    refreshThemeCatalog(locale)
      .catch((err) => console.warn("读取主题目录失败，暂用上次的：", err))
      .finally(() => !cancelled && setCatalogSettled(true));
    return () => {
      cancelled = true;
    };
  }, [locale]);

  // 蒙版是全局 CSS（.page-scrim 的底色 + backdrop-filter），不像侧栏玻璃那样
  // 逐组件传参，因此这里把生效值（含预览草稿）写到 <html> 的 --scrim-blur /
  // --scrim-dark 变量上，全站蒙版即时跟随；调节滑杆时也走预览草稿，拖动即预览。
  const effectiveScrim = (preview ?? prefs).scrim;
  useEffect(() => {
    const root = document.documentElement;
    root.style.setProperty("--scrim-blur", `${effectiveScrim.blur}px`);
    root.style.setProperty("--scrim-dark", `${effectiveScrim.dark}`);
    // blur(0px) 仍启用滤镜；零档让共用蒙版彻底停用 backdrop-filter。
    root.toggleAttribute("data-scrim-no-blur", effectiveScrim.blur === 0);
  }, [effectiveScrim.blur, effectiveScrim.dark]);

  // 主题同步：把生效主题（含设置页的预览草稿——点主题卡实时预览就靠它）写到
  // <html> 的 data-theme 属性上。token 层与圆角换档都挂在这个作用域，属性一改
  // 全站换肤；结构层（外壳分支）由 useTheme() 的消费方跟随同一份值渲染。
  // 默认主题移除属性而不是写 data-theme="silver"，与防闪烁脚本（只认非默认
  // 主题）的落点保持一致，SSR 首屏也无需任何属性。外壳几何由主题 CSS 在
  // data-theme 作用域里声明，属性一改就跟着换，这里不必另写。
  const phone = useIsPhone();
  const requestedTheme = resolveThemeId(preview ?? prefs, phone);
  // catalogVersion / runtimeVersion 只为在目录、加载状态变化时重算这两个值
  void catalogVersion;
  void runtimeVersion;
  const effectiveTheme = effectiveThemeId(requestedTheme, catalogSettled);
  const themePending = themeIsPending(requestedTheme, catalogSettled);

  // 外框组件按需加载：只按服务端目录给的地址取（同一地址只取一次）
  const fresh = themeCatalogFresh();
  const requestedScript = catalogTheme(requestedTheme)?.script ?? null;
  useEffect(() => {
    if (fresh && requestedScript) void loadTheme(requestedTheme, requestedScript);
  }, [fresh, requestedTheme, requestedScript]);

  // 生效主题的样式表：本页加载后才装 / 升级的主题不在聚合样式表里，补挂一份
  const effectiveCss = catalogTheme(effectiveTheme)?.css ?? null;
  useEffect(() => {
    if (effectiveCss) void ensureThemeStylesheet(effectiveCss);
  }, [effectiveCss]);

  // 加载失败：外壳已整体回落默认主题，这里告诉用户一声（每个主题提示一次）
  const toast = useToast();
  const warned = useRef(new Set<string>());
  const requestedFailed = requestedScript !== null && themeLoadStatus(requestedTheme) === "failed";
  useEffect(() => {
    if (!requestedFailed || warned.current.has(requestedTheme)) return;
    warned.current.add(requestedTheme);
    const label = catalogTheme(requestedTheme)?.label ?? requestedTheme;
    toast.error(t("settings.appearance.loadFallback", { theme: label }));
  }, [requestedFailed, requestedTheme, toast, t]);

  // 某个坑位渲染出错：那一处已回落基础实现（components/theme-slot-boundary.tsx），提示一次
  const slotErrorCount = themeSlotErrors(effectiveTheme).length;
  useEffect(() => {
    const key = `${effectiveTheme}:slots`;
    if (slotErrorCount === 0 || warned.current.has(key)) return;
    warned.current.add(key);
    toast.error(t("settings.appearance.slotFallback", { theme: themeMeta(effectiveTheme, locale).label }));
  }, [effectiveTheme, slotErrorCount, toast, t, locale]);

  useEffect(() => {
    const root = document.documentElement;
    if (effectiveTheme === DEFAULT_THEME_ID) root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", effectiveTheme);
    if (themeMeta(effectiveTheme).glass) root.removeAttribute("data-glass");
    else root.setAttribute("data-glass", "off");
    // 浏览器 UI 框颜色与画布同源跟随（含设置页实时预览切主题的瞬间）。
    // Next 的路由元数据机制可能在客户端导航时把 viewport 导出的静态
    // themeColor（银玻璃值）写回 meta——用观察器持续断言当前主题的画布色，
    // 无论被谁改写都拉回，避免主题与浏览器框颜色脱节。
    const desired = themeMeta(effectiveTheme).themeColor;
    const apply = () => {
      const meta = document.querySelector('meta[name="theme-color"]');
      if (meta && meta.getAttribute("content") !== desired) {
        meta.setAttribute("content", desired);
      }
      return meta;
    };
    const meta = apply();
    const observer = new MutationObserver(apply);
    if (meta) observer.observe(meta, { attributes: true, attributeFilter: ["content"] });
    return () => observer.disconnect();
  }, [effectiveTheme]);

  const savePrefs = useCallback(
    async (next: UiPreferences) => {
      const previous = prefs;
      // 乐观更新：开关立即生效；保存失败回滚并抛给调用方提示
      setPrefs(next);
      try {
        const saved = await updateUiPreferences(next);
        setPrefs(saved);
        writeUiPrefsCache(saved);
        // 保存成功后草稿使命完成，撤销以免遮住刚落库的新值
        setPreview(null);
      } catch (err) {
        setPrefs(previous);
        throw err;
      }
    },
    [prefs],
  );

  const value = useMemo<UiPrefsContextValue>(
    () => ({
      prefs: preview ?? prefs,
      savedPrefs: prefs,
      loading,
      savePrefs,
      setPreview,
      themeId: effectiveTheme,
      themePending,
    }),
    [prefs, preview, loading, savePrefs, effectiveTheme, themePending],
  );

  return <UiPrefsContext.Provider value={value}>{children}</UiPrefsContext.Provider>;
}

/** 读取界面偏好与保存方法。必须在 UiPrefsProvider 内使用。 */
export function useUiPrefs(): UiPrefsContextValue {
  const ctx = useContext(UiPrefsContext);
  if (!ctx) throw new Error("useUiPrefs 必须在 <UiPrefsProvider> 内使用");
  return ctx;
}

/**
 * 读取当前主题（含设置页未保存的预览草稿）。
 *
 * 在 UiPrefsProvider 外调用（登录 / 初始化页的 GlassPanel 等前置页面）不抛错、
 * 按默认主题渲染：那些页面还没有账号上下文，主题本就未知；token 层不受影响
 * ——layout.tsx 的内联脚本已按 localStorage 缓存把 data-theme 写上 <html>，
 * 纯 CSS 换肤在任意页面都生效，这里兜底的只是结构层的分支选择。
 *
 * **只换皮肤（token 层）的消费方用它就够**；要按主题换路由或换整页结构的
 * 消费方必须改用 useThemeState()，原因见该函数说明。
 */
export function useTheme(): ThemeMeta {
  const locale = useLocale();
  const ctx = useContext(UiPrefsContext);
  // Provider 外（登录页等）没有偏好可依，按默认主题渲染
  return themeMeta(ctx ? ctx.themeId : DEFAULT_THEME_ID, locale);
}

/**
 * 主题 + 「首次拉取是否还在进行中」。
 *
 * 结构层里凡是**会把人送走**的分支（/my 与 /settings 按主题 replace 到别的
 * 路由）都必须等 loading 落定再决策：首帧的主题取自 localStorage 缓存，
 * 冷缓存（新设备首次登录、无痕窗口、清过站点数据、别人发来的链接）时它
 * 返回的是默认主题 silver，于是 Netflix 用户点「我的」会被立刻 replace 走，
 * 等偏好到账时人已经在别的页面上了——刷新一次才正常，这个 bug 只在缓存
 * 冷的时候出现，非常难查。纯换肤的分支没有这个问题（渲染错一帧会自愈），
 * 换路由的分支不会自愈：路由已经跳了。
 */
export function useThemeState(): { theme: ThemeMeta; loading: boolean } {
  const locale = useLocale();
  const ctx = useContext(UiPrefsContext);
  return {
    theme: themeMeta(ctx ? ctx.themeId : DEFAULT_THEME_ID, locale),
    // Provider 外（登录页等）没有偏好可等，直接按「已落定」处理；主题还在加载也算没落定
    loading: ctx ? ctx.loading || ctx.themePending : false,
  };
}

/** 当前生效主题的版式（docs/design/theme-plugins.md §4.2）：内核组件按它分叉排布，不认识具体主题。 */
export function useLayout(): ThemeLayout {
  return useTheme().layout;
}
