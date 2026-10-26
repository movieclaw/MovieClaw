"use client";

import { useCallback, useEffect, useId, useRef, useState } from "react";

import Link from "next/link";
import { useLocale, useTranslations } from "next-intl";

import type { MediaSearchItem } from "@/lib/api/discover";
import { searchTitles } from "@/lib/api/search";
import { BrandLoader } from "@/components/brand-loader";
import { CheckIcon, ListIcon, SparklesIcon, XIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import { RuleSetsPanel } from "@/components/rule-sets-panel";
import { SmartSubscriptionSettings } from "@/components/smart-subscription-settings";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  checkSubscriptionAutomationReadiness,
  previewSubscriptionDownloadRouting,
  type DispatchPreview,
  type FixOption,
  type LibraryPipeline,
  type PipelineCheck,
  type PipelineHealth,
  type PipelineIssue,
} from "@/lib/api/subscriptions";

/** 规则设置分区浏览，不改变订阅使用的模式；保留切换前未保存的表单。 */
export function SubscriptionSettingsSection() {
  const t = useTranslations();
  const [tab, setTab] = useState<"smart" | "rules">("smart");
  const [previewOpen, setPreviewOpen] = useState(false);
  const tabId = useId();
  const tabs = [{ id: "smart", label: t("settings.subscription.smartTab"), Icon: SparklesIcon }, { id: "rules", label: t("settings.subscription.rulesTab"), Icon: ListIcon }] as const;

  return (
    <div className="space-y-6">
      <div role="tablist" aria-label={t("settings.subscription.tabsLabel")} className="grid grid-cols-2 border-b border-[var(--line)]">
        {tabs.map(({ id, label, Icon }, index) => (
          <button key={id} type="button" role="tab" id={`${tabId}-${id}`} aria-controls={`${tabId}-${id}-panel`} aria-selected={tab === id} tabIndex={tab === id ? 0 : -1}
            onClick={() => setTab(id)}
            onKeyDown={(event) => {
              if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
              event.preventDefault();
              const next = event.key === "Home" ? 0 : event.key === "End" ? 1 : 1 - index;
              setTab(tabs[next].id);
              event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>('[role="tab"]')[next]?.focus();
            }}
            className={`flex min-h-12 items-center justify-center gap-2 border-b-2 px-3 pb-3 text-ui font-semibold transition-colors ${tab === id ? "border-[var(--accent)] text-[var(--text)]" : "border-transparent text-[var(--text-muted)] hover:text-[var(--text)]"}`}>
            <Icon className="size-4" />{label}
          </button>
        ))}
      </div>
      <div role="tabpanel" id={`${tabId}-smart-panel`} aria-labelledby={`${tabId}-smart`} hidden={tab !== "smart"}>
        <SmartSubscriptionSettings />
      </div>
      <div role="tabpanel" id={`${tabId}-rules-panel`} aria-labelledby={`${tabId}-rules`} hidden={tab !== "rules"}>
        <RuleSetsPanel onPreview={() => setPreviewOpen(true)} />
      </div>
      {previewOpen && <RuleMatchPreview onClose={() => setPreviewOpen(false)} />}
    </div>
  );
}

/** 状态 → 颜色/文案（节点、检查项、库行共用一套语义）。 */
const STATUS_META = {
  ok: { dot: "bg-[var(--ok)]", text: "text-[var(--ok)]", label: "subscription.pipeline.ok" },
  warn: { dot: "bg-[var(--warn)]", text: "text-[var(--warn)]", label: "subscription.pipeline.warn" },
  error: { dot: "bg-[var(--danger)]", text: "text-[var(--danger)]", label: "subscription.pipeline.error" },
} as const;

type Status = keyof typeof STATUS_META;

/** 修复去处 → 跳转地址与文案。 */
function fixTarget(section: string | null): { href: string; label: "subscription.pipeline.goSites" | "subscription.pipeline.goDownloaders" | "subscription.pipeline.goWatch" | "subscription.pipeline.goLibraries" } | null {
  if (section === "sites") return { href: "/settings/sites", label: "subscription.pipeline.goSites" };
  if (section === "downloaders") return { href: "/settings/downloaders", label: "subscription.pipeline.goDownloaders" };
  if (section === "import-watch") return { href: "/settings/import-watch", label: "subscription.pipeline.goWatch" };
  if (section === "libraries") return { href: "/library", label: "subscription.pipeline.goLibraries" };
  return null;
}

