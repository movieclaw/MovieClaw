import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { NewTask } from "@/components/new-task";

/**
 * AI 新任务（/new，docs/design/web-themes.md §6）：
 * Netflix 主题把 AI 入口从首页收进顶栏「＋ 新任务」与这里；银玻璃主题下
 * 侧栏「新会话」仍指向 /（本路由作为双主题通用的直达地址并存）。
 * 与首页共用 NewTask 组件，内容完全一致。
 */
export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("nav.cinema.newTask") };
}

export default function NewTaskPage() {
  return <NewTask />;
}
