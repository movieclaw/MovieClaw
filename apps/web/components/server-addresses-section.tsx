"use client";

import { useCallback, useEffect, useState } from "react";

import { StatusPill } from "@/components/cloud-push-ui";
import { XIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  addServerAddress,
  getServerAddresses,
  removeServerAddress,
  type ServerAddressItem,
  type ServerAddressKind,
} from "@/lib/api/app";
import { guessKind } from "@/lib/server-addresses";
import { formatRelativeTime } from "@/lib/time";

/**
 * 访问地址（设置 → 网络，docs/design/server-addresses.md）。
 *
 * 各端 App 拿这份地址簿，在家自动走内网、出门自动走外网，用户不用选。地址主要靠自动收集
 * （管理员登录后用过就记下；成员的请求不算，因为地址会发给全家的 App 去连），这里只做两件事：看看收集到了什么、补上自动收集不到的（典型是家里
 * DNS 把域名解析到内网——只看名字判断不出它是内网地址，要手动标一下）。外部访问地址也会列在
 * 这里，但改它在下面的「外部访问」里。
 */

function sourceText(item: ServerAddressItem): string {
  const seen = item.last_seen ? `${formatRelativeTime(item.last_seen)}用过` : null;
  switch (item.source) {
    case "manual":
      return ["手动添加，不会过期", seen].filter(Boolean).join(" · ");
    case "configured":
      return ["外部访问地址，在下方「外部访问」修改", seen].filter(Boolean).join(" · ");
    default:
      return seen ? `自动记录 · ${seen}` : "自动记录";
  }
}

function KindPill({ kind }: { kind: ServerAddressKind }) {
  return kind === "lan" ? (
    <StatusPill tone="ok" label="内网" />
  ) : (
    <StatusPill tone="info" label="外网" />
  );
}

export function ServerAddressesSection() {
  const [items, setItems] = useState<ServerAddressItem[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState("");
  const [kind, setKind] = useState<ServerAddressKind>("wan");
  const [kindTouched, setKindTouched] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [removeError, setRemoveError] = useState<string | null>(null);

  const reload = useCallback(() => {
    setFailed(false);
    getServerAddresses()
      .then((view) => setItems(view.addresses))
      .catch(() => setFailed(true));
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  const closeForm = () => {
    setAdding(false);
    setDraft("");
    setKind("wan");
    setKindTouched(false);
    setError(null);
  };

  const onDraft = (value: string) => {
    setDraft(value);
    setError(null);
    const guessed = guessKind(value);
    if (guessed && !kindTouched) setKind(guessed);
  };

  const save = async () => {
    const url = draft.trim();
    if (!/^https?:\/\/[^\s/]+/.test(url)) {
      setError("地址要以 http:// 或 https:// 开头");
      return;
    }
    setBusy(true);
    try {
      const view = await addServerAddress(url, kind);
      setItems(view.addresses);
      closeForm();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const remove = async (url: string) => {
    setRemoveError(null);
    try {
      setItems((await removeServerAddress(url)).addresses);
    } catch (e) {
      setRemoveError((e as Error).message);
    }
  };

  const guessed = guessKind(draft);
  const hint =
    guessed === "lan"
      ? "看起来是内网地址"
      : guessed === "wan"
        ? "看起来是外网地址；家里 DNS 把它解析到内网的话，改成内网"
        : null;

  return (
    <SettingsSection
      title="访问地址"
      description="各端 App 在家自动走内网、出门自动走外网。管理员用过的地址会自动出现在这里。"
      action={
        !adding && items !== null ? (
          <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={() => setAdding(true)}>
            添加地址
          </button>
        ) : null
      }
      footnote={removeError ?? undefined}
    >
      <SettingsList>
        {failed && (
          <SettingsRow label="读取访问地址失败" description="检查网络后重试">
            <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={reload}>
              重试
            </button>
          </SettingsRow>
        )}
        {items?.length === 0 && !adding && (
          <SettingsRow
            label="还没有记录到地址"
            description="用管理员账号在浏览器或 App 里登录一次，用的地址就会出现在这里。"
          />
        )}
        {items?.map((item) => (
          <SettingsRow
            key={item.url}
            leading={<KindPill kind={item.kind} />}
            label={<span className="break-all font-mono text-sub">{item.url}</span>}
            description={sourceText(item)}
          >
            {item.source !== "configured" && (
              <button
                type="button"
                aria-label={`删除 ${item.url}`}
                title="删除"
                onClick={() => void remove(item.url)}
                className="grid size-8 place-items-center rounded-full text-[var(--text-faint)] transition-colors hover:bg-white/[0.06] hover:text-[var(--text)]"
              >
                <XIcon className="size-4" />
              </button>
            )}
          </SettingsRow>
        ))}
        {adding && (
          <div className="space-y-3 px-4 py-3">
            <input
              autoFocus
              value={draft}
              onChange={(e) => onDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void save();
                if (e.key === "Escape") closeForm();
              }}
              placeholder="https://nas.home.example.com"
              aria-label="要添加的地址"
              className={`${SETTINGS_INPUT_CLASS} w-full font-mono`}
            />
            {error && <p className="text-sub text-[var(--danger)]">{error}</p>}
            <div className="flex flex-wrap items-center gap-2">
              <div role="radiogroup" aria-label="地址类型" className="flex gap-2">
                {(["lan", "wan"] as const).map((value) => (
                  <button
                    key={value}
                    type="button"
                    role="radio"
                    aria-checked={kind === value}
                    onClick={() => {
                      setKind(value);
                      setKindTouched(true);
                    }}
                    className={`${SETTINGS_BUTTON_CLASS} ${kind === value ? "!border-[var(--accent)] !text-[var(--text)]" : "!text-[var(--text-muted)]"}`}
                  >
                    {value === "lan" ? "内网（在家用）" : "外网（出门用）"}
                  </button>
                ))}
              </div>
              {hint && <span className="text-caption text-[var(--text-faint)]">{hint}</span>}
            </div>
            <div className="flex justify-end gap-2">
              <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={closeForm}>
                取消
              </button>
              <button
                type="button"
                className={SETTINGS_PRIMARY_BUTTON_CLASS}
                disabled={busy}
                onClick={() => void save()}
              >
                保存
              </button>
            </div>
          </div>
        )}
      </SettingsList>
    </SettingsSection>
  );
}
