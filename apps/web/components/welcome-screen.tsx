"use client";

import { useLocale, useTranslations } from "next-intl";

import localFont from "next/font/local";
import { useCallback, useEffect, useState, type ReactNode } from "react";

import { CosmosBackdrop } from "@/components/cosmos-backdrop";
import { XIcon } from "@/components/icons";
import { sceneText, shuffledScenes, type WelcomeScene } from "@/lib/welcome-scenes";

/**
 * 欢迎页的宋体：思源宋体（Noto Serif SC，SIL OFL 1.1）子集，与原生 App 同一份
 * （apps/apple/scripts/subset-welcome-font.py 生成，许可证见 app/fonts/WelcomeSerif-OFL.txt）。
 * 只含欢迎页用到的字，子集外的字回落到系统衬线体。
 */
const welcomeSerif = localFont({
  src: "../app/fonts/WelcomeSerif.otf",
  variable: "--font-welcome-serif",
  display: "swap",
});

/** 中文衬线：宋体子集 → 系统宋体 */
export const WELCOME_SERIF = `var(--font-welcome-serif), "Songti SC", "STSong", "Noto Serif SC", serif`;
/** 片名「MovieClaw」的西文衬线（App 用系统 serif 设计，即 New York） */
const LATIN_SERIF = `"New York", ui-serif, "Iowan Old Style", Georgia, serif`;

/** 每句台词停留的时长（点一下换句后重新计时） */
const SCENE_MS = 9000;

/**
 * 登录 / 初始化页的整屏外壳：写实的深空背景 + 片名 + 影史台词轮播 + 底部玻璃按钮，
 * 点了按钮才从下方升起卡片。对齐原生 App 的欢迎页
 * （apps/apple/MovieClaw/Features/Onboarding/WelcomeView.swift），但网页不需要服务器地址——
 * 页面本身就是从服务器打开的，卡片里只有账号与密码。
 *
 * 两种状态在同一页里切换，不跳页面：
 *   - 首页：星空从黑暗中浮现、地平线像轨道日出一样亮起，片名、台词、按钮依次浮现；
 *     先让人看完首页，点了按钮（桌面按回车也行）才升起卡片，不一进来就弹键盘；
 *   - 卡片：片名缩小留在顶部，台词与按钮让位，卡片从下方升起；右上角 × 收起回首页。
 *     手机上正在输入时收起片名，免得小屏上「片名 + 表单」高过键盘上方的空间。
 * 手机与桌面同一套版式：内容是一列最宽 440px 的竖排，桌面上整列在屏幕中间、限高。
 */
