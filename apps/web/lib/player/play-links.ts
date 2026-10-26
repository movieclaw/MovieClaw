/**
 * 播放页地址与「退出回到哪」的约定（docs/design/web-player.md §6.10）。
 *
 * 地址就是分享凭证：只带 media_item_id（以 (kind, tmdb_id) 为锚，比库自增
 * id 稳定）+ sXXeYY 季集段 + 可选 `?t=` 秒。**导航状态（returnTo）永不进
 * 地址**——那是点进来的人的上下文，不是内容标识：分享出去的链接带着它，
 * 接收者退出播放会被送进分享者当时的页面（可能无权访问），地址还又长又丑。
 * 它走 sessionStorage：同一浏览器标签内有效，链接接收者自然回条目页兜底。
 */

/** sXXeYY（大小写不敏感）。解析不动就当电影播——地址是人手打的，别苛刻。 */
const UNIT_PATTERN = /^s(\d{1,3})e(\d{1,4})$/i;

export function parseUnitSegment(segment: string | undefined): {
  season: number;
  episode: number;
} | null {
  const match = segment?.match(UNIT_PATTERN) ?? null;
  if (!match) return null;
  return { season: Number(match[1]), episode: Number(match[2]) };
}

/** 生成播放页地址。季集号补零是媒体库的通用写法（s01e03），别自创。 */
export function playHref(
  mediaItemId: number,
  options?: {
    season?: number;
    episode?: number;
    tSeconds?: number;
    /** 用户在详情页明确选中的版本：播放页锁定该文件起播（跳过自动择优）。
     * 默认高亮的第一个版本不是选择，别传——见 pickedVersionFileId */
    fileId?: number;
  },
): string {
  const { season, episode, tSeconds, fileId } = options ?? {};
  let href = `/play/${mediaItemId}`;
  if (season !== undefined && episode !== undefined) {
    href += `/s${String(season).padStart(2, "0")}e${String(episode).padStart(2, "0")}`;
  }
  const query: string[] = [];
  if (tSeconds !== undefined && tSeconds > 0) {
    query.push(`t=${Math.floor(tSeconds)}`);
  }
  if (fileId !== undefined && fileId > 0) {
    query.push(`file=${fileId}`);
  }
  if (query.length > 0) href += `?${query.join("&")}`;
  return href;
}

/**
 * 详情页点播放要不要锁定文件（`playHref` 的 `fileId`）：只有用户**亲手**在版本选择器里选过、
 * 且这个版本属于当前播放单元才锁，否则 undefined——让服务端按择优选版。
 *
 * 版本选择器没人碰过时默认高亮列表里的第一个版本，那不是用户的选择。把它也锁住会让服务端
 * 跳过择优：服务端本来会按观看场景（内外网、播放器能力）挑最合适的版本，锁住第一个之后
 * 从详情页点播放就永远用不上它。剧集切集后上一集选过的版本不在当前集的文件里，同样不锁。
 */
export function pickedVersionFileId(
  selectedFileId: number | null,
  availableFileIds: readonly number[],
): number | undefined {
  return selectedFileId !== null && availableFileIds.includes(selectedFileId)
    ? selectedFileId
    : undefined;
}

/**
 * 播放页 `?file=` 的锁定只对**进入播放页的那一集**生效，别的集回到自动择优。
 *
 * 自动连播 / 点「下一集」只是换 unit、不重新导航，`lockedFileId` 这个 prop 在整个播放页
 * 生命周期里一直都在；而服务端 `file_id` 的优先级高于 `media_item_id + 季集`，不按集收口就会
 * 拿第 1 集的文件去请求第 2 集（界面与进度按第 2 集走，实际又播了一遍第 1 集）。
 * 同一集里 seek / 换轨 / 降档重开会话照旧锁定；切回进入时的那一集也照旧锁定。
 */
export function lockedFileForUnit(
  unitKey: string,
  entryUnitKey: string,
  lockedFileId: number | undefined,
): number | undefined {
  return unitKey === entryUnitKey ? lockedFileId : undefined;
}

const RETURN_KEY = "movieclaw.player.return-to";

/** 进播放页前记下「从哪来」。只收站内路径——防开放跳转。 */
export function rememberPlayerReturnPath(path: string): void {
  if (!path.startsWith("/")) return;
  try {
    window.sessionStorage.setItem(RETURN_KEY, path);
  } catch {
    // 隐私模式写不进：退出走条目页兜底，不算错误
  }
}

/**
 * 最近一次「点播放」的时刻（`performance.now()`）。站内跳转不换页面，时间原点不变，
 * 播放页据此把起播计时的起点对到用户点下去的那一刻（含跳路由、挂载），与 iOS 同一口径。
 */
let playIntentAt: number | null = null;

/** 播放键被点下：记下时刻（紧接着 `router.push` 进播放页） */
export function markPlayIntent(): void {
  playIntentAt = performance.now();
}

/** 取走点播放的时刻，只给紧接着的那次起播用；超过 10 秒没被取走视为过期（用户中途去了别处） */
export function consumePlayIntent(): number | null {
  const at = playIntentAt;
  playIntentAt = null;
  if (at === null || performance.now() - at > 10_000) return null;
  return at;
}

/** 退出播放时读「回哪去」；没有（直开链接 / 隐私模式）返回 null 走兜底。 */
export function playerReturnPath(): string | null {
  try {
    const value = window.sessionStorage.getItem(RETURN_KEY);
    return value && value.startsWith("/") ? value : null;
  } catch {
    return null;
  }
}
