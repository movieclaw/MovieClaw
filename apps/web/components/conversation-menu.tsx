"use client";

import { useLocale, useTranslations } from "next-intl";

import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

import { useConfirm, usePrompt, useToast } from "@/components/feedback";
import { BranchIcon, MoreIcon, PencilIcon, TrashIcon } from "@/components/icons";
import { PAGE_NAV_BUTTON_CLASS } from "@/components/page-nav";
import { useAgentConversations } from "@/lib/agent-conversations";

/**
 * 会话菜单三个动作的完整流程（确认 / 输入 / 失败提示），「我的」页与会话页共用一份，
 * 文案同原生 App（MorePage.swift / AgentConversationView.swift）：
 *   - 续接：先确认，再开新会话并跳过去（原会话保留不变）；
 *   - 重命名：输入框初值是当前标题，去空白、截 80 字，没变化不发请求；
 *   - 删除：确认后删除；``onRemoved`` 给会话页用来离开这张已不存在的页。
 */
export function useConversationActions() {
  const t = useTranslations();
  const router = useRouter();
  const { fork, rename, remove } = useAgentConversations();
  const prompt = usePrompt();
  const confirm = useConfirm();
  const toast = useToast();

  const forkConversation = async (id: string, title: string, fromHere = false) => {
    const ok = await confirm({
      title: fromHere ? t("agent.conversation.forkHereTitle") : t("agent.conversation.forkTitle", {name: title}),
      description: t("agent.conversation.forkHint"),
      confirmLabel: t("agent.conversation.forkConfirm"),
    });
    if (!ok) return;
    try {
      const targetId = await fork(id);
      router.push(`/sessions/${targetId}` as Route);
    } catch (error) {
      toast.error(t("agent.conversation.forkFailed", {error: (error as Error).message}));
    }
  };

  const renameConversation = async (id: string, currentTitle: string) => {
    const input = await prompt({ title: t("agent.conversation.renameTitle"), initialValue: currentTitle, maxLength: 80 });
    if (input == null) return;
    const title = input.trim().slice(0, 80);
    if (!title || title === currentTitle) return;
    void rename(id, title).catch((error) => {
      toast.error(t("agent.conversation.renameFailed", {error: (error as Error).message}));
    });
  };

  const removeConversation = async (id: string, title: string, onRemoved?: () => void) => {
    const ok = await confirm({
      title: t("agent.conversation.deleteTitle", {name: title}),
      description: t("agent.conversation.deleteHint"),
      confirmLabel: t("agent.conversation.deleteConfirm"),
      tone: "danger",
    });
    if (!ok) return;
    try {
      await remove(id);
      onRemoved?.();
    } catch (error) {
      toast.error(t("agent.conversation.deleteFailed", {error: (error as Error).message}));
    }
  };

  return { forkConversation, renameConversation, removeConversation };
}

/**
 * 会话的「⋯」操作菜单：在新会话中继续 / 重命名 /（分隔）/ 删除会话。
 *
 * 两处用：「我的」页最近会话的行尾，以及手机会话页顶栏右上角（操作的是当前会话，
 * 续接项写作「从此处创建新会话」）。菜单项、图标与顺序对齐原生 App 的会话菜单
 * （apps/apple/.../AgentConversationView.swift 的 sessionMenu、MorePage.swift 的 sessionActions）：
 * 续接放第一位（聊天记录页最常用），删除用分隔线隔开垫底；「复制会话 ID」随 App 一起去掉
 * （桌面侧栏的 RunRow 另有一份内联菜单，保留复制 ID——桌面上配合 mclaw 命令行用得到）。
 * 续接与删除的确认由调用方负责。
 *
 * 菜单 Portal 到 body：所在卡片有 overflow 裁剪，行内弹层会被切掉。
 * 点击外部、Esc、滚动都关闭。
 */
