"use client";

import { useEffect, useRef } from "react";

/**
 * 行级深链（插件列表 ?module= 的同款手法，推广给别的设置页）：地址栏带 ?<param>=<键>
 * 到达这一页时，等列表渲染好（ready），滚到 ``[<attr>="键"]`` 那一行并高亮约两秒。
 *
 * 参数用完即清（原生 history.replaceState，不触发 Next 重渲染、不留历史记录——同
 * lib/use-tab-param.ts）：刷新不常亮，收藏/分享当前页也不带这个一次性参数。
 */

/** 行的定位锚点样式：高亮时描一道强调色的内环（与插件列表行同规格） */
export const ROW_ANCHOR_CLASS =
  "scroll-mt-24 transition-shadow duration-500 data-[highlight=true]:shadow-[inset_0_0_0_2px_var(--accent)]";

export function useRowAnchor(param: string, attr: string, ready: boolean) {
  /** ?param= 要定位的行键：列表到了之后处理一次 */
  const targetRef = useRef<string | null>(null);

  // 地址栏只在挂载时读一次（SSR 阶段没有 window，同 useTabParam）
  useEffect(() => {
    const value = new URLSearchParams(window.location.search).get(param);
    if (!value) return;
    targetRef.current = value;
    const url = new URL(window.location.href);
    url.searchParams.delete(param);
    window.history.replaceState(window.history.state, "", url);
    // param 是调用方的字面量常量；地址栏只在挂载时读一次
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 只处理一次；行还没渲染出来（ready=false）时等数据到了再试
  useEffect(() => {
    const target = targetRef.current;
    if (!target || !ready) return;
    targetRef.current = null;
    window.setTimeout(() => {
      const row = document.querySelector<HTMLElement>(`[${attr}="${CSS.escape(target)}"]`);
      if (!row) return;
      row.scrollIntoView({ block: "center", behavior: "smooth" });
      row.dataset.highlight = "true";
      window.setTimeout(() => delete row.dataset.highlight, 2400);
    }, 80);
    // attr 是调用方的字面量常量；定时器不随重渲染取消（数据到了本身就触发一次重渲染）
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready]);
}
