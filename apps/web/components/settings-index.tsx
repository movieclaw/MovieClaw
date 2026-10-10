"use client";

import type { Route } from "next";
import { useRouter } from "next/navigation";

import { ChevronRightIcon } from "@/components/icons";
import { settingsSectionGroupsFor } from "@/lib/mock-data";
import { useSession } from "@/lib/session";
import { useTheme } from "@/lib/ui-prefs";

/**
 * 移动端的设置分区列表页（路由 /settings，基础实现，两个主题共用）。
 *
 * 原为 Netflix 主题专属（2026-09 修订：NetflixSettingsNav 页顶的分区下拉浮层
 * 在分区一多时高过视口又不能滚）；银玻璃移动端的抽屉侧栏随液态玻璃底栏退役
 * （docs/design/web-themes-mobile/04），分区切换同样需要一个列表页，于是上移为
 * 基础实现：本页按组列出全部分区（glass-row 行，主题 CSS 自动换皮），点行进
 * /settings/[section]，页顶返回键回本页（见 components/mobile-settings-nav.tsx）。
 * 桌面端不用本页（分区菜单在常驻侧栏，/settings 直接重定向到首个分区）。
 *
 * 外观对齐原生 App 的设置首页（iOS 插入分组列表）：每组一张圆角卡片、组名在卡片上方、
 * 行间一道从文字起缩进的发丝线。手机没有悬停，只给按下态（松手淡出）；悬停高亮
 * 只在有指针的设备上出现，免得点过的行回来后一直亮着。
 */
export function SettingsIndex() {
  const router = useRouter();
  const { session } = useSession();
  // 分区清单按角色过滤：成员只看到通用组，管理分区没有入口（后端 403 兜底）。
  // 银玻璃不再单列「个人信息」：入口统一为「我的」页的头像卡（同原生 App 的设置目录），
  // /settings/profile 深链照常可用；Netflix 的「我的」页没有头像卡入口，保留这一行
  const isNetflix = useTheme().structural;
  const groups = settingsSectionGroupsFor(session.role)
    .map((group) =>
      isNetflix ? group : { ...group, items: group.items.filter((s) => s.id !== "profile") },
    )
    .filter((group) => group.items.length > 0);

  return (
    <div className="scroll-thin scroll-safe h-full overflow-y-auto">
      <div className="mx-auto w-full max-w-2xl px-4 pb-16 pt-2">
        {groups.map((group) => (
          <section key={group.label || group.items[0]?.id} className="mt-7 first:mt-0">
            {/* 概览组不设标题（label 为空串），空标题不渲染组名 */}
            {group.label && (
              <h2 className="px-4 pb-2 text-caption text-[var(--text-muted)]">{group.label}</h2>
            )}
            <nav
              aria-label={group.label || "设置分区"}
              className="css-glass overflow-hidden"
            >
              {group.items.map((section, index) => {
                const Icon = section.icon;
                return (
                  <button
                    key={section.id}
                    type="button"
                    onClick={() => router.push(`/settings/${section.id}` as Route)}
                    className="relative flex min-h-[52px] w-full items-center gap-3.5 pl-4 pr-3.5 text-left text-[var(--text)] transition-colors duration-300 hover:bg-white/[0.04] active:bg-white/[0.1] active:duration-0"
                  >
                    {Icon && <Icon className="size-[22px] shrink-0 text-[var(--text-muted)]" />}
                    <span className="min-w-0 flex-1 truncate text-body-lg">{section.label}</span>
                    <ChevronRightIcon className="size-4 shrink-0 text-[var(--text-faint)]" />
                    {/* 发丝线从文字起（左内边距 16 + 图标 22 + 间距 14），最后一行不画 */}
                    {index < group.items.length - 1 && (
                      <span
                        aria-hidden
                        className="pointer-events-none absolute bottom-0 left-[52px] right-0 h-[0.5px] bg-white/[0.14]"
                      />
                    )}
                  </button>
                );
              })}
            </nav>
          </section>
        ))}
      </div>
    </div>
  );
}