export function WelcomeScreen({
  footer,
  buttonLabel,
  initialStage = "home",
  ready = true,
  card,
}: {
  footer?: ReactNode;
  /** 首页按钮的文字（「登录」「开始使用」） */
  buttonLabel: string;
  /** 一进来就是卡片（会话过期回来、添加账号时）；挂载后才读 URL，所以允许后到 */
  initialStage?: "home" | "card";
  /** 页面还在判断要不要跳走（已登录、未初始化）时先不放片头 */
  ready?: boolean;
  /**
   * 卡片内容：close 收起回首页；autoFocus = 卡片是用户点按钮打开的（才自动聚焦输入框，
   * 页面自己出现的卡片不抢焦点，同 App）
   */
  card: (props: { close: () => void; autoFocus: boolean }) => ReactNode;
}) {
  const [stage, setStage] = useState<"home" | "card">(initialStage);
  const [autoFocus, setAutoFocus] = useState(false);
  const [lit, setLit] = useState(false);
  const [editing, setEditing] = useState(false);

  useEffect(() => setStage(initialStage), [initialStage]);
  // 片头：先点亮星空，片名、台词、按钮随 CSS 延时依次浮现
  useEffect(() => {
    if (!ready) return;
    const frame = requestAnimationFrame(() => setLit(true));
    return () => cancelAnimationFrame(frame);
  }, [ready]);

  const openCard = useCallback(() => {
    setAutoFocus(true);
    setStage("card");
  }, []);
  const close = useCallback(() => {
    setEditing(false);
    setStage("home");
  }, []);

  // 桌面：首页按回车直接打开卡片
  useEffect(() => {
    if (stage !== "home" || !lit) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Enter" && !event.isComposing) openCard();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [lit, openCard, stage]);

  const home = stage === "home";
  return (
    <div className={`${welcomeSerif.variable} relative`}>
      <CosmosBackdrop lit={lit} dimmed={!home} />
      <main
        className="viewport-app-height relative z-10 flex w-full justify-center overflow-y-auto px-6 md:items-center [padding-bottom:calc(0.75rem+var(--safe-bottom))] [padding-top:var(--safe-top)]"
        data-revealed={lit}
      >
        <div className="flex min-h-full w-full max-w-[440px] flex-col md:min-h-0 md:h-[min(100%,820px)]">
          <div
            className={`welcome-masthead-wrap transition-[padding,opacity] duration-600 ease-out ${
              !home && editing ? "max-md:hidden" : ""
            }`}
            style={{ paddingTop: home ? "22vh" : 12 }}
          >
            <WelcomeMasthead compact={!home} />
          </div>

          <div className="min-h-7 flex-1" />

          {home ? (
            <>
              <FilmSubtitles />
              <div className="min-h-10 flex-1" />
              <button
                type="button"
                onClick={openCard}
                style={{ fontFamily: WELCOME_SERIF }}
                className="welcome-glass welcome-reveal welcome-reveal--button mx-auto mb-3 min-w-[188px] rounded-full px-7 py-3.5 text-[17px] tracking-[4px] text-[var(--text)] transition-transform active:scale-[0.97]"
              >
                {buttonLabel}
              </button>
            </>
          ) : (
            <div
              className="welcome-card-rise mb-1"
              onFocusCapture={(event) => {
                // Button focus must not move the card between pointer down and click.
                const target = event.target;
                if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement || (target instanceof HTMLElement && target.isContentEditable)) setEditing(true);
              }}
              onBlurCapture={(event) => {
                if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setEditing(false);
              }}
            >
              {card({ close, autoFocus })}
            </div>
          )}
          <div className="my-3 flex justify-center">{footer}</div>
        </div>
      </main>
    </div>
  );
}

/**
 * 片名：衬线体「Movie*Claw*」+ 一道细线 + 宋体「智能影音服务器」。
 * 片头时字距从宽收紧、缓缓浮现（CSS 延时见 globals.css 的 welcome-reveal 组）；
 * 打开卡片后整体缩小留在顶部。
 */
function WelcomeMasthead({ compact }: { compact: boolean }) {
  const t = useTranslations("auth");
  return (
    <header
      className="flex origin-top flex-col items-center gap-3.5 [text-shadow:0_0_16px_rgba(0,0,0,0.35)] transition-transform duration-600 ease-out"
      style={{ transform: compact ? "scale(0.72)" : "none" }}
    >
      <h1
        className="welcome-reveal welcome-reveal--title text-[46px] font-light md:text-[60px] leading-none text-[var(--accent-strong)]"
        style={{ fontFamily: LATIN_SERIF }}
      >
        Movie<i>Claw</i>
      </h1>
      <span aria-hidden="true" className="welcome-reveal--rule block h-px bg-white/50" />
      <p
        className="welcome-reveal welcome-reveal--tagline pl-[8px] text-[13px] tracking-[8px] md:text-[14px] text-[var(--text-muted)]"
        style={{ fontFamily: WELCOME_SERIF }}
      >
        {t("welcome.tagline")}
      </p>
    </header>
  );
}

/**
 * 电影字幕（宋体）：中文一两行在上，外语原句小一号斜体在下，再下是片名与年份。
 * 每次进首页打乱一次顺序，9 秒换一句，点一下立刻换（并重新计时）；换句时旧句上移淡出并虚化、
 * 新句稍晚从下方浮上来，读起来是一句接一句。固定最小高度，一行与三行的字幕不会把按钮顶来顶去。
 */
function FilmSubtitles() {
  const t = useTranslations();
  const locale = useLocale();
  const [scenes, setScenes] = useState<WelcomeScene[] | null>(null);
  const [index, setIndex] = useState(0);
  // 第几次换句：给进出两句各自一个新 key，让 CSS 动画每次都重新播放
  const [turn, setTurn] = useState(0);
  const [leaving, setLeaving] = useState<{ scene: WelcomeScene; key: number } | null>(null);
  // 打乱放在挂载后：服务端渲染与首帧不能各自随机
  useEffect(() => setScenes(shuffledScenes()), []);

  const next = useCallback(() => {
    if (!scenes) return;
    setTurn((value) => value + 1);
    setLeaving({ scene: scenes[index], key: turn });
    if (index + 1 < scenes.length) {
      setIndex(index + 1);
    } else {
      setScenes(shuffledScenes());
      setIndex(0);
    }
  }, [index, scenes, turn]);

  useEffect(() => {
    if (!scenes) return;
    const timer = window.setTimeout(next, SCENE_MS);
    return () => window.clearTimeout(timer);
  }, [next, scenes]);

  const scene = scenes?.[index];
  const text = scene && sceneText(scene, locale);
  return (
    <div className="welcome-reveal welcome-reveal--quote relative">
      <button
        type="button"
        onClick={next}
        aria-label={
          text
            ? t("auth.welcome.quoteAria", {
                // 断行处：中文直接连上，英文补一个空格
                line: text.headline.replace(/\n/g, locale === "zh-Hans" ? "" : " "),
                film: text.film,
              })
            : t("auth.welcome.quoteLabel")
        }
        className="relative grid min-h-[150px] w-full cursor-pointer items-end text-center"
      >
        {leaving && (
          <FilmSubtitle
            key={`out-${leaving.key}`}
            scene={leaving.scene}
            locale={locale}
            className="welcome-quote-out"
            onDone={() => setLeaving(null)}
          />
        )}
        {scene && <FilmSubtitle key={`in-${turn}`} scene={scene} locale={locale} className="welcome-quote-in" />}
      </button>
    </div>
  );
}

function FilmSubtitle({
  scene,
  locale,
  className,
  onDone,
}: {
  scene: WelcomeScene;
  locale: string;
  className: string;
  onDone?: () => void;
}) {
  const { headline, subline, source } = sceneText(scene, locale);
  // 小字：外语原句用拉丁衬线斜体；英文界面里华语片附的中文原句用宋体正体
  const sublineFont = scene.original === null ? WELCOME_SERIF : LATIN_SERIF;
  return (
    <span
      aria-hidden="true"
      onAnimationEnd={onDone}
      className={`${className} col-start-1 row-start-1 flex flex-col items-center gap-2.5 whitespace-pre-line [text-shadow:0_0_10px_rgba(0,0,0,0.6)]`}
    >
      <span className="text-[18px] leading-[1.7] text-[var(--text)] md:text-[21px]" style={{ fontFamily: WELCOME_SERIF }}>
        {headline}
      </span>
      {subline && (
        <span
          className={`text-[13px] leading-[1.45] text-[var(--text-muted)] md:text-[15px] ${
            scene.original === null ? "" : "italic"
          }`}
          style={{ fontFamily: sublineFont }}
        >
          {subline}
        </span>
      )}
      <span
        className="pt-1.5 text-[11px] tracking-[2px] text-[var(--text-faint)]"
        style={{ fontFamily: WELCOME_SERIF }}
      >
        {locale === "zh-Hans" ? `——${source}` : `— ${source}`}
      </span>
    </span>
  );
}

/* —— 卡片积木：登录页与初始化页共用 —— */

/**
 * 欢迎页的玻璃卡片：标题（宋体）+ 说明 + 右上角 ×，与底栏同一种液态玻璃材质（globals.css 的
 * .welcome-glass）。卡片自己已是玻璃，× 不再叠一层玻璃，用内嵌底色的小圆（同 App）。
 */
export function WelcomeCard({
  title,
  subtitle,
  onClose,
  children,
}: {
  title: string;
  subtitle: string;
  onClose?: () => void;
  children: ReactNode;
}) {
  const t = useTranslations("common");
  return (
    <section className="welcome-glass rounded-[30px] p-[22px]">
      <header className="mb-4 flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <h2 className="text-[22px] leading-tight text-[var(--text)]" style={{ fontFamily: WELCOME_SERIF }}>
            {title}
          </h2>
          <p className="mt-1.5 text-sub leading-relaxed text-[var(--text-muted)]">{subtitle}</p>
        </div>
        {onClose && (
          <button
            type="button"
            onClick={onClose}
            aria-label={t("close")}
            className="grid size-[30px] shrink-0 place-items-center rounded-full border border-white/[0.08] bg-white/[0.05] text-[var(--text-muted)] transition-colors hover:text-[var(--text)]"
          >
            <XIcon className="size-3.5" strokeWidth={2.6} />
          </button>
        )}
      </header>
      {children}
    </section>
  );
}

/** 输入框组：同一块内嵌底色里用细线分隔，像系统设置里的分组 */
export function WelcomeFields({ children }: { children: ReactNode }) {
  return (
    <div className="divide-y divide-white/[0.08] rounded-2xl border border-white/[0.08] bg-white/[0.05]">
      {children}
    </div>
  );
}

/** 一行输入框：左侧图标 + 无边框输入；读屏名用 aria-label（占位符就是字段名） */
export function WelcomeField({
  icon,
  ref,
  ...inputProps
}: { icon: ReactNode; ref?: React.Ref<HTMLInputElement> } & React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <label className="flex min-h-[50px] items-center gap-3 px-3.5">
      <span aria-hidden="true" className="grid w-[22px] shrink-0 place-items-center text-[var(--text-faint)]">
        {icon}
      </span>
      <input
        ref={ref}
        {...inputProps}
        aria-label={inputProps["aria-label"] ?? inputProps.placeholder}
        className="min-w-0 flex-1 bg-transparent py-3 text-body text-[var(--text)] outline-none placeholder:text-[var(--text-faint)]"
      />
    </label>
  );
}

/** 卡片主按钮：亮银实底 + 深色字（App 的 glassProminent + accentStrong） */
export function WelcomeSubmit({ busy, disabled, children }: { busy: boolean; disabled: boolean; children: ReactNode }) {
  return (
    <button
      type="submit"
      disabled={disabled}
      className="flex h-[50px] w-full items-center justify-center gap-2 rounded-full bg-[var(--accent-strong)] text-[17px] font-semibold text-black/85 shadow-[0_8px_24px_-10px_rgba(0,0,0,0.6)] transition active:scale-[0.98] disabled:opacity-40"
    >
      {busy && <span className="size-4 animate-spin rounded-full border-2 border-black/25 border-t-black/80" />}
      {children}
    </button>
  );
}

/** 表单级错误（登录失败 / 校验不通过 / 限速提示） */
export function WelcomeError({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <p role="alert" className="text-sub leading-relaxed text-[var(--danger)]">
      {message}
    </p>
  );
}
