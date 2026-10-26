import { appTranslator } from "./i18n/translate.ts";
import type { AppLocale } from "./i18n/negotiate.ts";
import { formatList } from "./i18n/format.ts";
import type { ConfirmCheckbox, ConfirmOptions } from "@/components/feedback";

/**
 * 扫描库 / 刷新元数据的二次确认文案——三处入口共用一份，口径一致：
 * 首页库卡片菜单、库详情 ⋯ 菜单、条目详情工具栏。
 *
 * 写法约定（2026-08-04 用户反馈）：短导语 + 动作清单（bullets），
 * 用户语言、不用行话（"台账/刮削/介质规格"一律翻译成人话）；
 * 每份文案最后一条讲安全边界（会不会动我的文件）。只有「开始」需要
 * 确认；进行中的「停止」不设确认——停止本身就是在纠正一个重操作。
 */

export function scanLibraryConfirm(name: string, cloudTitles: string[] = []): ConfirmOptions {
  const t = appTranslator();
  // 挂了网盘目录的库：扫描顺带把网盘目录重新列一次（cloud-storage.md §4.3）
  const cloud = formatList([...new Set(cloudTitles)]);
  return {
    title: t("library.confirm.scanTitle", { name }),
    description: t("library.confirm.scanIntro"),
    bullets: [
      t("library.confirm.scanNew"),
      t("library.confirm.scanMissing"),
      ...(cloud ? [t("library.confirm.cloudListing", { cloud })] : []),
      t("library.confirm.scanMetadata"),
      t("library.confirm.scanProbe"),
      cloud ? t("library.confirm.scanSafeCloud") : t("library.confirm.scanSafe"),
    ],
    confirmLabel: t("library.confirm.startScan"),
  };
}

export function refreshLibraryConfirm(name: string): ConfirmOptions {
  const t = appTranslator();
  return {
    title: t("library.confirm.refreshLibraryTitle", { name }),
    description: t("library.confirm.refreshLibraryIntro"),
    bullets: [
      t("library.confirm.refreshDetails"),
      t("library.confirm.refreshArtwork"),
      t("library.confirm.syncSidecars"),
      t("library.confirm.refreshTime"),
      t("library.confirm.videoSafe"),
    ],
    confirmLabel: t("library.confirm.startRefresh"),
  };
}

export function refreshItemConfirm(title: string, locale?: AppLocale): ConfirmOptions {
  const t = appTranslator(locale);
  return {
    title: t("library.confirm.refreshItemTitle", { title }),
    description: t("library.confirm.refreshItemIntro"),
    bullets: [
      t("library.confirm.refreshItemDetails"),
      t("library.confirm.refreshItemArtwork"),
      t("library.confirm.syncSidecars"),
      t("library.confirm.itemSafe"),
    ],
    confirmLabel: t("library.confirm.refresh"),
  };
}

/** 其他库（家庭录像这类本地视频）没有刮削链：「刷新」是重读视频旁的 NFO + 重新生成封面，
 *  不联网——TMDB 那套文案放在这里既不对、也吓人。 */
export function rereadLibraryNfoConfirm(name: string): ConfirmOptions {
  const t = appTranslator();
  return {
    title: t("library.confirm.readLibraryTitle", { name }),
    description: t("library.confirm.readLibraryIntro"),
    bullets: [
      t("library.confirm.readNfo"),
      t("library.confirm.nfoCollections", { tag: "<set>" }),
      t("library.confirm.regenerateCover"),
      t("library.confirm.readSafe"),
    ],
    confirmLabel: t("library.confirm.startRead"),
  };
}

export function rereadItemNfoConfirm(title: string, locale?: AppLocale): ConfirmOptions {
  const t = appTranslator(locale);
  return {
    title: t("library.confirm.readItemTitle", { title }),
    description: t("library.confirm.readItemIntro"),
    bullets: [
      t("library.confirm.readNfo"),
      t("library.confirm.regenerateCover"),
      t("library.confirm.readItemSafe"),
    ],
    confirmLabel: t("library.confirm.read"),
  };
}

/** 整库生成章节：默认只补缺（跳过已经抓齐的文件），勾选项决定是否全部重做
 *  （force）。一个菜单入口 + 弹窗内开关，与「刷新元数据」的交互保持一致。 */
export function chapterImagesConfirm(name: string): ConfirmOptions & { checkbox: ConfirmCheckbox } {
  const t = appTranslator();
  return {
    title: t("library.confirm.chaptersTitle", { name }),
    description: t("library.confirm.chaptersIntro"),
    bullets: [
      t("library.confirm.chaptersMissing"),
      t("library.confirm.chaptersReads"),
      t("library.confirm.videoSafe"),
    ],
    checkbox: {
      label: t("library.confirm.chaptersForce"),
      description: t("library.confirm.chaptersForceHint"),
    },
    confirmLabel: t("library.confirm.startChapters"),
  };
}
