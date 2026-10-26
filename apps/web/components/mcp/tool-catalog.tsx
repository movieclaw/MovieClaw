"use client";

import { useTranslations } from "next-intl";

import { useEffect, useMemo, useRef, useState } from "react";

import { CopyButton } from "@/components/copy-button";
import { Badge } from "@/components/mcp/ui";
import type { McpToolCommand, McpToolParameter, McpToolPreview } from "@/lib/api/mcp";

/**
 * 工具目录：这个端点到底把什么交给了模型。
 *
 * 旧版是一个塞满截断文本的小滚动框——扫不了、搜不了、也看不到参数。开发者在这
 * 里真正要回答的问题只有三个，所以界面就按这三个问题组织：
 *
 * 1. **有没有我要的那个工具** → 顶部搜索，工具名与说明一起匹配；
 * 2. **这个工具属于哪个服务** → 按服务分组，组头带数量，能整组折叠；
 * 3. **它要什么参数** → 点开一行就是参数表（名称/类型/必填/落点/说明），
 *    参数名可直接复制。这是判断「模型能不能用对」的唯一依据。
 *
 * 折叠模式（一个服务一个工具）多一层：工具本身只有 command + params 两个参数，
 * 真正的信息是「这个服务覆盖了哪些命令」。那份清单在协议面是写给模型看的一大段
 * 自然语言，照搬到页面上就是几百行散文墙，所以后端把它结构化成 ``commands``，
 * 这里按命令表渲染，并与顶部搜索联动。
 */
