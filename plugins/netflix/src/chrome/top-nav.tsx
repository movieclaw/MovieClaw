"use client";

import Link from "next/link";
import type { Route } from "next";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import {
  AccountSwitcherDialog,
  AppUpdateEntry,
  AvatarBadge,
  ChevronDownIcon,
  LogoutIcon,
  MovieclawWordmark,
  NoticeCenter,
  SearchCommand,
  type SearchScope,
  type SearchSubmitOptions,
  signOut,
  taskActivityBadge,
  type TaskActivityBadge,
  useAgentConversations,
  useAppNavLinks,
  usePermissions,
  UsersIcon,
  useSearchAccess,
  useSession,
  useTaskActivity,
} from "@movieclaw/theme-sdk";


/**
 * Netflix 主题的桌面顶栏（≥768px，docs/design/web-themes.md §5.1）。
 *
 * - 高 68px、fixed，页面顶端透明（压一层向下渐隐的黑雾保证字标可读），
 *   任一滚动容器滚过阈值后过渡为 #141414 实底——Netflix 顶栏是实底不是毛玻璃，
 *   不引入 backdrop-filter。
 * - 左：品牌字标（回媒体库）+ 导航链接（激活 = 品牌红加粗——红只用于品牌
 *   标识与激活指示的 §4 纪律，未激活 = #e5e5e5、悬停变白）；
 *   <1100px 收敛为「浏览 ▾」下拉（Netflix 同款断点）。
 * - 右：「＋ 新任务」（白底黑字，AI 是本站差异能力，给一个 Netflix 没有但
 *   不破坏画面的入口）· 搜索（复用 SearchCommand 命令面板）· 通知铃 · 头像下拉。
 * - 侧栏的 nav.order 个人排序不作用于顶栏（记录在案的取舍）：顶栏链接是
 *   全局固定五项，权限过滤对齐侧栏的可见性判定（useVisibleNavItems 同口径）。
 *   插件网页的项（docs/design/plugin-web-pages.md）追加在固定项后面，同样尊重「移出侧边栏」。
 */

/** 顶栏导航链接的全局固定清单（权限过滤对齐侧栏可见性判定）。
 *  无「首页」——内容首页已与媒体库合并（2026-09 修订），字标直达 /library。 */
const NAV_LINKS: { id: string; label: string; href: Route }[] = [
  { id: "library", label: "媒体库", href: "/library" as Route },
  { id: "subscriptions", label: "我的订阅", href: "/subscriptions" as Route },
  { id: "discover", label: "发现", href: "/discover/movie" as Route },
];

/** pathname → 顶栏激活项 id（与 NAV_LINKS 对齐；未命中返回空串，无高亮）。 */
function activeNavId(pathname: string): string {
  if (pathname.startsWith("/discover/")) return "discover";
  // / 是 /library 的别名（Netflix 主题下 replace 过去），高亮随媒体库
  if (pathname === "/" || pathname.startsWith("/library")) return "library";
  if (pathname.startsWith("/subscriptions")) return "subscriptions";
  return "";
}

