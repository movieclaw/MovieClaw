import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { SubscriptionsPage } from "@/components/subscriptions-page";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("nav.main.subscriptions") };
}

/** 我的订阅（/subscriptions）：按主题分流（银玻璃海报墙 / Netflix 行式布局）。 */
export default function SubscriptionsPageRoute() {
  return (
    <div className="flex h-full flex-col">
      <SubscriptionsPage />
    </div>
  );
}
