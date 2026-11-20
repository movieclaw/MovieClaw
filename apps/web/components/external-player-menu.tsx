"use client";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { useTranslations } from "next-intl";
import { usePathname } from "next/navigation";
import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";

import { copyText } from "@/components/copy-button";
import { useToast } from "@/components/feedback";
import {
  CheckIcon,
  ChevronDownIcon,
  CopyIcon,
  MoreIcon,
  OpenIcon,
  XIcon,
} from "@/components/icons";
import { Modal } from "@/components/modal";
import { Tooltip } from "@/components/tooltip";
import {
  createExternalLink,
  type PlaybackExternalLink,
  type PlaybackExternalLinkRequest,
} from "@/lib/api/playback";
import {
  buildLaunchUrl,
  canLaunchDirectly,
  currentPlatform,
  EXTERNAL_PLAYER_KEY,
  loadDefaultPlayer,
  playersFor,
  safeHttpUrl,
  saveDefaultPlayer,
  subtitleLabel,
  type ExternalPlayerId,
  type ExternalPlayerSpec,
} from "@/lib/external-player";
import { formatClock } from "@/lib/player/timeline";
import { useIsMobile } from "@/lib/use-media-query";

export type ExternalPlayerAction =
  | { kind: "player"; id: ExternalPlayerId }
  | { kind: "copy" };

export type ExternalPlayerPanelMode = "launched" | "tapToOpen" | "manualCopy";

export interface ExternalPlayerPanelState {
  link: PlaybackExternalLink;
  playerId: ExternalPlayerId | null;
  launchUrl: string | null;
  mode: ExternalPlayerPanelMode;
}

const MENU_ITEM_CLASS =
  "glass-row nav-item cursor-pointer px-3 py-2 text-ui font-medium outline-none " +
  "data-[highlighted]:!bg-[var(--glass-fill-hover)] data-[highlighted]:!text-[var(--text)] " +
  "data-[disabled]:pointer-events-none data-[disabled]:opacity-40";

/** 与 PlayAction 旁的圆键（MARK_BUTTON_CLASS）保持同一玻璃语汇与主题钩子 */
const CIRCLE_BUTTON_CLASS =
  "page-nav-btn inline-flex h-12 shrink-0 items-center justify-center gap-2 rounded-full " +
  "border border-white/[0.12] bg-white/[0.08] text-white/85 backdrop-blur-md transition " +
  "duration-200 hover:bg-white/[0.14] hover:text-white active:scale-[0.96] " +
  "disabled:pointer-events-none disabled:opacity-60 " +
  "data-[state=open]:bg-white/[0.16] data-[state=open]:text-white " +
  "md:size-12 max-md:h-11 max-md:px-4";

const SPLIT_SHELL_CLASS =
  "page-nav-btn inline-flex h-12 shrink-0 items-center overflow-hidden rounded-full " +
  "border border-white/[0.12] bg-white/[0.08] text-white/85 backdrop-blur-md max-md:h-11";

/** 分享路径（/s/...）绝不渲染外部播放器入口，也不触碰 FeedbackProvider */
function isSharePath(pathname: string | null): boolean {
  return pathname === "/s" || Boolean(pathname?.startsWith("/s/"));
}

/** 通过临时隐藏 <a> 触发外部协议：不留空白标签页，也不受 iframe 协议拦截 */
function launchExternalUrl(url: string): void {
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.rel = "noreferrer";
  anchor.style.display = "none";
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
}

function getUserActivation(): { isActive: boolean } | undefined {
  if (typeof navigator === "undefined") return undefined;
  return (navigator as Navigator & { userActivation?: { isActive: boolean } }).userActivation;
}

export interface UseExternalPlayerResult {
  ready: boolean;
  players: ExternalPlayerSpec[];
  defaultPlayer: ExternalPlayerId | null;
  busy: boolean;
  run: (request: PlaybackExternalLinkRequest, action: ExternalPlayerAction) => Promise<void>;
  panelNode: ReactNode;
}

const DEFAULT_PLAYER_CHANGED_EVENT = "movieclaw:external-player-default-changed";

