/**
 * 设置页基础组件（Linear / Vercel 式规范的落地，见 docs/design/settings-ui.md）。
 *
 * 一页设置 = 若干 SettingsSection（标题 + 说明 + 右侧页面级动作）。小节内容二选一：
 *   - SettingsList + SettingsRow：左「名称 + 说明」、右控件的行组，开关/下拉/单值
 *     即时生效，不配保存按钮；
 *   - SettingsCard：多字段一起提交的表单，页脚左提示、右唯一的提交按钮。
 * 危险操作统一放在页底的 tone="danger" 卡片里。
 *
 * 材质只复用既有的 .css-glass / .btn-glass / .btn-accent，主题换皮（Netflix 实色卡）
 * 自动生效，这里不写任何主题判断。
 */

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import type { Route } from "next";
import Link from "next/link";
import { Fragment, type ReactNode } from "react";

import { CheckIcon, ChevronRightIcon, MoreIcon, XIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import { useTheme } from "@/lib/ui-prefs";

/** 设置页文本输入框：聚焦环由 .field-shell 承载 */
export const SETTINGS_INPUT_CLASS =
  "field-shell rounded-lg border border-white/[0.08] bg-black/25 px-3 py-1.5 text-ui text-[var(--text)] outline-none placeholder:text-[var(--text-faint)] disabled:opacity-50";

/** 次要按钮（编辑、恢复、发送测试）：小号描边胶囊 */
export const SETTINGS_BUTTON_CLASS =
  "btn-glass h-8 shrink-0 px-3.5 text-sub font-medium disabled:opacity-40";

/** 主按钮（卡片页脚的提交）：小号实心，每屏最多一个 */
export const SETTINGS_PRIMARY_BUTTON_CLASS =
  "btn-accent h-8 shrink-0 rounded-full px-4 text-sub font-semibold disabled:opacity-40";

/** 危险按钮：红字描边，后果写在确认弹窗里 */
export const SETTINGS_DANGER_BUTTON_CLASS =
  "btn-glass h-8 shrink-0 px-3.5 text-sub font-medium !text-[var(--danger)] disabled:opacity-40";

export function SettingsSection({
  title,
  description,
  action,
  footnote,
  children,
}: {
  title: string;
  description?: ReactNode;
  /** 作用于整个小节的动作（添加、邀请），放在标题行最右侧 */
  action?: ReactNode;
  /** 小节下方的补充说明 */
  footnote?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section>
      {/* 说明长时按钮换到下一行，不把说明挤成窄条 */}
      <div className="mb-3 flex flex-wrap items-end justify-between gap-x-4 gap-y-2 px-1">
        <div className="min-w-0 flex-1 basis-64">
          <h2 className="text-body font-semibold text-[var(--text)]">{title}</h2>
          {description && (
            <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">{description}</p>
          )}
        </div>
        {action}
      </div>
      {children}
      {footnote && (
        <p className="mt-2 px-1 text-caption leading-5 text-[var(--text-faint)]">{footnote}</p>
      )}
    </section>
  );
}

/** 行组容器：行与行之间一道发丝线 */
export function SettingsList({ children }: { children: ReactNode }) {
  return (
    <div className="css-glass divide-y divide-[var(--line)] !rounded-xl">
      {children}
    </div>
  );
}

export function SettingsRow({
  label,
  description,
  leading,
  error,
  children,
  href,
}: {
  label: ReactNode;
  description?: ReactNode;
  /** 行首图标 / 头像 */
  leading?: ReactNode;
  /** 行内错误：贴在说明下方 */
  error?: string | null;
  /** 行尾控件或动作 */
  children?: ReactNode;
  /** 点行进详情页：名称与说明区域成为链接，行尾控件照常可点 */
  href?: string;
}) {
  const text = (
    <>
      <div className="text-body font-medium text-[var(--text)]">{label}</div>
      {description && (
        <div className="mt-0.5 text-caption leading-5 text-[var(--text-faint)]">
          {description}
        </div>
      )}
      {error && <p className="mt-1 text-sub text-[var(--danger)]">{error}</p>}
    </>
  );
  return (
    <div
      className={`flex min-h-[56px] items-center gap-4 px-4 py-3 ${href ? "transition-colors hover:bg-white/[0.03]" : ""}`}
    >
      {leading}
      {href ? (
        <Link href={href as Route} className="group min-w-0 flex-1">
          {text}
        </Link>
      ) : (
        <div className="min-w-0 flex-1">{text}</div>
      )}
      {children != null && <div className="flex shrink-0 items-center gap-2">{children}</div>}
      {href && (
        <Link href={href as Route} aria-hidden tabIndex={-1} className="shrink-0">
          <ChevronRightIcon className="size-4 text-[var(--text-faint)]" />
        </Link>
      )}
    </div>
  );
}

export function SettingsCard({
  title,
  description,
  hint,
  action,
  tone = "default",
  children,
}: {
  title: string;
  description?: ReactNode;
  /** 页脚左侧：限制条件、了解更多 */
  hint?: ReactNode;
  /** 页脚右侧：这张卡唯一的提交按钮 */
  action?: ReactNode;
  tone?: "default" | "danger";
  children?: ReactNode;
}) {
  const danger = tone === "danger";
  return (
    <div
      className={`css-glass overflow-hidden !rounded-xl ${
        danger ? "!border-[color-mix(in_srgb,var(--danger)_35%,transparent)]" : ""
      }`}
    >
      <div className="px-5 py-4">
        <h3 className="text-body font-semibold text-[var(--text)]">{title}</h3>
        {description && (
          <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">{description}</p>
        )}
        {children && <div className="mt-4">{children}</div>}
      </div>
      {(hint || action) && (
        <div
          className={`flex min-h-[52px] items-center justify-between gap-4 border-t px-5 py-2.5 ${
            danger
              ? "border-[color-mix(in_srgb,var(--danger)_25%,transparent)] bg-[color-mix(in_srgb,var(--danger)_6%,transparent)]"
              : "border-[var(--line)] bg-black/20"
          }`}
        >
          <div className="min-w-0 text-caption leading-5 text-[var(--text-faint)]">{hint}</div>
          {action}
        </div>
      )}
    </div>
  );
}

/**
 * 分区内的页签（胶囊）。配合 useTabParam 用：?tab= 深链、切换写回地址栏。
 * Netflix 的选中态是白底黑字（品牌语言），银玻璃是灰底白字。
 */
export function SettingsTabs<T extends string>({
  tabs,
  value,
  onChange,
}: {
  tabs: readonly { id: T; label: ReactNode }[];
  value: T;
  onChange: (id: T) => void;
}) {
  const activeCls = useTheme().structural ? "bg-white text-black" : "bg-white/[0.14] text-white";
  return (
    <div className="flex flex-wrap gap-1.5">
      {tabs.map((t) => (
        <button
          key={t.id}
          type="button"
          aria-pressed={t.id === value}
          onClick={() => onChange(t.id)}
          className={`flex items-center gap-1.5 rounded-full px-3.5 py-1.5 text-sub font-medium transition-colors ${
            t.id === value
              ? activeCls
              : "text-[var(--text-muted)] hover:bg-white/[0.07] hover:text-[var(--text)]"
          }`}
        >
          {t.label}
        </button>
      ))}
    </div>
  );
}

/**
 * 列表为空：放在列表原本的位置，一句话说清是什么 + 怎么开始。
 * 动作按钮只在小节标题行没有「添加」入口时才放这里，同一屏不出现两个添加入口。
 */
export function SettingsEmpty({
  icon,
  title,
  description,
  action,
}: {
  icon?: ReactNode;
  title: string;
  description?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="css-glass flex flex-col items-center gap-3 !rounded-xl px-6 py-10 text-center">
      {icon && <span className="icon-chip size-10 !rounded-xl">{icon}</span>}
      <div>
        <p className="text-body font-medium text-[var(--text)]">{title}</p>
        {description && (
          <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">{description}</p>
        )}
      </div>
      {action}
    </div>
  );
}

export interface SettingsMenuItem {
  label: string;
  onSelect: () => void;
  disabled?: boolean;
  /** 删除、注销这类：红字；放在最后 */
  danger?: boolean;
  /** 停用这类可逆但影响大的：黄字；排在危险项之前 */
  warn?: boolean;
  /** 右侧灰字说明（如为什么不可用） */
  hint?: string;
}

const MENU_ITEM_CLASS =
  "glass-row nav-item cursor-pointer px-3 py-2 text-sub font-medium outline-none " +
  "data-[highlighted]:!bg-[var(--glass-fill-hover)] data-[highlighted]:!text-[var(--text)] " +
  "data-[disabled]:pointer-events-none data-[disabled]:opacity-40";

/** 行尾「⋯」菜单：收纳一行的次要动作，危险动作在最后 */
export function SettingsMoreMenu({
  label,
  items,
  disabled = false,
}: {
  /** 读屏名，如「「qBittorrent」的更多操作」 */
  label: string;
  items: SettingsMenuItem[];
  disabled?: boolean;
}) {
  const firstRisky = items.findIndex((item) => item.danger || item.warn);
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          aria-label={label}
          className="flex size-8 shrink-0 items-center justify-center rounded-full text-[var(--text-muted)] outline-none transition hover:bg-white/[0.08] hover:text-[var(--text)] focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)] disabled:opacity-40 data-[state=open]:bg-white/[0.1] data-[state=open]:text-[var(--text)]"
        >
          <MoreIcon className="size-[18px]" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          collisionPadding={12}
          className="menu-surface z-50 min-w-[10rem] p-1"
        >
          {items.map((item, i) => (
            <Fragment key={item.label}>
              {/* 警示 / 危险项成组排在最后，组前一道分隔线 */}
              {i > 0 && i === firstRisky && (
                <DropdownMenu.Separator className="my-1 h-px bg-[var(--line)]" />
              )}
              <DropdownMenu.Item
                disabled={item.disabled}
                onSelect={item.onSelect}
                className={`${MENU_ITEM_CLASS} ${
                  item.danger
                    ? "!text-[var(--danger)] data-[highlighted]:!bg-[color-mix(in_srgb,var(--danger)_12%,transparent)]"
                    : item.warn
                      ? "!text-[var(--warn)] data-[highlighted]:!bg-[color-mix(in_srgb,var(--warn)_12%,transparent)]"
                      : ""
                }`}
              >
                {item.label}
                {item.hint && (
                  <span className="ml-auto pl-3 text-caption font-normal text-[var(--text-faint)]">
                    {item.hint}
                  </span>
                )}
              </DropdownMenu.Item>
            </Fragment>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/**
 * 右侧编辑抽屉（手机上是底部抽屉）：复杂对象的新增与编辑放这里，不在列表里展开大表单。
 * 头部标题 + 关闭，中间滚动，页脚常驻（左提示、右动作，提交按钮放最右）。
 */
export function SettingsDrawer({
  open,
  onClose,
  title,
  description,
  hint,
  actions,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  description?: ReactNode;
  /** 页脚左侧 */
  hint?: ReactNode;
  /** 页脚右侧：取消 + 提交 */
  actions?: ReactNode;
  children: ReactNode;
}) {
  return (
    <Modal
      open={open}
      onClose={onClose}
      label={title}
      width="lg"
      placement="right"
      panelClassName="h-full !max-h-full !rounded-none max-md:h-[92dvh] max-md:!rounded-t-3xl"
    >
      <header className="flex shrink-0 items-start justify-between gap-3 border-b border-[var(--line)] px-5 py-4">
        <div className="min-w-0">
          <h2 className="text-body font-semibold text-[var(--text)]">{title}</h2>
          {description && (
            <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">{description}</p>
          )}
        </div>
        <button
          type="button"
          onClick={onClose}
          aria-label="关闭"
          className="flex size-8 shrink-0 items-center justify-center rounded-full text-[var(--text-muted)] hover:bg-white/[0.08] hover:text-[var(--text)]"
        >
          <XIcon className="size-4" />
        </button>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 py-5 scroll-thin">
        {children}
      </div>
      {(hint || actions) && (
        <footer className="flex min-h-[56px] shrink-0 items-center justify-between gap-3 border-t border-[var(--line)] bg-black/20 px-5 py-3">
          <div className="min-w-0 text-caption leading-5 text-[var(--text-faint)]">{hint}</div>
          {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
        </footer>
      )}
    </Modal>
  );
}

/** 改完即存的反馈：「保存中… / ✓ 已保存 / 保存失败」，放在小节标题行或行尾 */
export function SettingsSaveStatus({
  state,
  error,
  savedLabel = "已保存",
}: {
  state: "idle" | "saving" | "saved" | "error";
  error?: string | null;
  savedLabel?: string;
}) {
  if (state === "idle") return null;
  return (
    <span className="shrink-0 text-sub">
      {state === "saving" && <span className="text-[var(--text-faint)]">保存中…</span>}
      {state === "saved" && (
        <span className="flex items-center gap-1 text-[var(--ok)]">
          <CheckIcon className="size-3.5" />
          {savedLabel}
        </span>
      )}
      {state === "error" && (
        <span className="text-[var(--danger)]">保存失败{error ? `：${error}` : ""}</span>
      )}
    </span>
  );
}
