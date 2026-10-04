"use client";

import {
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type RefObject,
} from "react";

import { useBackdrop } from "@/lib/backdrop";
import { IMAGE_ASPECT, tmdbImageForWidth, withImageWidth } from "@/lib/image-proxy";
import type { AmbientRgb } from "@/lib/hero-ambient-color";
import { useElementCoverWidth, useViewportCoverWidth } from "@/lib/image-resolution";
import { useTapGuard } from "@/lib/use-tap-guard";

/**
 * 沉浸式大图（Hero）的通用部件：订阅首页与发现页（银玻璃）共用，同 iOS 两页共用 ImmersiveHero。
 * 移植自原生 App 的 DesignSystem/ImmersiveHero.swift，文字与按钮各页自己排（renderContent），
 * 这里只管图与节奏：
 *
 * - 剧照层：慢速推近（Ken Burns，12 秒 1 → 1.1）、上滑视差（画面只跟 0.6 倍，相对下沉 0.4）、
 *   下半部压暗托字、底部渐隐进页面氛围色、顶部压暗托住状态栏与顶栏；
 * - 轮播：每张停留 8 秒，指示器当前格按 8 秒线性填满（看得出「还有多久换下一张」），
 *   手动切换（点圆点 / 触屏横滑）重新计时，页面不可见时不推进；
 * - 指示器：居中底部，当前格是 26×5 的胶囊，其余是 5×5 可点的小圆点；
 * - 文字随滚动淡出（滚过 260px 全透明）并轻微下沉；
 * - 预载：帧壳常驻、交叉淡入，大图只在轮到（当前 / 下一张）时才写 src；取图宽度按剧照框
 *   实测尺寸 × 屏幕倍率 × 推近 1.1 算（lib/image-resolution.ts），远程 TMDB 图不够时升 original。
 *
 * 滚动联动不走 React 状态：调用方用 useHeroScrollVar 把滚动距离写成祖先元素上的 CSS 变量
 * --hero-scroll（px 数值、不带单位），视差 / 淡出 / 氛围底退淡都由 CSS calc 读它，
 * 滚动时整页不重渲染。
 */

/**
 * 桌面的两种页面外框（银玻璃，发现页与订阅首页共用）：
 * - 沉浸：有 Hero 时主区铺满整个窗口（抵掉外壳的 p-3.5 留白，左边一直伸到侧栏底下、窗口左沿），
 *   不画卡片边框，大图从侧栏底下穿过、侧栏是浮在画面上的一块玻璃（macOS 26 的侧栏形态），
 *   配合 useHeroWindowBackdrop 整个窗口是同一部片的画面。页面内容用 --immersive-inset
 *   （侧栏宽 + 两道 14px）让出侧栏：滚动区左内边距 IMMERSIVE_INSET，大图用 HeroBleed 抵回去铺满。
 *   为什么不让大图停在侧栏右缘：侧栏是圆角卡片、四周留 14px，大图矩形的左上角会在侧栏上方
 *   露出一条直角竖边；更早停在两栏缝右侧时缝里又是一条对不上的模糊竖带（2026-09-27 用户截图两次）；
 * - 卡片：没有 Hero（豆瓣视角、筛选结果、加载失败）时是一张深色圆角卡片。
 */
export const DESKTOP_IMMERSIVE_FRAME =
  "md:-my-3.5 md:-mr-3.5 md:-ml-[calc(var(--sidebar-w,300px)+28px)] md:[--immersive-inset:calc(var(--sidebar-w,300px)+28px)]";
/** 沉浸外框里给侧栏让位的左内边距（手机与卡片外框下变量不存在，等于 0） */
export const IMMERSIVE_INSET = "pl-[var(--immersive-inset,0px)]";

/** 包住 Hero（及其骨架）：在让位后的滚动区里用负外边距抵回去，大图铺到窗口左沿、从侧栏底下穿过 */
export function HeroBleed({ children }: { children: ReactNode }) {
  return <div className="-ml-[var(--immersive-inset,0px)]">{children}</div>;
}
export const DESKTOP_CARD_FRAME =
  "md:overflow-hidden md:rounded-2xl md:shadow-[0_24px_70px_-18px_rgba(0,0,0,0.62)] md:ring-1 md:ring-white/10";