export function ConversationMenu({
  onFork,
  onRename,
  onDelete,
  forkLabel,
  variant = "row",
  triggerClassName = "",
  iconClassName = "size-5",
}: {
  onFork: () => void;
  onRename: () => void;
  onDelete: () => void;
  /** 续接项的文案：会话页里写「从此处创建新会话」 */
  forkLabel?: string;
  /** row = 列表行尾的小键（默认）；nav = 顶栏圆形玻璃键（会话页右上角，与搜索键同一副） */
  variant?: "row" | "nav";
  /** 触发键的定位/尺寸由所在行决定（默认只给基础皮肤） */
  triggerClassName?: string;
  iconClassName?: string;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const menuWidth = locale === "en" ? 244 : 176;
  // 菜单打开状态即定位坐标（打开瞬间按触发按钮位置计算一次）
  const [menuPos, setMenuPos] = useState<{ left: number; top: number } | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const moreRef = useRef<HTMLButtonElement>(null);
  const open = menuPos != null;

  useEffect(() => {
    if (!open) return;
    const close = () => setMenuPos(null);
    const onPointer = (e: MouseEvent) => {
      const target = e.target as Node;
      if (menuRef.current?.contains(target) || moreRef.current?.contains(target)) return;
      close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    document.addEventListener("mousedown", onPointer);
    document.addEventListener("keydown", onKey);
    // passive：只做关闭动作、不会 preventDefault，别让浏览器为它放弃滚动快路径
    document.addEventListener("scroll", close, { capture: true, passive: true });
    return () => {
      document.removeEventListener("mousedown", onPointer);
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("scroll", close, { capture: true });
    };
  }, [open]);

  const pick = (action: () => void) => {
    setMenuPos(null);
    action();
  };

  return (
    <>
      <button
        ref={moreRef}
        type="button"
        aria-label={t("agent.conversation.actions")}
        aria-expanded={open}
        data-active={open}
        onClick={(e) => {
          e.stopPropagation();
          if (open) {
            setMenuPos(null);
            return;
          }
          const rect = e.currentTarget.getBoundingClientRect();
          // 菜单宽 176px（w-44），右缘与触发键右缘对齐；窄屏上不会越出左边
          setMenuPos({ left: Math.max(8, rect.right - menuWidth), top: rect.bottom + 6 });
        }}
        className={
          variant === "nav"
            ? `${PAGE_NAV_BUTTON_CLASS} ${triggerClassName}`
            : `glass-row touch-target justify-center !rounded-md !p-0 ${triggerClassName}`
        }
      >
        <MoreIcon className={iconClassName} />
      </button>

      {open &&
        createPortal(
          <div
            ref={menuRef}
            className={`menu-surface ${locale === "en" ? "w-[244px] max-w-[calc(100vw-16px)]" : "w-44"} overflow-hidden p-1.5`}
            // z 取菜单档 70：Portal 到 body 后与全站浮层同层比较，须压过 60 档的
            // 全屏面板（撰写面板），否则会被盖住、点 ⋯ 毫无反应
            style={{ position: "fixed", left: menuPos.left, top: menuPos.top, zIndex: 70 }}
          >
            <button
              type="button"
              onClick={() => pick(onFork)}
              className="glass-row px-2.5 py-2 text-ui font-medium max-md:py-2.5"
            >
              <BranchIcon className="size-4 shrink-0 opacity-80 max-md:size-5" />
              <span className="flex-1">{forkLabel ?? t("agent.conversation.fork")}</span>
            </button>
            <button
              type="button"
              onClick={() => pick(onRename)}
              className="glass-row px-2.5 py-2 text-ui font-medium max-md:py-2.5"
            >
              <PencilIcon className="size-4 shrink-0 opacity-80 max-md:size-5" />
              <span className="flex-1">{t("agent.conversation.rename")}</span>
            </button>
            <div role="separator" className="mx-2 my-1 h-px bg-[var(--line)]" />
            <button
              type="button"
              onClick={() => pick(onDelete)}
              className="glass-row px-2.5 py-2 text-ui font-medium !text-[var(--danger)] hover:!bg-[rgba(255,107,107,0.12)] max-md:py-2.5"
            >
              <TrashIcon className="size-4 shrink-0 opacity-80 max-md:size-5" />
              <span className="flex-1">{t("agent.conversation.delete")}</span>
            </button>
          </div>,
          document.body,
        )}
    </>
  );
}