export function ToolCatalog({ tools }: { tools: McpToolPreview[] }) {
  const t = useTranslations();
  const [query, setQuery] = useState("");
  const [only, setOnly] = useState<"all" | "read" | "write">("all");
  const [openTool, setOpenTool] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const searchRef = useRef<HTMLInputElement>(null);

  /** `/` 聚焦搜索：开发者在文档站与控制台里的肌肉记忆。输入框内不劫持。 */
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing = target && /^(INPUT|TEXTAREA)$/.test(target.tagName);
      if (e.key === "/" && !typing) {
        e.preventDefault();
        searchRef.current?.focus();
      }
      if (e.key === "Escape" && document.activeElement === searchRef.current) {
        setQuery("");
        searchRef.current?.blur();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const groups = useMemo(() => {
    const keyword = query.trim().toLowerCase();
    const matched = tools.filter((t) => {
      if (only === "read" && !t.read_only) return false;
      if (only === "write" && t.read_only) return false;
      if (!keyword) return true;
      return (
        t.name.toLowerCase().includes(keyword) ||
        t.description.toLowerCase().includes(keyword) ||
        // 折叠模式下用户搜的多半是命令名（服务名只有寥寥几个，搜它没意义）
        t.commands.some((c) => `${c.name} ${c.summary}`.toLowerCase().includes(keyword))
      );
    });
    const byService = new Map<string, McpToolPreview[]>();
    for (const tool of matched) {
      const list = byService.get(tool.service) ?? [];
      list.push(tool);
      byService.set(tool.service, list);
    }
    return [...byService.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [tools, query, only]);

  const shown = groups.reduce((sum, [, list]) => sum + list.length, 0);

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <div className="field-shell relative flex min-w-[220px] flex-1 items-center rounded-lg border border-white/[0.08] bg-black/25 pr-2">
          <input
            ref={searchRef}
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t("settings.mcp.controls.searchTools")}
            // 藏掉 WebKit 给 type=search 自带的清除叉：右侧已经有我们自己的清除按钮，
            // 两个叉并排出现是明显的瑕疵
            className="w-full bg-transparent px-3 py-1.5 text-sub outline-none placeholder:text-[var(--text-faint)] [&::-webkit-search-cancel-button]:appearance-none"
          />
          {query ? (
            <button
              type="button"
              onClick={() => setQuery("")}
              aria-label={t("settings.mcp.controls.clearSearch")}
              className="shrink-0 px-1 text-[var(--text-faint)] hover:text-[var(--text)]"
            >
              ×
            </button>
          ) : (
            <kbd className="shrink-0 rounded border border-white/[0.12] px-1.5 text-[11px] text-[var(--text-faint)]">
              /
            </kbd>
          )}
        </div>

        {/* 只读 / 会改动：判断「这个端点危不危险」最快的一刀 */}
        <div className="flex shrink-0 items-center gap-1">
          {(
            [
              ["all", t("settings.mcp.controls.all")],
              ["read", t("settings.mcp.controls.readOnly")],
              ["write", t("settings.mcp.controls.write")],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              type="button"
              onClick={() => setOnly(id)}
              className={`rounded-full border px-2.5 py-1 text-caption transition-colors ${
                only === id
                  ? "border-[var(--accent)] bg-white/[0.06] text-[var(--text)]"
                  : "border-white/[0.12] text-[var(--text-muted)] hover:text-[var(--text)]"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        <span className="shrink-0 text-caption tabular-nums text-[var(--text-faint)]">
          {shown === tools.length ? t("settings.mcp.controls.toolsCount", { count: tools.length }) : t("settings.mcp.controls.toolFraction", { shown, total: tools.length })}
        </span>
      </div>

      {shown === 0 && (
        <p className="py-6 text-center text-sub text-[var(--text-muted)]">
          {t("settings.mcp.controls.noMatchingTools", { query })}
        </p>
      )}

      {groups.map(([service, list]) => {
        const folded = collapsed.has(service);
        return (
          <section key={service} className="overflow-hidden rounded-xl border border-white/[0.07]">
            <button
              type="button"
              onClick={() =>
                setCollapsed((prev) => {
                  const next = new Set(prev);
                  if (next.has(service)) next.delete(service);
                  else next.add(service);
                  return next;
                })
              }
              className="flex w-full items-center gap-2 bg-white/[0.03] px-3 py-2 text-left hover:bg-white/[0.05]"
            >
              <span className="text-[var(--text-faint)]">{folded ? "▸" : "▾"}</span>
              <span className="font-mono text-sub text-[var(--text)]">{service}</span>
              <span className="text-caption text-[var(--text-faint)]">{t("settings.mcp.controls.toolsCount", { count: list.length })}</span>
            </button>

            {!folded && (
              <ul className="divide-y divide-white/[0.05]">
                {list.map((tool) => {
                  const open = openTool === tool.name;
                  return (
                    <li key={tool.name}>
                      <button
                        type="button"
                        onClick={() => setOpenTool(open ? null : tool.name)}
                        className="flex w-full items-start gap-3 px-3 py-2 text-left hover:bg-white/[0.03]"
                      >
                        {/* 两行：工具名与说明各占一行。挤成一行时说明必然被截断成
                            半句话，而「这个工具是干嘛的」恰恰是这一屏最该看清的东西 */}
                        <div className="min-w-0 flex-1 space-y-0.5">
                          <div className="flex flex-wrap items-center gap-2">
                            <span className="font-mono text-sub text-[var(--accent)]">
                              {tool.name}
                            </span>
                            {tool.read_only && <Badge>{t("settings.mcp.controls.readOnly")}</Badge>}
                            {tool.destructive && <Badge tone="danger">{t("settings.mcp.controls.destructive")}</Badge>}
                          </div>
                          <p className="text-caption leading-relaxed text-[var(--text-muted)]">
                            {tool.summary || tool.description}
                          </p>
                        </div>
                        <span className="shrink-0 pt-0.5 text-caption tabular-nums text-[var(--text-faint)]">
                          {tool.commands.length > 0
                            ? t("settings.mcp.controls.commandBadge", { count: tool.commands.length })
                            : t("settings.mcp.controls.parameterBadge", { count: tool.parameters.length })}
                        </span>
                      </button>

                      {open && (
                        <div className="space-y-3 border-t border-white/[0.05] bg-black/20 px-3 py-3">
                          <p className="text-caption leading-relaxed text-[var(--text-muted)]">
                            {tool.description}
                          </p>
                          {tool.commands.length > 0 ? (
                            <CommandTable commands={tool.commands} keyword={query.trim().toLowerCase()} />
                          ) : tool.parameters.length === 0 ? (
                            <p className="text-caption text-[var(--text-faint)]">{t("settings.mcp.controls.noParameters")}</p>
                          ) : (
                            <ParameterTable parameters={tool.parameters} />
                          )}
                          <div className="flex items-center gap-2">
                            <CopyButton
                              text={tool.name}
                              label={t("settings.mcp.controls.copyToolName")}
                              className="btn-glass px-2.5 py-1 text-caption"
                            />
                            <CopyButton
                              text={JSON.stringify(
                                {
                                  name: tool.name,
                                  arguments:
                                    tool.commands.length > 0
                                      ? { command: tool.commands[0].name, params: {} }
                                      : Object.fromEntries(
                                          tool.parameters
                                            .filter((p) => p.required)
                                            .map((p) => [p.name, `<${p.type}>`]),
                                        ),
                                },
                                null,
                                2,
                              )}
                              label={t("settings.mcp.controls.copyExample")}
                              className="btn-glass px-2.5 py-1 text-caption"
                            />
                          </div>
                        </div>
                      )}
                    </li>
                  );
                })}
              </ul>
            )}
          </section>
        );
      })}
    </div>
  );
}

/**
 * 折叠模式的命令表：一行一条命令，带参数名与风险标记。
 *
 * 与顶部搜索联动——用户在折叠端点里搜的几乎一定是命令名，命中时只列命中的那几条，
 * 否则一个服务动辄五十多条，翻起来和散文墙没区别。
 *
 * 窄屏改成堆叠块：390px 上三列表格会把 ``items.list-media-source-annotation-candidates``
 * 这样的标识符按字符掰成五行，比没有排版更难读。标识符宁可占满一行也不能断词。
 */
function CommandTable({ commands, keyword }: { commands: McpToolCommand[]; keyword: string }) {
  const t = useTranslations();
  const matched = keyword
    ? commands.filter((c) => `${c.name} ${c.summary}`.toLowerCase().includes(keyword))
    : commands;
  const list = matched.length > 0 ? matched : commands;

  const dangerMark = (command: McpToolCommand) =>
    command.dangerous ? (
      <span
        className="ml-1 text-[var(--danger)]"
        title={
          command.dangerous === "destructive" ? t("settings.mcp.controls.destructiveHint") : t("settings.mcp.controls.clearHint")
        }
      >
        ⚠
      </span>
    ) : null;

  const summaryOf = (command: McpToolCommand) => (
    <>
      {command.summary || "—"}
      {command.is_job && (
        <span className="ml-1 text-[var(--text-faint)]">{t("settings.mcp.controls.backgroundJob")}</span>
      )}
    </>
  );

  return (
    <div>
      <p className="pb-1 text-caption text-[var(--text-faint)]">
        {list.length === commands.length
          ? t("settings.mcp.controls.commandCaption", { count: commands.length })
          : t("settings.mcp.controls.matchingCommands", { query: keyword, shown: list.length, total: commands.length })}
      </p>

      {/* 窄屏：堆叠 */}
      <ul className="divide-y divide-white/[0.05] sm:hidden">
        {list.map((command) => (
          <li key={command.name} className="space-y-0.5 py-2 text-caption">
            <p className="font-mono text-[var(--text)]">
              {command.name}
              {dangerMark(command)}
            </p>
            <p className="text-[var(--text-muted)]">{summaryOf(command)}</p>
            {command.params.length > 0 && (
              <p className="font-mono text-[11px] text-[var(--text-faint)]">
                {command.params.join(", ")}
              </p>
            )}
          </li>
        ))}
      </ul>

      {/* 宽屏：定宽三列。自动布局会被某一条超长的 params 拽歪，整张表就没法一眼扫下来 */}
      <table className="hidden w-full table-fixed text-caption sm:table">
        <colgroup>
          <col className="w-[26%]" />
          <col className="w-[42%]" />
          <col className="w-[32%]" />
        </colgroup>
        <thead>
          <tr className="text-left text-[var(--text-faint)]">
            <th className="pb-1 font-normal">{t("settings.mcp.controls.command")}</th>
            <th className="pb-1 font-normal">{t("settings.mcp.controls.description")}</th>
            <th className="pb-1 font-normal">{t("settings.mcp.controls.paramsFields")}</th>
          </tr>
        </thead>
        <tbody className="align-top">
          {list.map((command) => (
            <tr key={command.name} className="border-t border-white/[0.05]">
              <td className="py-1.5 pr-3">
                <span className="font-mono break-all text-[var(--text)]">{command.name}</span>
                {dangerMark(command)}
              </td>
              <td className="py-1.5 pr-3 text-[var(--text-muted)]">{summaryOf(command)}</td>
              <td className="py-1.5 font-mono text-[11px] break-all text-[var(--text-faint)]">
                {command.params.length > 0 ? command.params.join(", ") : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/**
 * 展开模式的参数表。窄屏同样改成堆叠块：四列（参数/类型/位置/说明）在 390px 上
 * 每列都不够放下一个标识符。
 */
function ParameterTable({ parameters }: { parameters: McpToolParameter[] }) {
  const t = useTranslations();
  const required = (param: McpToolParameter) =>
    param.required ? (
      <span className="ml-0.5 text-[var(--danger)]" title={t("settings.mcp.controls.required")}>
        *
      </span>
    ) : null;

  const options = (param: McpToolParameter) =>
    param.options.length > 0 ? (
      <span className="mt-0.5 block font-mono text-[11px] text-[var(--text-faint)]">
        {t("settings.mcp.controls.options")}{param.options.join(" / ")}
      </span>
    ) : null;

  return (
    <div>
      <ul className="divide-y divide-white/[0.05] sm:hidden">
        {parameters.map((param) => (
          <li key={param.name} className="space-y-0.5 py-2 text-caption">
            <p className="flex flex-wrap items-baseline gap-x-2">
              <span className="font-mono text-[var(--text)]">
                {param.name}
                {required(param)}
              </span>
              <span className="font-mono text-[11px] text-[var(--text-muted)]">{param.type}</span>
              {param.location && (
                <span className="text-[11px] text-[var(--text-faint)]">{param.location}</span>
              )}
            </p>
            <p className="text-[var(--text-muted)]">
              {param.description || "—"}
              {options(param)}
            </p>
          </li>
        ))}
      </ul>

      <table className="hidden w-full text-caption sm:table">
        <thead>
          <tr className="text-left text-[var(--text-faint)]">
            <th className="pb-1 font-normal">{t("settings.mcp.controls.parameter")}</th>
            <th className="pb-1 font-normal">{t("settings.mcp.controls.type")}</th>
            <th className="pb-1 font-normal">{t("settings.mcp.controls.location")}</th>
            <th className="pb-1 font-normal">{t("settings.mcp.controls.description")}</th>
          </tr>
        </thead>
        <tbody className="align-top">
          {parameters.map((param) => (
            <tr key={param.name} className="border-t border-white/[0.05]">
              <td className="py-1.5 pr-3">
                <span className="font-mono text-[var(--text)]">{param.name}</span>
                {required(param)}
              </td>
              <td className="py-1.5 pr-3 font-mono text-[var(--text-muted)]">{param.type}</td>
              <td className="py-1.5 pr-3 text-[var(--text-faint)]">{param.location}</td>
              <td className="py-1.5 text-[var(--text-muted)]">
                {param.description || "—"}
                {options(param)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