/**
 * 外部播放器拉起与降级状态管理。
 *
 * - 绝不预取 token：只在用户显式点击时现调 createExternalLink；
 * - 绝不持久化 token：只把播放器 id 记入 localStorage，链接仅存于 panel state，关闭即丢弃；
 * - 服务端 409/404/403 文案已按 Accept-Language 本地化，直接经 toast 提示。
 */
export function useExternalPlayer(): UseExternalPlayerResult {
  const t = useTranslations();
  const toast = useToast();
  const pathname = usePathname();
  const sharePath = isSharePath(pathname);

  const platform = useMemo(() => currentPlatform(), []);
  const players = useMemo(() => playersFor(platform), [platform]);

  const [ready, setReady] = useState(false);
  const [defaultPlayer, setDefaultPlayer] = useState<ExternalPlayerId | null>(null);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [panel, setPanel] = useState<ExternalPlayerPanelState | null>(null);

  useEffect(() => {
    if (sharePath) {
      setReady(false);
      return;
    }
    const syncDefaultPlayer = () => {
      setDefaultPlayer(loadDefaultPlayer(platform));
    };
    const handleStorage = (event: StorageEvent) => {
      if (event.key !== null && event.key !== EXTERNAL_PLAYER_KEY) return;
      syncDefaultPlayer();
    };
    syncDefaultPlayer();
    setReady(true);
    window.addEventListener(DEFAULT_PLAYER_CHANGED_EVENT, syncDefaultPlayer);
    window.addEventListener("storage", handleStorage);
    return () => {
      window.removeEventListener(DEFAULT_PLAYER_CHANGED_EVENT, syncDefaultPlayer);
      window.removeEventListener("storage", handleStorage);
    };
  }, [platform, sharePath]);

  const run = useCallback(
    async (request: PlaybackExternalLinkRequest, action: ExternalPlayerAction) => {
      if (sharePath || busyRef.current) return;
      busyRef.current = true;
      setBusy(true);
      const t0 = performance.now();

      try {
        let link: PlaybackExternalLink;
        try {
          link = await createExternalLink(request);
        } catch (error) {
          toast.error(
            error instanceof Error && error.message
              ? error.message
              : t("library.externalPlayer.failed"),
          );
          return;
        }

        if (!safeHttpUrl(link.stream_url)) {
          toast.error(t("library.externalPlayer.invalidLink"));
          return;
        }

        if (action.kind === "player") {
          const url = buildLaunchUrl(platform, action.id, link);
          if (!url) {
            toast.error(t("library.externalPlayer.invalidLink"));
            return;
          }
          saveDefaultPlayer(action.id);
          setDefaultPlayer(action.id);
          if (typeof window !== "undefined") {
            window.dispatchEvent(new Event(DEFAULT_PLAYER_CHANGED_EVENT));
          }

          if (canLaunchDirectly(getUserActivation(), performance.now() - t0)) {
            launchExternalUrl(url);
            setPanel({
              link,
              playerId: action.id,
              launchUrl: url,
              mode: "launched",
            });
          } else {
            setPanel({
              link,
              playerId: action.id,
              launchUrl: url,
              mode: "tapToOpen",
            });
          }
          return;
        }

        try {
          await copyText(link.stream_url);
          toast.success(t("library.externalPlayer.copied"));
        } catch {
          setPanel({
            link,
            playerId: null,
            launchUrl: null,
            mode: "manualCopy",
          });
        }
      } finally {
        busyRef.current = false;
        setBusy(false);
      }
    },
    [platform, sharePath, t, toast],
  );

  const activePlayer = panel?.playerId
    ? (players.find((spec) => spec.id === panel.playerId) ?? null)
    : null;

  const panelNode = panel ? (
    <ExternalPlayerPanel
      state={panel}
      player={activePlayer}
      onClose={() => setPanel(null)}
    />
  ) : null;

  return { ready, players, defaultPlayer, busy, run, panelNode };
}

