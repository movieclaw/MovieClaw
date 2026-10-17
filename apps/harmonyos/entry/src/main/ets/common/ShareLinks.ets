/**
 * 分享链接的纯逻辑（照 iOS `ShareLinkKit`，同 Web `lib/share.ts`）：
 * 链接补全、复制文本、到期提示、深链 slug 解析。
 *
 * 媒体库的分享对话框（`ShareSheet`）里有一份私有实现；这里给访客页用，口径逐字相同。
 */

/** 相对 `/s/{slug}` → 绝对地址（后端未配置外部访问地址时只给相对路径） */
export function shareAbsoluteUrl(url: string, origin: string): string {
  const lower: string = url.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return url;
  }
  let base: string = origin;
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return url.startsWith('/') ? base + url : base + '/' + url;
}

/** 「复制链接和密码」：一段可以直接粘进聊天框的话 */
export function shareCopyText(title: string, url: string, password: string): string {
  const parts: string[] = [`《${title}》`, `链接：${url}`];
  if (password.length > 0) {
    parts.push(`密码：${password}`);
  }
  return parts.join(' ');
}

/** 到期提示：「N 天后失效」/「N 小时后失效」/「N 分钟后失效」/「已失效」 */
export function shareExpiryHint(expiresAt: string): string {
  const date: Date = new Date(expiresAt);
  if (isNaN(date.getTime())) {
    return '已失效';
  }
  const remaining: number = (date.getTime() - Date.now()) / 1000;
  if (remaining <= 0) {
    return '已失效';
  }
  const hours: number = remaining / 3600;
  if (hours >= 47) {
    return `${Math.round(hours / 24)} 天后失效`;
  }
  if (hours >= 1) {
    return `${Math.floor(hours)} 小时后失效`;
  }
  return `${Math.max(1, Math.floor(remaining / 60))} 分钟后失效`;
}

/** 从深链 uri（`https://host/s/{slug}` 或 `/s/{slug}`）里解析 slug；不是分享链接返回空 */
export function slugFromWantUri(uri: string): string {
  const index: number = uri.indexOf('/s/');
  if (index < 0) {
    return '';
  }
  let slug: string = uri.substring(index + 3);
  const query: number = slug.indexOf('?');
  if (query >= 0) {
    slug = slug.substring(0, query);
  }
  const slash: number = slug.indexOf('/');
  if (slash >= 0) {
    slug = slug.substring(0, slash);
  }
  return slug;
}

/**
 * 深链中转：EntryAbility 在 onCreate/onNewWant 里拿到 want 的分享地址后调
 * `handOff`，主界面就绪后由 MainTabsPage 消费（`takePending`）并把访客页推上当前页签。
 */
@ObservedV2
export class ShareRouter {
  private static instance: ShareRouter | null = null;

  static shared(): ShareRouter {
    if (ShareRouter.instance === null) {
      ShareRouter.instance = new ShareRouter();
    }
    return ShareRouter.instance;
  }

  /** 待打开的分享 slug；空表示没有深链在等 */
  @Trace pendingSlug: string = '';

  handOff(slug: string): void {
    if (slug.length > 0) {
      this.pendingSlug = slug;
    }
  }

  /** 消费掉待打开的 slug（MainTabsPage 推入访客页后调用） */
  takePending(): string {
    const slug: string = this.pendingSlug;
    this.pendingSlug = '';
    return slug;
  }
}

/**
 * 各页签导航栈注册表：MainTabsPage 要把深链访客页推到**当前页签**的栈上（iOS 同款行为），
 * 但每个 NavHost 的 NavPathStack 是自己的成员，所以让各 NavHost 就绪时来这里登记。
 */
export class NavStacks {
  private static stacks: Record<string, NavPathStack> = {};

  /** 当前可见页签的键（媒体库/订阅/发现/活动/我的）；MainTabsPage 维护 */
  static currentKey: string = '媒体库';

  static register(tab: string, stack: NavPathStack): void {
    NavStacks.stacks[tab] = stack;
  }

  static of(tab: string): NavPathStack | null {
    const stack: NavPathStack | undefined = NavStacks.stacks[tab];
    if (stack !== undefined) {
      return stack;
    }
    // 该页签还没建过（理论上可见页签必已注册）：退回第一个登记过的栈，保证深链不丢
    const keys: string[] = Object.keys(NavStacks.stacks);
    for (const key of keys) {
      const fallback: NavPathStack | undefined = NavStacks.stacks[key];
      if (fallback !== undefined) {
        return fallback;
      }
    }
    return null;
  }
}
