"use client";

import { useLocale, useTranslations } from "next-intl";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { appTranslator } from "@/lib/i18n/translate";
import { useCallback, useEffect, useState } from "react";

import { AuthError, AuthField, AuthScreen } from "@/components/auth-screen";
import { BrandLoader } from "@/components/brand-loader";
import { SharedCollectionView } from "@/components/share/shared-collection-view";
import { SharedItemView } from "@/components/share/shared-item-view";
import { probeShare, unlockShare } from "@/lib/api/shares";
import { HttpError } from "@/lib/http";
import { usePageTitle } from "@/lib/use-page-title";

type Phase =
  | { kind: "loading" }
  | { kind: "locked" }
  | { kind: "unavailable"; message: string }
  /** 条目分享；合集分享点开某一部之后也是它（带着 mediaItemId） */
  | { kind: "ready"; mediaItemId?: number }
  /** 合集分享的名单 */
  | { kind: "collection" };

/** 探针失败 → 访客看得懂的一句话（后端 message 已是中文，直接用）。 */
export function unavailableMessage(error: unknown, locale?: AppLocale): string {
  const t = appTranslator(locale);
  if (error instanceof HttpError) {
    if (error.status === 404) return error.message || t("library.share.missing");
    return error.message || t("library.share.unavailable");
  }
  return t("library.share.networkFailed");
}

/**
 * 影片分享页的状态机（docs/design/media-share.md §1.2）：
 *
 *   探针 → 需要密码且未解锁 → 密码卡片（密码之前不露片名海报）
 *       → 失效（不存在 / 已取消 / 已过期）→ 整页提示
 *       → 可看 → 影片页
 */
export function SharePage({ slug }: { slug: string }) {
  const t = useTranslations();
  const locale = useLocale();
  const [phase, setPhase] = useState<Phase>({ kind: "loading" });

  // 解锁之后要知道这条链接是"一部片"还是"一个合集"——两者的落地页不一样
  const [isCollection, setIsCollection] = useState(false);

  const probe = useCallback(() => {
    probeShare(slug)
      .then((info) => {
        const collection = info.collection_id !== null;
        setIsCollection(collection);
        setPhase(
          info.requires_password && !info.unlocked
            ? { kind: "locked" }
            : collection
              ? { kind: "collection" }
              : { kind: "ready" },
        );
      })
      .catch((error: unknown) =>
        setPhase({ kind: "unavailable", message: unavailableMessage(error, locale) }),
      );
  }, [slug, locale]);

  useEffect(() => {
    setPhase({ kind: "loading" });
    probe();
  }, [probe]);

  if (phase.kind === "collection") {
    return (
      <SharedCollectionView
        slug={slug}
        onOpen={(mediaItemId) => setPhase({ kind: "ready", mediaItemId })}
      />
    );
  }
  if (phase.kind === "ready") {
    return (
      <SharedItemView
        slug={slug}
        mediaItemId={phase.mediaItemId}
        // 合集分享里给一条回名单的路；条目分享没有"上一层"
        onBack={isCollection ? () => setPhase({ kind: "collection" }) : undefined}
      />
    );
  }
  if (phase.kind === "locked") {
    return (
      <ShareGate
        slug={slug}
        onUnlocked={() => setPhase(isCollection ? { kind: "collection" } : { kind: "ready" })}
      />
    );
  }
  if (phase.kind === "unavailable") return <ShareUnavailable message={phase.message} />;
  return (
    <div className="flex min-h-dvh items-center justify-center gap-2.5 text-ui text-white/60">
      <BrandLoader className="size-5" />
      {t("library.share.opening")}
    </div>
  );
}

/** 密码卡片：与登录页同一个外壳，但没有任何站内入口。 */
function ShareGate({ slug, onUnlocked }: { slug: string; onUnlocked: () => void }) {
  const t = useTranslations();
  usePageTitle(t("library.share.passwordRequired"));
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!password.trim() || busy) return;
    setBusy(true);
    setError(null);
    try {
      await unlockShare(slug, password.trim());
      onUnlocked();
    } catch (e) {
      setError(
        e instanceof HttpError
          ? e.message || t("library.share.wrongPassword")
          : t("library.share.networkFailed"),
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthScreen title={t("library.share.passwordRequired")} subtitle={t("library.share.passwordIntro")}>
      <form onSubmit={submit} className="space-y-4">
        <AuthField
          label={t("library.share.password")}
          aria-label={t("library.share.password")}
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          autoComplete="off"
          autoFocus
          required
        />
        <AuthError message={error} />
        <button
          type="submit"
          disabled={busy || !password.trim()}
          className="w-full rounded-xl bg-white px-4 py-2.5 text-ui font-semibold text-black transition hover:bg-white/90 disabled:opacity-50"
        >
          {busy ? t("library.share.verifying") : t("library.share.open")}
        </button>
      </form>
    </AuthScreen>
  );
}

function ShareUnavailable({ message }: { message: string }) {
  const t = useTranslations();
  usePageTitle(t("library.share.unavailableTitle"));
  return (
    <AuthScreen title={message} subtitle={t("library.share.confirmLink")}>
      <p className="text-caption text-[var(--text-faint)]">
        {t("library.share.expiryHint")}
      </p>
    </AuthScreen>
  );
}