function ExternalPlayerMenuItems({
  players,
  defaultPlayer,
  busy,
  onSelect,
}: {
  players: ExternalPlayerSpec[];
  defaultPlayer: ExternalPlayerId | null;
  busy: boolean;
  onSelect: (action: ExternalPlayerAction) => void;
}) {
  const t = useTranslations();

  return (
    <>
      {players.map((spec) => {
        const isDefault = defaultPlayer === spec.id;
        return (
          <DropdownMenu.Item
            key={spec.id}
            disabled={busy}
            onSelect={() => onSelect({ kind: "player", id: spec.id })}
            className={MENU_ITEM_CLASS}
          >
            <span className="flex min-w-0 flex-1 flex-col">
              <span>{t("library.externalPlayer.openWith", { player: spec.name })}</span>
              {spec.needsHandler && (
                <span className="text-caption font-normal text-[var(--text-faint)]">
                  {t("library.externalPlayer.needsHandler")}
                </span>
              )}
            </span>
            {isDefault && <CheckIcon className="size-4 shrink-0 text-white/85" />}
          </DropdownMenu.Item>
        );
      })}
      {players.length > 0 && <DropdownMenu.Separator className="my-1 h-px bg-white/[0.07]" />}
      <DropdownMenu.Item
        disabled={busy}
        onSelect={() => onSelect({ kind: "copy" })}
        className={MENU_ITEM_CLASS}
      >
        <CopyIcon className="size-4 shrink-0 opacity-75" />
        <span>{t("library.externalPlayer.copyLink")}</span>
      </DropdownMenu.Item>
    </>
  );
}

/** 详情页主播放键旁的外部播放器入口：有本机默认时为「快捷默认 + 下拉」胶囊，否则为 48px 圆键 */
export function ExternalPlayerSplitButton({
  request,
}: {
  request: PlaybackExternalLinkRequest;
}) {
  const pathname = usePathname();
  if (isSharePath(pathname)) return null;
  return <ExternalPlayerSplitButtonInner request={request} />;
}

function ExternalPlayerSplitButtonInner({
  request,
}: {
  request: PlaybackExternalLinkRequest;
}) {
  const t = useTranslations();
  const isMobile = useIsMobile();
  const { ready, players, defaultPlayer, busy, run, panelNode } = useExternalPlayer();

  if (!ready) return null;

  const defaultSpec = defaultPlayer
    ? (players.find((spec) => spec.id === defaultPlayer) ?? null)
    : null;

  const handleSelect = (action: ExternalPlayerAction) => {
    void run(request, action);
  };

  if (defaultSpec) {
    return (
      <>
        <div className={SPLIT_SHELL_CLASS}>
          <button
            type="button"
            disabled={busy}
            aria-busy={busy || undefined}
            onClick={() => void run(request, { kind: "player", id: defaultSpec.id })}
            className="inline-flex h-full items-center gap-2 pl-4 pr-3 text-ui font-medium text-white/90 transition hover:bg-white/[0.1] hover:text-white active:scale-[0.98] disabled:pointer-events-none disabled:opacity-60"
          >
            <OpenIcon className="size-4 shrink-0" />
            <span>{t("library.externalPlayer.openWith", { player: defaultSpec.name })}</span>
          </button>
          <span aria-hidden="true" className="h-5 w-px shrink-0 bg-white/[0.14]" />
          <DropdownMenu.Root>
            <DropdownMenu.Trigger asChild>
              <button
                type="button"
                disabled={busy}
                aria-busy={busy || undefined}
                aria-label={t("library.externalPlayer.choose")}
                className="inline-flex h-full items-center justify-center px-3 text-white/80 transition hover:bg-white/[0.1] hover:text-white disabled:pointer-events-none disabled:opacity-60 data-[state=open]:bg-white/[0.14] data-[state=open]:text-white"
              >
                <ChevronDownIcon className="size-4" />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content
                align="start"
                sideOffset={6}
                collisionPadding={12}
                className="menu-surface z-50 min-w-[13rem] p-1"
              >
                <ExternalPlayerMenuItems
                  players={players}
                  defaultPlayer={defaultPlayer}
                  busy={busy}
                  onSelect={handleSelect}
                />
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        </div>
        {panelNode}
      </>
    );
  }

  return (
    <>
      <DropdownMenu.Root>
        <Tooltip
          content={t("library.externalPlayer.choose")}
          dismissOnReferencePress
          disabled={isMobile}
        >
          <DropdownMenu.Trigger asChild>
            <button
              type="button"
              disabled={busy}
              aria-busy={busy || undefined}
              aria-label={t("library.externalPlayer.choose")}
              className={CIRCLE_BUTTON_CLASS}
            >
              <OpenIcon className="size-5" />
              <span className="text-ui font-medium md:hidden">
                {t("library.externalPlayer.choose")}
              </span>
            </button>
          </DropdownMenu.Trigger>
        </Tooltip>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="start"
            sideOffset={6}
            collisionPadding={12}
            className="menu-surface z-50 min-w-[13rem] p-1"
          >
            <ExternalPlayerMenuItems
              players={players}
              defaultPlayer={defaultPlayer}
              busy={busy}
              onSelect={handleSelect}
            />
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
      {panelNode}
    </>
  );
}

