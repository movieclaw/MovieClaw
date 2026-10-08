"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { Toggle } from "@/components/cloud-push-ui";
import { ExternalAccessSection } from "@/components/external-access-section";
import { ChevronDownIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSaveStatus,
  SettingsSection,
  SettingsTabs,
} from "@/components/settings-ui";
import { Tooltip } from "@/components/tooltip";
import {
  type NetworkConfigPayload,
  type NetworkConfigView,
  type NetworkTestResult,
  type ProxyMode,
  getNetworkConfig,
  saveNetworkConfig,
  testNetworkService,
} from "@/lib/api/network";

/**
 * 网络设置（设置 → 网络）。
 *
 * 交互模型：**自动保存，立即生效**。开关/模式点击即落库；地址输入框失焦落库；
 * 没有「保存」按钮，也就不存在「先保存才能测试」的中间态——「测试」随时可点，
 * 点击前会先冲刷未落库的修改。说明是行内一行灰字，长的原理性说明放小节脚注或折叠行里。
 *
 * 小节：
 *   代理 —— 方式三选一 + （手动）地址 /（环境变量）探测结果
 *   走代理的服务 —— 内置服务开关 + 每行连通性测试；PT 站点单独一张卡
 *   外部访问 —— 外部访问地址 / 对外端口（原「应用」分区迁来，
 *     见 external-access-section.tsx）
 *   镜像 / 反代地址 —— 高级项，默认折叠，沉底
 */

type TestState = { state: "pending" } | { state: "done"; result: NetworkTestResult };

const PROXY_URL_PATTERN = /^(http|https|socks5|socks5h):\/\//i;

const PROXY_MODES: readonly { id: ProxyMode; label: string }[] = [
  { id: "off", label: "不使用" },
  { id: "env", label: "环境变量" },
  { id: "manual", label: "手动" },
];

/** 代理方式的行内说明：随当前选中的方式换一句 */
const PROXY_MODE_HINT: Record<ProxyMode, string> = {
  off: "全部服务直连",
  env: "代理地址取自 HTTPS_PROXY / ALL_PROXY 等环境变量",
  manual: "直接填写代理地址，支持 http 与 socks5",
};

/** 地址类输入框：等宽字体，窄屏收窄 */
const URL_INPUT_CLASS = `${SETTINGS_INPUT_CLASS} w-64 font-mono max-sm:w-40`;

