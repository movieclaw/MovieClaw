"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";

import { Banner, ErrorBanner, LINK_CLASS, StatusPill } from "@/components/cloud-push-ui";
import { ChevronRightIcon } from "@/components/icons";
import { PluginPackagesSection } from "@/components/plugin-packages-section";
import {
  SETTINGS_BUTTON_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  exitSafeMode,
  listPlugins,
  type PluginInfo,
  type PluginsOverview,
} from "@/lib/api/plugins";
import { TONE_COLOR } from "@/lib/cloud-push-display";
import {
  displayState,
  formatMs,
  groupBuiltins,
  isLocalPlugin,
  needsAttention,
  officialPlugins,
  officialSourceText,
  pluginDetail,
  pluginLogsHref,
  pluginStateLabel,
  pluginStateTone,
  pluginsSummary,
  slowestStarts,
  systemModules,
  systemModulesLine,
} from "@/lib/plugins-display";

/**
 * 设置 → 插件（系统组）：只放真正的插件（docs/design/plugin-page-tiers.md）。不为了插件而插件：
 * 自动入库、AI 字幕这些是 MovieClaw 本身的能力，归系统模块，不在这里展示也不在这里开关。
 *
 *   - 官方插件：随应用提供、可用插件包替换的（现在是 IM 通道）；
 *   - 第三方插件 / 本地插件：插件包的上传、批准、回滚、卸载（PluginPackagesSection）；
 *   - 系统模块：应用运行所需，平时只在页面底部留一行入口；出问题时浮到页面顶部。
 *
 * 深链：?module=<条目 id> 定位到那一行（系统模块会先展开）；旧链接 ?tab=builtin 展开系统模块。
 * 安全模式影响整页（本地 / 第三方插件都被跳过），横幅放在最上面。
 */
export function PluginsPage() {
  const [overview, setOverview] = useState<PluginsOverview | null>(null);
  const [exiting, setExiting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showSystem, setShowSystem] = useState(false);
  /** ?module= 要定位的条目：列表到了之后处理一次 */
  const targetRef = useRef<string | null>(null);

  const reload = useCallback(() => {
    listPlugins()
      .then((value) => {
        setOverview(value);
        setError(null);
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "加载失败"));
  }, []);
  useEffect(() => {
    reload();
  }, [reload]);

  // 地址栏只在挂载时读一次（SSR 阶段没有 window，同 useTabParam）
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get("tab") === "builtin") setShowSystem(true);
    targetRef.current = params.get("module");
  }, []);

  const plugins = overview?.plugins ?? null;

  // 定位到 ?module= 指的那一行：它是系统模块就先展开清单，渲染后滚过去并高亮一下。
  // 只处理一次；定时器不随重渲染取消（展开清单本身就会触发一次重渲染）
  useEffect(() => {
    const target = targetRef.current;
    if (!target || plugins === null) return;
    targetRef.current = null;
    if (systemModules(plugins).some((p) => p.id === target)) setShowSystem(true);
    window.setTimeout(() => {
      const row = document.querySelector<HTMLElement>(
        `[data-plugin-ids~="${CSS.escape(target)}"]`,
      );
      if (!row) return;
      row.scrollIntoView({ block: "center", behavior: "smooth" });
      row.dataset.highlight = "true";
      window.setTimeout(() => delete row.dataset.highlight, 2400);
    }, 80);
  }, [plugins]);

  const leaveSafeMode = useCallback(() => {
    setExiting(true);
    exitSafeMode()
      .then(() => reload())
      .catch((err: unknown) => setError(err instanceof Error ? err.message : "退出失败"))
      .finally(() => setExiting(false));
  }, [reload]);

  const safeMode = overview?.safe_mode;
  const system = plugins ? systemModules(plugins) : [];
  const systemProblems = system.filter(needsAttention);

  return (
    <div className="space-y-10">
      {error && <ErrorBanner>{error}</ErrorBanner>}
      {safeMode?.active && (
        <Banner
          tone="warn"
          title="插件安全模式：本次没有加载本地 / 第三方插件"
          action={
            safeMode.forced === "env" ? undefined : (
              <button
                type="button"
                disabled={exiting}
                onClick={leaveSafeMode}
                className="btn-accent inline-flex rounded-full px-4 py-1.5 text-sub font-semibold disabled:opacity-60"
              >
                {exiting ? "正在加载…" : "退出安全模式"}
              </button>
            )
          }
        >
          {safeMode.reason}。跳过的插件：{safeMode.skipped.join("、") || "无"}。
          {safeMode.forced === "env"
            ? "去掉环境变量 MOVIECLAW_SAFE_MODE 并重启即可退出。"
            : "排查后退出，被跳过的插件会当场重新加载；它若再把应用拖垮，下次启动会自动回到安全模式。"}
        </Banner>
      )}
      {systemProblems.length > 0 && <SystemProblems plugins={systemProblems} />}

      {plugins === null ? (
        !error && <p className="px-1 text-sub text-[var(--text-muted)]">正在加载…</p>
      ) : (
        <>
          <OfficialSection plugins={officialPlugins(plugins)} />
        </>
      )}
      <PluginPackagesSection locals={plugins?.filter(isLocalPlugin) ?? []} onChanged={reload} />
      {plugins !== null && system.length > 0 && (
        <SystemModules
          plugins={system}
          groups={overview?.groups ?? []}
          open={showSystem}
          onToggle={() => setShowSystem((v) => !v)}
        />
      )}
    </div>
  );
}