/**
 * 桌面沉浸：把全站背景临时换成当前 Hero 的剧照（lib/backdrop.tsx 的页面级覆盖，同影片详情页）。
 * 覆盖层在全站模糊蒙版之下，于是侧栏四周的缝隙透出的是这部片的模糊画面、侧栏的液态玻璃
 * 折射的也是它——Hero 像是一直延伸到侧栏底下（苹果叫 Background Extension Effect）。
 * 轮播换张时背景跟着交叉淡入；url 为空（手机、没有 Hero）时恢复用户自己的背景。
 * 只改运行时状态，不落外观设置。
 *
 * 同时给 <html> 挂 hero-window 标记，把全站蒙版从「压暗 + 模糊」换成「重模糊、轻压暗」
 * （globals.css）：默认蒙版把缝里的剧照压到七成黑，夹在鲜艳的大图与侧栏玻璃之间
 * 成了一条灰带（2026-09-27 用户截图）。压暗改由主区自己的渐变承担，只压海报行那一段。
 */
export function useHeroWindowBackdrop(url: string | null | undefined) {
  const { setOverrideBackdrop } = useBackdrop();
  // 窗口背景铺满整窗，按整窗算宽度；放大系数取 Hero 推近的 1.1——Hero 在桌面也是整窗宽，
  // 两边算出来几乎总落在同一档，同一张图浏览器只下载一次（窗口背景是重模糊，略大无妨）
  const width = useViewportCoverWidth(IMAGE_ASPECT.backdrop, HERO_ZOOM);
  const sized = url && width ? tmdbImageForWidth(url, width) : null;
  useEffect(() => {
    setOverrideBackdrop(sized);
    document.documentElement.classList.toggle("hero-window", Boolean(sized));
  }, [sized, setOverrideBackdrop]);
  useEffect(
    () => () => {
      setOverrideBackdrop(null);
      document.documentElement.classList.remove("hero-window");
    },
    [setOverrideBackdrop],
  );
}

/** 剧照推近的终点倍数（12 秒 1 → 1.1），取图宽度要把它算进去，推到底也不糊 */
const HERO_ZOOM = 1.1;

/** 默认每张停留时长（毫秒），同 iOS SubsHomeHero.interval */
const DEFAULT_INTERVAL = 8000;

/** 滚动距离（px）：只算向上滚的部分，下拉回弹不参与 */
const SCROLL = "max(var(--hero-scroll, 0), 0)";

/** 文字与指示器随滚动淡出：滚过 260px 全透明（CSS 会把 opacity 自动夹到 0~1） */
const FADE_STYLE: CSSProperties = { opacity: `calc(1 - ${SCROLL} / 260)` };

/**
 * 把滚动容器的滚动距离写到 target 元素的 --hero-scroll 上（每帧至多一次）。
 * Hero 与氛围底都放在 target 之内，读的是同一个变量。
 * remountKey：两个元素不是一挂载就在（发现页要等版式数据到了才渲染滚动容器）时，
 * 传一个随它们出现而变化的值，让监听在元素就位后重新挂上。
 */
export function useHeroScrollVar(
  scrollRef: RefObject<HTMLElement | null>,
  targetRef: RefObject<HTMLElement | null>,
  remountKey?: unknown,
) {
  useEffect(() => {
    const scroller = scrollRef.current;
    const target = targetRef.current;
    if (!scroller || !target) return;
    let frame = 0;
    const write = () => {
      frame = 0;
      target.style.setProperty("--hero-scroll", String(Math.round(scroller.scrollTop)));
    };
    const onScroll = () => {
      if (!frame) frame = window.requestAnimationFrame(write);
    };
    write();
    scroller.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      scroller.removeEventListener("scroll", onScroll);
      window.cancelAnimationFrame(frame);
    };
  }, [scrollRef, targetRef, remountKey]);
}

export interface ImmersiveHeroProps<T> {
  slides: readonly T[];
  /** 当前张（受控：页面要拿它算氛围底色） */
  index: number;
  onIndexChange: (index: number) => void;
  slideKey: (slide: T) => string | number;
  /** 剧照地址（已经过 imageUrl / cachedImageUrl 代理）；大屏上组件自己升 TMDB original 档 */
  imageOf: (slide: T) => string | undefined;
  /** 文字与按钮（贴 Hero 底部排）；按钮要自己 stopPropagation，免得同时触发整张的点击 */
  renderContent: (slide: T, active: boolean) => ReactNode;
  /** 点剧照（按钮以外）的动作；会过一遍触屏误触判定 */
  onActivate?: (slide: T) => void;
  /** 整张可点时的读屏名 */
  activateLabel?: (slide: T) => string;
  /** 指示器小圆点的读屏名（「切换到《片名》」） */
  indicatorLabel: (slide: T) => string;
  /** 每张停留时长（毫秒） */
  interval?: number;
  /** 追加到外框的类名：高度、圆角、外边距由调用方决定 */
  className?: string;
}