export function NetworkConfigSection() {
  const [view, setView] = useState<NetworkConfigView | null>(null);
  const [failed, setFailed] = useState(false);
  const [form, setForm] = useState<NetworkConfigPayload | null>(null);
  // 保存状态：idle 不占视觉；saving/saved/error 在页面右上角以一行小字反馈
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [saveError, setSaveError] = useState<string | null>(null);
  const [proxyUrlError, setProxyUrlError] = useState<string | null>(null);
  const [mirrorErrors, setMirrorErrors] = useState<Record<string, string>>({});
  const [tests, setTests] = useState<Record<string, TestState>>({});
  const [advancedOpen, setAdvancedOpen] = useState(false);
  // 保存请求串行化：快速连点开关时按顺序落库，避免旧请求覆盖新配置
  const saveChain = useRef<Promise<unknown>>(Promise.resolve());
  const savedTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const reload = useCallback(() => {
    setFailed(false);
    getNetworkConfig()
      .then((v) => {
        setView(v);
        setForm({
          proxy_mode: v.proxy_mode,
          proxy_url: v.proxy_url,
          proxy_services: v.proxy_services,
          tmdb_api_base_url: v.tmdb_api_base_url,
          tmdb_image_base_url: v.tmdb_image_base_url,
          douban_api_base_url: v.douban_api_base_url,
        });
      })
      .catch(() => setFailed(true));
  }, []);

  useEffect(() => {
    reload();
    return () => {
      if (savedTimer.current) clearTimeout(savedTimer.current);
    };
  }, [reload]);

  /** 落库一份完整配置（串行）。手动模式地址为空/非法时只改表单不落库。 */
  const commit = useCallback((next: NetworkConfigPayload) => {
    setForm(next);
    if (next.proxy_mode === "manual") {
      const url = next.proxy_url.trim();
      if (!url) {
        // 刚切到手动、地址还没填：等地址失焦后再落库
        setProxyUrlError(null);
        return;
      }
      if (!PROXY_URL_PATTERN.test(url)) {
        setProxyUrlError("地址需以 http:// 、socks5:// 或 socks5h:// 开头");
        return;
      }
    }
    setProxyUrlError(null);
    setSaveState("saving");
    setSaveError(null);
    saveChain.current = saveChain.current.then(() =>
      saveNetworkConfig(next)
        .then((v) => {
          setView(v);
          // 后端会把镜像地址规范化（补 /3、/t/p，去末尾斜杠），回填让用户
          // 看到实际生效的地址；值没变就不会触发输入框重挂载
          setForm((prev) =>
            prev
              ? {
                  ...prev,
                  tmdb_api_base_url: v.tmdb_api_base_url,
                  tmdb_image_base_url: v.tmdb_image_base_url,
                }
              : prev,
          );
          // 出口配置变了，旧的测试结论不再可信
          setTests({});
          setSaveState("saved");
          if (savedTimer.current) clearTimeout(savedTimer.current);
          savedTimer.current = setTimeout(() => setSaveState("idle"), 2000);
        })
        .catch((e) => {
          setSaveState("error");
          setSaveError((e as Error).message);
        }),
    );
  }, []);

  const runTest = useCallback(
    (service: string) => {
      setTests((prev) => ({ ...prev, [service]: { state: "pending" } }));
      // 先冲刷在途的保存，测试才反映用户此刻看到的配置
      void saveChain.current.then(() =>
        testNetworkService(service)
          .then((result) => setTests((prev) => ({ ...prev, [service]: { state: "done", result } })))
          .catch((e) =>
            setTests((prev) => ({
              ...prev,
              [service]: {
                state: "done",
                result: { ok: false, latency_ms: null, message: (e as Error).message },
              },
            })),
          ),
      );
    },
    [],
  );

  const [builtinServices, siteServices] = useMemo(() => {
    const all = view?.services ?? [];
    return [all.filter((s) => !s.id.startsWith("site:")), all.filter((s) => s.id.startsWith("site:"))];
  }, [view]);

  if (failed) {
    return (
      <div className="flex items-center gap-3">
        <p className="text-ui text-[var(--text-muted)]">网络配置加载失败</p>
        <button type="button" onClick={reload} className="btn-glass px-3 py-1.5 text-sub font-medium">
          重试
        </button>
      </div>
    );
  }
  if (!view || !form) {
    return <p className="text-ui text-[var(--text-muted)]">正在加载网络配置…</p>;
  }

  const proxyActive =
    form.proxy_mode === "manual"
      ? PROXY_URL_PATTERN.test(form.proxy_url.trim())
      : form.proxy_mode === "env" && Boolean(view.env_proxy_detected);

  const toggleService = (id: string) =>
    commit({
      ...form,
      proxy_services: form.proxy_services.includes(id)
        ? form.proxy_services.filter((s) => s !== id)
        : [...form.proxy_services, id],
    });

  const serviceRows = (services: typeof builtinServices) =>
    services.map((service) => (
      <ServiceRow
        key={service.id}
        label={service.label}
        description={service.description}
        enabled={form.proxy_services.includes(service.id)}
        toggleDisabled={!proxyActive}
        test={tests[service.id]}
        onTest={() => runTest(service.id)}
        onToggle={() => toggleService(service.id)}
      />
    ));

  return (
    <div className="space-y-10">
      {/* —— 代理 —— */}
      <SettingsSection
        title="代理"
        description="改动立即生效，无需重启。"
        // 保存状态挂在首个小节标题行右侧：不单占一行
        action={<SettingsSaveStatus state={saveState} error={saveError} savedLabel="已保存，立即生效" />}
      >
        <SettingsList>
          <SettingsRow label="代理方式" description={PROXY_MODE_HINT[form.proxy_mode]}>
            <SettingsTabs
              tabs={PROXY_MODES}
              value={form.proxy_mode}
              onChange={(mode) => commit({ ...form, proxy_mode: mode })}
            />
          </SettingsRow>

          {form.proxy_mode === "env" && (
            <SettingsRow
              label="环境变量探测"
              description={
                view.env_proxy_detected
                  ? undefined
                  : "未检测到 HTTPS_PROXY / HTTP_PROXY / ALL_PROXY。Docker 部署可通过 -e HTTPS_PROXY=… 传入；或改用「手动」直接填写。"
              }
            >
              {view.env_proxy_detected ? (
                <span className="font-mono text-sub text-[var(--text)]">{view.env_proxy_detected}</span>
              ) : (
                <span className="text-sub text-[var(--warn)]">未发现代理地址</span>
              )}
            </SettingsRow>
          )}

          {form.proxy_mode === "manual" && (
            <SettingsRow
              label="代理地址"
              description={
                <>
                  Clash / sing-box 等的 HTTP 或 SOCKS5 入站地址；要由代理端解析域名（对抗 DNS
                  污染）用 <code>socks5h://</code>。
                  {!form.proxy_url.trim() && " 填写后自动保存生效。"}
                </>
              }
              error={proxyUrlError}
            >
              <input
                type="text"
                defaultValue={form.proxy_url}
                onBlur={(e) => commit({ ...form, proxy_url: e.target.value.trim() })}
                onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
                placeholder="socks5://192.168.1.2:7891"
                aria-label="代理地址"
                className={URL_INPUT_CLASS}
              />
            </SettingsRow>
          )}
        </SettingsList>
      </SettingsSection>

      {/* —— 走代理的服务 —— */}
      <SettingsSection
        title="走代理的服务"
        description={
          <>
            按服务选择流量是否经过上面的代理；内网的下载器、媒体服务器永远直连，不在此列。
            {!proxyActive && (
              <span className="block text-[var(--text-faint)]">
                当前无可用代理，开关已禁用（测试仍可用，测的是直连/镜像的连通性）
              </span>
            )}
          </>
        }
        footnote="经验默认：TMDB、图片回源与 Fanart.tv 走代理（国内被墙）；豆瓣与 PT 站直连通常更快，且部分 PT 站风控在意出口 IP，按需开启。「测试」按当前配置发一次真实请求，熔断中的服务测通后立即恢复。"
      >
        <SettingsList>{serviceRows(builtinServices)}</SettingsList>
      </SettingsSection>

      {/* —— PT 站点（有已配置站点才出现）—— */}
      {siteServices.length > 0 && (
        <SettingsSection
          title="PT 站点"
          description="每个已配置的站点独立控制。国内 PT 站直连通常更快，且部分站点风控在意出口 IP——只给确实需要翻墙的站点开代理。"
        >
          <SettingsList>{serviceRows(siteServices)}</SettingsList>
        </SettingsSection>
      )}

      {/* —— 外部访问：外部访问地址 / 对外端口（独立组件，走应用配置接口）—— */}
      <ExternalAccessSection />

      {/* —— 高级：TMDB 镜像地址（默认折叠，行组里的折叠行）—— */}
      <SettingsSection title="高级">
        <SettingsList>
          <div>
            <button
              type="button"
              onClick={() => setAdvancedOpen((v) => !v)}
              aria-expanded={advancedOpen}
              className="flex min-h-[56px] w-full items-center gap-4 px-4 py-3 text-left transition-colors hover:bg-white/[0.03]"
            >
              <span className="min-w-0 flex-1">
                <span className="block text-body font-medium text-[var(--text)]">TMDB 镜像地址</span>
                <span className="mt-0.5 block truncate text-caption text-[var(--text-faint)]">
                  不走代理的替代方案
                </span>
              </span>
              <ChevronDownIcon
                className={`size-4 shrink-0 text-[var(--text-faint)] transition-transform ${
                  advancedOpen ? "rotate-180" : ""
                }`}
              />
            </button>
            {/* 高度过渡用 grid 0fr → 1fr；内容常驻挂载，收起时 inert 防止键盘 Tab 进去 */}
            <div
              className={`grid transition-[grid-template-rows] duration-200 ease-out ${
                advancedOpen ? "grid-rows-[1fr]" : "grid-rows-[0fr]"
              }`}
            >
              <div className="overflow-hidden" inert={!advancedOpen}>
                <p className="px-4 pb-3 text-caption leading-5 text-[var(--text-muted)]">
                  解决「TMDB 不可达」有两条独立的路：代理让流量绕行（访问地址不变）；镜像把官方地址换成一个可直连的反代地址。
                  有代理就不用配镜像，二选一即可；两者都设置时，请求会经代理去访问镜像地址。
                  镜像可以是自建反代（nginx / Cloudflare Workers）或公共镜像，注意公共镜像会经手你的 API Key。
                </p>
                <div className="divide-y divide-[var(--line)] border-t border-[var(--line)]">
                  {(
                    [
                      [
                        "tmdb_api_base_url",
                        "接口地址",
                        "替换 api.themoviedb.org（发现页/搜索/订阅建档用）。只填域名会自动补 /3；留空使用默认值",
                      ],
                      [
                        "tmdb_image_base_url",
                        "图床地址",
                        "替换 image.tmdb.org（海报/背景图回源用）。只填域名会自动补 /t/p；留空使用默认值",
                      ],
                    ] as const
                  ).map(([field, label, help]) => (
                    <SettingsRow
                      key={field}
                      label={label}
                      description={help}
                      error={mirrorErrors[field] || null}
                    >
                      <input
                        // key 绑已落库的值：后端补全后回填时重挂载显示新值，
                        // 用户打字过程中（值未提交）不会被打断
                        key={`${field}:${form[field]}`}
                        type="text"
                        defaultValue={form[field]}
                        onBlur={(e) => {
                          const value = e.target.value.trim();
                          if (value && !/^https?:\/\//.test(value)) {
                            setMirrorErrors((prev) => ({ ...prev, [field]: "需以 http(s):// 开头" }));
                            return;
                          }
                          setMirrorErrors((prev) => ({ ...prev, [field]: "" }));
                          commit({ ...form, [field]: value });
                        }}
                        onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
                        placeholder={view.mirror_defaults[field] ?? ""}
                        aria-label={`TMDB ${label}`}
                        className={URL_INPUT_CLASS}
                      />
                    </SettingsRow>
                  ))}
                </div>
              </div>
            </div>
          </div>
        </SettingsList>
      </SettingsSection>
    </div>
  );
}

