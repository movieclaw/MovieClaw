import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { SubscriptionInspectorView } from "@/components/subscription-inspector-view";

/** 兜底标题；片名要等接口返回，就绪后由视图内的 usePageTitle 覆盖为「{片名}」。 */
export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("subscription.inspector.pageTitle") };
}

/** 订阅详情分析页（/subscriptions/[id]）：追踪明细 + 活动时间线。
 * `?upgrade-run=1` 进入即打开「洗一轮版」弹层（库详情洗版入口的并轨跳转）。 */
export default async function SubscriptionDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { id } = await params;
  const query = await searchParams;
  return (
    <div className="flex h-full flex-col">
      <SubscriptionInspectorView
        id={Number(id)}
        autoOpenUpgradeRun={query["upgrade-run"] === "1"}
      />
    </div>
  );
}