export function ImmersiveHero<T>({
  slides,
  index,
  onIndexChange,
  slideKey,
  imageOf,
  renderContent,
  onActivate,
  activateLabel,
  indicatorLabel,
  interval = DEFAULT_INTERVAL,
  className = "",
}: ImmersiveHeroProps<T>) {
  const count = slides.length;
  const current = count > 0 ? Math.min(index, count - 1) : 0;
  // 页面从后台回到前台时 +1：重新计时、指示器从头填（后台期间不推进）
  const [cycle, setCycle] = useState(0);
  const touchStart = useRef<{ x: number; y: number } | null>(null);
  const indexRef = useRef(current);
  indexRef.current = current;
  const changeRef = useRef(onIndexChange);
  changeRef.current = onIndexChange;

  // 轮播计时：index 变了（自动或手动）即重新计时；页面不可见时停表，回来后从头计
  useEffect(() => {
    if (count <= 1) return;
    let timer = 0;
    const start = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => changeRef.current((indexRef.current + 1) % count), interval);
    };
    const onVisibility = () => {
      if (document.hidden) window.clearTimeout(timer);
      else setCycle((value) => value + 1);
    };
    if (!document.hidden) start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [count, current, cycle, interval]);

  // 张数变少时把越界的 index 拉回 0
  useEffect(() => {
    if (count > 0 && index >= count) onIndexChange(0);
  }, [count, index, onIndexChange]);

  if (count === 0) return null;
  const next = (current + 1) % count;

  return (
    <div
      className={`relative w-full overflow-hidden ${className}`}
      onTouchStart={(event) => {
        const touch = event.touches[0];
        touchStart.current = { x: touch.clientX, y: touch.clientY };
      }}
      onTouchEnd={(event) => {
        const start = touchStart.current;
        touchStart.current = null;
        if (!start || count <= 1) return;
        const touch = event.changedTouches[0];
        const dx = touch.clientX - start.x;
        const dy = touch.clientY - start.y;
        // 明显横向且位移够大才算切换；纵向滚动起手、普通点按都不受影响
        if (Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.5) {
          onIndexChange((current + (dx < 0 ? 1 : -1) + count) % count);
        }
      }}
    >
      {slides.map((slide, offset) => (
        <HeroFrame
          key={slideKey(slide)}
          active={offset === current}
          preload={offset === current || offset === next}
          image={imageOf(slide)}
          onActivate={onActivate ? () => onActivate(slide) : undefined}
          label={activateLabel?.(slide)}
        >
          {renderContent(slide, offset === current)}
        </HeroFrame>
      ))}

      {count > 1 && (
        <div
          // 沉浸外框下大图伸到了侧栏底下：指示器按内容区居中，不按整窗
          className="absolute inset-x-0 bottom-4 z-[2] flex items-center justify-center gap-1.5 pl-[var(--immersive-inset,0px)]"
          style={FADE_STYLE}
        >
          {slides.map((slide, offset) =>
            offset === current ? (
              // 当前格：26×5 胶囊，内层按停留时长从左到右线性填满
              <span
                key={slideKey(slide)}
                aria-hidden="true"
                className="relative h-[5px] w-[26px] overflow-hidden rounded-full bg-white/[0.26] transition-[width] duration-300"
              >
                <span
                  key={`${current}-${cycle}`}
                  className="absolute inset-0 origin-left rounded-full bg-white/95"
                  style={{ animation: `immersive-hero-fill ${interval}ms linear forwards` }}
                />
              </span>
            ) : (
              // 其余是 5×5 小圆点；点击热区向外扩 8px，手指点得中
              <button
                key={slideKey(slide)}
                type="button"
                aria-label={indicatorLabel(slide)}
                onClick={() => onIndexChange(offset)}
                className="relative size-[5px] rounded-full bg-white/[0.34] transition-colors before:absolute before:-inset-2 before:content-[''] hover:bg-white/60"
              />
            ),
          )}
        </div>
      )}
    </div>
  );
}