/** 分集横滚卡上的紧凑 ⋯ 外部播放器菜单；坐标落在 16:9 剧照右下角，避开标题行与进度条 */
export function ExternalPlayerEpisodeMenu({
  request,
  episodeNumber,
}: {
  request: PlaybackExternalLinkRequest;
  episodeNumber: number;
}) {
  const pathname = usePathname();
  if (isSharePath(pathname)) return null;
  return <ExternalPlayerEpisodeMenuInner request={request} episodeNumber={episodeNumber} />;
}

function ExternalPlayerEpisodeMenuInner({
  request,
  episodeNumber,
}: {
  request: PlaybackExternalLinkRequest;
  episodeNumber: number;
}) {
  const t = useTranslations();
  const { ready, players, defaultPlayer, busy, run, panelNode } = useExternalPlayer();

  if (!ready) return null;

  return (
    <>
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button
            type="button"
            disabled={busy}
            aria-busy={busy || undefined}
            aria-label={t("library.externalPlayer.episodeMenu", { episode: episodeNumber })}
            onClick={(event) => event.stopPropagation()}
            className="touch-reveal absolute right-1.5 top-[76px] z-10 flex size-7 items-center justify-center rounded-full bg-black/60 text-white opacity-0 transition-opacity hover:bg-black/80 group-hover/episode:opacity-100 focus-visible:opacity-100 data-[state=open]:opacity-100 disabled:pointer-events-none disabled:opacity-50"
          >
            <MoreIcon className="size-4" />
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="start"
            sideOffset={6}
            collisionPadding={12}
            className="menu-surface z-50 min-w-[13rem] p-1"
          >
            <ExternalPlayerMenuItems
              players={players}
              defaultPlayer={defaultPlayer}
              busy={busy}
              onSelect={(action) => void run(request, action)}
            />
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
      {panelNode}
    </>
  );
}

