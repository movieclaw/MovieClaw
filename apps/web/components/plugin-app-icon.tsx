import type { ComponentType, SVGProps } from "react";

import { PuzzleIcon } from "@/components/icons";

/**
 * 插件网页的侧边栏图标（docs/design/plugin-web-pages.md §4.1）：
 * - manifest 标了 `purpose: "monochrome"`：当作遮罩，用当前文字颜色填充——选中、悬停、
 *   明暗主题的变化都跟内置图标一致，插件不用管颜色；
 * - 普通图标按原图显示；
 * - 没有图标：默认的拼图图标。
 * 尺寸由调用方的 className 定，与内置图标同一套（桌面 18px、手机 22px）。
 */
export function PluginAppIcon({
  src,
  monochrome,
  className,
}: {
  src: string | null;
  monochrome: boolean;
  className?: string;
}) {
  if (!src) return <PuzzleIcon className={className} />;
  if (monochrome) {
    const mask = `url("${src.replace(/"/g, "%22")}") center / contain no-repeat`;
    return (
      <span
        aria-hidden
        className={`inline-block bg-current ${className ?? ""}`}
        style={{ mask, WebkitMask: mask }}
      />
    );
  }
  return <img src={src} alt="" aria-hidden className={`object-contain ${className ?? ""}`} />;
}

const iconCache = new Map<string, ComponentType<SVGProps<SVGSVGElement>>>();

/**
 * 给主导航项用的图标组件（与内置项一样是 `icon: Component`）。按图标地址缓存：
 * 每次渲染都造一个新组件会让图标每帧都被卸载重挂。
 */
export function pluginAppIconComponent(
  src: string | null,
  monochrome: boolean,
): ComponentType<SVGProps<SVGSVGElement>> {
  const key = `${monochrome ? "m" : "c"}:${src ?? ""}`;
  let component = iconCache.get(key);
  if (!component) {
    const Icon = ({ className }: SVGProps<SVGSVGElement>) => (
      <PluginAppIcon src={src} monochrome={monochrome} className={className} />
    );
    Icon.displayName = "PluginAppNavIcon";
    component = Icon;
    iconCache.set(key, component);
  }
  return component;
}