export function NetflixTopNav({
  onSearch,
  onOpenSettings,
}: {
  onSearch: (keyword: string, scope: SearchScope, options?: SearchSubmitOptions) => void;
  onOpenSettings: (sectionId?: string) => void;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const { canSubscribe, isAdmin } = usePermissions();
  // 搜索入口按「任一搜索分区可用」露出（影视 / 资源 / 媒体库），不只看资源搜索开关
  const { canOpenSearch } = useSearchAccess();
  const appNav = useAppNavLinks();
  const active = appNav.activeId ?? activeNavId(pathname);

  // 顶栏透明 → 实底的滚动判定：全站页面都是「外壳固定 + 内部容器滚动」，
  // window 本身不滚，用 capture 监听才能收到各页面滚动容器的事件。
  // 多个滚动容器并存时以最后滚动者为准——实际场景每页只有一条主滚动容器，
  // 且任何一条滚过阈值都意味着顶栏该落底了，判定足够稳。
  // 过渡不做成阈值翻转（bg 在 transparent/black 间跳变，观感生硬），而是把
  // 「滚入深度 0→1」连续写进 CSS 变量 --nf-nav-dim（24px 内保持全透明、
  // 24~404px 线性加深），黑底层按它连续淡入——滚动过程零 React 重渲染。
  // 变量已注册为 <number> 类型（globals.css 的 @property），.nf-topnav 上还
  // 挂了 450ms 的变量过渡：滚轮一次甩几百像素时黑底层也是缓动跟随，不会跳变。
  const rootRef = useRef<HTMLElement>(null);
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    const onScroll = (e: Event) => {
      const target = e.target;
      const top =
        target instanceof Element ? target.scrollTop : (target as Window | null)?.scrollY ?? 0;
      const progress = Math.min(1, Math.max(0, (top - 24) / 380));
      root.style.setProperty("--nf-nav-dim", progress.toFixed(3));
    };
    document.addEventListener("scroll", onScroll, { capture: true, passive: true });
    return () => document.removeEventListener("scroll", onScroll, { capture: true });
  }, []);
  // 顶栏常驻外壳、不随路由重建，滚动深度是跨页面残留的：上个页面滚过后跳到
  // 详情页，新页面停在顶部却没有滚动事件来纠正，顶栏会一直保持实底黑。路由
  // 切换即复位为页面顶端状态。复位与随后的「落位纠正」都要瞬时完成：媒体库
  // 等页面带着恢复的滚动位置回来时（滚动恢复在首帧绘制前写 scrollTop），纠正
  // 若参与 450ms 渐变，顶栏底色会在已经滚到深处的新页面上重放一遍
  // 「透明 → 黑」，观感即到达后闪一下。整个短窗口内压掉变量过渡（过渡属性
  // 挂 inline），等窗口过期再交还类上的缓动；在窗口内做过样式计算后再恢复
  // 才安全，靠墙钟 timeout 而非 rAF——rAF 在渲染节流（后台标签）下可能与
  // 写入挤进同一次样式计算，瞬时写入又被渐变接管（实测踩过）。
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    root.style.transition = "none";
    root.style.setProperty("--nf-nav-dim", "0");
    const resume = window.setTimeout(() => {
      root.style.transition = "";
    }, 250);
    return () => window.clearTimeout(resume);
  }, [pathname]);

  const appLinks = appNav.items.map((item) => ({
    id: item.id,
    label: item.label,
    href: item.href as Route,
  }));
  const visibleLinks = [
    ...NAV_LINKS.filter((link) => link.id !== "subscriptions" || canSubscribe),
    ...appLinks,
  ];

  return (
    <header ref={rootRef} className="nf-topnav nf:fixed nf:inset-x-0 nf:top-0 nf:z-40">
      {/* 两层背景随 --nf-nav-dim 连续叠合：底部永远铺「向下渐隐的黑雾」
          （页面顶端时黑字标在亮图上可读），黑实底层按滚动进度淡入盖过它。
          变量已注册（@property <number>），过渡写在变量自身上（.nf-topnav），
          直接给 opacity 加 transition 反而会被每帧写入的变量卡住（同
          PageNav --nav-reveal 的既知结论）。 */}
      <div
        aria-hidden="true"
        className="nf:absolute nf:inset-0 nf:bg-[linear-gradient(180deg,rgba(0,0,0,0.72),rgba(0,0,0,0)_100%)]"
      />
      <div aria-hidden="true" className="nf:absolute nf:inset-0 nf:bg-black" style={{ opacity: "var(--nf-nav-dim, 0)" }} />
      <div className="nf:relative nf:flex nf:h-[68px] nf:items-center nf:gap-6 nf:px-[4vw]">
        {/* 品牌字标：回媒体库（Netflix 主题没有首页——内容首页与媒体库合并；
            内容可点区拉满高度，与导航链接同标准） */}
        <Link
          href="/library"
          aria-label="回到媒体库"
          className="nf:flex nf:shrink-0 nf:items-center nf:transition-opacity nf:hover:opacity-80"
        >
          {/* 字标高度 = 大写高，宽度由字形比例推导（≈6.25 : 1）。22px 高 ≈ 137px
              宽，在 68px 顶栏里约占 1/3 高——原先的 h-7（28px / 175px 宽）把
              右边四条 14px 的导航链接整个压住了。MOVIECLAW 是 9 个字母，比
              NETFLIX 的 7 个天然更宽，同样的大写高会显著更抢眼，因此取比
              Netflix 官方字标（约 25px 高）更小的一档。 */}
          <MovieclawWordmark className="nf:h-[22px] nf:w-auto" />
        </Link>

        {/* 导航链接：≥1100px 全量展开 */}
        <nav className="nf:hidden nf:min-w-0 nf:items-center nf:gap-5 nf:min-[1100px]:flex">
          {visibleLinks.map((link) => (
            <Link
              key={link.id}
              href={link.href}
              className={`nf:shrink-0 nf:text-[14px] nf:transition-colors ${
                active === link.id
                  ? "nf:font-bold nf:text-[var(--accent)]"
                  : "nf:font-normal nf:text-[#e5e5e5] nf:hover:text-white"
              }`}
            >
              {link.label}
            </Link>
          ))}
        </nav>

        {/* <1100px：链接收敛为「浏览 ▾」下拉 */}
        <BrowseDropdown links={visibleLinks} active={active} />

        <div className="nf:ml-auto nf:flex nf:shrink-0 nf:items-center nf:gap-1.5">
          {/* ＋ 新任务：白底黑字主操作（§4 用色纪律：红只给品牌字标 / 进度条 /
              匹配度 / 激活指示，主按钮走 Netflix 生产主键语言——白底黑字，
              三态透明度 1 / hover 0.75 / 按下 0.5，与 .btn-accent 的主题覆盖
              同一款；白钮在纯黑顶栏上依旧是最醒目的一处）。
              管理员专属——银玻璃侧栏用 memberNavItems 把「新会话」整条摘掉，
              这里必须同口径，否则成员会看到一个后端全 403 的入口。 */}
          {isAdmin && (
            <button
              type="button"
              onClick={() => router.push("/new")}
              className="nf:flex nf:h-9 nf:items-center nf:gap-1.5 nf:rounded-[4px] nf:bg-white nf:px-3 nf:text-[14px] nf:font-semibold nf:text-black nf:transition-colors nf:hover:bg-white/75 nf:active:bg-white/50"
            >
              <PlusGlyph />
              新任务
            </button>
          )}
          {canOpenSearch && <SearchCommand onSearch={onSearch} triggerClassName="icon-btn" />}
          <NoticeCenter collapsed variant="bell" />
          <NetflixAvatarMenu onOpenSettings={onOpenSettings} isAdmin={isAdmin} />
        </div>
      </div>
    </header>
  );
}

