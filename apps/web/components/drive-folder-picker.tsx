"use client";

/**
 * 选网盘上的文件夹挂到媒体库（docs/design/cloud-storage.md §4.1，样稿 mockups/cloud-storage-demo.html）。
 *
 * 与「选择服务器目录」同一种走法：点子目录下钻、面包屑回跳，选当前目录。只列目录、按需展开，
 * 不预先遍历网盘；子目录旁写网盘给的视频数，帮用户判断选哪一层。已挂在别的库上的目录（含上下层）
 * 标出库名、不能选——同一份文件只能在一个库里；本次表单里已经加过的同理。
 */

import { useCallback, useEffect, useRef, useState } from "react";

import { CheckIcon, ChevronRightIcon, FolderIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import { type DriveAccount, type DriveDir, listDriveDirs } from "@/lib/api/drives";

export interface PickedDriveFolder {
  account: DriveAccount;
  id: string;
  path: string;
}

interface Level {
  id: string;
  path: string;
  name: string;
  /** 进到这一层时它挂在哪个库上（从上一层的列表带下来） */
  libraryName: string | null;
  libraryId: number | null;
}

const ROOT: Level = { id: "", path: "", name: "", libraryName: null, libraryId: null };

function overlaps(a: string, b: string): boolean {
  return a === b || a === "" || b === "" || a.startsWith(b + "/") || b.startsWith(a + "/");
}

export function DriveFolderPicker({
  accounts,
  libraryId,
  taken,
  onClose,
  onSelect,
}: {
  accounts: DriveAccount[];
  /** 正在编辑的库（它自己挂着的目录不算被占用）；新建为 null */
  libraryId: number | null;
  /** 本次表单里已经加了的网盘目录 */
  taken: { account_id: number; path: string }[];
  onClose: () => void;
  onSelect: (picked: PickedDriveFolder) => void;
}) {
  const [accountId, setAccountId] = useState(accounts[0]?.id ?? 0);
  const [stack, setStack] = useState<Level[]>([ROOT]);
  const [dirs, setDirs] = useState<DriveDir[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);
  const crumbRef = useRef<HTMLDivElement | null>(null);
  const account = accounts.find((a) => a.id === accountId) ?? accounts[0];
  const current = stack[stack.length - 1];

  const load = useCallback(
    async (level: Level) => {
      setLoading(true);
      setError(null);
      try {
        setDirs(await listDriveDirs(accountId, level.id, level.path));
        listRef.current?.scrollTo({ top: 0 });
      } catch (e) {
        setDirs([]);
        setError((e as Error).message);
      } finally {
        setLoading(false);
      }
    },
    [accountId],
  );

  useEffect(() => {
    void load(current);
  }, [current, load]);

  useEffect(() => {
    const el = crumbRef.current;
    if (el) el.scrollLeft = el.scrollWidth;
  }, [stack]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      // capture 阶段拦截：同一个 Escape 不要把下层的库表单也关掉
      e.stopPropagation();
      onClose();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);

  const usedElsewhere = (libId: number | null) => libId !== null && libId !== libraryId;
  const inForm = (path: string) =>
    taken.some((t) => t.account_id === accountId && overlaps(t.path, path));
  const blocked =
    stack.length === 1
      ? "点进要挂的文件夹再选"
      : usedElsewhere(current.libraryId)
        ? `已在《${current.libraryName}》库里`
        : inForm(current.path)
          ? "与已添加的网盘目录重叠"
          : null;

  return (
    <Modal open onClose={onClose} label="选择网盘上的文件夹" width="lg" raised panelClassName="flex max-h-[76dvh] flex-col">
      <div className="space-y-3 p-5 pb-3">
        <h2 className="text-body-lg font-bold text-white">选择 {account?.backend_title ?? "网盘"} 上的文件夹</h2>
        {accounts.length > 1 && (
          <div className="flex flex-wrap gap-1.5">
            {accounts.map((a) => (
              <button
                key={a.id}
                type="button"
                data-active={a.id === accountId}
                onClick={() => {
                  setAccountId(a.id);
                  setStack([ROOT]);
                }}
                className="rounded-full border border-white/[0.08] px-3 py-1 text-sub text-[var(--text-muted)] transition-colors hover:text-white data-[active=true]:border-[var(--accent)]/50 data-[active=true]:bg-[var(--accent)]/15 data-[active=true]:text-white"
              >
                {a.name}
              </button>
            ))}
          </div>
        )}
        <div
          ref={crumbRef}
          className="scroll-none flex items-center gap-0.5 overflow-x-auto rounded-xl border border-white/[0.08] bg-white/[0.04] px-2 py-1.5"
        >
          {stack.map((level, i) => (
            <span key={`${level.id}:${i}`} className="flex shrink-0 items-center gap-0.5">
              {i > 0 && <ChevronRightIcon className="size-3 shrink-0 text-[var(--text-faint)]" />}
              <button
                type="button"
                onClick={() => setStack(stack.slice(0, i + 1))}
                className={`rounded-md px-1.5 py-0.5 text-ui hover:bg-white/10 hover:text-white ${
                  i === stack.length - 1 ? "font-semibold text-white" : "text-[var(--text-muted)]"
                }`}
              >
                {i === 0 ? (account?.name ?? "网盘") : level.name}
              </button>
            </span>
          ))}
        </div>
        {error && (
          <p className="rounded-lg border border-red-400/25 bg-red-500/10 px-3 py-2 text-sub leading-5 text-red-200">
            {error}
          </p>
        )}
      </div>

      <div ref={listRef} className="min-h-[240px] flex-1 overflow-y-auto px-3 pb-2">
        {loading && dirs === null ? (
          <p className="px-3 py-8 text-center text-ui text-[var(--text-muted)]">加载中…</p>
        ) : dirs !== null && dirs.length === 0 && !error ? (
          <p className="px-3 py-8 text-center text-ui text-[var(--text-muted)]">
            这里没有子目录，可直接选择当前目录
          </p>
        ) : (
          dirs?.map((dir) => {
            const other = usedElsewhere(dir.library_id);
            return (
              <button
                key={dir.id}
                type="button"
                disabled={loading}
                onClick={() =>
                  setStack([
                    ...stack,
                    {
                      id: dir.id,
                      path: dir.path,
                      name: dir.name,
                      libraryId: dir.library_id,
                      libraryName: dir.library_name,
                    },
                  ])
                }
                className="glass-row group flex w-full items-center gap-2.5 px-3 py-2 text-left disabled:opacity-50"
              >
                <FolderIcon className="size-4 shrink-0 text-[var(--accent)]/80" />
                <span className="min-w-0 flex-1 truncate text-ui text-[var(--text)]">{dir.name}</span>
                {other ? (
                  <span className="shrink-0 text-caption text-[var(--text-faint)]">已在《{dir.library_name}》库</span>
                ) : (
                  dir.video_count != null && (
                    <span className="shrink-0 text-caption tabular-nums text-[var(--text-faint)]">
                      {dir.video_count.toLocaleString()} 个视频
                    </span>
                  )
                )}
                <ChevronRightIcon className="size-3.5 shrink-0 text-[var(--text-faint)] opacity-0 transition-opacity group-hover:opacity-100" />
              </button>
            );
          })
        )}
      </div>

      <div className="flex items-center gap-3 border-t border-white/[0.08] bg-white/[0.02] px-5 py-3.5">
        <p className="min-w-0 flex-1 truncate text-sub text-[var(--text-muted)]" title={current.path}>
          {blocked ?? current.path}
        </p>
        <button type="button" onClick={onClose} className="btn-glass h-8 shrink-0 px-3.5 text-ui font-medium">
          取消
        </button>
        <button
          type="button"
          disabled={loading || blocked !== null || !account}
          onClick={() => account && onSelect({ account, id: current.id, path: current.path })}
          className="btn-accent flex h-8 shrink-0 items-center gap-1.5 rounded-full px-4 text-ui font-semibold disabled:opacity-40"
        >
          <CheckIcon className="size-3.5" />
          选择此文件夹
        </button>
      </div>
    </Modal>
  );
}
