import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { AgentConversationView } from "@/components/agent-conversation-view";

/** 兜底标题；会话名在客户端 store，就绪后由视图内的 usePageTitle 覆盖为「{会话名}」。 */
export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("agent.conversation.pageTitle") };
}

/** AI 会话（/sessions/[id]）：ChatGPT 式对话页，会话数据在客户端 store。 */
export default async function SessionPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  // 会话切换时重建局部输入/改写状态，避免把上一会话尚未发送的内容带进来。
  return <AgentConversationView key={id} conversationId={id} />;
}