/** 修复选项 → 带预填参数的跳转地址（目标设置页读取参数自动填表单）。 */
function fixOptionHref(option: FixOption): string | null {
  const target = fixTarget(option.fix_section);
  if (!target) return null;
  if (!option.fix_params) return target.href;
  return `${target.href}?${new URLSearchParams(option.fix_params)}`;
}

function worst(statuses: Status[]): Status {
  if (statuses.includes("error")) return "error";
  if (statuses.includes("warn")) return "warn";
  return "ok";
}

// ---------------------------------------------------------------------------
// 链路体检
// ---------------------------------------------------------------------------

export function PipelineHealthPanel() {
  const t = useTranslations();
  const locale = useLocale();

  const [health, setHealth] = useState<PipelineHealth | null>(null);
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const reloadId = useRef(0);

  const reload = useCallback(() => {
    const id = ++reloadId.current;
    setFailed(false);
    setBusy(true);
    checkSubscriptionAutomationReadiness()
      .then((result) => { if (id === reloadId.current) setHealth(result); })
      .catch(() => { if (id === reloadId.current) setFailed(true); })
      .finally(() => { if (id === reloadId.current) setBusy(false); });
  }, []);

  useEffect(() => {
    reload();
    return () => { reloadId.current += 1; };
  }, [reload, locale]);

  // 修完配置回到本页自动重检：修复 → 回来 → 变绿的反馈闭环
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") reload();
    };
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);
    return () => {
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
    };
  }, [reload]);

  // 开局清单条件：三个必要件（站点/下载器/媒体库）任一**从未配置**。
  // 用"配置过"而非"当前可用"判断——站点 cookie 过期的老用户该看到的是
  // 体检红项，不是新手三步清单
  const setupNeeded =
    health !== null &&
    (!health.sites_configured || !health.downloaders_configured || health.libraries.length === 0);

  // 已聚合成修复卡的检查项 key：库卡片默认不再重复其红项文字（状态点保留）
  const issueKeys = new Set((health?.issues ?? []).map((i) => i.key));

  return (
    <SettingsSection
      title={t("subscription.pipeline.title")}
      description={
        setupNeeded
          ? t("subscription.pipeline.setupHint")
          : t("subscription.pipeline.description")
      }
      action={
        <button
          type="button"
          onClick={reload}
          disabled={busy}
          className={`${SETTINGS_BUTTON_CLASS} flex items-center gap-1.5`}
        >
          {busy && (
            <span className="size-3 animate-spin rounded-full border-2 border-white/20 border-t-white/70" />
          )}
          {t("subscription.pipeline.reload")}</button>
      }
    >
      {failed && (
        <p className="rounded-xl bg-white/[0.03] px-4 py-5 text-center text-ui text-[var(--text-muted)]">
          {t("subscription.pipeline.failed")}</p>
      )}
      {health === null && !failed && (
        <p className="flex items-center gap-2.5 rounded-xl bg-white/[0.03] px-4 py-5 text-ui text-[var(--text-muted)]">
          <BrandLoader className="size-5" />
          {t("subscription.pipeline.loading")}</p>
      )}

      {health !== null && setupNeeded && <SetupChecklist health={health} />}

      {health !== null && !setupNeeded && (
        <div className="space-y-3">
          {/* 修复卡置顶：按根因聚合，「需要处理 N 件事」——一个根因一张卡，
              不随受影响的库数膨胀；库卡片里对应的红项文字随之隐藏（状态点保留） */}
          {health.issues.length > 0 && <IssueCardList issues={health.issues} />}
          {/* 公共段：资源搜索 + 下载器（所有库共享，不逐库重复） */}
          <SharedSegmentsRow health={health} hiddenKeys={issueKeys} />
          {health.libraries.map((pipeline) => (
            <LibraryPipelineCard
              key={pipeline.library_id}
              pipeline={pipeline}
              hiddenKeys={issueKeys}
            />
          ))}
        </div>
      )}
    </SettingsSection>
  );
}

/**
 * 开局清单：三个必要件缺任一时，体检数据换一种读法——"下一步做什么"。
 * 全部配齐后本清单自动让位给正常体检，同一页面从第一天用到第一百天。
 */
