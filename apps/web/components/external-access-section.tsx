"use client";

import { useLocale, useTranslations } from "next-intl";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useCallback, useEffect, useRef, useState } from "react";

import { Banner } from "@/components/cloud-push-ui";
import { InfoIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSaveStatus,
  SettingsSection,
} from "@/components/settings-ui";
import { Tooltip } from "@/components/tooltip";
import {
  type AppConfigView,
  getAppConfig,
  saveAppConfig,
  saveWebPort,
} from "@/lib/api/app";

/**
 * 外部访问设置（设置 → 网络，「外部访问」分组）。
 *
 * 原来住在「应用」分区的「网络与维护」标签里，设置页按功能重组后迁来这里——
 * 网络相关的配置（代理 / 镜像 / 外部访问）从此只有一个家：
 *   - 外部访问地址：从网络上能访问到本应用的完整地址，保存即生效（纯落库数据，
 *     供生成通知链接等绝对 URL 的场景使用）；
 *   - 对外端口：前端实际监听的端口，改它要全量重启，且改完当前页面的地址多半
 *     就打不开了——因此它是本组唯一不走「失焦即存」的字段。
 *
 * 端口这一项的交互为什么这么重：用户改端口用的正是这个 Web 界面，改错就把自己
 * 关在了门外。代码侧的兜底只覆盖「新端口在容器内绑不上」（entrypoint 试绑失败
 * 会废弃设置并回落，见 docker/resolve-web-port.sh）；而「bridge 网络下改了容器
 * 侧端口、compose 的 ports 映射没跟着改」在容器内一切正常，任何代码都察觉不到，
 * 只能靠改前的确认文案说清楚。所以二次确认里必须直白写出这一条。
 *
 * 其余字段的交互模型与本分区的代理设置一致：输入框失焦自动落库，无保存按钮。
 * 只有端口的原理说明太长，留在 ⓘ 里；其余说明是行内一行灰字。
 */

/** 端口修改的阶段：确认 → 已提交（应用重启到新端口，本页地址已失效） */
type PortPhase = "idle" | "confirming" | "switched";

