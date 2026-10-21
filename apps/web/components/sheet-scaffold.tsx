"use client";

/**
 * 表单弹层骨架（银玻璃手机端）——对齐原生 App 的 iOS 26 表单弹层
 * （apps/apple/MovieClaw/DesignSystem/SubscriptionKit.swift 的 SubsSheetScaffold）。
 *
 * 形态约定（与原生 App 逐条对应）：
 * - 头部三段：左 ✕ 关闭、中间标题、右 ✓ 确认（可禁用；忙碌时换成转圈；没有确认
 *   动作就不显示）。确认放右上角而不是底部满宽大按钮——和系统日历、提醒事项一致；
 * - 不自设底色：面板材质沿用 Modal 的贴底抽屉，只在里面排 iOS inset grouped
 *   分组（组标题 + 圆角卡 + 行间细线 + 组下脚注）；
 * - 高度跟内容走：只确认一两项的弹层就只开那么高，内容长了才在正文里滚；
 * - 破坏性动作（取消订阅、清理）不放 ✓：由调用方在末尾单独放一组红色行
 *   （SheetRow destructive），与系统「删除」类操作同一形态。
 *
 * 只在银玻璃主题的手机端使用（useSheetForm 判定）；桌面与 Netflix 主题保持各自
 * 原有的居中弹窗 / 实色卡形态，调用方按判定分支渲染。
 * 骨架包在 Modal 外面（portal、遮罩、Esc、软键盘避让都由 Modal 兜底），
 * 不改 modal.tsx，因此对其他弹窗零影响。
 */