/**
 * 单张：剧照层 + 调用方的文字层。所有帧常驻、靠透明度交叉淡入（切换不重新加载闪白），
 * 非当前帧关掉命中测试，点击不会落到看不见的那张上。
 */
function HeroFrame({
  active,
  preload,
  image,
  onActivate,
  label,
  children,
}: {
  active: boolean;
  /** 是否该装载大图（当前帧或下一帧）；装载过一次就保持，淡出时不闪白 */
  preload: boolean;
  image: string | undefined;
  onActivate?: () => void;
  label?: string;
  children: ReactNode;
}) {
  const [revealed, setRevealed] = useState(preload);
  useEffect(() => {
    if (preload) setRevealed(true);
  }, [preload]);
  // 剧照层的框（整张 Hero 的大小）：量出来按铺满 + 推近算取图宽度
  const [frameEl, setFrameEl] = useState<HTMLDivElement | null>(null);
  const width = useElementCoverWidth(frameEl, IMAGE_ASPECT.backdrop, HERO_ZOOM);
  const src = useUpgradedBackdrop(revealed, image, width);
  // 首帧挂载时就是 active 的那张要从 1 起推：挂载完成后再认推近标记，否则一出生就是终态
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  const zooming = active && mounted;
  const tapGuard = useTapGuard(onActivate);
  const interactive = active && Boolean(onActivate);

  return (
    <div
      aria-hidden={!active}
      role={interactive ? "button" : undefined}
      tabIndex={interactive ? 0 : -1}
      aria-label={interactive ? label : undefined}
      {...(onActivate ? tapGuard : {})}
      onKeyDown={(event) => {
        // 只认落在整张上的回车 / 空格；内部按钮的按键由按钮自己处理
        if (!onActivate || event.target !== event.currentTarget) return;
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onActivate();
        }
      }}
      className={`absolute inset-0 transition-opacity duration-700 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-white/70 ${
        active ? `z-[1] opacity-100 ${onActivate ? "cursor-pointer" : ""}` : "pointer-events-none z-0 opacity-0"
      }`}
    >
      {/* 剧照层：渐隐遮罩固定在 Hero 框上（底边永远化开，视差不会把硬边带出来），
          画面在框里做视差与推近 */}
      <div ref={setFrameEl} className="absolute inset-0 overflow-hidden [-webkit-mask-image:linear-gradient(to_bottom,#000_0%,#000_56%,rgba(0,0,0,0.6)_80%,transparent_100%)] [mask-image:linear-gradient(to_bottom,#000_0%,#000_56%,rgba(0,0,0,0.6)_80%,transparent_100%)]">
        <div
          className="absolute inset-0"
          style={{ transform: `translate3d(0, calc(${SCROLL} * 0.4px), 0)` }}
        >
          {src && (
            <img
              src={src}
              alt=""
              decoding="async"
              referrerPolicy="no-referrer"
              className="size-full object-cover"
              style={{
                transform: `scale(${zooming ? HERO_ZOOM : 1})`,
                // 推近 12 秒线性；离场时等淡出走完（0.8 秒）再无动画归位，看不到回缩
                transition: zooming ? "transform 12s linear" : "transform 0s linear 0.8s",
              }}
            />
          )}
          {/* 下半部压暗托住文字：在遮罩之内，与底部渐隐一起化开，不会切出横线 */}
          <div className="absolute inset-0 bg-[linear-gradient(to_bottom,transparent_36%,rgba(0,0,0,0.5)_100%)]" />
        </div>
      </div>
      {/* 顶部压暗：托住状态栏、顶栏与页内标题 */}
      <div className="pointer-events-none absolute inset-x-0 top-0 h-[26%] bg-gradient-to-b from-black/50 to-transparent" />

      <div
        className="absolute inset-x-0 bottom-0"
        style={{ ...FADE_STYLE, transform: `translate3d(0, calc(${SCROLL} * 0.15px), 0)` }}
      >
        <div
          className={`transition-all delay-150 duration-500 ease-out ${
            active ? "translate-y-0 opacity-100" : "translate-y-3 opacity-0"
          }`}
        >
          {children}
        </div>
      </div>
    </div>
  );
}