export function ExternalAccessSection() {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;

  const [view, setView] = useState<AppConfigView | null>(null);
  const [failed, setFailed] = useState(false);
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [saveError, setSaveError] = useState<string | null>(null);
  const [urlError, setUrlError] = useMessageState();
  // 输入框草稿是否为空：有输入时收起框内的「使用」按钮，避免误点覆盖手填内容
  const [draftEmpty, setDraftEmpty] = useState(true);
  const [portPhase, setPortPhase] = useState<PortPhase>("idle");
  // 待确认/已提交的目标端口；null = 恢复默认
  const [portTarget, setPortTarget] = useState<number | null>(null);
  const [portDraft, setPortDraft] = useState("");
  const [portError, setPortError] = useMessageState();
  const [restartPort, setRestartPort] = useState<number | null>(null);
  const savedTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  // 外部访问地址的最佳示例就是用户此刻浏览器正在使用的地址（SSR 阶段无 window，
  // 但表单要等客户端拉到配置才渲染，这里只是兜底给个通用示例）
  const currentOrigin =
    typeof window === "undefined" ? "https://movie.example.com" : window.location.origin;

  const reload = useCallback(() => {
    setFailed(false);
    getAppConfig()
      .then(setView)
      .catch(() => setFailed(true));
  }, []);

  useEffect(() => {
    reload();
    return () => {
      if (savedTimer.current) clearTimeout(savedTimer.current);
    };
  }, [reload]);

  /** 落库一份完整配置（失焦触发），错误信息中文回显在对应字段下方。 */
  const commit = useCallback(
    (patch: Partial<Pick<AppConfigView, "external_url">>) => {
      if (!view) return;
      setSaveState("saving");
      setSaveError(null);
      saveAppConfig({
        external_url: patch.external_url ?? view.external_url,
      })
        .then((v) => {
          setView(v);
          setSaveState("saved");
          if (savedTimer.current) clearTimeout(savedTimer.current);
          savedTimer.current = setTimeout(() => setSaveState("idle"), 2000);
        })
        .catch((e) => {
          setSaveState("error");
          setSaveError((e as Error).message);
        });
    },
    [view],
  );

  const handleUrlBlur = (raw: string) => {
    const url = raw.trim();
    if (url && !/^https?:\/\/.+/.test(url)) {
      setUrlError({ key: "settings.network.external.invalidUrl" });
      return;
    }
    setUrlError(null);
    commit({ external_url: url });
  };

  /** 校验端口草稿并进入二次确认（真正提交在 doSavePort）。 */
  const reviewPort = (raw: string) => {
    const text = raw.trim();
    setPortError(null);
    if (!text) {
      setPortError({ key: "settings.network.external.emptyPort" });
      return;
    }
    const port = Number(text);
    if (!/^\d+$/.test(text) || port < 1 || port > 65535) {
      setPortError({ key: "settings.network.external.invalidPort" });
      return;
    }
    if (view && port === view.web_port) {
      setPortError({ key: "settings.network.external.samePort" });
      return;
    }
    setPortTarget(port);
    setPortPhase("confirming");
  };

  /**
   * 提交端口修改。成功后不轮询等恢复——应用会在**新端口**上起来，本页所在的
   * 地址（以及 bridge 部署下的旧映射）多半已经不通，原地轮询只会白等到超时。
   * 改为直接切到引导页，把新地址交给用户。
   */
  const doSavePort = async () => {
    const before = view?.web_port;
    try {
      const next = await saveWebPort(portTarget);
      if (next.web_port === before) {
        // 生效端口其实没变（清除设置后回落值恰好等于当前端口），后端不会重启，
        // 这时切到「正在重启」页是误报——直接更新展示即可
        setView(next);
        setPortPhase("idle");
        return;
      }
      setRestartPort(next.web_port);
      setPortPhase("switched");
    } catch (e) {
      setPortPhase("idle");
      setPortError((e as Error).message);
    }
  };

  if (failed) {
    return (
      <div className="flex items-center gap-3">
        <p className="text-ui text-[var(--text-muted)]">{t("settings.network.external.failed")}</p>
        <button type="button" onClick={reload} className="btn-glass px-3 py-1.5 text-sub font-medium">
          {t("settings.network.ui.retry")}
        </button>
      </div>
    );
  }
  if (!view) {
    return <p className="text-ui text-[var(--text-muted)]">{t("settings.network.external.loading")}</p>;
  }

  const resetPort = view.web_port_reset_target ?? view.web_port_default;

  // 端口已改：应用正在新端口上重启，本页地址已失效——不轮询，直接给新地址
  if (portPhase === "switched") {
    const target = restartPort ?? portTarget ?? resetPort;
    return (
      <div className="css-glass !rounded-2xl px-6 py-10 text-center">
        <p className="text-body font-medium text-[var(--text)]">{t("settings.network.external.restarting", { port: target })}</p>
        <p className="mt-2 text-sub text-[var(--text-muted)]">
          {t("settings.network.external.restartHint")}
        </p>
        <a
          href={portUrl(target)}
          className="btn-accent mt-4 inline-block rounded-full px-4 py-1.5 text-sub font-semibold"
        >{t("settings.network.external.open", { url: portUrl(target) })}</a>
        <p className="mx-auto mt-4 max-w-md text-caption leading-5 text-[var(--text-faint)]">{t("settings.network.external.restartDocker", { port: target })}</p>
      </div>
    );
  }

  // 浏览器用的端口 ≠ 应用监听端口 = 确定有映射/反代夹在中间（见 browserPort）
  const seenPort = browserPort();
  const behindPortMapping = seenPort !== null && seenPort !== view.web_port;

  return (
    <SettingsSection
      title={t("settings.network.external.title")}
      action={<SettingsSaveStatus state={saveState} error={saveError} />}
    >
      <SettingsList>
        {/* 外部访问地址：未设置时说明换成一句引导，说清动作与收益 */}
        <SettingsRow stackOnMobile={locale === "en"}
          label={t("settings.network.external.address")}
          description={
            view.external_url
              ? t("settings.network.external.addressHint")
              : t("settings.network.external.useHint")
          }
          error={urlError}
        >
          <div className="relative">
            <input
              // key 随已保存值变化：一键填入/规范化（去尾斜杠）保存后，
              // 非受控输入框靠重挂载同步显示最新落库值
              key={view.external_url}
              type="text"
              defaultValue={view.external_url}
              onChange={(e) => setDraftEmpty(e.target.value.trim() === "")}
              onBlur={(e) => handleUrlBlur(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
              placeholder={currentOrigin}
              aria-label={t("settings.network.external.address")}
              className={`${SETTINGS_INPUT_CLASS} w-64 font-mono max-sm:w-40 ${
                !view.external_url && draftEmpty ? "pr-14" : ""
              }`}
            />
            {/* 框内快捷按钮：紧贴占位符（= 当前浏览器地址）末尾，点一下
                直接落库；保存成功后 external_url 非空，按钮随之消失 */}
            {!view.external_url && draftEmpty && (
              <button
                type="button"
                onClick={() => commit({ external_url: currentOrigin })}
                disabled={saveState === "saving"}
                title={t("settings.network.external.saveAs", { url: currentOrigin })}
                className="absolute right-1.5 top-1/2 -translate-y-1/2 rounded-md bg-white/[0.1] px-2 py-0.5 text-caption font-semibold text-[var(--text-muted)] transition-colors hover:bg-[var(--accent-soft)] hover:text-[var(--accent)] disabled:opacity-40"
              >
                {t("settings.network.external.use")}
              </button>
            )}
          </div>
        </SettingsRow>

        {/* 对外端口：唯一需要重启的字段，故不走失焦即存，改动要过二次确认。
            原理说明长且只在要改端口时才需要，留在 ⓘ 里 */}
        <SettingsRow stackOnMobile={locale === "en"}
          label={
            <LabelWithHelp
              label={t("settings.network.external.port")}
              help={
                <>
                  <p>{t("settings.network.external.portOverview", { defaultPort: view.web_port_default })}</p>
                  <p className="mt-1.5">{t.rich("settings.network.external.dockerHelp", { code: (chunks) => <code>{chunks}</code>, strong: (chunks) => <strong>{chunks}</strong> })}</p>
                  <p className="mt-1.5">{t("settings.network.external.hostHelp")}</p>
                  <p className="mt-1.5 text-[var(--text-muted)]">{t.rich("settings.network.external.envHelp", { code: (chunks) => <code>{chunks}</code>, strong: (chunks) => <strong>{chunks}</strong> })}</p>
                </>
              }
            />
          }
          description={
            <>
              {!view.web_port_configurable ? (
                t("settings.network.external.notConfigurable")
              ) : view.web_port_source === "setting" ? (
                <>
                  {t("settings.network.external.settingSource")}<button
                    type="button"
                    onClick={() => {
                      setPortTarget(null);
                      setPortPhase("confirming");
                    }}
                    className="ml-2 underline decoration-dotted underline-offset-2 hover:text-[var(--text-muted)]"
                  >{t("settings.network.external.restore", { defaultPort: resetPort })}</button>
                </>
              ) : view.web_port_source === "env" ? (
                t("settings.network.external.envSource")
              ) : (
                t("settings.network.external.defaultSource")
              )}
              {view.web_port_rejected !== null && (
                <span className="mt-1 block text-[var(--warn)]">{t("settings.network.external.rejected", { rejectedPort: view.web_port_rejected, currentPort: view.web_port })}</span>
              )}
            </>
          }
          error={portError}
        >
          {view.web_port_configurable && portDraft.trim() !== "" &&
            portDraft.trim() !== String(view.web_port) && (
              <button
                type="button"
                onClick={() => reviewPort(portDraft)}
                className={SETTINGS_BUTTON_CLASS}
              >
                {t("settings.network.external.change")}
              </button>
            )}
          <input
            key={view.web_port}
            type="text"
            inputMode="numeric"
            defaultValue={String(view.web_port)}
            disabled={!view.web_port_configurable}
            onChange={(e) => setPortDraft(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && reviewPort((e.target as HTMLInputElement).value)}
            aria-label={t("settings.network.external.port")}
            className={`${SETTINGS_INPUT_CLASS} w-24 font-mono`}
          />
        </SettingsRow>
      </SettingsList>

      {/* 端口二次确认：bridge 部署的映射同步是代码兜不住的部分，必须写明 */}
      {portPhase === "confirming" && (
        <div className="mt-4">
          <Banner
            tone={behindPortMapping ? "danger" : "warn"}
            title={
              portTarget === null
                ? t("settings.network.external.restoreTitle", { defaultPort: resetPort })
                : t("settings.network.external.changeTitle", { currentPort: view.web_port, targetPort: portTarget })
            }
            action={
              <span className="flex items-center gap-2">
                <button
                  type="button"
                  onClick={() => setPortPhase("idle")}
                  className={SETTINGS_BUTTON_CLASS}
                >
                  {t("settings.network.ui.cancel")}
                </button>
                <button
                  type="button"
                  onClick={() => void doSavePort()}
                  className={SETTINGS_PRIMARY_BUTTON_CLASS}
                >
                  {t("settings.network.external.confirm")}
                </button>
              </span>
            }
          >
            <p>{t("settings.network.external.confirmRestart", { url: portUrl(portTarget ?? resetPort) })}</p>
            {behindPortMapping ? (
              <p className="mt-1.5">{t("settings.network.external.mappedWarning", { seenPort: seenPort!, currentPort: view.web_port, targetPort: portTarget ?? resetPort })}</p>
            ) : (
              <p className="mt-1.5">{t("settings.network.external.dockerWarning", { targetPort: portTarget ?? resetPort })}</p>
            )}
          </Banner>
        </div>
      )}
    </SettingsSection>
  );
}

/**
 * 浏览器此刻实际访问的端口（地址栏省略端口时按协议补 80/443）。
 *
 * 它与应用监听端口一比就能确定性识别出「中间有端口映射或反向代理」：两者不等
 * 时，用户看到的端口不是应用自己监听的那个，改应用端口必然打断这条链路。相等
 * 则无法区分 host 网络与 1:1 映射（两种都长一样），只能给通用提醒。
 */
function browserPort(): number | null {
  if (typeof window === "undefined") return null;
  const explicit = window.location.port;
  if (explicit) return Number(explicit);
  return window.location.protocol === "https:" ? 443 : 80;
}

/**
 * 换端口后的候选访问地址：协议与主机沿用当前页面，只换端口。
 * host 网络/直连部署下这就是正确地址；bridge 部署下实际地址取决于宿主侧映射，
 * 因此所有用到它的地方都同时给出了映射需同步修改的说明。
 */
function portUrl(port: number): string {
  if (typeof window === "undefined") return `:${port}`;
  return `${window.location.protocol}//${window.location.hostname}:${port}`;
}

/** 字段名 + ⓘ 帮助（只给说明太长、放不进行内的字段用）。 */
function LabelWithHelp({ label, help }: { label: string; help: React.ReactNode }) {
  const t = useTranslations();

  return (
    <span className="flex shrink-0 items-center gap-1.5">
      <span className="text-body font-medium text-[var(--text)]">{label}</span>
      <Tooltip content={help} placement="top" maxWidth={340}>
        <button
          type="button"
          aria-label={t("settings.network.external.help")}
          className="flex text-[var(--text-faint)] transition-colors hover:text-[var(--text-muted)] focus-visible:text-[var(--text-muted)]"
        >
          <InfoIcon className="size-[15px]" />
        </button>
      </Tooltip>
    </span>
  );
}
