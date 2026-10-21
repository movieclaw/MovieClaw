"use client";

import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, type ReactNode } from "react";

import { AccountSwitcherDialog } from "@/components/account-switcher-dialog";
import { AppUpdateEntry } from "@/components/app-update-entry";
import { AvatarBadge } from "@/components/avatar-badge";
import { ConversationMenu, useConversationActions } from "@/components/conversation-menu";
import {
  ChevronRightIcon,
  ComposeIcon,
  GearIcon,
  LogoutIcon,
  UsersIcon,
} from "@/components/icons";
import { NoticeCenter } from "@/components/notice-center";
import { usePluginNavItems } from "@/components/sidebar";
import { signOut } from "@/lib/account-reload";
import { useAgentConversations } from "@/lib/agent-conversations";
import { usePageChrome } from "@/lib/page-chrome";
import { roleLabel, usePermissions } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import type { TaskActivityBadge } from "@/lib/task-activity";

/**
 * 「我的」页（路由 /my，主题 pages.my 坑位的基础实现）——银玻璃移动端液态玻璃
 * 底栏最右的头像页签（docs/design/web-themes-mobile/04-iOS-液态玻璃底栏.md §3.1）。
 *
 * 版式对齐原生 App 的「我的」页（apps/apple/MovieClaw/Features/Root/MorePage.swift），
 * iOS 设置式分组列表（inset grouped）：
 *   - 头像卡：头像 + 昵称 + `@用户名 · 角色`，整张卡可点进「个人信息」（同 iOS 设置 App
 *     顶部的账户卡），因此常用组里不再单列「个人信息」行；
 *   - 常用：待处理事项（管理员、有事才出现）/ 设置 / 应用更新（有更新才出现）；
 *   - 账号：切换账号 / 退出登录——紧跟设置之后，不被下面会长的会话列表推到页底；
 *   - 最近会话（管理员）：首行「新会话」（顶栏的「+」已去掉，这里是发起新会话的入口），
 *     下面是 AI 会话，滑到末尾自动取下一页（不再是「显示全部 / 收起」——那样手机上
 *     第 21 条以后的会话永远到不了）；行尾 ⋯ 菜单：在新会话中继续 / 重命名 / 删除。
 * 新会话与 AI 会话是 Agent 能力，管理员专属——与侧栏的 memberNavItems 同口径
 * （安全边界在后端 require_admin，这里是界面裁剪）。
 *
 * Netflix 主题有自己的「我的」页（plugins/netflix/src/pages/my-page），会覆盖本页。
 */
export function MorePage() {
  const router = useRouter();
  const { session } = useSession();
  const { isAdmin } = usePermissions();
  const { conversations, hasMore, loadingMore, loadMore } = useAgentConversations();
  const { forkConversation, renameConversation, removeConversation } = useConversationActions();
  const [switcherOpen, setSwitcherOpen] = useState(false);
  // 手机没有侧边栏：插件网页（docs/design/plugin-web-pages.md）的入口放在这里
  const pluginItems = usePluginNavItems();

  // 手机顶栏标题「我的」（同 App：这一页是正文字号的行内标题，不是大字标题）
  const setTopBarTitle = usePageChrome()?.setTopBarTitle;
  useEffect(() => setTopBarTitle?.("我的"), [setTopBarTitle]);

  // 最近会话触底续载：列表末尾的哨兵进入视口（留 200px 提前量）就取下一页
  const sentinelRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const node = sentinelRef.current;
    if (!node || !hasMore) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) loadMore();
      },
      { rootMargin: "200px 0px" },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [hasMore, loadMore, conversations.length]);

  /**
   * 退出登录：只退当前账号，本浏览器还有别的账号时后端自动切过去，
   * 没有了才去登录页；整页跳转重置全部前端状态（与侧栏用户菜单同一套流程）。
   */
  const handleLogout = async () => {
    await signOut();
  };

  return (
    <div className="scroll-thin scroll-safe h-full overflow-y-auto">
      <div className="mx-auto w-full max-w-2xl px-4 pb-10 pt-4 md:px-6 md:pt-10">
        {/* 头像卡：整张可点进个人信息，右缘 › 表达可点（同 iOS 设置 App 的账户卡） */}
        <button
          type="button"
          onClick={() => router.push("/settings/profile" as Route)}
          aria-label={`${session.nickname}，查看和修改个人信息`}
          className="glass-row mb-5 w-full gap-4 rounded-2xl bg-[var(--glass-fill)] px-4 py-3.5 ring-1 ring-inset ring-[var(--line)]"
        >
          <AvatarBadge
            nickname={session.nickname}
            avatarUrl={session.avatar_url}
            className="size-14 text-title-lg"
          />
          <span className="min-w-0 flex-1 text-left">
            <span className="block truncate text-title font-semibold tracking-[-0.01em] text-[var(--text)]">
              {session.nickname}
            </span>
            <span className="mt-0.5 block truncate text-ui text-[var(--text-muted)]">
              @{session.username} · {roleLabel(session)}
            </span>
          </span>
          <ChevronRightIcon className="size-4 shrink-0 text-[var(--text-faint)]" />
        </button>

        <MoreGroup label="常用">
          {/* 待处理事项与应用更新：组件自轮询，无事时整行不渲染 */}
          <NoticeCenter collapsed={false} />
          <MoreRow Icon={GearIcon} label="设置" onClick={() => router.push("/settings" as Route)} />
          <AppUpdateEntry collapsed={false} onOpen={() => router.push("/settings/app" as Route)} />
        </MoreGroup>

        {pluginItems.length > 0 && (
          <MoreGroup label="插件页面">
            {pluginItems.map((item) => (
              <MoreRow
                key={item.id}
                Icon={item.icon}
                label={item.label}
                onClick={() => router.push(item.href as Route)}
              />
            ))}
          </MoreGroup>
        )}

        <MoreGroup label="账号">
          <MoreRow Icon={UsersIcon} label="切换账号" onClick={() => setSwitcherOpen(true)} />
          <MoreRow Icon={LogoutIcon} label="退出登录" danger onClick={() => void handleLogout()} />
        </MoreGroup>

        {isAdmin && (
          <MoreGroup label="最近会话">
            <MoreRow
              Icon={ComposeIcon}
              label="新会话"
              accent
              onClick={() => router.push("/new" as Route)}
            />
            {conversations.length === 0 ? (
              <p className="px-4 py-3 text-caption leading-5 text-[var(--text-faint)]">
                还没有会话，点上方的「新会话」开始。
              </p>
            ) : (
              conversations.map((c) => (
                <MoreRow
                  key={c.id}
                  label={c.title}
                  running={c.running}
                  onClick={() => router.push(`/sessions/${c.id}` as Route)}
                  trailing={
                    <ConversationMenu
                      onFork={() => void forkConversation(c.id, c.title)}
                      onRename={() => void renameConversation(c.id, c.title)}
                      onDelete={() => void removeConversation(c.id, c.title)}
                      triggerClassName="!size-8 text-[var(--text-muted)]"
                    />
                  }
                />
              ))
            )}
            {loadingMore && (
              <p className="px-4 py-2.5 text-center text-caption text-[var(--text-faint)]">
                正在加载更多会话…
              </p>
            )}
          </MoreGroup>
        )}
        {/* 触底续载哨兵：放在卡片外，免得被 divide-y 画出一条多余的分隔线 */}
        {isAdmin && hasMore && <div ref={sentinelRef} aria-hidden="true" className="h-px" />}
      </div>

      <AccountSwitcherDialog open={switcherOpen} onClose={() => setSwitcherOpen(false)} />
    </div>
  );
}

