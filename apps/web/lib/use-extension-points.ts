"use client";

/**
 * 当前有登记的扩展点：设置侧栏据此决定插件驱动的分区出不出现（docs/design/cloud-storage.md §11.7）。
 *
 * 网盘（``drive-backends``）：装了存储插件、或者已经有网盘账号时出现——插件被卸载后用户仍要能看到
 * 账号与「需要安装插件」的提示。只有管理员会查（成员看不到这类分区）。查失败按「没有」处理。
 */

import { useEffect, useState } from "react";

import { getDriveStatus } from "@/lib/api/drives";
import type { ExtensionPoint } from "@/lib/mock-data";

const EMPTY: ReadonlySet<ExtensionPoint> = new Set();

export function useActiveExtensionPoints(enabled: boolean): ReadonlySet<ExtensionPoint> {
  const [active, setActive] = useState<ReadonlySet<ExtensionPoint>>(EMPTY);
  useEffect(() => {
    if (!enabled) return;
    let cancelled = false;
    void getDriveStatus()
      .then((status) => {
        if (cancelled) return;
        setActive(status.active || status.accounts > 0 ? new Set(["drive-backends"]) : EMPTY);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [enabled]);
  return active;
}