/** 一行服务：名称 + 说明 ｜ 测试结果 ｜ 测试 ｜ 开关。 */
function ServiceRow({
  label,
  description,
  enabled,
  toggleDisabled,
  test,
  onTest,
  onToggle,
}: {
  label: string;
  description: string;
  enabled: boolean;
  /** 无可用代理时禁用开关（拨了也不生效）；测试不受影响——直连也值得测 */
  toggleDisabled: boolean;
  test: TestState | undefined;
  onTest: () => void;
  onToggle: () => void;
}) {
  const pending = test?.state === "pending";
  const result = test?.state === "done" ? test.result : null;
  return (
    <SettingsRow label={label} description={description}>
      {pending && <span className="text-sub text-[var(--text-faint)]">测试中…</span>}
      {result && (
        <Tooltip content={result.message} placement="top">
          <span
            className={`flex items-center gap-1.5 text-sub ${
              result.ok ? "text-[var(--ok)]" : "text-[var(--danger)]"
            }`}
          >
            <span
              className={`size-1.5 rounded-full ${result.ok ? "bg-[var(--ok)]" : "bg-[var(--danger)]"}`}
            />
            {result.ok ? (result.latency_ms !== null ? `连通 · ${result.latency_ms} ms` : "连通") : "不通"}
          </span>
        </Tooltip>
      )}
      <button type="button" onClick={onTest} disabled={pending} className={SETTINGS_BUTTON_CLASS}>
        测试
      </button>
      <span className={toggleDisabled ? "opacity-40" : undefined}>
        <Toggle
          checked={enabled}
          disabled={toggleDisabled}
          label={`${label} 走代理`}
          onChange={onToggle}
        />
      </span>
    </SettingsRow>
  );
}
