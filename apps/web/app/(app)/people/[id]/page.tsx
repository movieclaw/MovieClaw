import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { PersonDetailView } from "@/components/person-detail-view";

/** 兜底标题；人名要等接口返回，就绪后由视图内的 usePageTitle 覆盖。 */
export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("media.person.person") };
}

/**
 * 人物页（/people/[id]，id = TMDB 影人 ID）：
 * 回答「**我库里**这个人是谁、他参演/执导过我拥有的哪些片」。
 * 数据全部来自本地表，不联网——与条目详情页同一条自足原则。
 */
export default async function PersonPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return (
    <div className="flex h-full flex-col">
      <PersonDetailView tmdbPersonId={id} />
    </div>
  );
}