function SetupChecklist({ health }: { health: PipelineHealth }) {
  const t = useTranslations();

  const steps: { done: boolean; label: string; hint: string; href: string; action: string }[] = [
    {
      done: health.sites_configured,
      label: t("subscription.pipeline.connectSites"),
      hint: t("subscription.pipeline.sitesHint"),
      href: "/settings/sites",
      action: t("subscription.pipeline.connect"),
    },
    {
      done: health.downloaders_configured,
      label: t("subscription.pipeline.connectDownloader"),
      hint: t("subscription.pipeline.downloaderHint"),
      href: "/settings/downloaders",
      action: t("subscription.pipeline.connect"),
    },
    {
      done: health.libraries.length > 0,
      label: t("subscription.pipeline.createLibrary"),
      hint: t("subscription.pipeline.libraryHint"),
      href: "/library",
      action: t("subscription.pipeline.create"),
    },
  ];
  return (
    <>
      <SettingsList>
        {steps.map((step, i) => (
          <SettingsRow
            key={step.label}
            leading={
              <span
                className={`flex size-6 shrink-0 items-center justify-center rounded-full text-caption font-semibold ${
                  step.done ? "bg-[var(--ok)]/20 text-[var(--ok)]" : "bg-white/10 text-white/70"
                }`}
              >
                {step.done ? <CheckIcon className="size-3.5" /> : i + 1}
              </span>
            }
            label={
              <span className={step.done ? "text-[var(--text-faint)] line-through" : undefined}>
                {step.label}
              </span>
            }
            description={step.hint}
          >
            {!step.done && (
              <Link href={step.href as never} className={`${SETTINGS_BUTTON_CLASS} flex items-center`}>
                {step.action}
              </Link>
            )}
          </SettingsRow>
        ))}
      </SettingsList>
      <p className="mt-2 px-1 text-caption leading-5 text-[var(--text-faint)]">
        {t("subscription.pipeline.optionalWatch")}</p>
    </>
  );
}

/**
 * 修复卡列表：「需要处理 N 件事」。
 * 一张卡 = 一个根因，卡内列出受影响的库与结构化的修复选项（多选项时
 * 由用户按自己的部署取舍，每个选项讲清做什么/为什么/跳到哪）。
 */
function IssueCardList({ issues }: { issues: PipelineIssue[] }) {
  const t = useTranslations();

  return (
    <div className="space-y-2.5">
      <p className="text-ui font-medium text-white/90">
        {t("subscription.pipeline.issueCount", { count: issues.length })}
      </p>
      {issues.map((issue) => (
        <IssueCard key={issue.key + issue.title} issue={issue} />
      ))}
    </div>
  );
}

function IssueCard({ issue }: { issue: PipelineIssue }) {
  const t = useTranslations();
  const locale = useLocale();

  const isError = issue.status === "error";
  return (
    <div
      className={`rounded-xl border p-4 ${
        isError ? "border-[#ff6b6b]/30 bg-[#ff6b6b]/[0.06]" : "border-amber-400/25 bg-amber-500/[0.06]"
      }`}
    >
      <div className="flex items-start gap-2.5">
        <span className={`mt-[5px] size-2 shrink-0 rounded-full ${STATUS_META[issue.status].dot}`} />
        <div className="min-w-0 flex-1">
          <p className="text-ui font-semibold text-white/95">{issue.title}</p>
          {issue.affected_libraries.length > 0 && (
            <p className="mt-1 text-caption text-[var(--text-faint)]">
              {t("subscription.pipeline.affectedLibraries", { count: issue.affected_libraries.length, names: issue.affected_libraries.join(locale === "zh-Hans" ? "、" : ", ") })}
            </p>
          )}
          <p className="mt-1.5 text-sub leading-relaxed text-[var(--text-muted)]">
            {issue.detail}
          </p>
        </div>
      </div>
      {issue.options.length > 0 && (
        <div
          className={`mt-3 grid gap-2.5 ${issue.options.length > 1 ? "md:grid-cols-2" : ""}`}
        >
          {issue.options.map((option, i) => (
            <FixOptionBlock
              key={option.title}
              option={option}
              ordinal={issue.options.length > 1 ? i + 1 : null}
            />
          ))}
        </div>
      )}
    </div>
  );
}