/**
 * 剧照按需要的宽度取图，必要时「同图升清」。``width`` 是需要的物理像素宽（已取阶梯档，
 * 0 = 框还没量到，先不取图）：
 *   - 库内 / 本地图：直接在地址上带 ``w``，服务端从本地母版派生；
 *   - 发现页的远程 TMDB 图：列表只给 w1280 这类固定尺寸段（首屏快）。需要的宽度超过它时，
 *     先显示列表档（带 w），后台预加载 original + w（服务端从原图派生到那一档），
 *     加载并解码完成才替换——大屏整幅拉伸 w1280 会发虚；手机等小物理宽屏列表档已够，不多拉。
 * 全站 Hero 共用这一份（Netflix 主题发现页的横幅也用它）。
 */
export function useUpgradedBackdrop(
  revealed: boolean,
  src: string | undefined,
  width: number,
): string | undefined {
  const base = src && width ? withImageWidth(src, width) : undefined;
  const original = src && width ? tmdbImageForWidth(src, width) : undefined;
  const upgradable = Boolean(original && original !== base);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    if (!revealed || !upgradable || !original) {
      setReady(false);
      return;
    }
    let cancelled = false;
    const img = new Image();
    img.onload = () => {
      img
        .decode()
        .catch(() => {})
        .then(() => {
          if (!cancelled) setReady(true);
        });
    };
    img.src = original;
    return () => {
      cancelled = true;
    };
  }, [revealed, upgradable, original]);
  return revealed ? (ready ? original : base) : undefined;
}

/**
 * 页面氛围底：纯黑之上叠一层当前 Hero 剧照的主色，从顶部向下渐隐（Apple TV / Apple Music 的做法），
 * 移植自 iOS ImmersiveHeroAmbient。
 *
 * - 剧照底部渐隐进这层颜色，Hero 与下面的内容之间没有硬边；
 * - 换下一张时新颜色 1.2 秒淡入叠在旧颜色上（交叉淡入），旧层在下一次换色时才撤；
 * - 往下滚时整体退淡（滚 900px 退到最淡 0.35），不让下半页一直泡在颜色里；
 * - 自带纯黑实底：全站 .page-scrim 是半透明蒙版，壁纸会透出来，这一层要把它整个盖住。
 * 放在页面根（absolute inset-0）里、滚动容器之外，读祖先上的 --hero-scroll。
 */
export function HeroAmbientBackdrop({
  color,
  className = "",
  windowed = false,
}: {
  color: AmbientRgb | null;
  className?: string;
  /**
   * 桌面沉浸外框：不铺纯黑实底与主色层，让窗口背景（useHeroWindowBackdrop 换上的同一张剧照，
   * 已被全站蒙版模糊）直接透上来，只叠一层自上而下加深的压暗托住海报行。手机不受影响。
   */
  windowed?: boolean;
}) {
  // 最多留两层：底下是上一种颜色，上面是正在淡入的新颜色
  const [layers, setLayers] = useState<Array<{ key: string; color: AmbientRgb }>>(() =>
    color ? [{ key: rgbKey(color), color }] : [],
  );
  useEffect(() => {
    if (!color) {
      setLayers([]);
      return;
    }
    const key = rgbKey(color);
    setLayers((current) =>
      current.at(-1)?.key === key ? current : [...current.slice(-1), { key, color }],
    );
  }, [color]);

  return (
    <div
      aria-hidden="true"
      className={`pointer-events-none absolute inset-0 bg-black ${
        windowed
          ? "md:bg-transparent md:bg-[linear-gradient(to_bottom,transparent_0,rgba(5,7,12,0.5)_560px,rgba(5,7,12,0.66)_100%)]"
          : ""
      } ${className}`}
    >
      <div
        className={`absolute inset-0 ${windowed ? "md:hidden" : ""}`}
        style={{ opacity: `max(0.35, calc(1 - ${SCROLL} / 900))` }}
      >
        {layers.map(({ key, color: rgb }) => {
          const c = `${rgb.r} ${rgb.g} ${rgb.b}`;
          return (
            <div
              key={key}
              className="absolute inset-0"
              style={{
                background: `linear-gradient(to bottom, rgb(${c} / 0.85) 0%, rgb(${c} / 0.5) 42%, rgb(${c} / 0.14) 72%, transparent 100%)`,
                animation: "immersive-hero-ambient-in 1.2s ease-in-out both",
              }}
            />
          );
        })}
      </div>
    </div>
  );
}

function rgbKey(color: AmbientRgb): string {
  return `${color.r}-${color.g}-${color.b}`;
}