import type { ReactNode } from "react";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import { CheckIcon, ChevronRightIcon, XIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import { useIsMobile } from "@/lib/use-media-query";
import { useLayout } from "@/lib/ui-prefs";

/** 是否走表单弹层形态：panel 版式 + 手机。 */
export function useSheetForm(): boolean {
  const isMobile = useIsMobile();
  const cinema = useLayout() === "cinema";
  return isMobile && !cinema;
}

/** 右上角确认键：界面上是 ✓，label 作读屏名；busy 时换成转圈。 */
export interface SheetConfirm {
  label: string;
  onConfirm: () => void;
  enabled?: boolean;
  busy?: boolean;
}

/** 按钮内的微型转圈（品牌 M 字标塞进 36px 圆键太吵，沿用 border spinner） */
function Spinner({ className = "size-4" }: { className?: string }) {
  return (
    <span
      aria-hidden
      className={`inline-block animate-spin rounded-full border-2 border-current border-t-transparent ${className}`}
    />
  );
}

export function SheetScaffold({
  open = true,
  onClose,
  title,
  label,
  subtitle,
  confirm,
  closeLabel = "关闭",
  raised = false,
  children,
}: {
  open?: boolean;
  onClose: () => void;
  title: string;
  /** 无障碍名称；缺省用 title */
  label?: string;
  /** 标题下的一段说明（不带底色，替代桌面弹窗标题下的副标题） */
  subtitle?: ReactNode;
  /** 右上角确认；不传 = 只有关闭（纯展示，或确认动作在列表行里） */
  confirm?: SheetConfirm;
  /** 关闭键读屏名（界面上显示 ✕） */
  closeLabel?: string;
  /** 叠在另一个弹窗之上时置 true */
  raised?: boolean;
  /** 若干 SheetSection */
  children: ReactNode;
}) {
  const busy = !!confirm?.busy;
  return (
    <Modal open={open} onClose={busy ? () => {} : onClose} label={label ?? title} raised={raised}>
      {/* 自身限高到 88dvh：Modal 手机端面板可以顶满容器，iOS 弹层顶上总留一截
          露出身后页面，看得出这是「浮起的一层」而不是换了页 */}
      <div className="flex max-h-[88dvh] min-h-0 flex-col">
        <div className="grid shrink-0 grid-cols-[2.25rem_1fr_2.25rem] items-center gap-2 px-3 pb-2 pt-3">
          <button
            type="button"
            aria-label={closeLabel}
            disabled={busy}
            onClick={onClose}
            className="btn-glass size-9 !gap-0 p-0 text-white/80"
          >
            <XIcon className="size-4" />
          </button>
          <h2 className="truncate text-center text-ui font-semibold text-white">{title}</h2>
          {confirm ? (
            busy ? (
              <span
                role="status"
                aria-label={confirm.label}
                className="grid size-9 place-items-center text-white/80"
              >
                <Spinner />
              </span>
            ) : (
              <button
                type="button"
                aria-label={confirm.label}
                disabled={confirm.enabled === false}
                onClick={confirm.onConfirm}
                className="btn-accent grid size-9 place-items-center rounded-full disabled:opacity-35"
              >
                <CheckIcon className="size-[18px]" strokeWidth={2.4} />
              </button>
            )
          ) : (
            <span />
          )}
        </div>
        <div className="scroll-thin min-h-0 flex-1 space-y-5 overflow-y-auto overscroll-contain px-4 pb-5 pt-2">
          {subtitle && <div className="px-1 text-sub leading-6 text-white/75">{subtitle}</div>}
          {children}
        </div>
      </div>
    </Modal>
  );
}

/** 一组：组标题 + 圆角卡（行间细线）+ 组下脚注。 */
export function SheetSection({
  title,
  footer,
  children,
}: {
  title?: ReactNode;
  footer?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section>
      {title && (
        <h3 className="mb-1.5 px-4 text-caption font-medium text-[var(--text-muted)]">{title}</h3>
      )}
      <div className="divide-y divide-white/[0.07] overflow-hidden rounded-xl bg-white/[0.06]">
        {children}
      </div>
      {footer && (
        <div className="mt-1.5 space-y-1 px-4 text-caption leading-relaxed text-[var(--text-muted)]">
          {footer}
        </div>
      )}
    </section>
  );
}

const ROW_CLS = "flex min-h-11 w-full items-center gap-3 px-4 py-2.5 text-left text-ui";
const PRESSABLE_CLS = "transition hover:bg-white/[0.04] active:bg-white/[0.08] disabled:opacity-40";

/**
 * 一行：可选图标 + 标题（下方可挂一段说明 children）+ 右侧值 / 箭头。
 * 传 onClick 渲染为按钮；destructive 为红色破坏性行（放在单独一组里垫底）。
 */
export function SheetRow({
  icon,
  label,
  value,
  chevron = false,
  destructive = false,
  onClick,
  disabled,
  trailing,
  children,
}: {
  icon?: ReactNode;
  label: ReactNode;
  value?: ReactNode;
  chevron?: boolean;
  destructive?: boolean;
  onClick?: () => void;
  disabled?: boolean;
  trailing?: ReactNode;
  children?: ReactNode;
}) {
  const body = (
    <>
      {icon && (
        <span
          aria-hidden
          className={`grid size-5 shrink-0 place-items-center ${destructive ? "" : "text-white/70"}`}
        >
          {icon}
        </span>
      )}
      <span className="min-w-0 flex-1">
        <span className="block">{label}</span>
        {children}
      </span>
      {value !== undefined && (
        <span className="max-w-[55%] shrink-0 truncate text-[var(--text-muted)]">{value}</span>
      )}
      {trailing}
      {chevron && <ChevronRightIcon aria-hidden className="size-3.5 shrink-0 text-white/30" />}
    </>
  );
  const tone = destructive ? "text-[#ff8b8b]" : "text-white/90";
  if (!onClick) return <div className={`${ROW_CLS} ${tone}`}>{body}</div>;
  return (
    <button type="button" disabled={disabled} onClick={onClick} className={`${ROW_CLS} ${PRESSABLE_CLS} ${tone}`}>
      {body}
    </button>
  );
}

/** 单选 / 多选行：右侧对勾表示选中（季、规则组）。对应 iOS SubsChoiceRow。 */
export function SheetChoiceRow({
  label,
  detail,
  selected,
  onSelect,
  disabled,
}: {
  label: ReactNode;
  detail?: ReactNode;
  selected: boolean;
  onSelect: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      aria-pressed={selected}
      disabled={disabled}
      onClick={onSelect}
      className={`${ROW_CLS} ${PRESSABLE_CLS} text-white/90`}
    >
      <span className="min-w-0 flex-1">
        <span className="block">{label}</span>
        {detail && <span className="mt-0.5 block text-caption text-[var(--text-muted)]">{detail}</span>}
      </span>
      <CheckIcon
        aria-hidden
        strokeWidth={2.4}
        className={`size-[18px] shrink-0 text-[var(--accent-2)] ${selected ? "" : "opacity-0"}`}
      />
    </button>
  );
}

/**
 * 开关行（自动续订、清理勾选）：整行是一个 switch，标题下可挂说明与警示。
 * danger 让开关打开时染红（清理类开关，对应 iOS SubsCleanupToggle 的 tint）。
 */
export function SheetToggleRow({
  label,
  description,
  warning,
  checked,
  onChange,
  disabled,
  danger = false,
}: {
  label: ReactNode;
  description?: ReactNode;
  warning?: ReactNode;
  checked: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
  danger?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={`${ROW_CLS} text-white/90 disabled:opacity-45`}
    >
      <span className="min-w-0 flex-1">
        <span className="block leading-6">{label}</span>
        {description && (
          <span className="block text-caption leading-5 text-[var(--text-muted)]">{description}</span>
        )}
        {warning && <span className="mt-0.5 block text-caption leading-5 text-[var(--danger)]">{warning}</span>}
      </span>
      <span
        aria-hidden
        className={`relative h-[26px] w-[44px] shrink-0 rounded-full transition-colors ${
          checked ? (danger ? "bg-[var(--danger)]" : "bg-[var(--ok,#5fd39b)]") : "bg-white/20"
        }`}
      >
        <span
          className={`absolute left-[3px] top-[3px] size-5 rounded-full bg-white shadow transition-transform ${
            checked ? "translate-x-[18px]" : ""
          }`}
        />
      </span>
    </button>
  );
}

/** 菜单行的一个选项 */
export interface SheetMenuOption {
  value: string;
  label: string;
}

const MENU_ITEM_CLS =
  "flex cursor-pointer items-center gap-2 rounded-lg px-3 py-2 text-ui text-white/90 outline-none " +
  "data-[highlighted]:bg-white/[0.08] data-[disabled]:pointer-events-none data-[disabled]:opacity-40";

/**
 * 菜单行（规则组、入库库）：对应 iOS 的 `Picker(.menu)` / `Menu` 行——行右侧写当前值
 * 与上下箭头，点开是就地弹出的单选菜单；extra 放菜单末尾的低频动作（如「新建规则组…」），
 * children 挂在行内当前值下方（如规则组的品质摘要——行底比脚注实，字看得清）。
 */
export function SheetMenuRow({
  label,
  value,
  options,
  onChange,
  extra,
  children,
}: {
  label: string;
  value: string;
  options: SheetMenuOption[];
  onChange: (value: string) => void;
  extra?: ReactNode;
  children?: ReactNode;
}) {
  const current = options.find((o) => o.value === value);
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button type="button" className={`${ROW_CLS} ${PRESSABLE_CLS} flex-col !items-stretch !gap-1 text-white/90`}>
          <span className="flex items-center gap-2">
            <span className="shrink-0">{label}</span>
            <span className="min-w-0 flex-1 truncate text-right text-[var(--text-muted)]">
              {current?.label ?? "未选择"}
            </span>
            {/* 上下箭头：原生菜单行的「可展开选择」记号 */}
            <svg
              aria-hidden
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth={2}
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-3.5 shrink-0 text-[var(--text-muted)]"
            >
              <path d="m8 9 4-4 4 4M8 15l4 4 4-4" />
            </svg>
          </span>
          {children}
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        {/* z-[70]：压过底下的弹层（普通 z-50 / raised z-60） */}
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          collisionPadding={12}
          className="menu-surface z-[70] max-h-[min(60dvh,var(--radix-dropdown-menu-content-available-height))] min-w-[12rem] max-w-[calc(100vw-24px)] overflow-y-auto p-1"
        >
          <DropdownMenu.RadioGroup value={value} onValueChange={onChange}>
            {options.map((o) => (
              <DropdownMenu.RadioItem key={o.value} value={o.value} className={MENU_ITEM_CLS}>
                <span className="grid size-4 shrink-0 place-items-center">
                  <DropdownMenu.ItemIndicator>
                    <CheckIcon className="size-4" strokeWidth={2.4} />
                  </DropdownMenu.ItemIndicator>
                </span>
                <span className="min-w-0 flex-1">{o.label}</span>
              </DropdownMenu.RadioItem>
            ))}
          </DropdownMenu.RadioGroup>
          {extra && (
            <>
              <DropdownMenu.Separator className="my-1 h-px bg-white/[0.07]" />
              {extra}
            </>
          )}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** 菜单末尾的动作项（与 SheetMenuRow 的 extra 搭配） */
export function SheetMenuAction({
  icon,
  label,
  onSelect,
}: {
  icon?: ReactNode;
  label: string;
  onSelect: () => void;
}) {
  return (
    <DropdownMenu.Item onSelect={onSelect} className={MENU_ITEM_CLS}>
      <span aria-hidden className="grid size-4 shrink-0 place-items-center">
        {icon}
      </span>
      <span className="min-w-0 flex-1">{label}</span>
    </DropdownMenu.Item>
  );
}

/** 提示行（错误 / 警示 / 说明）：单独成组的一行文字。对应 iOS SubsNoticeRow。 */
export function SheetNotice({
  tone = "info",
  children,
}: {
  tone?: "error" | "warn" | "info";
  children: ReactNode;
}) {
  const color =
    tone === "error" ? "text-red-200" : tone === "warn" ? "text-amber-200" : "text-white/85";
  return (
    <SheetSection>
      <div role={tone === "error" ? "alert" : undefined} className={`px-4 py-3 text-sub leading-6 ${color}`}>
        {children}
      </div>
    </SheetSection>
  );
}