/** 分组卡片：小节标题 + 圆角卡片，行间细分隔线（iOS inset grouped 列表） */
function MoreGroup({ label, children }: { label: string; children: ReactNode }) {
  return (
    <nav aria-label={label} className="mt-5 first:mt-0">
      <p className="group-label px-4 pb-1.5">{label}</p>
      <div className="divide-y divide-[var(--line)] overflow-hidden rounded-2xl bg-[var(--glass-fill)] ring-1 ring-inset ring-[var(--line)] [&_.glass-row]:rounded-none">
        {children}
      </div>
    </nav>
  );
}

/**
 * 列表行：glass-row 皮肤 + 右缘 chevron 表达「点进去」的可点性。
 * ``trailing``：行尾叠一个独立控件（会话行的「⋯」菜单）——它不能嵌在主体
 * 按钮里（button 不能套 button），所以绝对定位盖在行尾、主体按钮右侧留出位置，
 * 有它时不再画 chevron（一行只表达一种可点性）。
 */
function MoreRow({
  Icon,
  label,
  onClick,
  danger = false,
  accent = false,
  running = false,
  badge,
  trailing,
}: {
  Icon?: React.ComponentType<React.SVGProps<SVGSVGElement>>;
  label: string;
  onClick: () => void;
  danger?: boolean;
  /** 强调色行（最近会话首行的「新会话」，同 App 的 accentStrong） */
  accent?: boolean;
  running?: boolean;
  /** 右缘状态角标（活动行的任务计数：alert 红 / 否则提示蓝） */
  badge?: TaskActivityBadge;
  trailing?: ReactNode;
}) {
  const row = (
    <button
      type="button"
      onClick={onClick}
      title={badge?.hint}
      className={`glass-row w-full px-4 py-3 text-body font-medium ${
        danger
          ? "!text-[var(--danger)]"
          : accent
            ? "!text-[var(--accent-strong)]"
            : "!text-[var(--text)]"
      } ${trailing ? "pr-14" : ""}`}
    >
      {running && (
        <span aria-hidden="true" className="size-1.5 shrink-0 animate-pulse rounded-full bg-[var(--info)]" />
      )}
      {Icon && (
        <Icon
          className={`size-[22px] shrink-0 ${accent || danger ? "" : "text-[var(--text-muted)]"}`}
        />
      )}
      <span className="min-w-0 flex-1 truncate text-left">{label}</span>
      {badge && badge.count > 0 && (
        <span
          className={`shrink-0 rounded-full px-1.5 py-0.5 text-micro font-semibold leading-none ${
            badge.alert
              ? "bg-[var(--danger-solid)] text-white"
              : "bg-[var(--info)]/20 text-[var(--info)]"
          }`}
        >
          {badge.count}
        </span>
      )}
      {!trailing && <ChevronRightIcon className="size-4 shrink-0 text-[var(--text-faint)]" />}
    </button>
  );
  if (!trailing) return row;
  return (
    <div className="relative">
      {row}
      <div className="absolute right-3 top-1/2 -translate-y-1/2">{trailing}</div>
    </div>
  );
}
