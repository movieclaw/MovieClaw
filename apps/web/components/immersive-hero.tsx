"use client";

import {
  useCallback,
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
 * - 轮播：每张停留 8 秒，指示器当前格按 8 秒线性填满（看得出「还有多久换下一张」）；
 *   计时从**真正上台的那一刻**算起（手动切换 / 等解码期间不计也不切），页面不可见时不推进；
 * - 指示器：居中底部，当前格是 26×5 的胶囊，其余是 5×5 可点的小圆点；
 * - 文字随滚动淡出（滚过 260px 全透明）并轻微下沉；
 * - 预载：帧壳常驻、交叉淡入，大图只在轮到（当前 / 下一张 / 正要切过去的那张）时才写 src；取图宽度按剧照框
 *   实测尺寸 × 屏幕倍率 × 推近 1.1 算（lib/image-resolution.ts），远程 TMDB 图不够时升 original；
 * - 上屏闸门：图**解码就位**之后才让那张帧淡入（预载期间就把解码做完）。只提前写 src 是不够的
 *   —— 浏览器会先把位置画成空白、等后台解码完再补画，切换那一下就会先露白再出图（详见
 *   HeroFrame 与 READY_TIMEOUT_MS 的说明）。
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
 * 同时给 <html> 挂 hero-window 标记，保留桌面 Hero 既有的饱和度；
 * 蒙版的模糊与暗度仍跟随全站用户偏好（globals.css）。
 */
export function useHeroWindowBackdrop(url: string | null | undefined) {
  const { setOverrideBackdrop } = useBackdrop();
  // 窗口背景铺满整窗，按整窗算宽度；放大系数取 Hero 推近的 1.1——Hero 在桌面也是整窗宽，
  // 两边算出来几乎总落在同一档，同一张图浏览器只下载一次（窗口背景是重模糊，略大无妨）
  const width = useViewportCoverWidth(IMAGE_ASPECT.backdrop, HERO_ZOOM);
  const sized = url && width ? tmdbImageForWidth(url, width) : null;
  // 解码就位后再交给覆盖层：覆盖层换图的规矩是「先把旧图淡出、新图就绪再淡入」，
  // 直接把还没下载完的地址塞过去，整窗会在那段加载期里空着——桌面轮播换张时看到的
  // 「整个页面空一下」就是从这来的。先留旧图，新图就位才换（模糊背景上看不出硬切）。
  const decoded = useDecodedUrl(sized);
  useEffect(() => {
    setOverrideBackdrop(decoded);
    document.documentElement.classList.toggle("hero-window", Boolean(decoded));
  }, [decoded, setOverrideBackdrop]);
  useEffect(
    () => () => {
      setOverrideBackdrop(null);
      document.documentElement.classList.remove("hero-window");
    },
    [setOverrideBackdrop],
  );
}

/**
 * 只交出「已经加载并解码完成」的地址。
 *
 * 换 URL 时先保留上一个已经解码好的地址，等新图加载+解码完成才换成新的；url 变成 null
 * （离开沉浸页 / 手机上不需要）时立即交 null，让覆盖层照旧淡出。
 *
 * 为什么非要 decode：只等 onload 不够——首帧绘制要的是解码好的位图，没解码的图上去
 * 就是一帧空白（detail-backdrop-slideshow、BackdropProvider 的覆盖层都是同一个规矩）。
 */
function useDecodedUrl(url: string | null): string | null {
  const [decoded, setDecoded] = useState<string | null>(null);
  useEffect(() => {
    if (!url) {
      setDecoded(null);
      return;
    }
    let cancelled = false;
    const img = new Image();
    img.onload = () => {
      if (cancelled) return;
      void img
        .decode()
        .catch(() => {})
        .then(() => {
          if (!cancelled) setDecoded(url);
        });
    };
    // 图坏了不能把上一张一直挂在窗口上：放行，让覆盖层自己走 onerror 的兜底
    img.onerror = () => {
      if (!cancelled) setDecoded(url);
    };
    img.src = url;
    return () => {
      cancelled = true;
    };
  }, [url]);
  return decoded;
}

/** 剧照推近的终点倍数（12 秒 1 → 1.1），取图宽度要把它算进去，推到底也不糊 */
const HERO_ZOOM = 1.1;

/** 默认每张停留时长（毫秒），同 iOS SubsHomeHero.interval */
const DEFAULT_INTERVAL = 8000;

/**
 * 等目标帧的图就位的上限（毫秒）。
 *
 * 正常情况下下一张在停留的 8 秒里早就下载并解码完了，切换是「一张直接化进下一张」；
 * 但手动跳到隔了几张的那张、或者图坏了/网很慢时，不能一直卡在上一张不换——
 * 超时就照常切过去（帧底是深色，宁可空一下也不假装没响应）。
 */
const READY_TIMEOUT_MS = 1200;

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
  /**
   * 真正上台的那一张的下标（图解码就位、开始淡入的那一刻）。
   *
   * 页面的氛围色、整窗背景要跟着它走，而不是跟着传进来的 `index`（目标下标）走：
   * 解码还没就位的那一两秒里，`index` 已经变了，但画面上还是上一张。
   */
  onPresented?: (index: number) => void;
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
  onPresented,
  className = "",
}: ImmersiveHeroProps<T>) {
  const count = slides.length;
  const current = count > 0 ? Math.min(index, count - 1) : 0;
  // 页面从后台回到前台时 +1：重新计时、指示器从头填（后台期间不推进）。
  // 另外「待上台被取消」时也 +1：让计时器和进度条从同一个时刻一起重头跑（见下方 pendingSwitch）。
  const [cycle, setCycle] = useState(0);
  const touchStart = useRef<{ x: number; y: number } | null>(null);
  const changeRef = useRef(onIndexChange);
  changeRef.current = onIndexChange;
  const onPresentedRef = useRef(onPresented);
  onPresentedRef.current = onPresented;

  // 已经解码好图的幻灯片（只增不减）：只有它就位的那一张才允许上台。
  // 单独记一份而不是“当前帧自己的 state”，是因为要提前决定“这一帧该不该淡入”，
  // 而这个决定属于父层（指示器、文字、下一张预载都跟着它走）。
  const [decodedKeys, setDecodedKeys] = useState<ReadonlySet<string | number>>(() => new Set());
  const markDecoded = useCallback((key: string | number) => {
    setDecodedKeys((prev) => (prev.has(key) ? prev : new Set(prev).add(key)));
  }, []);
  const targetKey = count > 0 ? slideKey(slides[current]) : null;
  const targetReady = targetKey !== null && decodedKeys.has(targetKey);
  // 实际上台的是哪一张（记 key 而不是下标：幻灯片会因为订阅数据刷新而重排，
  // 同一个下标底下可能已经换成另一部片）。目标帧的图还没就位时先留着上一张，
  // 等它解码完成再切（超时则照旧切，见 READY_TIMEOUT_MS）——切换中途不留空帧。
  const [presentedKey, setPresentedKey] = useState<string | number | null>(targetKey);

  // 正在展示的那张的下标与 key（它已经被从清单里拿掉时，退回目标张）
  const presentedIndex =
    presentedKey === null ? -1 : slides.findIndex((slide) => slideKey(slide) === presentedKey);
  const visible = presentedIndex >= 0 ? presentedIndex : current;
  const visibleKey = count > 0 ? slideKey(slides[visible]) : null;
  // 目标张还没上台（等解码）：这期间计时器停着，不把上一张的剩余时间算到新张头上
  const pendingSwitch = targetKey !== null && presentedKey !== null && targetKey !== presentedKey;
  const presentedIndexRef = useRef(visible);
  presentedIndexRef.current = visible;

  // 告诉调用方「现在轮到哪一张了」：氛围色、整窗背景跟着它走
  useEffect(() => {
    onPresentedRef.current?.(visible);
  }, [visible, visibleKey]);

  // 待上台被取消（目标又回到正在展示的那张）时，把计时和进度条一起从头开始。
  //
  // 不这么做就会脱节：A 在展示 → 点未解码的 B（pendingSwitch，JS 计时器停了，
  // A 的进度条动画还在跑）→ 又切回 A（pendingSwitch 变回 false），计时 effect 会重开
  // 一个完整 interval，而进度条的 key 还是 A——动画既不暂停也不重启，条可能已经
  // 填满甚至停在满格，实际停留却才刚开始。
  const wasPending = useRef(false);
  useEffect(() => {
    if (wasPending.current && !pendingSwitch) setCycle((value) => value + 1);
    wasPending.current = pendingSwitch;
  }, [pendingSwitch]);

  // 轮播计时：**从真正上台的那一刻**开始算满一个停留时长，不跟目标下标走。
  //
  // 跟 index 走的话，手动点隔了几张的圆点（或图还在解码）时，计时已经开跑、画面
  // 却还没切，那一张只能停剩零头，而进度条是上台时从头跑满的——就成了「条没填满
  // 就换张」。依赖里放的是上台的那张 key：订阅首页每 10/20 秒重排幻灯片时，同一个
  // 下标可能已经换成另一部片，光看 count / current 不会重启计时，新片会被旧计时器切走。
  useEffect(() => {
    if (count <= 1 || pendingSwitch) return;
    let timer = 0;
    const start = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(
        () => changeRef.current((presentedIndexRef.current + 1) % count),
        interval,
      );
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
  }, [count, visibleKey, pendingSwitch, cycle, interval]);

  // 张数变少时把越界的 index 拉回 0
  useEffect(() => {
    if (count > 0 && index >= count) onIndexChange(0);
  }, [count, index, onIndexChange]);

  // 上台的时机：目标帧已解码→立刻切；还没解码→留上一张，等就位（或超时兜底）。
  // 预载本身在渲染时就开始了（下面 preload 里包含 current），不等这个 effect。
  useEffect(() => {
    if (count === 0 || targetKey === null || targetKey === presentedKey) return;
    // 还什么都没有上台时没有「上一张」可留，直接展示（否则第一张要白等一个超时）
    if (presentedKey === null || targetReady) {
      setPresentedKey(targetKey);
      return;
    }
    const timer = window.setTimeout(() => setPresentedKey(targetKey), READY_TIMEOUT_MS);
    return () => window.clearTimeout(timer);
  }, [count, targetKey, presentedKey, targetReady]);

  if (count === 0) return null;
  const next = (visible + 1) % count;

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
          active={offset === visible}
          // 当前 / 下一张照旧，另外把「正要切过去的那张」也算上：手动跳到隔了几张的那张时，
          // 它得从点下去的那一刻就开始下载+解码（否则只能等到超时才切）。
          preload={offset === visible || offset === next || offset === current}
          slideId={slideKey(slide)}
          onDecoded={markDecoded}
          image={imageOf(slide)}
          onActivate={onActivate ? () => onActivate(slide) : undefined}
          label={activateLabel?.(slide)}
        >
          {renderContent(slide, offset === visible)}
        </HeroFrame>
      ))}

      {count > 1 && (
        <div
          // 沉浸外框下大图伸到了侧栏底下：指示器按内容区居中，不按整窗
          className="absolute inset-x-0 bottom-4 z-[2] flex items-center justify-center gap-1.5 pl-[var(--immersive-inset,0px)]"
          style={FADE_STYLE}
        >
          {slides.map((slide, offset) =>
            offset === visible ? (
              // 当前格：26×5 胶囊，内层按停留时长从左到右线性填满
              <span
                key={slideKey(slide)}
                aria-hidden="true"
                className="relative h-[5px] w-[26px] overflow-hidden rounded-full bg-white/[0.26] transition-[width] duration-300"
              >
                <span
                  key={`${visibleKey === null ? "" : String(visibleKey)}-${cycle}`}
                  className="absolute inset-0 origin-left rounded-full bg-white/95"
                  style={{
                    animation: `immersive-hero-fill ${interval}ms linear forwards`,
                    // 等目标张解码的那一小段先冻住：这张又还没走完，让它把条填满再回来会误导
                    animationPlayState: pendingSwitch ? "paused" : "running",
                  }}
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
  slideId,
  onDecoded,
  onActivate,
  label,
  children,
}: {
  active: boolean;
  /** 是否该装载大图（当前 / 下一张 / 正要切过去的那张）；装载过一次就保持，淡出时不重拉 */
  preload: boolean;
  image: string | undefined;
  /** 这张幻灯片在 slides 里的稳定标识（跟 key 同一个） */
  slideId: string | number;
  /** 大图已解码就位（父层据此决定什么时候让它上台） */
  onDecoded: (slideId: string | number) => void;
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
  // 预载期间就把解码做完（不是只写 src）。
  //
  // decoding=async 的规矩是：光栅化之前不解码，先把它那一片画成空白、后台解完再补画——
  // 帧靠透明度淡入，于是切换那一瞬间新帧已经上台、图还没到，看到的就是一闪白。
  // 这条 effect 在“轮到它装图”的那刻就把图加载并 decode 好，切换时是有位图可画的状态；
  // 父层再把“上台”推迟到它解码之后（见 ImmersiveHero 的 presentedKey）。
  useEffect(() => {
    if (!src) return;
    let cancelled = false;
    const img = new Image();
    img.onload = () => {
      if (cancelled) return;
      void img
        .decode()
        .catch(() => {})
        .then(() => {
          if (!cancelled) onDecoded(slideId);
        });
    };
    // 图坏了也要放行：否则这张永远等不到就位，只能白白卡到超时
    img.onerror = () => {
      if (!cancelled) onDecoded(slideId);
    };
    img.src = src;
    return () => {
      cancelled = true;
    };
  }, [src, slideId, onDecoded]);
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
      <div ref={setFrameEl} className="absolute inset-0 overflow-hidden bg-[#05070c] [-webkit-mask-image:linear-gradient(to_bottom,#000_0%,#000_56%,rgba(0,0,0,0.6)_80%,transparent_100%)] [mask-image:linear-gradient(to_bottom,#000_0%,#000_56%,rgba(0,0,0,0.6)_80%,transparent_100%)]">
        <div
          className="absolute inset-0"
          style={{ transform: `translate3d(0, calc(${SCROLL} * 0.4px), 0)` }}
        >
          {src && (
            <img
              src={src}
              alt=""
              // 同步解码：图早就预载解码好了，这里不该再有“先画空白、后台补画”的一帧
              decoding="sync"
              referrerPolicy="no-referrer"
              className="size-full bg-[#05070c] object-cover"
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