/** 修复卡里的一个选项块：做什么 / 为什么 / 带预填参数的跳转。 */
function FixOptionBlock({ option, ordinal }: { option: FixOption; ordinal: number | null }) {
  const href = fixOptionHref(option);
  return (
    <div className="flex flex-col rounded-lg bg-white/[0.04] p-3">
      <p className="text-sub font-semibold text-white/90">
        {ordinal !== null && (
          <span className="mr-1.5 inline-flex size-4.5 items-center justify-center rounded-full bg-white/10 text-micro text-white/70">
            {ordinal}
          </span>
        )}
        {option.title}
      </p>
      {option.why && (
        <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">{option.why}</p>
      )}
      <p className="mt-1.5 flex-1 text-sub leading-relaxed text-[var(--text-muted)]">
        {option.steps}
      </p>
      {href && (
        <Link
          href={href as never}
          className={`${SETTINGS_BUTTON_CLASS} mt-2.5 flex items-center self-start`}
        >
          {option.fix_label} →
        </Link>
      )}
    </div>
  );
}

/** 流水线上的一个节点（步骤条渲染单元）。 */
interface FlowNode {
  key: string;
  label: string;
  sub: string | null; // 节点下的一行小字（下载器名/路径等）
  status: Status;
  checks: PipelineCheck[]; // 该节点聚合的检查项（红黄项列在卡片下方）
}