/** 页面顶部：没有正常运行的系统模块（平时看不到它们，出问题才浮出来） */
function SystemProblems({ plugins }: { plugins: PluginInfo[] }) {
  return (
    <Banner tone="warn" title={`有 ${plugins.length} 个系统模块没有正常运行`}>
      <ul className="mt-1 space-y-1.5">
        {plugins.map((p) => (
          <li key={p.id} className="text-sub leading-5">
            <span className="font-medium text-[var(--text)]">{p.title}</span>
            <span className="text-[var(--text-muted)]">：{pluginDetail(p)}</span>{" "}
            <Link href={pluginLogsHref(p) as never} className={`${LINK_CLASS} whitespace-nowrap`}>
              查看日志
            </Link>
          </li>
        ))}
      </ul>
      <p className="mt-2 text-caption text-[var(--text-faint)]">
        其余功能不受影响；修复后重启应用即可恢复。
      </p>
    </Banner>
  );
}

function SettingsLink({ href }: { href: string }) {
  return (
    <Link href={href as never} className={`${SETTINGS_BUTTON_CLASS} inline-flex items-center gap-0.5`}>
      设置
      <ChevronRightIcon className="size-3.5 opacity-60" />
    </Link>
  );
}

/** 行的定位锚点：?module=<条目 id> 按它找行；高亮时描一道强调色的内环 */
const ROW_ANCHOR =
  "scroll-mt-24 transition-shadow duration-500 data-[highlight=true]:shadow-[inset_0_0_0_2px_var(--accent)]";

function OfficialSection({ plugins }: { plugins: PluginInfo[] }) {
  if (plugins.length === 0) return null;
  return (
    <SettingsSection
      title="官方插件"
      description="随 MovieClaw 提供的插件。装一个同名的插件包就能替换内置版本，卸载即恢复；也可以安装第三方插件接入更多平台。"
    >
      <SettingsList>
        {plugins.map((p) => (
          <div key={p.id} data-plugin-ids={p.id} className={ROW_ANCHOR}>
            <SettingsRow
              label={p.title}
              description={needsAttention(p) ? pluginDetail(p) : officialSourceText(p)}
            >
              <StatusPill tone={pluginStateTone(displayState(p))} label={pluginStateLabel(displayState(p))} />
              <SettingsLink href="/settings/im-push" />
            </SettingsRow>
          </div>
        ))}
      </SettingsList>
    </SettingsSection>
  );
}

/** 页面底部：系统模块的入口一行，点开是只读清单（按领域分组，带启动耗时） */
function SystemModules({
  plugins,
  groups,
  open,
  onToggle,
}: {
  plugins: PluginInfo[];
  groups: string[];
  open: boolean;
  onToggle: () => void;
}) {
  const line = systemModulesLine(plugins);
  const slow = slowestStarts(plugins);
  return (
    <section className="space-y-6 border-t border-[var(--line)] pt-6">
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={open}
        className="flex w-full items-center gap-2 px-1 text-left text-sub text-[var(--text-muted)] hover:text-[var(--text)]"
      >
        <span
          className="size-1.5 shrink-0 rounded-full"
          style={{ background: TONE_COLOR[line.tone] }}
        />
        <span className="flex-1">{line.text}</span>
        <span className="text-[var(--text-faint)]">{open ? "收起" : "查看"}</span>
        <ChevronRightIcon
          className={`size-3.5 text-[var(--text-faint)] transition-transform ${open ? "rotate-90" : ""}`}
        />
      </button>
      {open && (
        <div className="space-y-10">
          <p className="px-1 text-caption leading-5 text-[var(--text-faint)]">
            应用运行所需的内部模块，无需操作。一个出问题只影响它自己，其余功能照常。
            {` ${pluginsSummary(plugins)}`}
            {slow.length > 0 &&
              ` · 启动最慢：${slow.map((p) => `${p.title} ${formatMs(p.apply_ms ?? 0)}`).join("、")}`}
          </p>
          {groupBuiltins(plugins, groups).map((group) => (
            <SettingsSection key={group.label} title={group.label}>
              <SettingsList>
                {group.plugins.map((p) => (
                  <div key={p.id} data-plugin-ids={p.id} className={ROW_ANCHOR}>
                    <SettingsRow
                      label={
                        <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
                          {p.title}
                          <span className="text-caption font-normal text-[var(--text-faint)]">
                            {p.id}
                          </span>
                        </span>
                      }
                      description={pluginDetail(p)}
                    >
                      <StatusPill tone={pluginStateTone(displayState(p))} label={pluginStateLabel(displayState(p))} />
                    </SettingsRow>
                  </div>
                ))}
              </SettingsList>
            </SettingsSection>
          ))}
        </div>
      )}
    </section>
  );
}
