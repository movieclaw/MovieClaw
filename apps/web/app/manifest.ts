import type { MetadataRoute } from "next";

import { getLocale, getTranslations } from "next-intl/server";

import { publicEnv } from "@/lib/env";

/**
 * PWA 应用清单（Next 会自动在 <head> 里注入 <link rel="manifest">）。
 * 主要服务 iOS「添加到主屏幕」：standalone 让它以独立 App 形态运行
 * （无浏览器地址栏），theme/background 取全站底色纯黑 #000000，冷启动
 * 的过渡帧不会闪白。图标为不透明满幅方图（iOS 自己裁圆角），maskable
 * 版本同一张图——字标只占画布 58%，留白天然满足安全区要求。
 */
export const dynamic = "force-dynamic";

export default async function manifest(): Promise<MetadataRoute.Manifest> {
  const t = await getTranslations("home.metadata");
  return {
    lang: await getLocale(),
    name: publicEnv.appName,
    short_name: publicEnv.appName,
    description: t("manifestDescription"),
    start_url: "/",
    display: "standalone",
    background_color: "#000000",
    theme_color: "#000000",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
}