/** 步骤条：节点胶囊 + 连接线，红黄节点自然显眼。 */
function FlowStepper({ nodes }: { nodes: FlowNode[] }) {
  const locale = useLocale();
  return (
    <div className="flex flex-wrap items-center gap-y-2">
      {nodes.map((node, i) => (
        <div key={node.key} className={`flex items-center ${locale === "en" ? "min-w-0 max-w-full" : ""}`}>
          {i > 0 && <span className="mx-1.5 h-px w-4 shrink-0 bg-white/20" />}
          <div
            className={`flex items-center gap-2 rounded-lg border px-2.5 py-1.5 ${locale === "en" ? "min-w-0" : ""} ${
              node.status === "ok"
                ? "border-white/[0.08] bg-white/[0.03]"
                : node.status === "warn"
                  ? "border-amber-400/30 bg-amber-500/10"
                  : "border-[#ff6b6b]/35 bg-[#ff6b6b]/10"
            }`}
          >
            <span className={`size-1.5 shrink-0 rounded-full ${STATUS_META[node.status].dot}`} />
            <span className="text-sub font-medium text-white/90">{node.label}</span>
            {node.sub && (
              <span
                dir="rtl"
                className="max-w-[180px] truncate font-mono text-caption text-[var(--text-faint)]"
                title={node.sub}
              >
                {"‎" + node.sub + "‎"}
              </span>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

/** 公共段（资源搜索 + 下载器）：所有库共享，单独一行不逐库重复。 */
function SharedSegmentsRow({
  health,
  hiddenKeys,
}: {
  health: PipelineHealth;
  /** 已被修复卡聚合的检查项 key：红项文字不再重复（状态点保留） */
  hiddenKeys: Set<string>;
}) {
  const t = useTranslations();

  const downloaderCheck = health.libraries[0]?.checks.find((c) => c.key === "downloader");
  const nodes: FlowNode[] = [
    {
      key: "sites",
      label: t("subscription.pipeline.search"),
      sub: null,
      status: health.site_check.status,
      checks: [health.site_check],
    },
    {
      key: "downloader",
      label: t("subscription.pipeline.downloader"),
      sub: null,
      status: downloaderCheck?.status ?? (health.downloader_ok ? "ok" : "error"),
      checks: downloaderCheck ? [downloaderCheck] : [],
    },
  ];
  const problems = nodes
    .flatMap((n) => n.checks)
    .filter((c) => c.status !== "ok" && !hiddenKeys.has(c.key));
  return (
    <div className="rounded-xl border border-white/[0.08] bg-white/[0.04] px-4 py-3">
      <div className="flex items-center gap-3">
        <span className="w-24 shrink-0 text-sub text-[var(--text-faint)] max-md:hidden">
          {t("subscription.pipeline.shared")}</span>
        <FlowStepper nodes={nodes} />
      </div>
      {problems.length > 0 && <ProblemList checks={problems} />}
    </div>
  );
}

/** 一个库的流水线卡片：步骤条 + 叙事 + 红黄项详情（已聚合的红项让位给修复卡）。 */
function LibraryPipelineCard({
  pipeline,
  hiddenKeys,
}: {
  pipeline: LibraryPipeline;
  /** 已被修复卡聚合的检查项 key：红项文字不再逐库重复（状态点保留） */
  hiddenKeys: Set<string>;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const [showAll, setShowAll] = useState(false);

  const byKey = (keys: string[]) => pipeline.checks.filter((c) => keys.includes(c.key));
  const dispatchChecks = byKey(["dispatch_dir", "mapping"]);
  const transferChecks = byKey(["transfer_disk", "watch_active"]);
  const ingestError = pipeline.checks.some(
    (c) => c.key === "dispatch_dir" && c.fix_section === "libraries" && c.status !== "ok",
  );

  const nodes: FlowNode[] = [
    {
      key: "dispatch",
      label: pipeline.mode === "watch" ? t("subscription.pipeline.dispatchWatch") : t("subscription.pipeline.dispatch"),
      sub: pipeline.path,
      status: worst(dispatchChecks.map((c) => c.status)),
      checks: dispatchChecks,
    },
  ];
  if (pipeline.mode === "watch") {
    nodes.push({
      key: "transfer",
      label: pipeline.staging_path ? t("subscription.pipeline.output") : t("subscription.pipeline.transfer"),
      sub: pipeline.staging_path,
      status: worst(transferChecks.map((c) => c.status)),
      checks: transferChecks,
    });
  }
  if (pipeline.staging_path) {
    // 自定义目录规则：整理后不直接入库——中间隔着用户自己的外部流转
    // （上传/转存/人工确认），movieclaw 不判它的死活，节点仅作说明
    nodes.push({
      key: "external",
      label: t("subscription.pipeline.external"),
      sub: null,
      status: "ok",
      checks: [],
    });
  }
  nodes.push({
    key: "ingest",
    label: pipeline.staging_path ? t("subscription.pipeline.returnIngest") : t("subscription.pipeline.ingest"),
    sub: pipeline.library_root,
    status: ingestError ? "error" : "ok",
    checks: [],
  });

  // 卡片下方默认只列**未被修复卡聚合**的红黄项；「查看全部」仍展开全部事实
  const problems = pipeline.checks.filter((c) => c.status !== "ok" && !hiddenKeys.has(c.key));
  const listed = showAll ? pipeline.checks.filter((c) => c.key !== "downloader") : problems;
  const meta = STATUS_META[pipeline.status];

  return (
    <div className="rounded-xl border border-white/[0.08] bg-white/[0.04] px-4 py-3">
      <div className={`flex items-center gap-3 ${locale === "en" ? "max-md:flex-col max-md:items-stretch" : ""}`}>
        <span className="w-24 shrink-0 max-md:hidden">
          <span className="block truncate text-ui font-medium text-white/90">
            {pipeline.library_name}
          </span>
          <span className="block text-caption text-[var(--text-faint)]">
            {pipeline.kind === "movie" ? t("media.kind.movie") : t("media.kind.tv")}
            {pipeline.is_default ? t("subscription.pipeline.defaultSuffix") : ""}
          </span>
        </span>
        <div className="min-w-0 flex-1">
          <p className="mb-1.5 text-sub font-medium text-white/90 md:hidden">
            {pipeline.library_name}
          </p>
          <FlowStepper nodes={nodes} />
          {/* 正向叙事：订阅命中本库会发生什么——全绿时的可预期，不用去玩模拟一单 */}
          {pipeline.narrative && (
            <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
              {pipeline.narrative}
            </p>
          )}
        </div>
        <div className={`flex shrink-0 flex-col items-end gap-1 ${locale === "en" ? "max-md:flex-row max-md:items-center max-md:justify-end max-md:gap-3" : ""}`}>
          <span className={`text-sub font-medium ${meta.text}`}>{t(meta.label)}</span>
          <button
            type="button"
            onClick={() => setShowAll((v) => !v)}
            className="text-caption text-[var(--text-faint)] hover:text-white"
          >
            {showAll ? t("subscription.pipeline.collapse") : t("subscription.feed.seeAll")}
          </button>
        </div>
      </div>
      {listed.length > 0 && <ProblemList checks={listed} />}
    </div>
  );
}

/** 检查项明细列表（红黄项默认展示；「查看全部」时含绿项）。 */
function ProblemList({ checks }: { checks: PipelineCheck[] }) {
  const t = useTranslations();

  return (
    <div className="mt-2.5 space-y-1.5 border-t border-white/[0.06] pt-2.5">
      {checks.map((check) => {
        const fix = check.status !== "ok" ? fixTarget(check.fix_section) : null;
        return (
          <div key={check.key + check.detail} className="flex items-start gap-2.5">
            <span
              className={`mt-[5px] size-1.5 shrink-0 rounded-full ${STATUS_META[check.status].dot}`}
            />
            <p className="min-w-0 flex-1 text-sub leading-relaxed text-[var(--text-muted)]">
              <span className="font-medium text-[var(--text)]">{check.label}</span>
              <span className="ml-2">{check.detail}</span>
              {fix && (
                <Link
                  href={fix.href as never}
                  className="ml-2 whitespace-nowrap font-medium text-[var(--accent)] hover:underline"
                >
                  {t(fix.label)} →
                </Link>
              )}
            </p>
          </div>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------------------
// 自定义规则的匹配与入库预览（不创建订阅或下载资源）
// ---------------------------------------------------------------------------

function RuleMatchPreview({ onClose }: { onClose: () => void }) {
  const t = useTranslations();
  const locale = useLocale();
  const previewLocale = useRef(locale);

  const [query, setQuery] = useState("");
  const [candidates, setCandidates] = useState<MediaSearchItem[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [picked, setPicked] = useState<MediaSearchItem | null>(null);
  const [preview, setPreview] = useState<DispatchPreview | null>(null);
  const [error, setError] = useState<{ message: string } | { key: "subscription.pipeline.searchFailed" | "subscription.pipeline.searchRetry" | "subscription.pipeline.previewFailed" } | null>(null);
  const requestId = useRef(0);

  // 关闭或换关键词后，忽略之前搜索与预览的返回结果。
  useEffect(() => {
    let active = true;
    requestId.current += 1;
    setPicked(null);
    setPreview(null);
    setError(null);
    setCandidates(null);
    setSearching(false);
    if (query.trim().length < 2) return;
    const timer = setTimeout(() => {
      setSearching(true);
      searchTitles(query.trim(), { provider: "tmdb" })
        .then(({ items, providers }) => {
          if (!active) return;
          const failed = providers.find((provider) => !provider.success);
          if (failed) setError(failed.message ? { message: failed.message } : { key: "subscription.pipeline.searchFailed" });
          else setCandidates(items.filter((it) => it.type).slice(0, 6));
        })
        .catch(() => { if (active) setError({ key: "subscription.pipeline.searchRetry" }); })
        .finally(() => { if (active) setSearching(false); });
    }, 400);
    return () => { active = false; clearTimeout(timer); requestId.current += 1; };
  }, [query]);

  const pick = useCallback((item: MediaSearchItem) => {
    setPicked(item);
    setPreview(null);
    setError(null);
    if (!item.type) return;
    const current = ++requestId.current;
    void previewSubscriptionDownloadRouting(item.type, null, Number(item.id), {
      title: item.title,
      year: item.year,
    })
      .then((result) => { if (current === requestId.current) setPreview(result); })
      .catch(() => { if (current === requestId.current) setError({ key: "subscription.pipeline.previewFailed" }); });
  }, []);

  useEffect(() => {
    if (previewLocale.current === locale) return;
    previewLocale.current = locale;
    if (picked) pick(picked);
  }, [locale, picked, pick]);

  return (
    <Modal open onClose={onClose} label={t("subscription.pipeline.previewTitle")} width="lg">
      <div className="p-5 sm:p-6">
        <div className="mb-2 flex items-center justify-between gap-3">
          <h2 className="text-title font-semibold text-[var(--text)]">{t("subscription.pipeline.previewTitle")}</h2>
          <button type="button" onClick={onClose} aria-label={t("subscription.pipeline.closePreview")} className="btn-glass -mr-2 grid size-11 shrink-0 place-items-center"><XIcon className="size-5" /></button>
        </div>
        <p className="mb-4 text-sub leading-relaxed text-[var(--text-muted)]">{t("subscription.pipeline.previewHint")}</p>
        <input
          type="search"
          aria-label={t("subscription.pipeline.searchLabel")}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t("subscription.pipeline.searchPlaceholder")}
          autoComplete="off"
          className={`${SETTINGS_INPUT_CLASS} w-full`}
        />
        {error && <p role="alert" className="mt-3 text-sub text-[var(--danger)]">{"key" in error ? t(error.key) : error.message}{picked && <button type="button" onClick={() => pick(picked)} className="ml-3 underline">{t("subscription.pipeline.retryPreview")}</button>}</p>}
        {searching && (
          <p className="mt-2 text-sub text-[var(--text-faint)]">{t("subscription.pipeline.searching")}</p>
        )}
        {candidates !== null && !searching && !picked && (
          <div className="mt-2 flex flex-wrap gap-1.5">
            {candidates.length === 0 && (
              <p className="text-sub text-[var(--text-faint)]">{t("subscription.pipeline.noResults")}</p>
            )}
            {candidates.map((item) => (
              <button
                key={item.id}
                type="button"
                onClick={() => pick(item)}
                className="glass-row nav-item !w-auto px-3 py-1.5 text-sub font-medium"
              >
                {item.title}
                <span className="ml-1.5 text-[var(--text-faint)]">
                  {item.year ?? ""} {item.type === "movie" ? t("media.kind.movie") : t("media.kind.tv")}
                </span>
              </button>
            ))}
          </div>
        )}
        {picked && (
          <div className="mt-3 rounded-xl border border-white/[0.08] bg-white/[0.04] px-4 py-3">
            <p className="text-ui font-medium text-white/90">
              {t("subscription.pipeline.previewPicked", { title: picked.title, hasYear: picked.year ? "yes" : "no", year: picked.year ?? "" })}
            </p>
            {error ? null : preview === null ? (
              <p className="mt-2 text-sub text-[var(--text-faint)]">{t("subscription.pipeline.previewing")}</p>
            ) : (
              <div className="mt-2 space-y-1.5">
                {preview.rule_set_reason && <SimStep n={1} text={preview.rule_set_reason} />}
                <SimStep
                  n={preview.rule_set_reason ? 2 : 1}
                  text={
                    preview.route_reason ??
                    (preview.library_name ? t("subscription.pipeline.libraryTarget", { name: preview.library_name }) : t("subscription.pipeline.noLibraries"))
                  }
                />
                <details className="py-1 text-sub text-[var(--text-muted)]">
                  <summary className="cursor-pointer py-1">{t("subscription.pipeline.details")}</summary>
                  <div className="mt-2 space-y-2">
                <SimStep
                  n={preview.rule_set_reason ? 3 : 2}
                  text={
                    preview.mode === "watch"
                      ? preview.staging_path
                        ? t("subscription.pipeline.watchOutput", { path: preview.path ?? "", target: preview.staging_path })
                        : t("subscription.pipeline.watchImport", { path: preview.path ?? "" })
                      : preview.mode === "inplace"
                        ? // 条目目录由后端按命名模板渲染，前端不自己拼「标题 (年份)」
                          t("subscription.pipeline.directImport", { path: (preview.entry_dir ?? preview.path)?.replace(/\/+$/, "") ?? "" })
                        : t("subscription.pipeline.defaultDownload")
                  }
                />
                {preview.staging_path && (
                  <SimStep
                    n={preview.rule_set_reason ? 4 : 3}
                    text={t("subscription.pipeline.waitExternal")}
                  />
                )}
                  </div>
                </details>
                {preview.ok ? (
                  <p className="flex items-center gap-1.5 pt-1 text-sub font-medium text-[var(--ok)]">
                    {t("subscription.pipeline.available")}</p>
                ) : (
                  <p className="rounded-lg border border-amber-400/25 bg-amber-500/10 px-3 py-2 text-sub leading-relaxed text-amber-200">
                    {preview.warning}
                  </p>
                )}
              </div>
            )}
          </div>
        )}
      </div>
    </Modal>
  );
}

function SimStep({ n, text }: { n: number; text: string }) {
  return (
    <p className="flex items-start gap-2.5 text-sub leading-relaxed text-[var(--text-muted)]">
      <span className="mt-px flex size-4.5 shrink-0 items-center justify-center rounded-full bg-white/10 text-micro font-semibold text-white/70">
        {n}
      </span>
      <span className="min-w-0 flex-1 [overflow-wrap:anywhere]">{text}</span>
    </p>
  );
}