function ExternalPlayerPanel({
  state,
  player,
  onClose,
}: {
  state: ExternalPlayerPanelState;
  player: ExternalPlayerSpec | null;
  onClose: () => void;
}) {
  const t = useTranslations();
  const toast = useToast();
  const streamInputId = useId();
  const streamInputRef = useRef<HTMLInputElement>(null);
  const manualSubInputRef = useRef<HTMLInputElement>(null);

  const [streamCopied, setStreamCopied] = useState(false);
  const [showManualHint, setShowManualHint] = useState(state.mode === "manualCopy");
  const [copiedSubtitleKey, setCopiedSubtitleKey] = useState<string | null>(null);
  const [manualSubtitleKey, setManualSubtitleKey] = useState<string | null>(null);

  const { link, launchUrl, mode } = state;
  const validSubtitles = useMemo(
    () => link.subtitles.filter((sub) => safeHttpUrl(sub.url) !== null),
    [link.subtitles],
  );

  useEffect(() => {
    if (mode !== "manualCopy") return;
    setShowManualHint(true);
    const selectInput = () => {
      const input = streamInputRef.current;
      if (!input) return;
      input.focus();
      input.select();
      input.setSelectionRange(0, input.value.length);
    };
    selectInput();
    const frame = window.requestAnimationFrame(selectInput);
    return () => window.cancelAnimationFrame(frame);
  }, [mode, link.stream_url]);

  useEffect(() => {
    if (!streamCopied) return;
    const timer = window.setTimeout(() => setStreamCopied(false), 1600);
    return () => window.clearTimeout(timer);
  }, [streamCopied]);

  useEffect(() => {
    if (!copiedSubtitleKey) return;
    const timer = window.setTimeout(() => setCopiedSubtitleKey(null), 1600);
    return () => window.clearTimeout(timer);
  }, [copiedSubtitleKey]);

  useEffect(() => {
    if (!manualSubtitleKey) return;
    const input = manualSubInputRef.current;
    if (!input) return;
    input.focus();
    input.select();
    input.setSelectionRange(0, input.value.length);
  }, [manualSubtitleKey]);

  const title =
    mode !== "manualCopy" && player
      ? t("library.externalPlayer.panelTitle", { player: player.name, title: link.title })
      : t("library.externalPlayer.copyTitle", { title: link.title });

  const handleCopyStream = () => {
    void copyText(link.stream_url)
      .then(() => {
        setStreamCopied(true);
        toast.success(t("library.externalPlayer.copied"));
      })
      .catch(() => {
        setShowManualHint(true);
        const input = streamInputRef.current;
        if (input) {
          input.focus();
          input.select();
          input.setSelectionRange(0, input.value.length);
        }
        toast.info(t("library.externalPlayer.manualCopyHint"));
      });
  };

  const handleCopySubtitle = (key: string, url: string) => {
    void copyText(url)
      .then(() => {
        setCopiedSubtitleKey(key);
        setManualSubtitleKey((current) => (current === key ? null : current));
        toast.success(t("library.externalPlayer.copied"));
      })
      .catch(() => {
        setManualSubtitleKey(key);
        toast.info(t("library.externalPlayer.manualCopyHint"));
      });
  };

  return (
    <Modal open onClose={onClose} label={title} width="md">
      <div className="flex items-start justify-between gap-3 border-b border-white/[0.07] px-6 py-5 max-md:px-5">
        <h2 className="min-w-0 text-title-sm font-semibold leading-snug text-[var(--text)]">
          {title}
        </h2>
        <button
          type="button"
          onClick={onClose}
          aria-label={t("common.close")}
          className="inline-flex size-8 shrink-0 items-center justify-center rounded-full text-[var(--text-muted)] transition hover:bg-white/[0.08] hover:text-[var(--text)]"
        >
          <XIcon className="size-4" />
        </button>
      </div>

      <div className="scroll-thin min-h-0 flex-1 space-y-5 overflow-y-auto px-6 py-5 max-md:px-5">
        {mode === "launched" && player && (
          <div className="space-y-3">
            <p className="text-sub leading-6 text-[var(--text-muted)]">
              {t("library.externalPlayer.launched", { player: player.name })}
            </p>
            {launchUrl && (
              <div>
                <a
                  href={launchUrl}
                  rel="noreferrer"
                  className="btn-glass px-4 py-2 text-ui font-medium text-[var(--text)]"
                >
                  <OpenIcon className="size-4" />
                  <span>{t("library.externalPlayer.retry")}</span>
                </a>
              </div>
            )}
          </div>
        )}

        {mode === "tapToOpen" && player && (
          <div className="space-y-3">
            <p className="text-sub leading-6 text-[var(--text-muted)]">
              {t("library.externalPlayer.tapToOpen", { player: player.name })}
            </p>
            {launchUrl && (
              <a
                href={launchUrl}
                rel="noreferrer"
                className="media-cta inline-flex h-11 w-full items-center justify-center gap-2 rounded-full bg-white px-6 text-ui font-semibold text-black shadow-[0_10px_30px_rgba(0,0,0,0.3)] transition duration-200 hover:bg-white/90 active:scale-[0.985]"
              >
                <OpenIcon className="size-4" />
                <span>{t("library.externalPlayer.openButton", { player: player.name })}</span>
              </a>
            )}
          </div>
        )}

        {mode === "manualCopy" && (
          <p className="text-sub leading-6 text-[var(--text-muted)]">
            {t("library.externalPlayer.copyFailed")}
          </p>
        )}

        <div className="space-y-2">
          <label
            htmlFor={streamInputId}
            className="block text-sub font-medium text-[var(--text-muted)]"
          >
            {t("library.externalPlayer.streamLink")}
          </label>
          <div className="flex items-center gap-2">
            <input
              ref={streamInputRef}
              id={streamInputId}
              type="text"
              readOnly
              value={link.stream_url}
              aria-label={t("library.externalPlayer.streamLink")}
              onFocus={(event) => event.currentTarget.select()}
              spellCheck={false}
              className="min-w-0 flex-1 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2 font-mono text-sub text-[var(--text)] outline-none transition focus:border-white/25"
            />
            <button
              type="button"
              onClick={handleCopyStream}
              className="btn-glass shrink-0 px-3.5 py-2 text-sub font-medium text-[var(--text)]"
            >
              {streamCopied ? (
                <CheckIcon className="size-3.5 text-[var(--ok)]" />
              ) : (
                <CopyIcon className="size-3.5" />
              )}
              <span>{streamCopied ? t("common.copied") : t("common.copy")}</span>
            </button>
          </div>
          {showManualHint && (
            <p className="text-caption text-[var(--text-muted)]">
              {t("library.externalPlayer.manualCopyHint")}
            </p>
          )}
        </div>

        {validSubtitles.length > 0 && (
          <div className="space-y-2.5">
            <p className="text-sub font-medium text-[var(--text-muted)]">
              {t("library.externalPlayer.subtitles")}
            </p>
            {player && !player.subtitleParam && (
              <p className="text-caption leading-5 text-[var(--text-muted)]">
                {t("library.externalPlayer.noSubtitleParam", { player: player.name })}
              </p>
            )}
            <div className="space-y-2">
              {validSubtitles.map((sub, index) => {
                const subKey = `${sub.track}-${index}`;
                const subCopied = copiedSubtitleKey === subKey;
                const subManual = manualSubtitleKey === subKey;
                return (
                  <div
                    key={subKey}
                    className="space-y-2 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3.5 py-2.5"
                  >
                    <div className="flex items-center justify-between gap-3">
                      <span className="min-w-0 truncate text-sub text-[var(--text)]">
                        {`${subtitleLabel(sub)} · ${sub.format.toUpperCase()}`}
                      </span>
                      <button
                        type="button"
                        onClick={() => handleCopySubtitle(subKey, sub.url)}
                        className="inline-flex shrink-0 items-center gap-1.5 rounded-lg px-2.5 py-1 text-sub text-[var(--text-muted)] transition-colors hover:bg-white/[0.08] hover:text-[var(--text)]"
                      >
                        {subCopied ? (
                          <CheckIcon className="size-3.5 text-[var(--ok)]" />
                        ) : (
                          <CopyIcon className="size-3.5" />
                        )}
                        <span>{t("library.externalPlayer.copySubtitle")}</span>
                      </button>
                    </div>
                    {subManual && (
                      <div className="space-y-1">
                        <input
                          ref={manualSubInputRef}
                          type="text"
                          readOnly
                          value={sub.url}
                          aria-label={t("library.externalPlayer.copySubtitle")}
                          onFocus={(event) => event.currentTarget.select()}
                          spellCheck={false}
                          className="w-full rounded-lg border border-white/[0.08] bg-white/[0.04] px-2.5 py-1.5 font-mono text-caption text-[var(--text)] outline-none focus:border-white/25"
                        />
                        <p className="text-caption text-[var(--text-muted)]">
                          {t("library.externalPlayer.manualCopyHint")}
                        </p>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {link.start_ms > 0 && player && !player.startParam && (
          <p className="rounded-xl border border-white/[0.08] bg-white/[0.04] px-3.5 py-2.5 text-caption leading-5 text-[var(--text-muted)]">
            {t("library.externalPlayer.noStartParam", {
              time: formatClock(link.start_ms),
              player: player.name,
            })}
          </p>
        )}

        <div className="space-y-1.5 border-t border-white/[0.07] pt-4 text-caption leading-5 text-[var(--text-faint)]">
          <p>{t("library.externalPlayer.expiry")}</p>
          <p>{t("library.externalPlayer.noProgress")}</p>
          {player?.jellyfinHint && (
            <p className="text-[var(--text-muted)]">
              {t("library.externalPlayer.jellyfinHint")}
            </p>
          )}
        </div>
      </div>

      <div className="flex justify-end border-t border-white/[0.07] px-6 py-4 max-md:px-5">
        <button
          type="button"
          onClick={onClose}
          className="btn-glass px-4 py-2 text-ui text-[var(--text-muted)]"
        >
          {t("common.close")}
        </button>
      </div>
    </Modal>
  );
}