/** 「＋」字符字形：与文本基线对齐的一次性加号，不为此引入图标档位 */
function PlusGlyph() {
  return (
    <svg viewBox="0 0 24 24" className="nf:size-4" fill="none" stroke="currentColor" strokeWidth={2.4} aria-hidden="true">
      <path d="M12 5v14M5 12h14" strokeLinecap="round" />
    </svg>
  );
}

/** 「浏览 ▾」下拉：<1100px 的导航收敛形态（Netflix 同款交互）。 */
function BrowseDropdown({
  links,
  active,
}: {
  links: readonly { id: string; label: string; href: Route }[];
  active: string;
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onPointer = (e: MouseEvent) => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onPointer);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onPointer);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const currentLabel = links.find((link) => link.id === active)?.label ?? "浏览";

  return (
    <div ref={rootRef} className="nf:relative nf:min-[1100px]:hidden">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="nf:flex nf:h-9 nf:items-center nf:gap-1 nf:rounded-[4px] nf:px-2 nf:text-[14px] nf:font-medium nf:text-[#e5e5e5] nf:transition-colors nf:hover:text-white"
      >
        {currentLabel}
        <ChevronDownIcon className={`nf:size-4 nf:transition-transform ${open ? "nf:rotate-180" : ""}`} />
      </button>
      {open && (
        <div
          className="menu-surface nf:absolute nf:left-0 nf:top-full nf:z-50 nf:mt-2 nf:w-44 nf:p-1.5"
          // .menu-surface 的无层 CSS position:relative 会压过 absolute 工具类
          // （无层规则优先于 @layer utilities），菜单因此脱离按钮锚点、被顶栏
          // flex 居中推出窗口——内联覆盖才能赢（同 composer.tsx / user-menu.tsx）
          style={{ position: "absolute" }}
        >
          {links.map((link) => (
            <Link
              key={link.id}
              href={link.href}
              onClick={() => setOpen(false)}
              className={`glass-row nf:px-2.5 nf:py-2 nf:text-ui nf:font-medium ${
                active === link.id ? "nf:font-bold nf:text-[var(--accent)]" : ""
              }`}
            >
              <span className="nf:flex-1">{link.label}</span>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * 方角小头像下拉：设置 / 活动 / AI 会话 / 切换账号 / 退出。
 *
 * Netflix 原版头像菜单没有「设置」项——这是有意的偏离（功能需要，见设计
 * 文档 §2.5）；「AI 会话」是侧栏「最近会话」列表的收拢：顶栏放不下，收敛
 * 进头像下拉的一节（滚动列表而非真正的二级浮层，触达路径更短）。
 */
function NetflixAvatarMenu({
  onOpenSettings,
  isAdmin,
}: {
  onOpenSettings: (sectionId?: string) => void;
  isAdmin: boolean;
}) {
  const router = useRouter();
  const { session } = useSession();
  const { conversations } = useAgentConversations();
  const [open, setOpen] = useState(false);
  const [switcherOpen, setSwitcherOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onPointer = (e: MouseEvent) => {
      const t = e.target as Node;
      if (rootRef.current?.contains(t) || menuRef.current?.contains(t)) return;
      setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onPointer);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onPointer);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  /**
   * 退出登录：与侧栏 UserMenu 同一套语义——只退当前账号，本浏览器还有别的
   * 账号时后端自动切过去，没有了才去登录页；整页跳转重置全部前端状态。
   */
  const handleLogout = async () => {
    setOpen(false);
    await signOut();
  };

  return (
    <div ref={rootRef} className="nf:relative">
      {open && (
        <div
          ref={menuRef}
          className="menu-surface nf:absolute nf:right-0 nf:top-full nf:z-50 nf:mt-2 nf:w-64 nf:overflow-hidden nf:p-1.5"
          // 同 BrowseDropdown：内联覆盖 .menu-surface 的无层 position:relative，
          // 否则菜单脱离按钮锚点、被顶栏 flex 布局推出窗口顶
          style={{ position: "absolute" }}
        >
          <div className="nf:flex nf:items-center nf:gap-3 nf:px-2.5 nf:pb-2.5 nf:pt-2">
            <AvatarBadge
              nickname={session.nickname}
              avatarUrl={session.avatar_url}
              className="nf:size-9 nf:text-ui"
            />
            <div className="nf:min-w-0">
              <p className="nf:truncate nf:text-ui nf:font-semibold nf:text-[var(--text)]">
                {session.nickname}
              </p>
              <p className="nf:truncate nf:text-caption nf:text-[var(--text-muted)]">@{session.username}</p>
            </div>
          </div>
          <div className="nf:my-1 nf:h-px nf:bg-white/[0.08]" />
          {/* 更新入口：侧栏在 Netflix 主题下退役，常驻更新徽标由头像菜单承接
              （组件自轮询自鉴权，无更新时整行不渲染），一跳直达更新分区 */}
          <AppUpdateEntry
            collapsed={false}
            onOpen={() => {
              setOpen(false);
              onOpenSettings("app");
            }}
          />
          <MenuRow label="设置" onClick={() => { setOpen(false); onOpenSettings(); }} />
          {isAdmin && (
            <AvatarActivityRow
              onGo={(href) => {
                setOpen(false);
                router.push(href as Route);
              }}
            />
          )}
          {isAdmin && conversations.length > 0 && (
            <>
              <p className="group-label nf:px-3 nf:pb-1 nf:pt-2.5">AI 会话</p>
              <div className="scroll-thin nf:max-h-56 nf:overflow-y-auto">
                {conversations.map((c) => (
                  <MenuRow
                    key={c.id}
                    label={c.title}
                    running={c.running}
                    onClick={() => {
                      setOpen(false);
                      router.push(`/sessions/${c.id}`);
                    }}
                  />
                ))}
              </div>
            </>
          )}
          <div className="nf:my-1 nf:h-px nf:bg-white/[0.08]" />
          <MenuRow
            label="切换账号"
            icon={<UsersIcon className="nf:size-[18px]" />}
            onClick={() => {
              setOpen(false);
              setSwitcherOpen(true);
            }}
          />
          <MenuRow
            label="退出登录"
            danger
            icon={<LogoutIcon className="nf:size-[18px]" />}
            onClick={() => void handleLogout()}
          />
        </div>
      )}
      <AccountSwitcherDialog open={switcherOpen} onClose={() => setSwitcherOpen(false)} />

      {/* 触发按钮：方角小头像（Netflix 头像是圆角方形，不做全圆） */}
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-label="账号菜单"
        className="icon-btn"
      >
        {/* rounded-* 要经 style 才压得过 AvatarBadge 内部硬写的 rounded-full
            （同特异度的工具类拼在一起，胜负取决于生成 CSS 的先后，实测是
            rounded-full 赢）——Netflix 头像是圆角方形，不做全圆 */}
        <AvatarBadge
          nickname={session.nickname}
          avatarUrl={session.avatar_url}
          className="nf:size-8 nf:text-ui"
          style={{ borderRadius: 4 }}
        />
      </button>
    </div>
  );
}

/** 头像菜单里的活动行：带任务角标（alert 红 / 进行中蓝）与动态落点——
 *  侧栏 JobCenter 的同一套徽标逻辑（taskActivityBadge）。拆成独立组件让
 *  任务快照变化只重渲染这一行；数据来自全站 Provider，本组件不发起请求。 */
function AvatarActivityRow({ onGo }: { onGo: (href: string) => void }) {
  const badge = taskActivityBadge(useTaskActivity());
  return (
    <MenuRow
      label="活动"
      badge={badge.count > 0 ? badge : undefined}
      onClick={() => onGo(badge.href)}
    />
  );
}

/** 头像下拉里的一行（glass-row 皮肤在 Netflix 主题下自动跟随 token）。 */
function MenuRow({
  label,
  onClick,
  icon,
  danger = false,
  running = false,
  badge,
}: {
  label: string;
  onClick: () => void;
  icon?: React.ReactNode;
  danger?: boolean;
  running?: boolean;
  /** 右缘状态角标（活动行的任务计数：alert 红 / 否则提示蓝） */
  badge?: TaskActivityBadge;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={badge?.hint ?? label}
      className={`glass-row nf:px-3 nf:py-2 nf:text-ui nf:font-medium nf:max-md:py-2.5 ${
        danger ? "nf:!text-[var(--danger)] nf:hover:!bg-[rgba(255,107,107,0.12)]" : ""
      }`}
    >
      {running && (
        <span aria-hidden="true" className="nf:size-1.5 nf:shrink-0 nf:animate-pulse nf:rounded-full nf:bg-[var(--info)]" />
      )}
      {icon && <span className="nf:shrink-0 nf:opacity-80">{icon}</span>}
      <span className="nf:min-w-0 nf:flex-1 nf:truncate">{label}</span>
      {badge && badge.count > 0 && (
        <span
          className={`nf:shrink-0 nf:rounded-full nf:px-1.5 nf:py-0.5 nf:text-micro nf:font-semibold nf:leading-none ${
            badge.alert
              ? "nf:bg-[var(--danger-solid)] nf:text-white"
              : "nf:bg-[var(--info)]/20 nf:text-[var(--info)]"
          }`}
        >
          {badge.count}
        </span>
      )}
    </button>
  );
}
